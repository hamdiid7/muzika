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
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:muzika/utilities/artist_names.dart';
import 'package:muzika/constants/clients.dart'
    show loadSongHint, registerSongHint;
import 'package:muzika/services/data_manager.dart';
import 'package:muzika/services/deezer_catalog.dart';
import 'package:muzika/services/deezer_related.dart';
import 'package:muzika/services/proxy_manager.dart' show ytClient;
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

/// The catalog without the relay (Muzika): Apple's iTunes Search API answers
/// from Ethiopia, needs no key, and knows Ethiopian music well (titles,
/// albums, lengths, square covers). Songs from it carry an `itunes-<id>`
/// ytid; the audio is the YouTube upload found for them when they first play
/// (see getManifestWithFallback). Artist photos come from the artist's
/// YouTube channel, since Apple mostly has album covers for them.
///
/// Always on now that the relay is gone.
const useItunesCatalog = true;

/// Lets playback look up an Apple song nothing registered (after a restart,
/// for a download).
void initItunesCatalog() {
  loadSongHint = (songId) async {
    if (isDeezerSongId(songId)) return deezerSongHint(songId);
    if (!isItunesSongId(songId)) return null;
    try {
      final found = await _call('lookup', {
        'id': songId.substring(itunesSongPrefix.length),
      });
      // A song, or the music video behind a Discover clip.
      final track = found
          .where((t) => _isSong(t) || t['kind'] == 'music-video')
          .firstOrNull;
      if (track == null) return null;
      final ms = (track['trackTimeMillis'] as num?)?.toInt();
      return (
        title: '${track['trackName'] ?? ''}'.trim(),
        artist: '${track['artistName'] ?? ''}'.trim(),
        duration: ms == null ? null : Duration(milliseconds: ms),
      );
    } catch (_) {
      return null;
    }
  };
}

const itunesSongPrefix = 'itunes-';
const itunesAlbumPrefix = 'itunes-album-';
const itunesArtistPrefix = 'itunes-artist-';

bool isItunesSongId(String? id) =>
    id != null &&
    id.startsWith(itunesSongPrefix) &&
    !id.startsWith(itunesAlbumPrefix) &&
    !id.startsWith(itunesArtistPrefix);

const _base = 'https://itunes.apple.com';
const _timeout = Duration(seconds: 10);

/// Apple allows about 20 calls a minute per address: answers are kept a
/// day, and calls run one at a time.
final _inFlight = <String, Future<List<Map>>>{};

/// One call per address at a time: the same question asked again while it
/// is on its way shares the answer.
Future<List<Map>> _call(String path, Map<String, String> query) {
  final id = '$path?${Uri(queryParameters: query).query}';
  // A block body: `=> remove(id)` would hand whenComplete this very future,
  // which it would then wait for forever.
  return _inFlight[id] ??= _fetch(path, query).whenComplete(() {
    _inFlight.remove(id);
  });
}

Future<List<Map>> _fetch(String path, Map<String, String> query) async {
  final uri = Uri.parse('$_base/$path')
      .replace(queryParameters: {'country': 'US', ...query});
  final cacheKey = 'itunes_v1_$uri';
  final cached = await getData(
    'cache',
    cacheKey,
    cachingDuration: const Duration(days: 1),
  );
  if (cached is List) return cached.whereType<Map>().toList();

  // A call now and then hangs or drops here: one more try.
  Future<http.Response> get() => http.get(uri).timeout(_timeout);
  final response = await _serial(() => get().catchError((Object _) => get()));
  if (response.statusCode != 200) {
    throw http.ClientException('iTunes ${response.statusCode}', uri);
  }
  final results = [
    ...((json.decode(utf8.decode(response.bodyBytes)) as Map)['results']
                as List? ??
            const [])
        .whereType<Map>(),
  ];
  unawaited(addOrUpdateData<List>('cache', cacheKey, results));
  return results;
}

Future<void> _chain = Future.value();

Future<T> _serial<T>(Future<T> Function() call) {
  final result = _chain.then((_) => call());
  _chain = result.then((_) {}, onError: (_) {});
  return result;
}

// ---------------------------------------------------------------------------
// Shapes the rest of the app uses
// ---------------------------------------------------------------------------

String? _art(Map item, int size) {
  final url = item['artworkUrl100']?.toString();
  if (url == null || url.isEmpty) return null;
  return url.replaceFirst(RegExp(r'/\d+x\d+bb\.'), '/${size}x${size}bb.');
}

