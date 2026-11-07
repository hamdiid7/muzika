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

import 'package:http/http.dart' as http;
import 'package:muzika/utilities/artist_names.dart';
import 'package:muzika/constants/clients.dart' show registerSongHint;
import 'package:muzika/main.dart' show logger;
import 'package:muzika/services/data_manager.dart';
import 'package:muzika/services/itunes_catalog.dart' show itunesArtistReleases;

/// The catalog (Muzika): Deezer's open API, reached directly with no key.
/// Search, albums, artists (real photos, related artists, radio), public
/// playlists and charts, in the same shapes the rest of the app uses. Songs
/// carry a `deezer-<id>` ytid; like Apple's, their audio is the YouTube
/// upload found for them when they first play (see getManifestWithFallback).
/// Clips still come from Apple, which has the music videos.
const deezerSongPrefix = 'deezer-';
const deezerAlbumPrefix = 'deezer-album-';
const deezerArtistPrefix = 'deezer-artist-';
const deezerPlaylistPrefix = 'deezer-playlist-';

bool isDeezerSongId(String? id) =>
    id != null &&
    id.startsWith(deezerSongPrefix) &&
    !id.startsWith(deezerAlbumPrefix) &&
    !id.startsWith(deezerArtistPrefix) &&
    !id.startsWith(deezerPlaylistPrefix);

// ---------------------------------------------------------------------------
// Calls
// ---------------------------------------------------------------------------

final _inFlight = <String, Future<Map<String, dynamic>>>{};

/// GET [path] from api.deezer.com, kept a day (an hour for charts).
Future<Map<String, dynamic>> _get(String path, {Duration? keep}) {
  return _inFlight[path] ??= _fetch(path, keep).whenComplete(() {
    _inFlight.remove(path);
  });
}

Future<Map<String, dynamic>> _fetch(String path, Duration? keep) async {
  final key = 'deezer_v1_$path';
  final cached = await getData(
    'cache',
    key,
    cachingDuration: keep ?? const Duration(days: 1),
  );
  if (cached is String) {
    return json.decode(cached) as Map<String, dynamic>;
  }
  final response = await http
      .get(Uri.parse('https://api.deezer.com/$path'))
      .timeout(const Duration(seconds: 12));
  if (response.statusCode != 200) {
    throw Exception('Deezer ${response.statusCode} for $path');
  }
  final body = utf8.decode(response.bodyBytes);
  final data = json.decode(body) as Map<String, dynamic>;
  if (data['error'] != null) throw Exception('Deezer error for $path');
  unawaited(addOrUpdateData<String>('cache', key, body));
  return data;
}

List<Map> _data(Map<String, dynamic> r) =>
    [...(r['data'] as List? ?? const [])].whereType<Map>().toList();

String _q(String s) => Uri.encodeQueryComponent(s);

/// Lower-case letters and digits, to match names written slightly apart.
String _key(String s) =>
    s.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');

// ---------------------------------------------------------------------------
// Shapes the rest of the app uses
// ---------------------------------------------------------------------------

String? _year(Map item) {
  final date = item['release_date']?.toString() ?? '';
  return date.length >= 4 ? date.substring(0, 4) : null;
}

String _releaseType(Map album) => switch ('${album['record_type'] ?? ''}') {
  'single' => 'single',
  'ep' => 'ep',
  _ => 'album',
};

