import 'dart:convert';

import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

/// Clients tried in order - the next one is used only if the previous fails
const fallbackClients = [YoutubeApiClient.visionOs, YoutubeApiClient.android];

// Client that produced the stream URL of each song, so playback can send
// the matching headers.
final Map<String, YoutubeApiClient> _songClients = {};

/// Region-locked YouTube Music tracks mapped to a playable upload of the same
/// song (Muzika). Official "- Topic" art tracks are licensed per country and
/// are UNPLAYABLE from Ethiopia, while regular uploads usually are not.
final Map<String, String> _substitutes = {};

/// Streams of an upload [_findPlayableSubstitute] just checked, until the
/// song that needed it takes them (so they're looked up once, not twice).
final Map<String, StreamManifest> _checkedManifests = {};

/// The upload playing in place of [songId] when it is blocked here.
String? substituteFor(String songId) => _substitutes[songId];

/// A song from Deezer's or Apple's catalog: no video of its own, its audio
/// is the YouTube upload found for it.
bool _isCatalogSong(String songId) =>
    songId.startsWith('deezer-') || songId.startsWith('itunes-');

/// The YouTube video behind [songId]: for a song from Apple's catalog, the
/// upload found for it once it played (related songs, skip segments).
String youtubeIdOf(String songId) => _isCatalogSong(songId)
    ? _substitutes[songId] ?? _storedSubstitute(songId) ?? songId
    : songId;

/// Catalog metadata for songs we already know, so finding a substitute does
/// not need an extra request for the original video's details.
final Map<String, ({String title, String artist, Duration? duration})>
_songHints = {};

/// Looks up what a song is when nothing registered it (a song from Apple's
/// catalog, downloaded or played after the app restarted).
Future<({String title, String artist, Duration? duration})?> Function(
  String songId,
)?
loadSongHint;

void registerSongHint(
  String videoId, {
  required String title,
  required String artist,
  Duration? duration,
}) {
  _songHints[videoId] = (title: title, artist: artist, duration: duration);
}

/// [registerSongHint] from a song map, wherever it came from (history,
/// playlists, Discover…): without it a blocked song can't look for a
/// playable copy, because YouTube won't describe a blocked video either.
void registerSongHintFrom(Map? song) {
  final id = song?['ytid']?.toString() ?? '';
  final title = song?['title']?.toString() ?? '';
  if (id.isEmpty || title.isEmpty || _songHints.containsKey(id)) return;
  final raw = song!['duration'];
  final seconds = raw is num ? raw.toInt() : int.tryParse('$raw');
  registerSongHint(
    id,
    title: title,
    artist: '${song['artist'] ?? ''}'.trim(),
    duration: seconds == null || seconds <= 0
        ? null
        : Duration(seconds: seconds),
  );
}

Future<StreamManifest> getManifestWithFallback(
  YoutubeExplode yt,
  String songId, {
  required Duration timeout,
}) async {
  // A song that was region-locked before goes straight to its substitute.
  final known = _substitutes[songId] ?? _storedSubstitute(songId);
  if (known != null) {
    try {
      final manifest = await _manifestFromClients(yt, known, timeout: timeout);
      _songClients[songId] = _songClients[known] ?? fallbackClients.first;
      return manifest;
    } catch (_) {
      _forgetSubstitute(songId); // the upload went away; look again
    }
  }

  // A song from Apple's catalog has no video of its own: the upload found
  // for it is what plays.
  if (_isCatalogSong(songId)) {
    final found = await _findPlayableSubstitute(yt, songId, timeout);
    if (found == null) {
      throw VideoUnavailableException('No YouTube upload for "$songId"');
    }
    final manifest =
        _checkedManifests.remove(found) ??
        await _manifestFromClients(yt, found, timeout: timeout);
    _rememberSubstitute(songId, found);
    _songClients[songId] = _songClients[found] ?? fallbackClients.first;
    return manifest;
  }

  // Catalog songs are often region-locked "- Topic" tracks: look for a
  // substitute at the same time instead of after the first attempt fails.
  final speculative = _songHints.containsKey(songId)
      ? _findPlayableSubstitute(yt, songId, timeout)
      : null;
  try {
    return await _manifestFromClients(yt, songId, timeout: timeout);
  } on VideoUnplayableException catch (e, s) {
    final substitute =
        await (speculative ?? _findPlayableSubstitute(yt, songId, timeout));
    if (substitute == null) Error.throwWithStackTrace(e, s);
    final manifest =
        _checkedManifests.remove(substitute) ??
        await _manifestFromClients(yt, substitute, timeout: timeout);
    _rememberSubstitute(songId, substitute);
    _songClients[songId] = _songClients[substitute] ?? fallbackClients.first;
    return manifest;
  }
}

