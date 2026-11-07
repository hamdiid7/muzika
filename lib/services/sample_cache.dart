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
import 'package:muzika/constants/clients.dart' show registerSongHintFrom;
import 'package:muzika/main.dart' show logger;
import 'package:muzika/services/common_services.dart';
import 'package:muzika/services/itunes_catalog.dart';
import 'package:muzika/services/proxy_manager.dart' show ytClient;
import 'package:path_provider/path_provider.dart';

/// Songs downloaded ahead for the games, so a turn starts from a local file
/// (opens at once, seeks at once) instead of a stream that takes seconds to
/// open, which on Windows is most of the wait. Apple's 30-second preview
/// when it has one (about 1 MB, see [isPreview]), else the whole song. Not
/// part of Offline: a temp folder that keeps the last [_keep] songs.
class SampleCache {
  SampleCache._();

  static const _keep = 60;
  static const _parallel = 2;

  static final _jobs = <String, Future<File?>>{};
  static final _ready = <String, File>{};
  static final _waiting = <(Map, Completer<File?>)>[];
  static int _running = 0;
  static Directory? _dir;

  static Future<Directory> _folder() async {
    if (_dir != null) return _dir!;
    final temp = await getTemporaryDirectory();
    return _dir = await Directory(
      '${temp.path}${Platform.pathSeparator}muzika_samples',
    ).create(recursive: true);
  }

  /// Whether [file] is Apple's preview (play it from the start) rather
  /// than the whole song.
  static bool isPreview(File file) => file.path.endsWith('.preview.m4a');

  /// The song's file if it is already downloaded.
  static File? ready(Map song) => _ready['${song['ytid']}'];

  /// Downloads [song] (once; later calls share the same download). Null
  /// when it can't be fetched.
  static Future<File?> fetch(Map song) {
    final id = '${song['ytid'] ?? ''}';
    if (id.isEmpty) return Future.value();
    return _jobs[id] ??= _queue(song);
  }

  /// Whether [song] is downloading or done, so a caller can wait for it.
  static bool started(Map song) => _jobs.containsKey('${song['ytid']}');

  static Future<File?> _queue(Map song) {
    final done = Completer<File?>();
    _waiting.add((song, done));
    _pump();
    return done.future;
  }

  static void _pump() {
    while (_running < _parallel && _waiting.isNotEmpty) {
      final (song, done) = _waiting.removeAt(0);
      _running++;
      unawaited(
        _download(song).then(done.complete).whenComplete(() {
          _running--;
          _pump();
        }),
      );
    }
  }

  static Future<File?> _download(Map song) async {
    final id = '${song['ytid']}';
    try {
      final dir = await _folder();
      // Kept from an earlier match?
      for (final ext in ['preview.m4a', 'webm', 'm4a', 'mp4']) {
        final f = File('${dir.path}${Platform.pathSeparator}$id.$ext');
        if (await f.exists() && await f.length() > 0) {
          return _ready[id] = f;
        }
      }
      final preview = await itunesPreviewFor(song);
      if (preview != null) {
        final response = await http
            .get(Uri.parse(preview))
            .timeout(const Duration(seconds: 20));
        if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
          final file = File(
            '${dir.path}${Platform.pathSeparator}$id.preview.m4a',
          );
          await file.writeAsBytes(response.bodyBytes);
          unawaited(_trim(dir));
          return _ready[id] = file;
        }
      }
      registerSongHintFrom(song);
      final stream = await fetchBestAudioStream(id);
      if (stream == null) return null;
      final ext = stream.container.name.toLowerCase();
      final file = File('${dir.path}${Platform.pathSeparator}$id.$ext');
      final part = File('${file.path}.part');
      final sink = part.openWrite();
      try {
        await ytClient.videos.streamsClient.get(stream).pipe(sink);
      } finally {
        await sink.close();
      }
      await part.rename(file.path);
      unawaited(_trim(dir));
      return _ready[id] = file;
    } catch (e) {
      logger.log('Sample download failed for $id', error: e);
      unawaited(_jobs.remove(id)); // try again next time
      return null;
    }
  }

  /// Keeps the newest [_keep] songs.
  static Future<void> _trim(Directory dir) async {
    try {
      final files = await dir
          .list()
          .where((e) => e is File && !e.path.endsWith('.part'))
          .cast<File>()
          .toList();
      if (files.length <= _keep) return;
      final dated = [for (final f in files) (f, await f.lastModified())]
        ..sort((a, b) => a.$2.compareTo(b.$2));
      for (final (f, _) in dated.take(files.length - _keep)) {
        _ready.removeWhere((_, v) => v.path == f.path);
        await f.delete();
      }
    } catch (_) {}
  }
}
