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
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:muzika/services/youtube_canvas.dart';

/// A story's clip kept on disk: its picture and its sound, each a small
/// MP4 of just the slice that plays.
typedef StoryClip = ({File video, File? audio});

final _inFlight = <String, Future<StoryClip?>>{};

/// The [length] of [videoId] from [start], saved to disk the first time
/// (only those seconds are downloaded) and played from there after: a story
/// seen again uses no data. Null when the video can't be cut so (it isn't
/// an MP4 with an index); then it streams.
Future<StoryClip?> storyClip(String videoId, Duration start, Duration length) {
  return _inFlight[videoId] ??= _clip(
    videoId,
    start,
    length,
  ).whenComplete(() => _inFlight.remove(videoId));
}

/// The clip of [videoId] when it's on disk already (nothing downloaded).
Future<StoryClip?> savedStoryClip(String videoId) async {
  final dir = await _dir();
  final video = File('${dir.path}/${videoId}_v.mp4');
  if (!video.existsSync() || video.lengthSync() == 0) return null;
  unawaited(video.setLastModified(DateTime.now()).catchError((_) {}));
  final audio = File('${dir.path}/${videoId}_a.m4a');
  return (video: video, audio: audio.existsSync() ? audio : null);
}

Future<StoryClip?> _clip(
  String videoId,
  Duration start,
  Duration length,
) async {
  final dir = await _dir();
  final video = File('${dir.path}/${videoId}_v.mp4');
  final audio = File('${dir.path}/${videoId}_a.m4a');
  if (video.existsSync() && video.lengthSync() > 0) {
    // Seen before: from disk.
    unawaited(video.setLastModified(DateTime.now()).catchError((_) {}));
    return (video: video, audio: audio.existsSync() ? audio : null);
  }
  final streams = await youtubeStreamsFor(videoId, audio: true);
  if (streams == null) return null;
  final picture = await _slice(streams.video, streams.headers, start, length);
  if (picture == null) return null;
  final sound = streams.audio == null
      ? null
      : await _slice(streams.audio!, streams.headers, start, length);
  // Written whole or not at all, so a clip half-saved is never played.
  await _write(video, picture);
  if (sound != null) await _write(audio, sound);
  unawaited(_tidy(dir));
  return (video: video, audio: sound == null ? null : audio);
}

Future<void> _write(File file, Uint8List bytes) async {
  final part = File('${file.path}.part');
  await part.writeAsBytes(bytes, flush: true);
  await part.rename(file.path);
}

Directory? _clips;

Future<Directory> _dir() async {
  final kept = _clips;
  if (kept != null) return kept;
  final base = await getApplicationSupportDirectory();
  return _clips = await Directory('${base.path}/story_clips')
      .create(recursive: true);
}

/// Keeps the newest 60 clips (about 100 MB at most); stories older than
/// that have left the lists anyway.
Future<void> _tidy(Directory dir) async {
  try {
    final files =
        dir
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('_v.mp4'))
            .toList()
          ..sort(
            (a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()),
          );
    for (final old in files.skip(60)) {
      old.deleteSync();
      final sound = File(old.path.replaceFirst('_v.mp4', '_a.m4a'));
      if (sound.existsSync()) sound.deleteSync();
    }
  } catch (_) {}
}

/// The part of a fragmented MP4 (YouTube's streams) that holds [start] to
/// [start] + [length]: its header (ftyp, moov) and the fragments the index
/// (sidx) places there, as one playable file. Null when it has no index.
Future<Uint8List?> _slice(
  String url,
  Map<String, String> headers,
  Duration start,
  Duration length,
) async {
  final head = await _range(url, headers, 0, 65535);
  if (head == null) return null;
  final data = ByteData.sublistView(head);
  var at = 0;
  var headerEnd = -1;
  int? sidxAt;
  int? sidxSize;
  while (at + 8 <= head.length) {
    final size = data.getUint32(at);
    final type = String.fromCharCodes(head.sublist(at + 4, at + 8));
    if (size < 8) break;
    if (type == 'moov') headerEnd = at + size;
    if (type == 'sidx') {
      sidxAt = at;
      sidxSize = size;
      break;
    }
    at += size;
  }
  if (headerEnd < 0 || sidxAt == null || sidxSize == null) return null;
  if (sidxAt + sidxSize > head.length) return null;

  // sidx: version, flags, reference id, timescale, earliest time, first
  // offset, then (size, duration, …) per fragment.
  var p = sidxAt + 8;
  final version = data.getUint8(p);
  p += 4 + 4;
  final timescale = data.getUint32(p);
  p += 4;
  int earliest;
  int firstOffset;
  if (version == 0) {
    earliest = data.getUint32(p);
    firstOffset = data.getUint32(p + 4);
    p += 8;
  } else {
    earliest = data.getUint64(p);
    firstOffset = data.getUint64(p + 8);
    p += 16;
  }
  p += 2; // reserved
  final count = data.getUint16(p);
  p += 2;

  final from = start.inMilliseconds * timescale ~/ 1000;
  final to = (start + length).inMilliseconds * timescale ~/ 1000;
  var offset = sidxAt + sidxSize + firstOffset;
  var time = earliest;
  int? first;
  var last = -1;
  for (var i = 0; i < count; i++) {
    final size = data.getUint32(p) & 0x7fffffff;
    final duration = data.getUint32(p + 4);
    p += 12;
    final end = time + duration;
    if (end > from && time < to) {
      first ??= offset;
      last = offset + size - 1;
    }
    offset += size;
    time = end;
    if (time >= to) break;
  }
  if (first == null || last < first) return null;
  // A few MB at most: a 10 s slice.
  if (last - first > 12 * 1024 * 1024) return null;
  final body = await _range(url, headers, first, last);
  if (body == null) return null;
  return Uint8List.fromList([...head.sublist(0, headerEnd), ...body]);
}

Future<Uint8List?> _range(
  String url,
  Map<String, String> headers,
  int from,
  int to,
) async {
  final r = await http
      .get(Uri.parse(url), headers: {...headers, 'range': 'bytes=$from-$to'})
      .timeout(const Duration(seconds: 30));
  if (r.statusCode != 200 && r.statusCode != 206) return null;
  return r.bodyBytes;
}