/// Finds the YouTube upload of a song from Deezer's or Apple's catalog
/// ahead of time (Muzika: the songs waiting in the queue), so playing it
/// skips the search. Kept for good; if the upload is gone when it plays,
/// another is found then. True when a match was found now.
Future<bool> prematchCatalogSong(YoutubeExplode yt, String songId) async {
  if (!_isCatalogSong(songId)) return false;
  if (_substitutes[songId] != null || _storedSubstitute(songId) != null) {
    return false;
  }
  final found = await _findPlayableSubstitute(
    yt,
    songId,
    const Duration(seconds: 20),
    check: false,
  );
  if (found == null) return false;
  _rememberSubstitute(songId, found);
  return true;
}

String? _storedSubstitute(String songId) {
  try {
    final value = Hive.box('cache').get('subst:v3:$songId');
    if (value is String && value.isNotEmpty)
      return _substitutes[songId] = value;
  } catch (_) {}
  return null;
}

void _rememberSubstitute(String songId, String substitute) {
  _substitutes[songId] = substitute;
  try {
    Hive.box('cache').put('subst:v3:$songId', substitute);
  } catch (_) {}
}

void _forgetSubstitute(String songId) {
  _substitutes.remove(songId);
  try {
    Hive.box('cache').delete('subst:v3:$songId');
  } catch (_) {}
}

Future<StreamManifest> _manifestFromClients(
  YoutubeExplode yt,
  String songId, {
  required Duration timeout,
}) async {
  Object? lastError;
  StackTrace? lastStack;

  for (final client in fallbackClients) {
    try {
      final manifest = await yt.videos.streams
          .getManifest(songId, ytClients: [client])
          .timeout(timeout);
      if (manifest.audioOnly.isEmpty) {
        throw VideoUnavailableException('No audio streams for "$songId"');
      }
      _songClients[songId] = client;
      return manifest;
    } on VideoUnplayableException {
      // Unplayable is decided per video and country, not per client.
      rethrow;
    } catch (e, s) {
      lastError = e;
      lastStack = s;
    }
  }

  Error.throwWithStackTrace(lastError!, lastStack!);
}