Map<String, dynamic> deezerSongMap(
  Map track,
  int index, {
  Map? album,
  String? artistName,
}) {
  final id = '$deezerSongPrefix${track['id']}';
  final title = '${track['title'] ?? ''}'.trim();
  final artist = artistName ?? '${(track['artist'] as Map?)?['name'] ?? ''}';
  final seconds = (track['duration'] as num?)?.toInt();
  final duration = seconds == null || seconds <= 0
      ? null
      : Duration(seconds: seconds);
  registerSongHint(id, title: title, artist: artist, duration: duration);
  final from = (track['album'] as Map?) ?? album ?? const {};
  return {
    'id': index,
    'ytid': id,
    'title': title,
    'artist': artist,
    'artistId': '$deezerArtistPrefix${(track['artist'] as Map?)?['id']}',
    'album': '${from['title'] ?? ''}',
    'albumId': '$deezerAlbumPrefix${from['id']}',
    'image': from['cover_big'] ?? from['cover_medium'],
    'lowResImage': from['cover_medium'] ?? from['cover_big'],
    'highResImage': from['cover_xl'] ?? from['cover_big'],
    'duration': duration?.inSeconds,
    'isLive': false,
    'isCatalog': true,
    'preview': track['preview'],
    if (track['gain'] is num) 'gain': track['gain'],
    // How popular the song is on Deezer (what its charts sort by).
    if (track['rank'] is num) 'rank': track['rank'],
    'source': 'deezer',
  };
}

Map<String, dynamic> deezerAlbumMap(Map album, {String? artistName}) => {
  'ytid': '$deezerAlbumPrefix${album['id']}',
  'title': '${album['title'] ?? ''}',
  'artist': artistName ?? (album['artist'] as Map?)?['name'],
  'artistId': '$deezerArtistPrefix${(album['artist'] as Map?)?['id']}',
  'year': _year(album),
  'image': album['cover_big'] ?? album['cover_medium'],
  'lowResImage': album['cover_medium'] ?? album['cover_big'],
  'highResImage': album['cover_xl'] ?? album['cover_big'],
  'releaseType': _releaseType(album),
  'subtitle': _year(album),
  'isAlbum': true,
  'source': 'deezer-album',
};

Map<String, dynamic> deezerArtistMap(Map artist) => {
  'ytid': '$deezerArtistPrefix${artist['id']}',
  'title': '${artist['name'] ?? ''}',
  'image': artist['picture_xl'] ?? artist['picture_big'],
  'source': 'deezer-artist',
  'isArtist': true,
  'isVerifiedArtist': true,
  'list': [],
};

Map<String, dynamic> deezerPlaylistMap(Map playlist) => {
  'ytid': '$deezerPlaylistPrefix${playlist['id']}',
  'title': '${playlist['title'] ?? ''}',
  'artist':
      (playlist['user'] as Map?)?['name'] ??
      (playlist['creator'] as Map?)?['name'],
  'subtitle': playlist['nb_tracks'] == null
      ? 'Playlist'
      : 'Playlist · ${playlist['nb_tracks']} songs',
  'image': playlist['picture_big'] ?? playlist['picture_medium'],
  'lowResImage': playlist['picture_medium'] ?? playlist['picture_big'],
  'isAlbum': false,
  'source': 'deezer-playlist',
};

/// Deezer's rank of a song (up to about a million) as "Popularity 74" out
/// of 100, or null when it has none.
String? deezerPopularityLabel(Map song) {
  final rank = song['rank'];
  if (rank is! num || rank <= 0) return null;
  final score = (rank / 10000).round().clamp(1, 100);
  return 'Popularity $score';
}

// ---------------------------------------------------------------------------
// Search
// ---------------------------------------------------------------------------

Future<List<Map<String, dynamic>>> deezerSearchSongs(String query) async {
  final r = await _get('search?q=${_q(query)}&limit=50');
  final seen = <String>{};
  final songs = <Map<String, dynamic>>[];
  for (final t in _data(r)) {
    // One of each song (Deezer lists the same track on several releases).
    final k =
        '${_key('${t['title']}')}|${_key('${(t['artist'] as Map?)?['name']}')}';
    if (!seen.add(k)) continue;
    songs.add(deezerSongMap(t, songs.length));
  }
  return songs;
}

