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
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show md5, sha256;
import 'package:flutter/foundation.dart' show ValueNotifier, compute;
import 'package:http/http.dart' as http;
import 'package:muzika/services/common_services.dart' show getSongLyrics;
import 'package:muzika/services/data_manager.dart';
import 'package:pointycastle/export.dart'
    show
        AESEngine,
        ECBBlockCipher,
        KeyParameter,
        PKCS7Padding,
        PaddedBlockCipherImpl,
        PaddedBlockCipherParameters;

/// One timed line of an LRC file.
class LyricLine {
  const LyricLine(this.time, this.text, {this.words});
  final Duration time;
  final String text;

  /// When each word is sung, from LRCLIB's word-timed ("enhanced") LRC
  /// (`[00:12.00]<00:12.00>Hello <00:12.40>world`) or NetEase; null for
  /// most songs.
  final List<LyricWord>? words;
}

/// A word of a line and when it's sung.
class LyricWord {
  const LyricWord(this.time, this.text);
  final Duration time;

  /// The word with the space after it, as written.
  final String text;
}

/// Lyrics for a song: time-synced lines when available, else plain text.
class SongLyrics {
  const SongLyrics({this.lines, this.plain, required this.source});

  final List<LyricLine>? lines;
  final String? plain;

  /// Shown under the lyrics, e.g. "LRCLIB".
  final String source;

  bool get isSynced => lines != null && lines!.isNotEmpty;

  /// Whether each word's time is known (not just each line's).
  bool get hasWordTimes => lines?.any((l) => l.words != null) ?? false;

  Map<String, dynamic> toJson() => {
    'lrc': lines == null ? null : _toLrc(lines!),
    'plain': plain,
    'source': source,
  };

  static SongLyrics? fromJson(Map json) {
    final lrc = json['lrc'] as String?;
    final plain = json['plain'] as String?;
    if (lrc == null && plain == null) return null;
    return SongLyrics(
      lines: lrc == null ? null : parseLrc(lrc),
      plain: plain,
      source: (json['source'] ?? '').toString(),
    );
  }
}

const _lrclib = 'https://lrclib.net/api';
const _userAgent = 'Muzika (GPL-3.0 music player; https://lrclib.net)';
const _cacheVersion = 'lyrics:v4';

final _lrcLine = RegExp(r'^\[(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?\](.*)$');

/// Parses LRC text into timed lines. Lines with several timestamps
/// (`[00:10.00][00:42.00]chorus`) produce one entry per timestamp.
List<LyricLine> parseLrc(String lrc) {
  final lines = <LyricLine>[];
  for (final raw in const LineSplitter().convert(lrc)) {
    var rest = raw.trim();
    final times = <Duration>[];
    while (true) {
      final m = _lrcLine.firstMatch(rest);
      if (m == null) break;
      final frac = m.group(3) ?? '0';
      final ms = int.parse(frac.padRight(3, '0').substring(0, 3));
      times.add(
        Duration(
          minutes: int.parse(m.group(1)!),
          seconds: int.parse(m.group(2)!),
          milliseconds: ms,
        ),
      );
      rest = m.group(4)!.trim();
    }
    final words = _parseWords(rest);
    final text = words == null ? rest : words.map((w) => w.text).join().trim();
    for (final t in times) {
      lines.add(LyricLine(t, text, words: words));
    }
  }
  lines.sort((a, b) => a.time.compareTo(b.time));
  return lines;
}

final _wordTag = RegExp(r'<(\d{1,3}):(\d{2})[.:](\d{1,3})>');

Duration _tagTime(RegExpMatch m) => Duration(
  minutes: int.parse(m.group(1)!),
  seconds: int.parse(m.group(2)!),
  milliseconds: int.parse(m.group(3)!.padRight(3, '0').substring(0, 3)),
);

/// The words of a word-timed line, or null when it has no word times.
List<LyricWord>? _parseWords(String line) {
  final tags = _wordTag.allMatches(line).toList();
  if (tags.isEmpty) return null;
  final words = <LyricWord>[];
  for (final (i, tag) in tags.indexed) {
    final end = i + 1 < tags.length ? tags[i + 1].start : line.length;
    final text = line.substring(tag.end, end);
    if (text.trim().isNotEmpty) words.add(LyricWord(_tagTime(tag), text));
  }
  return words.isEmpty ? null : words;
}