/// Finds another upload of the same song: same title words, an artist match,
/// and a duration within 20 seconds. Returns its video id, or null.
Future<String?> _findPlayableSubstitute(
  YoutubeExplode yt,
  String songId,
  Duration timeout, {
  bool check = true,
}) async {
  final cached = _substitutes[songId];
  if (cached != null) return cached;

  try {
    var hint = _songHints[songId];
    if (hint == null && _isCatalogSong(songId)) {
      hint = await loadSongHint?.call(songId);
      if (hint != null) _songHints[songId] = hint;
    }
    String artist;
    String title;
    Duration? duration;
    if (hint != null) {
      (title: title, artist: artist, duration: duration) = hint;
      // Artist pages list songs without their length; YouTube still
      // describes a blocked video, length included.
      for (
        var attempt = 0;
        duration == null && attempt < 2 && !_isCatalogSong(songId);
        attempt++
      ) {
        try {
          duration = (await yt.videos.get(songId).timeout(timeout)).duration;
        } catch (_) {}
      }
    } else if (_isCatalogSong(songId)) {
      return null; // nothing known about it to search with
    } else {
      final original = await yt.videos.get(songId).timeout(timeout);
      artist = original.author.replaceAll(RegExp(r'\s*-\s*Topic$'), '');
      title = original.title;
      duration = original.duration;
    }
    // Uploads seldom name the featured artist: "Babure (feat. Sleshi
    // Demssie)" is just "Babure" there.
    title = title
        .replaceAll(
          RegExp(
            r'\s*[\(\[]\s*(feat|ft)\.?[^\)\]]*[\)\]]',
            caseSensitive: false,
          ),
          '',
        )
        .replaceAll(RegExp(r'\s+(feat|ft)\.?\s.*$', caseSensitive: false), '')
        .trim();

    // The small search first; the library's, which reads the whole results
    // page, only when it finds nothing.
    final results = await _quickSearch('$artist $title', timeout)
        .catchError((_) => <_Found>[])
        .then(
          (found) async => found.isNotEmpty
              ? found
              : [
                  for (final v
                      in await yt.search
                          .search('$artist $title')
                          .timeout(timeout))
                    (
                      id: v.id.value,
                      title: v.title,
                      author: v.author,
                      duration: v.duration,
                      isLive: v.isLive,
                    ),
                ],
        );

    String norm(String s) =>
        s.toLowerCase().replaceAll(RegExp('[^a-z0-9ሀ-፿]+'), ' ').trim();
    // Amharic titles are spelt many ways in Latin letters ("Yefikr Mrchay",
    // "Yefkr Mirchaye", "Yefikir Mirchaye"): compare the consonants.
    // Sounds written two ways count as one: "Ephrem" / "Efrem",
    // "Tsegaye" / "Tzegaye", "Qal" / "Kal".
    String skeleton(String w) => w
        .replaceAll('ph', 'f')
        .replaceAll('tz', 'ts')
        .replaceAll('q', 'k')
        .replaceAll(RegExp('[aeiouy]'), '')
        .replaceAllMapped(RegExp(r'(.)\1+'), (m) => m[1]!);
    bool hasWord(Set<String> hay, String joined, String word) {
      if (hay.contains(word)) return true;
      if (!RegExp(r'^[a-z0-9]+$').hasMatch(word)) return false;
      final s = skeleton(word);
      if (s.length < 2) return true; // "a", "ye": too short to tell apart
      if (hay.any((h) => skeleton(h) == s)) return true;
      // Spaced differently: "Endegebsu" vs "Ende Gebsu".
      return s.length >= 4 && skeleton(joined).contains(s);
    }

    final titleWords = norm(title).split(' ').where((w) => w.isNotEmpty);
    final shortTitle = titleWords.every((w) => skeleton(w).length < 2);
    // How a title sounds, its "y" kept: Apple's "Baybay" and the upload's
    // "Bye Bye" are both "byby".
    String sound(String s) =>
        norm(s)
            .replaceAll(RegExp('[^a-z]'), '')
            .replaceAll(RegExp('[aeiou]'), '')
            .replaceAllMapped(RegExp(r'(.)\1+'), (m) => m[1]!);
    final titleSound = sound(title);
    final artistKey = norm(artist);
    final artistFirst = artistKey.split(' ').first;

    // A live take, a TV show, a cover or a remix isn't the song that was
    // picked (unless the picked song is one itself).
    final notTheRecording = RegExp(
      r'\b(live|concert|session|sessions|tour|festival|show|performance|'
      'performs|unplugged|acoustic|cover|remix|karaoke|instrumental|'
      'sped up|slowed|reverb|8d|nightcore|reaction|tiny desk|glastonbury|'
      r'jools|ellen|tonight show|snl)\b',
      caseSensitive: false,
    );
    final originalIsLive = notTheRecording.hasMatch(title);
    // Channel names drop spaces and "the": "florencemachine" is
    // "Florence + The Machine".
    String compact(String s) =>
        norm(s).replaceAll(RegExp(r'\bthe\b'), '').replaceAll(' ', '');
    final artistCompact = compact(artist);

    final ranked = <({String id, int score})>[];
    for (final video in results.take(10)) {
      if (video.id == songId || video.isLive) continue;
      if (!originalIsLive && notTheRecording.hasMatch(video.title)) continue;
      final text = norm('${video.title} ${video.author}');
      final words = text.split(' ').toSet();
      final joined = text.replaceAll(' ', '');
      if (!titleWords.every((w) => hasWord(words, joined, w))) continue;
      final d = video.duration;
      final off = duration != null && d != null
          ? (d - duration).inSeconds.abs()
          : null;
      // A title of only short words ("La La") matches anything by sound:
      // the video's title has to carry it as written, or spelt another way
      // that sounds the same ("Baybay", "Bye Bye") by the artist at the
      // same length.
      if (shortTitle &&
          !' ${norm(video.title)} '.contains(' ${norm(title)} ') &&
          !(titleSound.length >= 3 &&
              sound(video.title).contains(titleSound) &&
              artistFirst.isNotEmpty &&
              hasWord(words, joined, artistFirst) &&
              off != null &&
              off <= 8)) {
        continue;
      }
      // The artist may be credited another way (a band's singer: "Tadele
      // Roba" for "Lafonte"); then the same title at about the same length
      // is needed. With the artist named, another edit of the song (up to
      // 45 s apart) beats silence; closer lengths still rank first.
      final named = artistFirst.isEmpty || hasWord(words, joined, artistFirst);
      if (off != null && off > (named ? 45 : 8)) continue;
      if (!named && off == null) continue;
      // Another official release first (often the same track, licensed
      // differently), an upload as long as the album track, then the
      // artist's own channel and audio uploads before videos.
      final title0 = video.title.toLowerCase();
      final channel = compact(video.author);
      final score =
          (video.author.endsWith('- Topic') ? 6 : 0) +
          (artistCompact.isNotEmpty &&
                  (channel.contains(artistCompact) ||
                      artistCompact.contains(channel)) &&
                  !channel.contains('fan')
              ? 4
              : 0) +
          (title0.contains('official audio')
              ? 3
              : title0.contains('audio')
              ? 2
              : 0) +
          (title0.contains('official') ? 1 : 0) +
          // The same length as the album track matters most: a music video
          // with an intro or an ending throws the synced lyrics off.
          (off == null
              ? 0
              : off <= 2
              ? 6
              : off <= 5
              ? 2
              : 0);
      ranked.add((id: video.id, score: score));
    }
    ranked.sort((a, b) => b.score.compareTo(a.score));
    // Matched ahead (a queue's songs): the best one, checked when played.
    if (!check) return ranked.firstOrNull?.id;

    // The first one that actually plays here: a blocked copy is no use.
    // Its streams are kept, so playing it doesn't look them up again.
    for (final candidate in ranked.take(4)) {
      try {
        // A speculative lookup's copy may never be taken: don't pile up.
        if (_checkedManifests.length > 20) _checkedManifests.clear();
        _checkedManifests[candidate.id] = await _manifestFromClients(
          yt,
          candidate.id,
          timeout: timeout,
        );
        return candidate.id;
      } catch (_) {}
    }
  } catch (_) {}
  return null;
}