/// The song [title] by [artist] (an imported playlist's row): Deezer's
/// search for both, then for the title alone, checked against
/// the artist. Null when Deezer doesn't have it.
Future<Map<String, dynamic>?> deezerFindSong(
  String title,
  String artist,
) async {
  final wantedArtist = _key(
    artist.split(RegExp(',|&| feat', caseSensitive: false)).first,
  );
  final wantedTitle = _key(
    title.replaceAll(RegExp(r'\s*[\(\[].*?[\)\]]'), '').split(' - ').first,
  );
  bool sameArtist(Map t) {
    final a = _key('${(t['artist'] as Map?)?['name'] ?? ''}');
    return wantedArtist.isEmpty ||
        a == wantedArtist ||
        a.contains(wantedArtist) ||
        wantedArtist.contains(a);
  }

  bool sameTitle(Map t) {
    final k = _key('${t['title_short'] ?? t['title'] ?? ''}');
    return k == wantedTitle ||
        k.contains(wantedTitle) ||
        wantedTitle.contains(k);
  }

  // (Deezer's artist:"…" track:"…" search answers nothing from here.)
  for (final q in ['$title $artist', title]) {
    final r = await _get('search?q=${_q(q)}&limit=10');
    final tracks = _data(r);
    final best =
        tracks.where((t) => sameArtist(t) && sameTitle(t)).firstOrNull ??
        tracks.where(sameArtist).firstOrNull;
    if (best != null) return deezerSongMap(best, 0);
  }
  return null;
}

Future<List<Map<String, dynamic>>> deezerSearchAlbums(String query) async {
  final r = await _get('search/album?q=${_q(query)}&limit=25');
  return [for (final a in _data(r)) deezerAlbumMap(a)];
}

Future<List<Map<String, dynamic>>> deezerSearchArtists(
  String query, {
  int limit = 5,
}) async {
  final r = await _get('search/artist?q=${_q(query)}&limit=${limit + 5}');
  // One artist spelt two ways ("Efrem"/"Ephrem Tamiru") shows once: the
  // spelling with most fans.
  final byFans = _data(r).toList()
    ..sort(
      (a, b) =>
          ((b['nb_fan'] as num?) ?? 0).compareTo((a['nb_fan'] as num?) ?? 0),
    );
  final kept = <Map>[];
  for (final a in byFans) {
    if (kept.any((k) => sameArtistName('${k['name']}', '${a['name']}'))) {
      continue;
    }
    kept.add(a);
  }
  // Back in Deezer's order of relevance.
  final order = _data(r).toList();
  kept.sort((a, b) => order.indexOf(a).compareTo(order.indexOf(b)));
  return [for (final a in kept.take(limit)) deezerArtistMap(a)];
}

/// The same artist under other spellings on Deezer (labels upload under
/// "Efrem Tamiru" or "Ephrem Tamiru"): their top songs and releases, shown
/// on one page with this one's. Two at most.
Future<
  List<({Map artist, Map<String, dynamic> top, Map<String, dynamic> albums})>
>
_artistTwins(String id, String name) async {
  if (!artistSoundKey(name).contains(' ')) return const [];
  final r = await _get('search/artist?q=${_q(name)}&limit=25');
  final twins = [
    for (final a in _data(r))
      if ('${a['id']}' != id && sameArtistName(name, '${a['name']}')) a,
  ].take(2).toList();
  return Future.wait([
    for (final t in twins)
      Future.wait([
        _get('artist/${t['id']}/top?limit=50'),
        _get(
          'artist/${t['id']}/albums?limit=100',
          keep: const Duration(hours: 3),
        ),
      ]).then((x) => (artist: t, top: x[0], albums: x[1])),
  ]);
}

Future<List<Map<String, dynamic>>> deezerSearchPlaylists(String query) async {
  final r = await _get('search/playlist?q=${_q(query)}&limit=25');
  return [for (final p in _data(r)) deezerPlaylistMap(p)];
}

// ---------------------------------------------------------------------------
// Artists
// ---------------------------------------------------------------------------