String _stamp(Duration t) {
  final m = t.inMinutes.toString().padLeft(2, '0');
  final s = (t.inSeconds % 60).toString().padLeft(2, '0');
  final cs = ((t.inMilliseconds % 1000) ~/ 10).toString().padLeft(2, '0');
  return '$m:$s.$cs';
}

String _toLrc(List<LyricLine> lines) => lines
    .map((l) {
      final words = l.words;
      final text = words == null
          ? l.text
          : words.map((w) => '<${_stamp(w.time)}>${w.text}').join();
      return '[${_stamp(l.time)}]$text';
    })
    .join('\n');

/// Shares lyrics someone timed in Muzika with everyone, on LRCLIB (no
/// account: LRCLIB asks for a small proof of work instead, solved here on
/// a background isolate, a few seconds to half a minute). True once LRCLIB
/// has them. Needs the song's length, as LRCLIB matches songs by it.
Future<bool> publishToLrclib({
  required String artist,
  required String title,
  required String? album,
  required Duration? duration,
  required List<LyricLine> lines,
}) async {
  if (duration == null || duration.inSeconds <= 0 || lines.isEmpty) {
    return false;
  }
  try {
    final headers = {'User-Agent': _userAgent};
    final challenge = await http
        .post(Uri.parse('$_lrclib/request-challenge'), headers: headers)
        .timeout(const Duration(seconds: 15));
    if (challenge.statusCode != 200) return false;
    final c = jsonDecode(challenge.body) as Map;
    final prefix = '${c['prefix']}';
    final nonce = await compute(_solveChallenge, (prefix, '${c['target']}'));
    final a = cleanArtistName(artist);
    final t = cleanTrackTitle(title);
    final sorted = [...lines]..sort((x, y) => x.time.compareTo(y.time));
    final r = await http
        .post(
          Uri.parse('$_lrclib/publish'),
          headers: {
            ...headers,
            'Content-Type': 'application/json',
            'X-Publish-Token': '$prefix:$nonce',
          },
          body: jsonEncode({
            'trackName': t,
            'artistName': a,
            'albumName': (album == null || album.trim().isEmpty)
                ? t
                : album.trim(),
            'duration': duration.inSeconds,
            'plainLyrics': sorted.map((l) => l.text).join('\n'),
            'syncedLyrics': _toLrc(sorted),
          }),
        )
        .timeout(const Duration(seconds: 20));
    return r.statusCode == 201 || r.statusCode == 200;
  } catch (_) {
    return false;
  }
}

/// LRCLIB's proof of work: the number that, after [challenge]'s prefix,
/// hashes (SHA-256) to at most its target.
int _solveChallenge((String, String) challenge) {
  final (prefix, targetHex) = challenge;
  final target = [
    for (var i = 0; i < targetHex.length; i += 2)
      int.parse(targetHex.substring(i, i + 2), radix: 16),
  ];
  final head = utf8.encode(prefix);
  for (var nonce = 0; ; nonce++) {
    final hash = sha256.convert([...head, ...utf8.encode('$nonce')]).bytes;
    var ok = true;
    for (var i = 0; i < target.length; i++) {
      if (hash[i] != target[i]) {
        ok = hash[i] < target[i];
        break;
      }
    }
    if (ok) return nonce;
  }
}

bool _hasWordTimes(Map r) => _wordTag.hasMatch('${r['syncedLyrics'] ?? ''}');

/// Removes video-title noise so LRCLIB matches the actual song.
String cleanTrackTitle(String title) {
  var t = title;
  t = t.replaceAll(
    RegExp(
      r'[\(\[][^\)\]]*(official|video|audio|lyric|visuali[sz]er|hd|4k|remaster|music video|clip)[^\)\]]*[\)\]]',
      caseSensitive: false,
    ),
    '',
  );
  t = t.replaceAll(RegExp(r'\s{2,}'), ' ');
  return t.trim();
}

String cleanArtistName(String artist) => artist
    .replaceAll(RegExp(r'\s*-\s*Topic$'), '')
    .replaceAll(RegExp(r'\s*(VEVO|Official)\b.*$', caseSensitive: false), '')
    .split(',')
    .first
    .trim();

