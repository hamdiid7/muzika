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
import 'package:image/image.dart' as img;
import 'package:muzika/constants/clients.dart';

import 'package:muzika/services/data_manager.dart';
import 'package:muzika/services/data_saver.dart';
import 'package:muzika/services/proxy_manager.dart' show ytClient;
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

/// A video to loop behind the player, the headers its server wants, and
/// where the loop starts (a third of the way in, where it has got going).
typedef CanvasVideo = ({
  String url,
  Map<String, String>? headers,
  Duration start,
});

/// A song's music video on YouTube: its id and length.
typedef MusicVideo = ({String id, Duration length});

/// The song's official music video on YouTube, or null when it has none
/// (Jaden's "Icon" has one; Eyob Mekonen's "Rekeda" only a still).
/// Lyric videos, audio uploads, "- Topic" stills, live takes and covers
/// don't count. Kept a month, the "none" too.
Future<MusicVideo?> musicVideoFor(Map song) async {
  final id = '${song['ytid'] ?? ''}';
  final title = '${song['title'] ?? ''}'.trim();
  final artist = '${song['artist'] ?? ''}'.split(RegExp('[,&]')).first.trim();
  if (id.isEmpty || title.isEmpty || artist.isEmpty) return null;

  // "videoId|seconds", or '' when the song has no music video.
  final key = 'yt_canvas_v4_$id';
  var found = await getData(
    'cache',
    key,
    cachingDuration: const Duration(days: 30),
  );
  if (found is! String) {
    found = await _findMusicVideo(title, artist, song['duration']) ?? '';
    unawaited(addOrUpdateData<String>('cache', key, found));
  }
  if (found.isEmpty) return null;
  final [videoId, seconds] = found.split('|');
  return (id: videoId, length: Duration(seconds: int.tryParse(seconds) ?? 0));
}

/// Where a slice of [length] starts in a video: a third of the way in,
/// where it has got going (the chorus, often), never past its end.
Duration sliceStart(Duration video, Duration length) {
  if (video <= length) return Duration.zero;
  final start = video * 0.33;
  return start + length > video ? video - length : start;
}

/// The video's streams: the picture (720p on Windows, 480p on a phone) and,
/// with [audio], its sound; and the headers their server wants. Kept four
/// hours (the addresses expire), so a video seen again starts at once.
Future<({String video, String? audio, Map<String, String> headers})?>
youtubeStreamsFor(String videoId, {bool audio = false}) async {
  final key = 'yt_streams_v1_${videoId}_${_height()}${audio ? '_a' : ''}';
  final kept = await getData(
    'cache',
    key,
    cachingDuration: const Duration(hours: 4),
  );
  if (kept is Map && kept['video'] is String) {
    return (
      video: kept['video'] as String,
      audio: kept['audio'] as String?,
      headers: {
        for (final e in ((kept['headers'] as Map?) ?? const {}).entries)
          '${e.key}': '${e.value}',
      },
    );
  }
  final manifest = await getManifestWithFallback(
    ytClient,
    videoId,
    timeout: const Duration(seconds: 15),
  );
  final video = _pick(manifest.videoOnly.toList())?.url.toString();
  if (video == null) return null;
  String? sound;
  if (audio) {
    // AAC (m4a) first: it plays everywhere.
    final tracks = manifest.audioOnly.toList()
      ..sort((a, b) {
        final mp4 =
            (b.container == StreamContainer.mp4 ? 1 : 0) -
            (a.container == StreamContainer.mp4 ? 1 : 0);
        return mp4 != 0
            ? mp4
            : b.bitrate.bitsPerSecond.compareTo(a.bitrate.bitsPerSecond);
      });
    sound = tracks.firstOrNull?.url.toString();
    if (sound == null) return null;
  }
  final headers = streamPlaybackHeaders(videoId);
  unawaited(
    addOrUpdateData('cache', key, {
      'video': video,
      'audio': sound,
      'headers': headers,
    }),
  );
  return (video: video, audio: sound, headers: headers);
}

/// The song's music video as a silent stream for the player's Canvas,
/// looped from a third of the way in.
Future<CanvasVideo?> youtubeCanvasFor(Map song) async {
  final found = await musicVideoFor(song);
  if (found == null) return null;
  final streams = await youtubeStreamsFor(found.id);
  if (streams == null) return null;
  return (
    url: streams.video,
    headers: streams.headers,
    start: sliceStart(found.length, const Duration(seconds: 20)),
  );
}

/// The video height wanted: 720p on Windows (sharp on the wide player),
/// 480p on a phone; 360p with the data saver on.
int _height() => dataSaverOn ? 360 : (Platform.isWindows ? 720 : 480);