/// "Salaysh - Single" is the release "Salaysh".
String _releaseTitle(String title) =>
    title.replaceFirst(RegExp(r'\s+-\s+(Single|EP)$'), '').trim();

String _releaseType(Map album) {
  final title = '${album['collectionName'] ?? ''}';
  if (title.endsWith(' - Single')) return 'single';
  if (title.endsWith(' - EP')) return 'ep';
  final count = (album['trackCount'] as num?)?.toInt() ?? 0;
  if (count > 0 && count <= 3) return 'single';
  if (count > 0 && count <= 6) return 'ep';
  return 'album';
}

String? _year(Map item) {
  final date = item['releaseDate']?.toString() ?? '';
  return date.length >= 4 ? date.substring(0, 4) : null;
}

Map<String, dynamic> _songMap(Map track, int index, {String? artistName}) {
  final id = '$itunesSongPrefix${track['trackId']}';
  final title = '${track['trackName'] ?? ''}'.trim();
  final artist = artistName ?? '${track['artistName'] ?? ''}'.trim();
  final ms = (track['trackTimeMillis'] as num?)?.toInt();
  final duration = ms == null ? null : Duration(milliseconds: ms);
  registerSongHint(id, title: title, artist: artist, duration: duration);
  return {
    'id': index,
    'ytid': id,
    'title': title,
    'artist': artist,
    'artistId': '$itunesArtistPrefix${track['artistId']}',
    'album': _releaseTitle('${track['collectionName'] ?? ''}'),
    'albumId': '$itunesAlbumPrefix${track['collectionId']}',
    'image': _art(track, 600),
    'lowResImage': _art(track, 226),
    'highResImage': _art(track, 1200),
    'duration': duration?.inSeconds,
    'isLive': false,
    'isCatalog': true,
    'preview': track['previewUrl'],
    'source': 'itunes',
  };
}

Map<String, dynamic> _albumMap(Map album, {String? artistName}) => {
  'ytid': '$itunesAlbumPrefix${album['collectionId']}',
  'title': _releaseTitle('${album['collectionName'] ?? ''}'),
  'artist': artistName ?? album['artistName'],
  'artistId': '$itunesArtistPrefix${album['artistId']}',
  'year': _year(album),
  'image': _art(album, 600),
  'lowResImage': _art(album, 226),
  'releaseType': _releaseType(album),
  'subtitle': _year(album),
  'isAlbum': true,
  'source': 'itunes-album',
};

/// Lower-case letters and digits, doubled letters once: "Eyob Mekonen" and
/// "Eyob Mekonnen" are the same artist, so are "Endegebsu" and "Ende Gebsu".
String _key(String s) => s
    .toLowerCase()
    .replaceAll(RegExp('[^a-z0-9ሀ-፿]+'), '')
    .replaceAllMapped(RegExp(r'(.)\1+'), (m) => m[1]!);

bool _isSong(Map item) =>
    item['wrapperType'] == 'track' && item['kind'] == 'song';

/// One copy of each song: Apple lists the same recording on every release
/// and reissue it's on.
List<Map> _uniqueSongs(Iterable<Map> tracks) {
  final seen = <String>{};
  return [
    for (final t in tracks)
      if (seen.add(
        '${_key('${t['artistName']}')}:${_key('${t['trackName']}')}',
      ))
        t,
  ];
}

/// One copy of each release, the fullest one: Salaysh is on Apple three
/// times, from three distributors.
List<Map> _uniqueAlbums(Iterable<Map> albums) {
  final best = <String, Map>{};
  for (final a in albums) {
    final key = _key(_releaseTitle('${a['collectionName'] ?? ''}'));
    final kept = best[key];
    final count = (a['trackCount'] as num?)?.toInt() ?? 0;
    if (kept == null || count > ((kept['trackCount'] as num?)?.toInt() ?? 0)) {
      best[key] = a;
    }
  }
  return best.values.toList();
}

// ---------------------------------------------------------------------------
// Search
// ---------------------------------------------------------------------------

Future<List<Map<String, dynamic>>> itunesSearchSongs(String query) async {
  final results = await _call('search', {
    'term': query,
    'entity': 'song',
    'limit': '50',
  });
  final songs = _uniqueSongs(results.where(_isSong));
  return [for (final (i, t) in songs.indexed) _songMap(t, i)];
}