/// Keeps lyrics the user timed themselves (touching each line as it's sung)
/// for the song, in place of what was found: [fetchSongLyrics] returns them
/// from now on.
Future<SongLyrics> saveTimedLyrics({
  required String artist,
  required String title,
  required List<LyricLine> lines,
  String? plain,
}) async {
  final a = cleanArtistName(artist);
  final t = cleanTrackTitle(title);
  final lyrics = SongLyrics(
    lines: [...lines]..sort((x, y) => x.time.compareTo(y.time)),
    plain: plain,
    source: 'you',
  );
  // Their own key, so a new cache version never drops them.
  await addOrUpdateData('cache', _mineKey(a, t), lyrics.toJson());
  return lyrics;
}

String _mineKey(String artist, String title) =>
    'lyrics:mine:${artist.toLowerCase()}|${title.toLowerCase()}';

/// Resolves once the song [ytid] has started (or isn't the one playing any
/// more), so its lyrics don't slow its start; set by the player.
Future<void> Function(String ytid)? untilSongStarted;

/// Fetches lyrics, best first:
/// 1. LRCLIB, matched loosely (spellings, "feat.", artist name variants),
///    when it has them word by word;
/// 2. NetEase's word-timed lyrics (most international hits, no Ethiopian
///    songs);
/// 3. LRCLIB timed line by line;
/// 4. YouTube Music's own lyrics when LRCLIB has nothing synced — for the
///    version being played and its other releases (one is often lyric-less);
/// 5. plain text from LRCLIB, YouTube Music or the web.
/// Results (including "not found") are cached so revisiting a song costs no
/// network. [background] lookups (Discover) use YouTube Music only while the
/// relay has requests to spare.
Future<SongLyrics?> fetchSongLyrics({
  required String artist,
  required String title,
  String? album,
  Duration? duration,
  String? videoId,
  bool background = false,
}) async {
  final a = cleanArtistName(artist);
  final t = cleanTrackTitle(title);
  final cacheKey = '$_cacheVersion:${a.toLowerCase()}|${t.toLowerCase()}';

  // Timed by the user: theirs first.
  final mine = await getData('cache', _mineKey(a, t));
  if (mine is Map) {
    final parsed = SongLyrics.fromJson(mine);
    if (parsed != null) return parsed;
  }
  final cached = await getData('cache', cacheKey);
  if (cached is Map) {
    final recent =
        DateTime.now().difference(
          DateTime.fromMillisecondsSinceEpoch(
            (cached['at'] as num?)?.toInt() ?? 0,
          ),
        ) <
        _recheckAfter;
    if (cached['none'] == true) {
      // None found: asked again when opened after half an hour (someone
      // may have added them since).
      if (recent) return null;
    } else {
      final parsed = SongLyrics.fromJson(cached);
      // Synced: kept for good.
      if (parsed != null && parsed.isSynced) return parsed;
      if (parsed != null) {
        // Plain: shown at once, and looked up again behind them (at most
        // every half hour), in case someone has timed them since.
        if (!recent && !background) {
          unawaited(_recheck(cacheKey, cached, a, t, album, duration, videoId));
        }
        return parsed;
      }
    }
  }
  // Not known yet: the song being started has the line first.
  if (!background && videoId != null) {
    await untilSongStarted?.call(videoId);
  }
  final found = await _lookUp(a, t, album, duration, videoId, background);
  if (found.keep) await _keep(cacheKey, found.lyrics);
  return found.lyrics;
}

/// Bumped when lyrics looked up again in the background came back better
/// (plain lyrics now synced): the lyrics showing load again.
final lyricsRefreshed = ValueNotifier<int>(0);

/// How long plain or missing lyrics go before they're looked up again.
const _recheckAfter = Duration(minutes: 30);

/// Saves [lyrics] for the song (with when, for plain or none: those are
/// looked up again later).
Future<void> _keep(String cacheKey, SongLyrics? lyrics) => addOrUpdateData(
  'cache',
  cacheKey,
  lyrics == null
      ? {'none': true, 'at': DateTime.now().millisecondsSinceEpoch}
      : lyrics.isSynced
      ? lyrics.toJson()
      : {...lyrics.toJson(), 'at': DateTime.now().millisecondsSinceEpoch},
);

/// Plain lyrics looked up again: kept (and shown) only if now synced.
Future<void> _recheck(
  String cacheKey,
  Map cached,
  String artist,
  String title,
  String? album,
  Duration? duration,
  String? videoId,
) async {
  // Marked first, so opening it again meanwhile doesn't ask twice.
  await addOrUpdateData('cache', cacheKey, {
    ...cached,
    'at': DateTime.now().millisecondsSinceEpoch,
  });
  final found = await _lookUp(artist, title, album, duration, videoId, false);
  final lyrics = found.lyrics;
  if (lyrics != null && lyrics.isSynced) {
    await _keep(cacheKey, lyrics);
    lyricsRefreshed.value++;
  }
}