/// The Deezer artist called exactly [name] (the one with most fans when
/// several share it), or null.
Future<Map?> deezerArtistNamed(String name) async {
  final wanted = _key(name);
  if (wanted.isEmpty) return null;
  final r = await _get('search/artist?q=${_q(name)}&limit=25');
  final matches =
      [
        for (final a in _data(r))
          if (_key('${a['name']}') == wanted) a,
      ]..sort(
        (a, b) =>
            ((b['nb_fan'] as num?) ?? 0).compareTo((a['nb_fan'] as num?) ?? 0),
      );
  return matches.firstOrNull;
}

String _fans(num? fans) {
  if (fans == null || fans <= 0) return '';
  final n = fans.toInt();
  final short = n >= 1000000
      ? '${(n / 1000000).toStringAsFixed(1)}M'
      : n >= 1000
      ? '${(n / 1000).toStringAsFixed(n >= 10000 ? 0 : 1)}K'
      : '$n';
  return '$short fans';
}

/// An artist's page, in the shape getArtistProfile returns: photo, fans,
/// top songs, releases, related artists and all songs. Everything it needs
/// is asked for at once (a slow line pays for one round, not three): Apple's
/// releases as soon as the name is known ([name] when the caller has it),
/// a small artist's album songs as soon as Deezer lists the albums.
Future<Map<String, dynamic>?> deezerArtistProfile(
  String ytid, {
  String? name,
}) async {
  final id = ytid.substring(deezerArtistPrefix.length);
  final artistCall = _get('artist/$id');
  final topCall = _get('artist/$id/top?limit=50');
  // Three hours, so a new album is there the same day.
  final albumsCall = _get(
    'artist/$id/albums?limit=100',
    keep: const Duration(hours: 3),
  );
  final relatedCall = _get('artist/$id/related?limit=20')
      .catchError((_) => <String, dynamic>{});
  // Apple's releases of the artist that Deezer doesn't have (Madingo's
  // Swedlat, Vol. 3), added to the page; never waited for more than 6 s.
  final appleCall =
      (name != null && name.isNotEmpty
              ? itunesArtistReleases(name)
              : artistCall.then(
                  (a) => itunesArtistReleases('${a['name'] ?? ''}'),
                ))
          .timeout(const Duration(seconds: 6))
          .catchError((_) => <Map<String, dynamic>>[]);
  // A smaller artist's "top" list can be a song or two: their newest
  // releases' songs fill it up, most popular first.
  final fillCall = Future.wait([topCall, albumsCall])
      .then((r) async {
        if (_data(r[0]).length >= 10) return <Map<String, dynamic>?>[];
        final newest = _data(r[1])
          ..sort(
            (a, b) => '${b['release_date'] ?? ''}'.compareTo(
              '${a['release_date'] ?? ''}',
            ),
          );
        return Future.wait([
          for (final album in newest.take(4))
            deezerAlbum('$deezerAlbumPrefix${album['id']}')
                .catchError((_) => null),
        ]);
      })
      .catchError((_) => <Map<String, dynamic>?>[]);

  final twinsCall = artistCall
      .then((a) => _artistTwins(id, '${a['name'] ?? name ?? ''}'))
      .timeout(const Duration(seconds: 8))
      .catchError(
        (_) =>
            <
              ({
                Map artist,
                Map<String, dynamic> top,
                Map<String, dynamic> albums,
              })
            >[],
      );
  // Apple's releases under the other spellings too (Apple only finds the
  // spelling it's asked for).
  final appleTwinsCall = twinsCall
      .then(
        (twins) => Future.wait([
          for (final t in twins)
            itunesArtistReleases('${t.artist['name'] ?? ''}')
                .catchError((_) => <Map<String, dynamic>>[]),
        ]),
      )
      .timeout(const Duration(seconds: 8))
      .catchError((_) => <List<Map<String, dynamic>>>[]);
  final results = await Future.wait([
    artistCall,
    topCall,
    albumsCall,
    relatedCall,
  ]);
  final artist = results[0];
  final artistName = '${artist['name'] ?? ''}';
  if (artistName.isEmpty) return null;
  final apple = await appleCall;
  final top = [
    for (final (i, t) in _data(results[1]).indexed)
      deezerSongMap(t, i, artistName: artistName),
  ];
  // One copy of each release: Deezer can list one twice ("Aydergem (
  // Ethiopian…" and "Aydergem (Ethiopian…").
  final seenReleases = <String>{};
  final releases = [
    for (final a in _data(results[2]))
      if (seenReleases.add(_key('${a['title']}')))
        {...deezerAlbumMap(a, artistName: artistName), 'artistId': ytid},
    for (final a in apple)
      if (seenReleases.add(_key('${a['title']}'))) a,
  ]..sort((a, b) => '${b['year'] ?? ''}'.compareTo('${a['year'] ?? ''}'));
  for (final list in await appleTwinsCall) {
    for (final a in list) {
      if (seenReleases.add(_key('${a['title']}'))) releases.add(a);
    }
  }
  // The same artist spelt another way: their songs and releases too, and
  // their fans counted with these.
  final twins = await twinsCall;
  var fans = (artist['nb_fan'] as num?) ?? 0;
  if (twins.isNotEmpty) {
    final seenSongs = {for (final t in top) _key('${t['title']}')};
    for (final twin in twins) {
      fans += (twin.artist['nb_fan'] as num?) ?? 0;
      for (final t in _data(twin.top)) {
        if (!seenSongs.add(_key('${t['title']}'))) continue;
        top.add(deezerSongMap(t, top.length, artistName: artistName));
      }
      for (final a in _data(twin.albums)) {
        if (!seenReleases.add(_key('${a['title']}'))) continue;
        releases.add({
          ...deezerAlbumMap(a, artistName: artistName),
          'artistId': ytid,
        });
      }
    }
    top.sort(
      (a, b) =>
          ((b['rank'] as num?) ?? -1).compareTo((a['rank'] as num?) ?? -1),
    );
    releases.sort(
      (a, b) => '${b['year'] ?? ''}'.compareTo('${a['year'] ?? ''}'),
    );
  }
  final albums = await fillCall;
  if (albums.isNotEmpty) {
    final seen = {for (final t in top) _key('${t['title']}')};
    final more =
        [
          for (final album in albums)
            for (final t
                in ((album?['list'] as List?) ?? const []).whereType<Map>())
              if (seen.add(_key('${t['title']}'))) Map<String, dynamic>.from(t),
        ]..sort(
          (a, b) =>
              ((b['rank'] as num?) ?? -1).compareTo((a['rank'] as num?) ?? -1),
        );
    top.addAll(more.take(30 - top.length));
  }
  return {
    ...deezerArtistMap(artist),
    'description': null,
    'monthlyListeners': _fans(fans),
    'topSongs': [
      for (final s in top.take(20)) {'song': s, 'playCount': null},
    ],
    'releases': releases,
    'relatedArtists': [for (final a in _data(results[3])) deezerArtistMap(a)],
    'allSongs': top,
  };
}