Future<List<Map<String, dynamic>>> itunesSearchAlbums(String query) async {
  final results = await _call('search', {
    'term': query,
    'entity': 'album',
    'limit': '25',
  });
  final albums = <String, Map>{};
  for (final a in results.where((r) => r['collectionType'] == 'Album')) {
    final key =
        '${_key('${a['artistName']}')}:'
        '${_key(_releaseTitle('${a['collectionName']}'))}';
    albums.putIfAbsent(key, () => a);
  }
  return [for (final a in albums.values) _albumMap(a)];
}

/// Artists named like [query], with their photos. Entries Apple keeps apart
/// under one name (two "Bezuayehu Demissie"s) come back as one artist.
Future<List<Map<String, dynamic>>> itunesSearchArtists(
  String query, {
  int limit = 5,
}) async {
  final results = await _call('search', {
    'term': query,
    'entity': 'musicArtist',
    'limit': '15',
  });
  final groups = <String, List<Map>>{};
  for (final a in results) {
    final name = '${a['artistName'] ?? ''}'.trim();
    if (name.isEmpty) continue;
    groups.putIfAbsent(_key(name), () => []).add(a);
  }
  final picked = groups.values.take(limit).toList();
  return Future.wait([
    for (final group in picked)
      () async {
        final name = '${group.first['artistName']}'.trim();
        final ids = [for (final a in group) '${a['artistId']}'];
        return _artistMap(ids, name, await artistPhoto(name));
      }(),
  ]);
}

Map<String, dynamic> _artistMap(List<String> ids, String name, String? image) =>
    {
      'ytid': '$itunesArtistPrefix${ids.join('_')}',
      'title': name,
      'image': image,
      'source': 'itunes-artist',
      'isArtist': true,
      'isVerifiedArtist': true,
      'list': [],
    };

List<String> _artistIds(String ytid) => ytid
    .substring(itunesArtistPrefix.length)
    .split('_')
    .where((id) => id.isNotEmpty)
    .toList();

// ---------------------------------------------------------------------------
// Artist photo from YouTube
// ---------------------------------------------------------------------------

/// The picture of the artist's own YouTube channel, which is a real photo
/// far more often than what Apple or Deezer show (album covers). Null when
/// there's no channel by that name.
Future<String?> artistPhoto(String name) async {
  // Deezer's photo first: one small request, a real 1000 px photo.
  final deezer = await deezerArtistPhoto(name).catchError((_) => null);
  if (deezer != null) return deezer;
  final key = 'itunes_photo_v1_${_key(name)}';
  final cached = await getData(
    'cache',
    key,
    cachingDuration: const Duration(days: 30),
  );
  if (cached is String) return cached.isEmpty ? null : cached;

  String? photo;
  try {
    final results = await ytClient.search
        .searchContent(name, filter: TypeFilters.channel)
        .timeout(_timeout);
    final wanted = _key(name);
    String bare(String channel) => _key(
      channel.replaceAll(
        RegExp(
          r'\s*-\s*topic$|\b(official|vevo|music)\b',
          caseSensitive: false,
        ),
        '',
      ),
    );
    // YouTube lists the artist's own channel first (it has the most
    // subscribers); copies with the same name come after it.
    final channels = results
        .whereType<SearchChannel>()
        .where((c) => bare(c.name) == wanted && c.thumbnails.isNotEmpty)
        .toList();
    final channel =
        channels.where((c) => c.isVerifiedArtist).firstOrNull ??
        channels.firstOrNull;
    if (channel != null) {
      var url = channel.thumbnails.last.url.toString();
      if (url.startsWith('//')) url = 'https:$url';
      // A channel that never set a picture has YouTube's letter avatar.
      if (!url.contains('/ytc/')) {
        photo = url.replaceFirst(RegExp(r'=s\d+'), '=s800');
      }
    }
  } catch (_) {}
  unawaited(addOrUpdateData<String>('cache', key, photo ?? ''));
  return photo;
}

// ---------------------------------------------------------------------------
// Artist page and album
// ---------------------------------------------------------------------------