/// The lookup itself (see [fetchSongLyrics]): the lyrics found, and whether
/// that's an answer to keep (not when LRCLIB was out of reach, or YouTube
/// Music was skipped).
Future<({SongLyrics? lyrics, bool keep})> _lookUp(
  String a,
  String t,
  String? album,
  Duration? duration,
  String? videoId,
  bool background,
) async {
  SongLyrics? lrclib;
  // LRCLIB busy or out of reach: "no lyrics" then isn't an answer to keep.
  var lrclibFailed = false;
  try {
    lrclib = await _fromLrclib(a, t, album, duration);
  } catch (_) {
    lrclibFailed = true;
  }
  // NetEase has no Ethiopian songs: those don't wait on it.
  if (!(lrclib?.hasWordTimes ?? false) &&
      !background &&
      !_ethiopic.hasMatch('$a$t')) {
    SongLyrics? netease;
    try {
      netease = await _fromNetEase(a, t, duration);
    } catch (_) {}
    if (netease != null) return (lyrics: netease, keep: true);
  }
  if (lrclib != null && lrclib.isSynced) return (lyrics: lrclib, keep: true);

  var result = lrclib;
  if (result == null) {
    // The web scrapers only ever have plain text.
    final plain = await getSongLyrics(a, t).catchError((_) => null);
    if (plain != null && plain.trim().isNotEmpty) {
      result = SongLyrics(plain: plain, source: 'web');
    }
  }
  // A lookup that couldn't reach LRCLIB isn't final.
  final keep = result != null || !lrclibFailed;
  return (lyrics: result, keep: keep);
}

// ---------------------------------------------------------------------------
// Loose matching (Amharic songs are spelt many ways in Latin letters)
// ---------------------------------------------------------------------------

String _plainName(String s) => s
    .toLowerCase()
    .replaceAll(RegExp(r'[\(\[][^\)\]]*[\)\]]'), ' ')
    .replaceAll(RegExp(r'\b(feat|ft|featuring)\b.*$'), ' ')
    .replaceAll(RegExp('[^a-z0-9ሀ-᎟]+'), '');

/// The consonants of a name: "Einde Wef", "Ende Wef" and "Endewef" agree,
/// and so do "Bezuayehu" and "Buzuayehu".
String _skeleton(String s) =>
    _plainName(s)
        .replaceAll(RegExp('[aeiouy]'), '')
        .replaceAllMapped(RegExp(r'(.)\1+'), (m) => m[1]!);

bool _sameTitle(String a, String b) {
  final x = _skeleton(a);
  final y = _skeleton(b);
  if (x.isEmpty || y.isEmpty) return false;
  if (x == y) return true;
  return x.length >= 4 && y.length >= 4 && (x.contains(y) || y.contains(x));
}

bool _sameArtist(String a, String b) {
  final x = _skeleton(a.split(RegExp('[,&]')).first);
  final y = _skeleton(b.split(RegExp('[,&]')).first);
  if (x.isEmpty || y.isEmpty) return true;
  String head(String s) => s.length > 4 ? s.substring(0, 4) : s;
  return x == y || head(x) == head(y) || x.contains(y) || y.contains(x);
}

bool _closeLength(Duration? want, num? seconds, {int slack = 6}) {
  if (want == null || seconds == null || want.inSeconds <= 0) return true;
  return (seconds - want.inSeconds).abs() <= slack;
}

// ---------------------------------------------------------------------------
// YouTube Music
// ---------------------------------------------------------------------------