/// The most played songs of the artist called [name] on Deezer, most
/// popular first (each with its `rank`).
Future<List<Map<String, dynamic>>> deezerArtistTopSongs(
  String name, {
  int limit = 12,
}) async {
  final artist = await deezerArtistNamed(name);
  if (artist == null) return const [];
  final r = await _get('artist/${artist['id']}/top?limit=$limit');
  return [
    for (final (i, t) in _data(r).indexed)
      deezerSongMap(t, i, artistName: '${artist['name']}'),
  ];
}

/// A page of the artist [ytid]'s songs, most played first: [limit] from
/// [index], and how many there are in all (for "See more").
Future<({List<Map<String, dynamic>> songs, int total})> deezerArtistSongsPage(
  String ytid, {
  int index = 0,
  int limit = 10,
}) async {
  final id = ytid.substring(deezerArtistPrefix.length);
  final r = await _get('artist/$id/top?limit=$limit&index=$index');
  return (
    songs: [for (final (i, t) in _data(r).indexed) deezerSongMap(t, index + i)],
    total: (r['total'] as num?)?.toInt() ?? 0,
  );
}

/// The artist called [name] on Deezer, as [deezerArtistProfile].
Future<Map<String, dynamic>?> deezerArtistByName(String name) async {
  final artist = await deezerArtistNamed(name);
  if (artist == null) return null;
  return deezerArtistProfile(
    '$deezerArtistPrefix${artist['id']}',
    name: '${artist['name'] ?? name}',
  );
}