/// The artist page in the shape getArtistProfile returns: top songs,
/// releases (newest first, one copy each), photo.
Future<Map<String, dynamic>?> itunesArtistProfile(String ytid) async {
  var ids = _artistIds(ytid);
  if (ids.isEmpty) return null;

  final albumsRaw = await _call('lookup', {
    'id': ids.join(','),
    'entity': 'album',
    'limit': '200',
  });
  final artists = albumsRaw.where((r) => r['wrapperType'] == 'artist');
  final name = artists.isEmpty
      ? '${albumsRaw.firstOrNull?['artistName'] ?? ''}'.trim()
      : '${artists.first['artistName']}'.trim();
  if (name.isEmpty) return null;

  // Opened from a song, the page knows one of the artist's entries: find
  // the others with the same name and read them too.
  if (ids.length == 1) {
    try {
      final more = [
        for (final a in await _call('search', {
          'term': name,
          'entity': 'musicArtist',
          'limit': '15',
        }))
          if (_key('${a['artistName']}') == _key(name)) '${a['artistId']}',
      ];
      final extra = more.where((id) => !ids.contains(id)).toList();
      if (extra.isNotEmpty) {
        ids = [...ids, ...extra];
        albumsRaw.addAll(
          await _call('lookup', {
            'id': extra.join(','),
            'entity': 'album',
            'limit': '200',
          }),
        );
      }
    } catch (_) {}
  }

  final songsRaw = await _call('lookup', {
    'id': ids.join(','),
    'entity': 'song',
    'limit': '200',
  });

  final albums = _uniqueAlbums(
    albumsRaw.where(
      (r) => r['wrapperType'] == 'collection' && _sameArtist(r, name),
    ),
  )..sort((a, b) => '${b['releaseDate']}'.compareTo('${a['releaseDate']}'));
  final songs = _uniqueSongs(
    songsRaw.where((r) => _isSong(r) && _sameArtist(r, name)),
  );
  final artistId = '$itunesArtistPrefix${ids.join('_')}';
  final photo = await artistPhoto(name);
  // Apple has no "related artists": Deezer's, opened by name.
  final related = await relatedArtists(name)
      .catchError((_) => <RelatedArtist>[]);

  return {
    ..._artistMap(ids, name, photo ?? _art(albums.firstOrNull ?? {}, 600)),
    'ytid': artistId,
    'description': null,
    'monthlyListeners': null,
    'topSongs': [
      for (final (i, t) in songs.take(20).indexed)
        {'song': _songMap(t, i, artistName: name), 'playCount': null},
    ],
    'releases': [
      for (final a in albums)
        {..._albumMap(a, artistName: name), 'artistId': artistId},
    ],
    'relatedArtists': [
      for (final r in related.take(20))
        {'ytid': r.name, 'title': r.name, 'image': r.photo},
    ],
    'allSongs': [
      for (final (i, t) in songs.indexed) _songMap(t, i, artistName: name),
    ],
  };
}

/// The artist's own songs, not compilations where they share the bill
/// under another name.
bool _sameArtist(Map item, String name) {
  final credit = _key('${item['artistName'] ?? ''}');
  final wanted = _key(name);
  return credit == wanted || credit.contains(wanted);
}

/// The releases Apple has for the artist called [name] (theirs alone, not
/// compilations), newest first: they fill in what Deezer is missing.
Future<List<Map<String, dynamic>>> itunesArtistReleases(String name) async {
  final wanted = _key(name);
  final found = await _call('search', {
    'term': name,
    'entity': 'album',
    'limit': '100',
  });
  // Theirs, spelt any way ("Ephrem"/"Efrem"), and theirs with a band
  // ("Ephrem Tamiru & Roha Band"); not other people's compilations.
  bool theirs(String credit) {
    if (_key(credit) == wanted) return true;
    final lead = credit.split(RegExp(r'\s*(?:&|,| and | feat\.? | ft\.? )\s*'));
    return sameArtistName(name, lead.first);
  }

  final albums = _uniqueAlbums(
    found.where(
      (a) =>
          a['wrapperType'] == 'collection' &&
          theirs('${a['artistName'] ?? ''}'),
    ),
  )..sort((a, b) => '${b['releaseDate']}'.compareTo('${a['releaseDate']}'));
  return [for (final a in albums) _albumMap(a, artistName: name)];
}

/// Finds the iTunes artist for a name (an artist saved from the YouTube
/// Music catalog, or opened from an older song).
Future<Map<String, dynamic>?> itunesArtistByName(String name) async {
  final found = await itunesSearchArtists(name);
  final wanted = _key(name);
  final match =
      found.where((a) => _key('${a['title']}') == wanted).firstOrNull ??
      found.firstOrNull;
  if (match == null) return null;
  return itunesArtistProfile('${match['ytid']}');
}