Future<SongLyrics?> _fromLrclib(
  String artist,
  String title,
  String? album,
  Duration? duration,
) async {
  final headers = {'User-Agent': _userAgent};

  // 1. Exact signature match (fast, cached by LRCLIB).
  final exact = Uri.parse('$_lrclib/get').replace(
    queryParameters: {
      'artist_name': artist,
      'track_name': title,
      if (album != null && album.isNotEmpty) 'album_name': album,
      if (duration != null && duration.inSeconds > 0)
        'duration': '${duration.inSeconds}',
    },
  );
  final r1 = await http
      .get(exact, headers: headers)
      .timeout(const Duration(seconds: 10));
  // Busy (503) or limiting (429): not the same as "no lyrics".
  if (r1.statusCode == 429 || r1.statusCode >= 500) {
    throw Exception('LRCLIB ${r1.statusCode}');
  }
  SongLyrics? exactHit;
  if (r1.statusCode == 200) {
    final record = jsonDecode(r1.body) as Map;
    final hit = _fromRecord(record);
    if (hit != null && hit.isSynced) {
      if (_hasWordTimes(record)) return hit;
      // Synced line by line: still look for a word-timed upload of it.
      exactHit = hit;
    }
  }

  // 2. Search, preferring synced lyrics with a close duration.
  final search = Uri.parse('$_lrclib/search')
      .replace(queryParameters: {'track_name': title, 'artist_name': artist});
  final r2 = await http
      .get(search, headers: headers)
      .timeout(const Duration(seconds: 10));
  if (r2.statusCode == 429 || r2.statusCode >= 500) {
    throw Exception('LRCLIB ${r2.statusCode}');
  }
  final records = r2.statusCode == 200
      ? (jsonDecode(r2.body) as List).whereType<Map>().toList()
      : <Map>[];

  bool closeDuration(Map r) {
    if (duration == null) return true;
    final d = (r['duration'] as num?)?.toDouble();
    return d == null || (d - duration.inSeconds).abs() <= 4;
  }

  // 3. Free-text search, matched loosely: LRCLIB's field search misses
  //    "Ende Wef" for "Einde Wef", "(feat. …)" titles and artist spellings.
  //    It also finds word-timed uploads the field search leaves out (APT.).
  if (!records.any(_hasWordTimes)) {
    final loose = Uri.parse('$_lrclib/search')
        .replace(queryParameters: {'q': '$title $artist'});
    final r3 = await http
        .get(loose, headers: headers)
        .timeout(const Duration(seconds: 10));
    if (r3.statusCode == 200) {
      records.insertAll(
        0,
        (jsonDecode(r3.body) as List).whereType<Map>().where(
          (r) =>
              _sameTitle('${r['trackName'] ?? ''}', title) &&
              _sameArtist('${r['artistName'] ?? ''}', artist) &&
              _closeLength(duration, r['duration'] as num?),
        ),
      );
    }
  }

  final worded = records.firstWhere(
    (r) => _hasWordTimes(r) && closeDuration(r),
    orElse: () => const {},
  );
  if (worded.isNotEmpty) return _fromRecord(worded);
  if (exactHit != null) return exactHit;

  Map? best = records.firstWhere(
    (r) =>
        (r['syncedLyrics'] as String?)?.isNotEmpty == true && closeDuration(r),
    orElse: () => records.firstWhere(
      (r) => (r['syncedLyrics'] as String?)?.isNotEmpty == true,
      orElse: () => records.firstWhere(
        (r) => (r['plainLyrics'] as String?)?.isNotEmpty == true,
        orElse: () => const {},
      ),
    ),
  );
  if (best.isEmpty) best = null;
  return best == null ? null : _fromRecord(best);
}

SongLyrics? _fromRecord(Map r) {
  if (r['instrumental'] == true) {
    return const SongLyrics(plain: '♪ Instrumental ♪', source: 'LRCLIB');
  }
  final synced = r['syncedLyrics'] as String?;
  final plain = r['plainLyrics'] as String?;
  if (synced != null && synced.trim().isNotEmpty) {
    final lines = parseLrc(synced);
    if (lines.isNotEmpty) {
      return SongLyrics(lines: lines, plain: plain, source: 'LRCLIB');
    }
  }
  if (plain != null && plain.trim().isNotEmpty) {
    return SongLyrics(plain: plain, source: 'LRCLIB');
  }
  return null;
}

// ---------------------------------------------------------------------------
// NetEase Cloud Music (word-timed "yrc" lyrics)
// ---------------------------------------------------------------------------

final _ethiopic = RegExp('[ሀ-፿]');

/// Versions that aren't the song itself, unless its title says so too.
final _otherVersion = RegExp(
  r'\b(acoustic|live|remix|cover|instrumental|karaoke|sped|slowed|'
  r'bootleg|edit|version|demo|piano)\b|翻自|伴奏',
  caseSensitive: false,
);

const _netEaseHeaders = {
  'User-Agent': 'NeteaseMusic/9.0.0 (iPhone; iOS 17.0)',
  'Referer': 'https://music.163.com',
};