/// [_height] in H.264 (mp4) first, which plays everywhere. Without that
/// height: the nearest below, else the smallest above.
VideoOnlyStreamInfo? _pick(List<VideoOnlyStreamInfo> streams) {
  final target = _height();
  int rank(VideoOnlyStreamInfo s) {
    final h = s.videoResolution.height;
    final mp4 = s.container == StreamContainer.mp4 ? 0 : 1;
    final distance = h == target
        ? 0
        : h < target
        ? 1 + (target - h)
        : 10000 + (h - target);
    return distance * 2 + mp4;
  }

  streams.sort((a, b) => rank(a).compareTo(rank(b)));
  return streams.firstOrNull;
}

String _key(String s) =>
    s.toLowerCase().replaceAll(RegExp('[^a-z0-9ሀ-፿]+'), '');

Future<String?> _findMusicVideo(
  String title,
  String artist,
  Object? duration,
) async {
  final bareTitle = title
      .replaceAll(RegExp(r'\s*[\(\[][^\)\]]*[\)\]]'), '')
      .replaceAll(RegExp(r'\s+(feat|ft)\.?\s.*$', caseSensitive: false), '')
      .trim();
  final wantedTitle = _key(bareTitle);
  final wantedArtist = _key(artist);
  final seconds = duration is num
      ? duration.toInt()
      : int.tryParse('${duration ?? ''}');
  final results = await ytClient.search.search(
    '$artist $bareTitle official video',
  );
  final notAVideo = RegExp(
    r'\b(lyrics?|lyric video|audio|visuali[sz]er|live|cover|karaoke|'
    'instrumental|reaction|remix|sped up|slowed|8d|parody|dance video|'
    r'track \d+|full album|legacy release)\b',
    caseSensitive: false,
  );
  final saysVideo = RegExp(
    r'(official\s+(music\s+)?video|music\s+video|\bmv\b|official\s+clip|'
    r'video\s+clip|ቪዲዮ ክሊፕ)',
    caseSensitive: false,
  );
  for (final v in results.take(10)) {
    if (v.author.endsWith(' - Topic')) continue;
    if (notAVideo.hasMatch(v.title)) continue;
    if (!_key(v.title).contains(wantedTitle)) continue;
    // The artist's own channel (or their VEVO), not a fan's re-upload.
    final channel = _key(v.author);
    final byArtist =
        channel.contains(wantedArtist) ||
        (channel.length >= 4 && wantedArtist.contains(channel)) ||
        channel.endsWith('vevo');
    if (!byArtist) continue;
    // A real video, not an album track posted with its cover as a still
    // (Eyob Mekonen's "Rekeda (Track 11)", 481 views): it says it's the
    // video and has been watched, or it's been watched a million times
    // ("Jaden - Icon" says nothing, 200 million views).
    final views = v.engagement.viewCount;
    final real =
        (saysVideo.hasMatch(v.title) && views >= 10000) || views >= 1000000;
    if (!real) continue;
    final length = v.duration?.inSeconds;
    // A video may add an intro or a scene; a different song won't fit.
    if (seconds != null && length != null && (length - seconds).abs() > 120) {
      continue;
    }
    // Lyric videos, visualizers and slow zooms on a photo hardly change.
    if (await _isStill(v.id.value)) continue;
    return '${v.id.value}|${length ?? 0}';
  }
  return null;
}

/// Whether the video is the same picture throughout: a lyric video, a
/// visualizer or a slow zoom on a photo. YouTube keeps three small frames
/// of every video (a quarter, half and three quarters in, 120×90, ~3 KB
/// each); greyed down to 16×12, a real video's frames differ by 30 or more
/// on average (Jaden "Icon" 32, Adele "Hello" 40), a still's by under 12
/// (Teddy Afro's lyric video 0.7, Eyob Mekonnen's photo zoom 11.6).
/// Unsure (no frames) counts as moving.
Future<bool> _isStill(String videoId) async {
  try {
    final frames = await Future.wait([
      for (final n in [1, 2, 3])
        http
            .get(Uri.parse('https://i.ytimg.com/vi/$videoId/$n.jpg'))
            .timeout(const Duration(seconds: 8)),
    ]);
    final grey = <List<int>>[];
    for (final r in frames) {
      if (r.statusCode != 200) return false;
      final decoded = img.decodeJpg(r.bodyBytes);
      if (decoded == null) return false;
      final small = img.copyResize(
        decoded,
        width: 16,
        height: 12,
        interpolation: img.Interpolation.average,
      );
      grey.add([for (final p in small) p.luminance.toInt()]);
    }
    var most = 0.0;
    for (final (a, b) in [(0, 1), (0, 2), (1, 2)]) {
      var sum = 0;
      for (var i = 0; i < grey[a].length; i++) {
        sum += (grey[a][i] - grey[b][i]).abs();
      }
      final diff = sum / grey[a].length;
      if (diff > most) most = diff;
    }
    return most < 18;
  } catch (_) {
    return false;
  }
}