/// A release with its tracks, in the shape getArtistAlbum returns.
Future<Map<String, dynamic>?> itunesAlbum(String ytid) async {
  final id = ytid.substring(itunesAlbumPrefix.length);
  final results = await _call('lookup', {
    'id': id,
    'entity': 'song',
    'limit': '200',
  });
  final album = results.where((r) => r['wrapperType'] == 'collection');
  if (album.isEmpty) return null;
  final info = album.first;
  final tracks = results.where(_isSong).toList()
    ..sort((a, b) {
      final disc = ((a['discNumber'] as num?) ?? 1).compareTo(
        (b['discNumber'] as num?) ?? 1,
      );
      return disc != 0
          ? disc
          : ((a['trackNumber'] as num?) ?? 0).compareTo(
              (b['trackNumber'] as num?) ?? 0,
            );
    });
  final cover = _art(info, 600);
  return {
    ..._albumMap(info),
    'list': [
      for (final (i, t) in tracks.indexed)
        {
          ..._songMap(t, i),
          // One cover for the whole release, as on YouTube Music.
          if (cover != null) 'image': cover,
        },
    ],
  };
}

// ---------------------------------------------------------------------------
// Previews
// ---------------------------------------------------------------------------

/// Apple's 30-second preview of [song] (Discover, the album game): a
/// small AAC file from Apple's servers, at the part Apple picked, that loads
/// at once. Any song, from any catalog: one not from Apple is looked up by
/// title, artist and length. Null when Apple doesn't have it.
Future<String?> itunesPreviewFor(Map song) async {
  final own = song['preview']?.toString();
  if (own != null && own.startsWith('http')) return own;
  final id = '${song['ytid'] ?? ''}';
  final title = '${song['title'] ?? ''}'.trim();
  if (id.isEmpty || title.isEmpty) return null;

  final key = 'itunes_preview_v1_$id';
  final cached = await getData(
    'cache',
    key,
    cachingDuration: const Duration(days: 30),
  );
  if (cached is String) return cached.isEmpty ? null : cached;

  String? found;
  try {
    found = (await _findPreview(song, title))?['previewUrl']?.toString();
  } catch (_) {
    return null; // not remembered: a failed call is tried again next time
  }
  unawaited(addOrUpdateData<String>('cache', key, found ?? ''));
  return found;
}

/// The preview of [song]'s music video on Apple (about 30 seconds), or
/// null when it has none. Kept a month.
Future<String?> itunesVideoPreviewFor(Map song) async {
  final id = '${song['ytid'] ?? ''}';
  final title = '${song['title'] ?? ''}'.trim();
  if (id.isEmpty || title.isEmpty) return null;

  final key = 'itunes_video_preview_v1_$id';
  final cached = await getData(
    'cache',
    key,
    cachingDuration: const Duration(days: 30),
  );
  if (cached is String) return cached.isEmpty ? null : cached;

  String? found;
  try {
    found = (await _findPreview(
      song,
      title,
      video: true,
    ))?['previewUrl']?.toString();
  } catch (_) {
    return null;
  }
  unawaited(addOrUpdateData<String>('cache', key, found ?? ''));
  return found;
}