/// The artist's photo from Deezer (a real photo, 1000 px), or null.
Future<String?> deezerArtistPhoto(String name) async {
  final artist = await deezerArtistNamed(name);
  final photo = (artist?['picture_xl'] ?? artist?['picture_big'])?.toString();
  // Deezer's stand-in for "no picture" is a grey silhouette.
  if (photo == null || photo.contains('/artist//')) return null;
  return photo;
}

/// Deezer's radio of an artist: their songs and songs like them.
Future<List<Map<String, dynamic>>> deezerArtistRadio(String name) async {
  final artist = await deezerArtistNamed(name);
  if (artist == null) return const [];
  final r = await _get('artist/${artist['id']}/radio?limit=40');
  return [for (final (i, t) in _data(r).indexed) deezerSongMap(t, i)];
}

// ---------------------------------------------------------------------------
// Albums and playlists
// ---------------------------------------------------------------------------

/// A release with its tracks, in the shape getArtistAlbum returns.
Future<Map<String, dynamic>?> deezerAlbum(String ytid) async {
  final id = ytid.substring(deezerAlbumPrefix.length);
  final album = await _get('album/$id');
  final tracks = _data((album['tracks'] as Map<String, dynamic>?) ?? {});
  return {
    ...deezerAlbumMap(album),
    'list': [
      for (final (i, t) in tracks.indexed) deezerSongMap(t, i, album: album),
    ],
  };
}

/// A public playlist with its songs, for the playlist page.
Future<Map<String, dynamic>?> deezerPlaylist(String ytid) async {
  final id = ytid.substring(deezerPlaylistPrefix.length);
  final playlist = await _get('playlist/$id');
  final tracks = _data((playlist['tracks'] as Map<String, dynamic>?) ?? {});
  return {
    ...deezerPlaylistMap(playlist),
    'list': [for (final (i, t) in tracks.indexed) deezerSongMap(t, i)],
  };
}

// ---------------------------------------------------------------------------
// Home
// ---------------------------------------------------------------------------

/// Deezer's chart (0 = everything, 2 = African music): its top songs.
Future<List<Map<String, dynamic>>> deezerChartSongs({int genre = 0}) async {
  final r = await _get(
    'chart/$genre/tracks?limit=50',
    keep: const Duration(hours: 6),
  );
  return [for (final (i, t) in _data(r).indexed) deezerSongMap(t, i)];
}

/// A release with the day it came out (`released`, "2026-10-22").
Map<String, dynamic> _withDate(Map album, {String? artistName}) => {
  ...deezerAlbumMap(album, artistName: artistName),
  'released': '${album['release_date'] ?? ''}',
};

/// Whether [album] came out in the last [days] days (and is out already).
bool _isNew(Map album, int days) {
  final date = DateTime.tryParse('${album['release_date'] ?? ''}');
  if (date == null) return false;
  final now = DateTime.now();
  return date.isAfter(now.subtract(Duration(days: days))) && !date.isAfter(now);
}

