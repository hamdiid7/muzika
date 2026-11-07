/*
 *     Copyright (C) 2026 Muzika contributors
 *
 *     Muzika is free software: you can redistribute it and/or modify
 *     it under the terms of the GNU General Public License as published by
 *     the Free Software Foundation, either version 3 of the License, or
 *     (at your option) any later version.
 *
 *     Muzika is distributed in the hope that it will be useful,
 *     but WITHOUT ANY WARRANTY; without even the implied warranty of
 *     MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *     GNU General Public License for more details.
 *
 *     You should have received a copy of the GNU General Public License
 *     along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:muzika/main.dart' show logger;
import 'package:path_provider/path_provider.dart';

/// Discover's clips on disk (Muzika): the newest 50 MB are kept, so a clip
/// seen before opens at once. Clips are fetched ahead of the scroll: the
/// next one whole, the few after it only their first half (about 15 of
/// their 30 seconds, as the file's index sits at the front), finished when
/// they become next. A clip plays from disk once it is whole, else it
/// streams.
class ClipCache {
  ClipCache._();

  static const _limit = 50 * 1024 * 1024;
  static const _parallel = 2;

  static Directory? _dir;
  static final _whole = <String, File>{};
  static final _jobs = <String, Future<void>>{};
  static final _waiting = <(String, bool, Completer<void>)>[];
  static int _running = 0;

  static Future<Directory> _folder() async {
    if (_dir != null) return _dir!;
    final temp = await getTemporaryDirectory();
    return _dir = await Directory(
      '${temp.path}${Platform.pathSeparator}muzika_clips',
    ).create(recursive: true);
  }

  static String _name(String url) =>
      url.hashCode.toUnsigned(32).toRadixString(16);

  /// The clip's file when it is on disk in full.
  static Future<File?> ready(String url) async {
    final known = _whole[url];
    if (known != null) return known;
    final dir = await _folder();
    final file = File('${dir.path}${Platform.pathSeparator}${_name(url)}.m4v');
    if (await file.exists() && await file.length() > 0) {
      // Used now: it moves to the back of the queue for trimming.
      unawaited(file.setLastModified(DateTime.now()).catchError((_) {}));
      return _whole[url] = file;
    }
    return null;
  }

  /// Fetches the clip: all of it, or with [half] only its first half (a
  /// later call without [half] finishes it). Calls for the same clip share
  /// the work; two downloads run at a time, in the order asked.
  static Future<void> fetch(String url, {bool half = false}) {
    final running = _jobs[url];
    if (running != null) {
      // A half download already queued is finished after it.
      return half ? running : running.then((_) => _queue(url, false));
    }
    return _queue(url, half);
  }

  static Future<void> _queue(String url, bool half) {
    final done = Completer<void>();
    _waiting.add((url, half, done));
    final job = done.future.whenComplete(() {
      unawaited(_jobs.remove(url));
    });
    _jobs[url] = job;
    _pump();
    return job;
  }

  static void _pump() {
    while (_running < _parallel && _waiting.isNotEmpty) {
      final (url, half, done) = _waiting.removeAt(0);
      _running++;
      unawaited(
        _download(url, half).then(done.complete).whenComplete(() {
          _running--;
          _pump();
        }),
      );
    }
  }

  static Future<void> _download(String url, bool half) async {
    if (await ready(url) != null) return;
    final dir = await _folder();
    final file = File('${dir.path}${Platform.pathSeparator}${_name(url)}.m4v');
    final part = File('${file.path}.part');
    try {
      final have = await part.exists() ? await part.length() : 0;
      final total = await _size(url);
      if (total == null) return;
      final want = half ? total ~/ 2 : total;
      if (have >= want) {
        if (!half) await part.rename(file.path);
        return;
      }
      final request = http.Request('GET', Uri.parse(url))
        ..headers['range'] = 'bytes=$have-${want - 1}';
      final response = await http.Client()
          .send(request)
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 206 && response.statusCode != 200) return;
      // A server that ignores the range sends the whole file from the start.
      final append = response.statusCode == 206 && have > 0;
      final sink = part.openWrite(
        mode: append ? FileMode.append : FileMode.write,
      );
      try {
        await response.stream.pipe(sink);
      } finally {
        await sink.close();
      }
      if (!half || response.statusCode == 200) {
        await part.rename(file.path);
        _whole[url] = file;
        unawaited(_trim(dir));
      }
    } catch (e) {
      logger.log('Clip download failed', error: e);
    }
  }

  static final _sizes = <String, int>{};

  static Future<int?> _size(String url) async {
    final known = _sizes[url];
    if (known != null) return known;
    try {
      final response = await http
          .head(Uri.parse(url))
          .timeout(const Duration(seconds: 15));
      final length = int.tryParse(response.headers['content-length'] ?? '');
      if (length != null && length > 0) _sizes[url] = length;
      return length;
    } catch (_) {
      return null;
    }
  }

  /// Keeps the newest clips within 50 MB.
  static Future<void> _trim(Directory dir) async {
    try {
      final files = [
        for (final e in await dir.list().toList())
          if (e is File && e.path.endsWith('.m4v')) (e, await e.stat()),
      ]..sort((a, b) => b.$2.modified.compareTo(a.$2.modified));
      var total = 0;
      for (final (file, stat) in files) {
        total += stat.size;
        if (total > _limit) {
          _whole.removeWhere((_, f) => f.path == file.path);
          await file.delete();
        }
      }
    } catch (_) {}
  }
}