/// The Apple song (or with [video], music video) that is [song]: same
/// title and artist, about the same length, not a live take or remix.
Future<Map?> _findPreview(Map song, String title, {bool video = false}) async {
  String bare(String s) => s
      .replaceAll(RegExp(r'\s*[\(\[][^\)\]]*[\)\]]'), '')
      .replaceAll(RegExp(r'\s+(feat|ft)\.?\s.*$', caseSensitive: false), '')
      .trim();
  final artist = '${song['artist'] ?? ''}'.split(RegExp('[,&]')).first.trim();
  final wantedTitle = _key(bare(title));
  final wantedArtist = _key(artist);
  final raw = song['duration'];
  final seconds = raw is num ? raw.toInt() : int.tryParse('$raw');

  // Videos are looked up per artist: one call answers for all of the
  // artist's songs (calls are few: about 20 a minute).
  final results = await _call('search', {
    'term': video ? artist : '$artist ${bare(title)}'.trim(),
    'entity': video ? 'musicVideo' : 'song',
    'limit': video ? '50' : '15',
  });
  final otherTake = RegExp(
    r'\b(live|concert|karaoke|instrumental|remix|cover|acoustic|sped up|'
    r'slowed)\b',
    caseSensitive: false,
  );
  final titleIsOtherTake = otherTake.hasMatch(title);
  Map? best;
  var bestScore = -1;
  bool wanted(Map t) => video
      ? t['wrapperType'] == 'track' && t['kind'] == 'music-video'
      : _isSong(t);
  for (final t in results.where(wanted)) {
    final preview = t['previewUrl']?.toString() ?? '';
    if (!preview.startsWith('http')) continue;
    // The censored name carries what the name may leave out ("(Live at…)").
    if (!titleIsOtherTake &&
        otherTake.hasMatch('${t['trackName']} ${t['trackCensoredName']}')) {
      continue;
    }
    final name = _key(bare('${t['trackName'] ?? ''}'));
    if (name.isEmpty ||
        !(name == wantedTitle ||
            name.contains(wantedTitle) ||
            wantedTitle.contains(name))) {
      continue;
    }
    final credit = _key('${t['artistName'] ?? ''}');
    if (wantedArtist.isNotEmpty &&
        !credit.contains(wantedArtist) &&
        !wantedArtist.contains(credit)) {
      continue;
    }
    final ms = (t['trackTimeMillis'] as num?)?.toInt();
    final off = seconds == null || ms == null
        ? null
        : (ms ~/ 1000 - seconds).abs();
    // Another recording (live, remix, a radio edit) runs a different length;
    // a music video may add an intro or a scene.
    if (off != null && off > (video ? 90 : 12)) continue;
    final score =
        (name == wantedTitle ? 2 : 0) + (off != null && off <= 3 ? 1 : 0);
    if (score > bestScore) {
      best = t;
      bestScore = score;
    }
  }
  return best;
}

// ---------------------------------------------------------------------------
// Clips (Discover's Clips feed)
// ---------------------------------------------------------------------------

/// One of Apple's music-video clips as a Discover card: `song` is the song
/// the video is of, as Apple sells it (its title, album and cover; an
/// `itunes-<id>` song matched on YouTube when played in full), and `url`
/// the video's 30-second clip with its own sound.
typedef AppleClip = ({Map<String, dynamic> song, String url});

/// Not the recording: live takes, concert films, lyric clips.
final _notTheVideo = RegExp(
  r'\b(live|concert|karaoke|lyric|lyrics|visualizer|visualiser|teaser|'
  r'trailer|behind the scenes|making of|interview)\b',
  caseSensitive: false,
);

/// A title without "(Official Video)", "feat. …" and the Ge'ez half of
/// "Ayne Bego - አይነ በጎ".
String _clipTitle(String s) => _clipTitleParts(s).firstOrNull ?? '';

/// Every part of a video title that may be the song's name: "ft Etenesh
/// Demeke - Ayne Bego - አይነ በጎ" holds it in the middle.
List<String> _clipTitleParts(String s) => [
  for (final part
      in s
          .replaceAll(RegExp(r'\s*[\(\[][^\)\]]*[\)\]]'), '')
          .split(RegExp(r'\s+[-–|_]\s+')))
    if (!RegExp(r'^(feat|ft)\.?\s', caseSensitive: false).hasMatch(part.trim()))
      part
          .replaceAll(RegExp(r'\s+(feat|ft)\.?\s.*$', caseSensitive: false), '')
          .trim(),
]..removeWhere((p) => p.isEmpty);

/// [artist]'s music-video clips on Apple, each with the song it is of.
/// Three calls (the videos, then the artist's songs), kept a day by the
/// cache. A clip whose song Apple doesn't sell is left out: its card would
/// show the video's name and play who knows what.
/// An artist's songs on Apple, most popular first (the same search the
/// clips are matched with, so usually already read): for Clips' lyric
/// videos, of songs that have no music video.
Future<List<Map<String, dynamic>>> appleArtistSongs(String artist) async {
  final wanted = _key(artist);
  if (wanted.isEmpty) return const [];
  final found = await _call('search', {
    'term': artist,
    'entity': 'song',
    'limit': '200',
  });
  final seen = <String>{};
  final songs = <Map<String, dynamic>>[];
  for (final t in found) {
    if (!_isSong(t) || !_key('${t['artistName'] ?? ''}').contains(wanted)) {
      continue;
    }
    if (!seen.add(_key(_clipTitle('${t['trackName'] ?? ''}')))) continue;
    songs.add(_songMap(t, songs.length));
  }
  return songs;
}