/// The releases of the artist called [name] out in the last [days] days.
/// (Deezer doesn't list an artist's albums by date, so all are looked at.)
Future<List<Map<String, dynamic>>> deezerArtistNewReleases(
  String name, {
  int days = 30,
}) async {
  final artist = await deezerArtistNamed(name);
  if (artist == null) return const [];
  final r = await _get(
    'artist/${artist['id']}/albums?limit=50',
    keep: const Duration(hours: 3),
  );
  return [
    for (final a in _data(r))
      if (_isNew(a, days)) _withDate(a, artistName: '${artist['name']}'),
  ];
}

/// Deezer's editors' picks of albums (0 = everything, 2 = African music),
/// without dates: [deezerNewRelease] has the day.
Future<List<Map<String, dynamic>>> deezerEditorialPicks({int genre = 0}) async {
  final r = await _get(
    'editorial/$genre/selection?limit=30',
    keep: const Duration(hours: 6),
  );
  return [for (final a in _data(r)) deezerAlbumMap(a)];
}

/// The release [ytid] (a Deezer album id) when it came out in the last
/// [days] days, with its date; else null.
Future<Map<String, dynamic>?> deezerNewRelease(
  String ytid, {
  int days = 30,
}) async {
  if (!ytid.startsWith(deezerAlbumPrefix)) return null;
  final album = await _get('album/${ytid.substring(deezerAlbumPrefix.length)}');
  return _isNew(album, days) ? _withDate(album) : null;
}

/// The release the song [title] by [artist] came out on, when that was in
/// the last [days] days; else null.
Future<Map<String, dynamic>?> deezerNewReleaseOfSong(
  String title,
  String artist, {
  int days = 30,
}) async {
  final song = await deezerFindSong(title, artist);
  if (song == null) return null;
  return deezerNewRelease('${song['albumId']}', days: days);
}

/// Public playlists with [artist] in them ("Featured in").
Future<List<Map<String, dynamic>>> deezerArtistPlaylists(String artist) async {
  final found = await deezerArtistNamed(artist);
  if (found == null) return const [];
  try {
    final r = await _get('artist/${found['id']}/playlists?limit=10');
    return [for (final p in _data(r)) deezerPlaylistMap(p)];
  } catch (_) {
    return const []; // Deezer answers "no playlist" with an error
  }
}

/// Deezer's chart playlists (0 = everything, 2 = African music).
Future<List<Map<String, dynamic>>> deezerChartPlaylists({int genre = 0}) async {
  final r = await _get(
    'chart/$genre/playlists?limit=10',
    keep: const Duration(hours: 6),
  );
  return [for (final p in _data(r)) deezerPlaylistMap(p)];
}

/// The songs of Deezer's ready mix called [title] ("Happy Hour", "Sad
/// Songs"…), or empty when there's none by that name.
Future<List<Map<String, dynamic>>> deezerMoodMix(String title) async {
  final all = await _get('radio', keep: const Duration(days: 7));
  final wanted = _key(title);
  final radio = _data(all).where((r) => _key('${r['title']}') == wanted);
  if (radio.isEmpty) return const [];
  final r = await _get('radio/${radio.first['id']}/tracks?limit=50');
  return [for (final (i, t) in _data(r).indexed) deezerSongMap(t, i)];
}

// ---------------------------------------------------------------------------
// Playback
// ---------------------------------------------------------------------------

/// What a Deezer song is, for finding its audio when nothing registered it
/// (after a restart, a download).
Future<({String title, String artist, Duration? duration})?> deezerSongHint(
  String songId,
) async {
  if (!isDeezerSongId(songId)) return null;
  try {
    final t = await _get('track/${songId.substring(deezerSongPrefix.length)}');
    final seconds = (t['duration'] as num?)?.toInt();
    return (
      title: '${t['title'] ?? ''}'.trim(),
      artist: '${(t['artist'] as Map?)?['name'] ?? ''}'.trim(),
      duration: seconds == null || seconds <= 0
          ? null
          : Duration(seconds: seconds),
    );
  } catch (e) {
    logger.log('Deezer track lookup failed for $songId', error: e);
    return null;
  }
}