/// The song's word-timed lyrics from NetEase, or null. Its search finds the
/// release (the same title, artist and length, not an acoustic take or a
/// fan's cover); the lyrics come from the app's own API, which wants its
/// requests sealed the way the app does ("eapi").
Future<SongLyrics?> _fromNetEase(
  String artist,
  String title,
  Duration? duration,
) async {
  final search = Uri.parse('https://music.163.com/api/search/get').replace(
    queryParameters: {'s': '$title $artist', 'type': '1', 'limit': '10'},
  );
  final r = await http
      .get(search, headers: _netEaseHeaders)
      .timeout(const Duration(seconds: 8));
  if (r.statusCode != 200) return null;
  final songs =
      ((jsonDecode(r.body) as Map)['result'] as Map?)?['songs'] as List? ??
      const [];
  final wantsVersion = _otherVersion.hasMatch(title);
  final matches = songs.whereType<Map>().where((s) {
    final name = '${s['name'] ?? ''}';
    final singer = '${((s['artists'] as List?)?.firstOrNull as Map?)?['name']}';
    final ms = s['duration'] as num?;
    return _sameTitle(name, title) &&
        _sameArtist(singer, artist) &&
        (wantsVersion || !_otherVersion.hasMatch(name)) &&
        _closeLength(duration, ms == null ? null : ms / 1000, slack: 5);
  });
  for (final song in matches.take(3)) {
    final d = await _eapi('/api/song/lyric/v1', {
      'id': song['id'],
      'cp': 'false',
      'tv': '0',
      'lv': '0',
      'rv': '0',
      'kv': '0',
      'yv': '0',
      'ytv': '0',
      'yrv': '0',
    });
    final lines = _parseYrc('${(d['yrc'] as Map?)?['lyric'] ?? ''}');
    if (lines.length >= 4) {
      return SongLyrics(lines: lines, source: 'NetEase');
    }
  }
  return null;
}

Future<Map> _eapi(String path, Map<String, Object?> payload) async {
  final text = jsonEncode(payload);
  final digest = md5.convert(
    utf8.encode('nobody${path}use${text}md5forencrypt'),
  );
  final data = '$path-36cd479b6b5-$text-36cd479b6b5-$digest';
  final cipher =
      PaddedBlockCipherImpl(PKCS7Padding(), ECBBlockCipher(AESEngine()))..init(
        true,
        PaddedBlockCipherParameters(
          KeyParameter(Uint8List.fromList(utf8.encode('e82ckenh8dichen8'))),
          null,
        ),
      );
  final sealed = cipher.process(Uint8List.fromList(utf8.encode(data)));
  final params = [for (final b in sealed) b.toRadixString(16).padLeft(2, '0')]
      .join()
      .toUpperCase();
  final r = await http
      .post(
        Uri.parse('https://interface3.music.163.com/e${path.substring(1)}'),
        headers: _netEaseHeaders,
        body: {'params': params},
      )
      .timeout(const Duration(seconds: 8));
  return r.statusCode == 200 ? jsonDecode(r.body) as Map : const {};
}

final _yrcLine = RegExp(r'^\[(\d+),(\d+)\](.*)$');
final _yrcWord = RegExp(r'\((\d+),(\d+),\d+\)([^(]*)');
final _credit = RegExp(r'^(作词|作曲|编曲|制作人|词|曲)\s*[:：]');

/// NetEase's word-timed lines: `[12930,2190](12930,180,0)So (13110,120,0)the`
/// — each line's and each word's start and length in milliseconds. Credit
/// lines ("作词 : …") are left out.
List<LyricLine> _parseYrc(String yrc) {
  final lines = <LyricLine>[];
  for (final raw in const LineSplitter().convert(yrc)) {
    final m = _yrcLine.firstMatch(raw.trim());
    if (m == null) continue;
    final words = [
      for (final w in _yrcWord.allMatches(m.group(3)!))
        if (w.group(3)!.trim().isNotEmpty)
          LyricWord(
            Duration(milliseconds: int.parse(w.group(1)!)),
            w.group(3)!,
          ),
    ];
    if (words.isEmpty) continue;
    final text = words.map((w) => w.text).join().trim();
    if (_credit.hasMatch(text)) continue;
    lines.add(
      LyricLine(
        Duration(milliseconds: int.parse(m.group(1)!)),
        text,
        words: words,
      ),
    );
  }
  lines.sort((a, b) => a.time.compareTo(b.time));
  return lines;
}