Future<List<AppleClip>> appleArtistClips(String artist) async {
  final wanted = _key(artist);
  if (wanted.isEmpty) return const [];
  final videos = [
    for (final t in await _call('search', {
      'term': artist,
      'entity': 'musicVideo',
      'limit': '25',
    }))
      if (t['kind'] == 'music-video' &&
          '${t['previewUrl'] ?? ''}'.startsWith('http') &&
          _key('${t['artistName'] ?? ''}').contains(wanted) &&
          !_notTheVideo.hasMatch(
            '${t['trackName'] ?? ''} ${t['trackCensoredName'] ?? ''}',
          ))
        t,
  ];
  if (videos.isEmpty) return const [];

  // Apple may file an artist's videos and songs under different artist
  // entries: the songs of the videos' entries, and a song search by name.
  final artistIds = {for (final v in videos) '${v['artistId']}'};
  final lists = await Future.wait([
    _call('lookup', {
      'id': artistIds.join(','),
      'entity': 'song',
      'limit': '200',
    }),
    _call('search', {'term': artist, 'entity': 'song', 'limit': '200'}),
  ]);
  final songs = [
    for (final t in lists.expand((l) => l))
      if (_isSong(t) && _key('${t['artistName'] ?? ''}').contains(wanted)) t,
  ];
  // A song's name without the artist's name and a label's "Ethiopia Album"
  // tag ("Kuku Sebsibe Wedaje Atkir Ethiopia Album" is "Wedaje Atkir").
  String songKey(Map song) {
    var k = _key(_clipTitle('${song['trackName'] ?? ''}'));
    if (k.startsWith(wanted) && k.length > wanted.length) {
      k = k.substring(wanted.length);
    }
    for (final tag in ['ethiopiaalbum', 'album']) {
      if (k.endsWith(tag) && k.length > tag.length) {
        k = k.substring(0, k.length - tag.length);
      }
    }
    return k;
  }

  // Plainly named songs first: "Wedaje Atikir" before a label's tagged copy.
  bool tagged(Map song) {
    final k = _key('${song['trackName'] ?? ''}');
    return k.startsWith(wanted) || k.endsWith('album');
  }

  final keyed = [
    for (final s in songs.where((s) => !tagged(s))) (s, songKey(s)),
    for (final s in songs.where(tagged)) (s, songKey(s)),
  ];
  // The parts of a video's title that may name the song: never the
  // artist's own name ("Kuku Sebsibe – Embaye" names "Embaye").
  List<String> partsOf(Map video) => [
    for (final part in _clipTitleParts('${video['trackName'] ?? ''}'))
      if (_key(part).length >= 2 &&
          _key(part) != wanted &&
          !wanted.contains(_key(part)))
        _key(part),
  ];

  Map? songOf(Map video) {
    final parts = partsOf(video);
    for (final k in parts) {
      final same = keyed.where((e) => e.$2 == k).firstOrNull;
      if (same != null) return same.$1;
      // One inside the other only when it is most of it ("Ayne Bego" in
      // "Ayne Bego (አይነ በጎ)"), not a word of a longer title.
      final close = keyed.where((e) {
        final sk = e.$2;
        if (sk.length < 4 || k.length < 4) return false;
        final shorter = min(sk.length, k.length);
        final longer = max(sk.length, k.length);
        return shorter / longer >= 0.6 && (sk.contains(k) || k.contains(sk));
      }).firstOrNull;
      if (close != null) return close.$1;
    }
    // Amharic names spelt two ways in Latin letters ("Siwedelat",
    // "Swedlat"): the same consonants.
    String consonants(String k) =>
        k.replaceAll(RegExp('[^a-z]'), '').replaceAll(RegExp('[aeiouy]'), '');
    for (final k in parts) {
      final c = consonants(k);
      if (c.length < 3) continue;
      final song = keyed.where((e) => consonants(e.$2) == c).firstOrNull;
      if (song != null) return song.$1;
    }
    return null;
  }

  final seen = <String>{};
  final clips = <AppleClip>[];
  for (final v in videos) {
    final song = songOf(v);
    if (song == null || !seen.add('${song['trackId']}')) continue;
    clips.add((song: _songMap(song, clips.length), url: '${v['previewUrl']}'));
  }
  return clips;
}