/// A video in YouTube's search results.
typedef _Found = ({
  String id,
  String title,
  String author,
  Duration? duration,
  bool isLive,
});

/// YouTube's video search as its own API answers it: about 25 KB, where
/// the results page the library reads is about 300 KB (seconds on a slow
/// line). Empty when it answers in a shape this doesn't know.
Future<List<_Found>> _quickSearch(String query, Duration timeout) async {
  final r = await http
      .post(
        Uri.parse(
          'https://www.youtube.com/youtubei/v1/search?prettyPrint=false',
        ),
        headers: const {'Content-Type': 'application/json'},
        body: jsonEncode({
          'query': query,
          'params': 'EgIQAQ%3D%3D', // videos only
          'context': {
            'client': {
              'clientName': 'WEB',
              'clientVersion': '2.20251020.01.00',
              'hl': 'en',
            },
          },
        }),
      )
      .timeout(timeout);
  if (r.statusCode != 200) return const [];
  final found = <_Found>[];
  void walk(Object? node) {
    if (node is List) {
      node.forEach(walk);
    } else if (node is Map) {
      final v = node['videoRenderer'];
      if (v is Map && v['videoId'] is String) {
        String text(Object? o) => o is Map
            ? '${o['simpleText'] ?? ((o['runs'] as List?)?.map((r) => (r as Map)['text']).join() ?? '')}'
            : '';
        // "5:35" or "1:02:03"; none while it's live.
        final length = text(v['lengthText']);
        Duration? duration;
        if (length.isNotEmpty) {
          var seconds = 0;
          for (final part in length.split(':')) {
            seconds = seconds * 60 + (int.tryParse(part) ?? 0);
          }
          duration = Duration(seconds: seconds);
        }
        found.add((
          id: v['videoId'] as String,
          title: text(v['title']),
          author: text(v['ownerText'] ?? v['longBylineText']),
          duration: duration,
          isLive: length.isEmpty,
        ));
        return;
      }
      node.values.forEach(walk);
    }
  }

  walk(jsonDecode(utf8.decode(r.bodyBytes)));
  return found;
}

/// Headers googlevideo.com expects for URLs minted by the client that served
/// [songId]; a mismatched User-Agent can cause HTTP 403.
Map<String, String> streamPlaybackHeaders(String? songId) {
  final client = _songClients[songId] ?? fallbackClients.first;
  final userAgent = client.payload['context']?['client']?['userAgent'];
  return {
    if (userAgent is String) 'user-agent': userAgent,
    for (final entry in client.headers.entries) entry.key: '${entry.value}',
  };
}
