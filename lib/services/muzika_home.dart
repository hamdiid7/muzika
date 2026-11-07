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
import 'dart:math';

import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:muzika/utilities/artist_names.dart';
import 'package:muzika/main.dart' show logger;
import 'package:muzika/services/artist_service.dart'
    show getArtistProfile, ytMusicClient;
import 'package:muzika/services/catalog_relay.dart';
import 'package:muzika/services/common_services.dart';
import 'package:muzika/services/deezer_catalog.dart';
import 'package:muzika/services/deezer_related.dart';
import 'package:muzika/services/itunes_catalog.dart';
import 'package:muzika/services/listening_stats.dart';
import 'package:muzika/services/netease_catalog.dart';
import 'package:muzika/services/playlists_manager.dart';
import 'package:muzika/services/youtube_canvas.dart' show musicVideoFor;
import 'package:muzika/services/youtube_trending.dart';
import 'package:youtube_music_explode_dart/youtube_music_explode_dart.dart'
    show MusicCollection;

/// Everything the Home screen ranks: built from what the user plays, likes
/// and saves, plus the country their IP is in (for brand-new users).

// ---------------------------------------------------------------------------
// Location
// ---------------------------------------------------------------------------

String? _country;

/// The ISO country of the user's IP (from Cloudflare's public trace page),
/// cached for a day; falls back to the phone's region.
Future<String> userCountry() async {
  if (_country != null) return _country!;
  final box = Hive.box('cache');
  final cached = box.get('geoCountry');
  final cachedAt = box.get('geoCountryAt');
  if (cached is String &&
      cachedAt is int &&
      DateTime.now().millisecondsSinceEpoch - cachedAt < 86400000) {
    return _country = cached;
  }
  try {
    final res = await http
        .get(Uri.parse('https://www.cloudflare.com/cdn-cgi/trace'))
        .timeout(const Duration(seconds: 6));
    final country = RegExp(
      r'^loc=([A-Z]{2})$',
      multiLine: true,
    ).firstMatch(res.body)?.group(1);
    if (country is String && country.length == 2) {
      unawaited(box.put('geoCountry', country));
      unawaited(box.put('geoCountryAt', DateTime.now().millisecondsSinceEpoch));
      return _country = country;
    }
  } catch (e) {
    logger.log('Country lookup failed', error: e);
  }
  final region = Platform.localeName.split(RegExp('[_-]')).elementAtOrNull(1);
  return _country = (region == null || region.isEmpty ? 'ET' : region);
}

/// What a new listener in [country] most likely wants to hear.
String _localQuery(String country) => switch (country) {
  'ET' => 'Ethiopian music',
  'ER' => 'Eritrean music',
  'KE' => 'Kenyan music',
  'SO' => 'Somali music',
  'SD' || 'SS' => 'Sudanese music',
  'NG' => 'Afrobeats hits',
  'US' || 'GB' || 'CA' => 'Habesha music',
  _ => 'Ethiopian music',
};

// ---------------------------------------------------------------------------
// Scoring what the user listens to
// ---------------------------------------------------------------------------

String _primaryArtist(Map song) => (song['artist'] ?? '')
    .toString()
    .split(RegExp(r',|&| x | feat\.?'))
    .first
    .trim();

/// Groups spellings of one name ("Abraham"/"Abreham Gebremedhin",
/// "Efrem"/"Ephrem Tamiru"): how it sounds ([artistSoundKey]), spaces
/// dropped.
String _artistKey(String artist) => artistSoundKey(artist).replaceAll(' ', '');

String _songKey(Map song) =>
    '${(song['title'] ?? '').toString().toLowerCase().trim()}|'
    '${_primaryArtist(song).toLowerCase()}';

/// How much the user cares about each song they have touched: minutes
/// listened, how recently and how often it was played, and likes.
Map<String, ({Map song, double score})> _songScores() {
  final scores = <String, ({Map song, double score})>{};
  void add(Map song, double points) {
    final id = song['ytid']?.toString() ?? '';
    if (id.isEmpty) return;
    final prev = scores[id];
    scores[id] = (song: prev?.song ?? song, score: (prev?.score ?? 0) + points);
  }

  final recent = userRecentlyPlayed.value.whereType<Map>().toList();
  for (final (i, song) in recent.indexed) {
    final count = (song['listeningCount'] as num?)?.toDouble() ?? 1;
    add(song, 3 * (1 - i / max(recent.length, 1)) + log(1 + count));
  }
  for (final song in userLikedSongsList.value.whereType<Map>()) {
    add(song, 2);
  }
  for (final id in scores.keys.toList()) {
    final minutes = ListeningStats.instance.secondsFor(id) / 60;
    final entry = scores[id]!;
    scores[id] = (
      song: entry.song,
      score: entry.score + log(1 + minutes) * 1.5,
    );
  }
  return scores;
}

/// One square of the "for you" grid.
class HomeTile {
  const HomeTile({
    required this.kind,
    required this.id,
    required this.title,
    required this.subtitle,
    this.image,
    this.images = const [],
    this.data,
    this.artist = '',
  });

  /// Whose it is, so the grid shows each artist once (their page, an album
  /// or a song — not all three).
  final String artist;

  /// `artist`, `album`, `playlist`, `liked` or `song`.
  final String kind;
  final String id;
  final String title;
  final String subtitle;
  final String? image;

  /// Up to four covers, for playlists drawn as a 2×2 mosaic.
  final List<String> images;

  /// The song map (songs) or the playlist map (playlists).
  final Map? data;
}

/// The grid at the top of Home: the artists, albums, playlists and songs
/// the user plays most, mixed so no kind takes over.
List<HomeTile> forYouGrid({int count = 8}) {
  final scores = _songScores();
  if (scores.isEmpty) return const [];

  final artists = <String, ({Map song, double score, String? id})>{};
  final artistNames = <String, String>{};
  final albums = <String, ({Map song, double score})>{};
  for (final e in scores.values) {
    final name = _primaryArtist(e.song);
    final artist = _artistKey(name);
    if (artist.isNotEmpty) {
      artistNames.putIfAbsent(artist, () => name);
      final prev = artists[artist];
      artists[artist] = (
        song: prev?.song ?? e.song,
        score: (prev?.score ?? 0) + e.score,
        id: prev?.id ?? e.song['artistId']?.toString(),
      );
    }
    final albumId = e.song['albumId']?.toString() ?? '';
    if (albumId.startsWith('MPRE')) {
      final prev = albums[albumId];
      albums[albumId] = (
        song: prev?.song ?? e.song,
        score: (prev?.score ?? 0) + e.score,
      );
    }
  }

  String? cover(Map song) => (song['lowResImage'] ?? song['image'])?.toString();

  final candidates = <({HomeTile tile, double score})>[];

  final topArtists = artists.entries.toList()
    ..sort((a, b) => b.value.score.compareTo(a.value.score));
  for (final a in topArtists.take(3)) {
    candidates.add((
      tile: HomeTile(
        kind: 'artist',
        id: a.value.id ?? artistNames[a.key]!,
        title: artistNames[a.key]!,
        subtitle: 'Artist',
        image: cover(a.value.song),
        data: a.value.song,
        artist: artistNames[a.key]!,
      ),
      score: a.value.score * 0.8,
    ));
  }

  final topAlbums = albums.entries.toList()
    ..sort((a, b) => b.value.score.compareTo(a.value.score));
  for (final a in topAlbums.take(2)) {
    candidates.add((
      tile: HomeTile(
        kind: 'album',
        id: a.key,
        title: (a.value.song['album'] ?? 'Album').toString(),
        subtitle: _primaryArtist(a.value.song),
        image: cover(a.value.song),
        artist: _primaryArtist(a.value.song),
      ),
      score: a.value.score * 0.7,
    ));
  }

  for (final playlist in getUserCustomPlaylists()) {
    final songs = (playlist['list'] as List? ?? const []).whereType<Map>();
    if (songs.isEmpty) continue;
    var total = 0.0;
    for (final s in songs) {
      total += scores[s['ytid']?.toString()]?.score ?? 0;
    }
    candidates.add((
      tile: HomeTile(
        kind: 'playlist',
        id: '${playlist['ytid']}',
        title: '${playlist['title'] ?? 'Playlist'}',
        subtitle: '${songs.length} songs',
        image: playlist['image']?.toString(),
        images: [for (final s in songs.take(4)) ?cover(s)],
        data: playlist,
      ),
      score: total / sqrt(songs.length) + 1,
    ));
  }

  final topSongs = scores.values.toList()
    ..sort((a, b) => b.score.compareTo(a.score));
  for (final s in topSongs.take(count)) {
    candidates.add((
      tile: HomeTile(
        kind: 'song',
        id: '${s.song['ytid']}',
        title: '${s.song['title'] ?? ''}',
        subtitle: _primaryArtist(s.song),
        image: cover(s.song),
        data: s.song,
        artist: _primaryArtist(s.song),
      ),
      score: s.score * 0.6,
    ));
  }

  candidates.sort((a, b) => b.score.compareTo(a.score));
  final tiles = <HomeTile>[];
  final perKind = <String, int>{};
  for (final c in candidates) {
    final kind = c.tile.kind;
    // At most three of a kind, so the grid stays a mix.
    if ((perKind[kind] ?? 0) >= 3) continue;
    perKind[kind] = (perKind[kind] ?? 0) + 1;
    tiles.add(c.tile);
    if (tiles.length == count) break;
  }
  return tiles;
}

/// "Or listen again": recent songs, once each (by title and artist too, so
/// two uploads of one song don't both show), skipping [exclude] ids.
List<Map> listenAgain({Set<String> exclude = const {}, int count = 5}) {
  final seenIds = <String>{...exclude};
  final seenKeys = <String>{};
  final out = <Map>[];
  for (final song in userRecentlyPlayed.value.whereType<Map>()) {
    final id = song['ytid']?.toString() ?? '';
    if (id.isEmpty || !seenIds.add(id) || !seenKeys.add(_songKey(song))) {
      continue;
    }
    out.add(song);
    if (out.length == count) break;
  }
  return out;
}

// ---------------------------------------------------------------------------
// For you (catalog radio around the favourites, square art)
// ---------------------------------------------------------------------------

Future<List<Map>> _localSongs() async {
  try {
    final query = _localQuery(await userCountry());
    return [...(await fetchSongsList(query)).whereType<Map>()];
  } catch (e) {
    logger.log('Local songs failed', error: e);
    return [];
  }
}

/// Seed songs for recommendations: the user's favourites, or popular music
/// from their country when they are new.
Future<List<Map>> _seeds(int count) async {
  final scores = _songScores().values.toList()
    ..sort((a, b) => b.score.compareTo(a.score));
  final top = scores.take(count * 2).map((e) => e.song).toList()..shuffle();
  if (top.length >= count) return top.take(count).toList();
  final local = await _localSongs();
  return [...top, ...local.take(count - top.length)];
}

/// Songs the user hasn't played yet that sound like what they love.
Future<List<Map>> forYouSongs({int count = 10}) async {
  final seeds = await _seeds(3);
  final heard = {
    for (final s in userRecentlyPlayed.value.whereType<Map>()) '${s['ytid']}',
  };
  final scores = <String, double>{};
  final byId = <String, Map>{};
  await Future.wait([
    for (final (seedIndex, seed) in seeds.indexed)
      getRelatedSongs('${seed['ytid']}').then((related) {
        for (final (i, song) in related.indexed) {
          final id = '${song['ytid']}';
          if (heard.contains(id)) continue;
          byId[id] = song;
          scores[id] = (scores[id] ?? 0) + (1 - i / 25) * (1 - seedIndex / 6);
        }
      }),
  ]);
  final keys = <String>{};
  final ranked = scores.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  discoveryPool = [
    for (final e in ranked)
      if (keys.add(_songKey(byId[e.key]!))) byId[e.key]!,
  ];
  return discoveryPool.take(count).toList();
}

/// "14M", "1.2B" or "950K" (an artist page's play count) as a number.
int? parsePlayCount(String? token) {
  final m = RegExp(
    r'([\d.,]+)\s?([KMB]?)',
    caseSensitive: false,
  ).firstMatch(token ?? '');
  if (m == null) return null;
  final n = double.tryParse(m.group(1)!.replaceAll(',', ''));
  if (n == null) return null;
  final unit = switch (m.group(2)!.toUpperCase()) {
    'K' => 1e3,
    'M' => 1e6,
    'B' => 1e9,
    _ => 1.0,
  };
  return (n * unit).round();
}

List<Map>? _hitsCache;

/// Big songs (50M+ plays) the user hasn't heard, from the top songs of the
/// artists they play and the artists Discover found for them. Discover
/// slips one in now and then.
Future<List<Map>> discoverHits({int minPlays = 50000000}) async {
  if (_hitsCache != null) return _hitsCache!;
  final heard = {
    for (final s in userRecentlyPlayed.value.whereType<Map>()) '${s['ytid']}',
  };
  // Artists to read: favourites first, then new ones from the discovery pool.
  final artists = <({String id, String name})>[];
  final keys = <String>{};
  final favourites = _songScores().values.toList()
    ..sort((a, b) => b.score.compareTo(a.score));
  for (final s in [...favourites.map((e) => e.song), ...discoveryPool]) {
    final name = _primaryArtist(s);
    final id = '${s['artistId'] ?? ''}';
    if (name.isEmpty || !keys.add(_artistKey(name))) continue;
    artists.add((id: id.isNotEmpty && id != 'null' ? id : name, name: name));
    if (artists.length == 8) break;
  }
  final profiles = await Future.wait([
    for (final a in artists)
      getArtistProfile(
        a.id,
        preferredName: a.name,
      ).timeout(const Duration(seconds: 15)).catchError((_) => null),
  ]);
  final hits = <Map>[];
  for (final profile in profiles) {
    for (final entry in (profile?['topSongs'] as List? ?? const [])) {
      if (entry is! Map || entry['song'] is! Map) continue;
      final plays = parsePlayCount(entry['playCount']?.toString()) ?? 0;
      final song = entry['song'] as Map;
      if (plays < minPlays || heard.contains('${song['ytid']}')) continue;
      hits.add(song);
    }
  }
  hits.shuffle();
  return _hitsCache = hits;
}

/// Every new song the last [forYouSongs] found, best first. The grid's
/// discovery tiles and the Discover tab draw from it.
List<Map> discoveryPool = const [];

/// Grid tiles for artists and albums the user has never played, taken from
/// songs that sound like their favourites.
List<HomeTile> discoveryTiles({int count = 4}) {
  final heardArtists = <String>{};
  final heardAlbums = <String>{};
  for (final e in _songScores().values) {
    heardArtists.add(_artistKey(_primaryArtist(e.song)));
    final album = '${e.song['albumId'] ?? ''}';
    if (album.isNotEmpty) heardAlbums.add(album);
  }
  final artists = <HomeTile>[];
  final albums = <HomeTile>[];
  for (final song in discoveryPool) {
    final name = _primaryArtist(song);
    final cover = (song['lowResImage'] ?? song['image'])?.toString();
    if (name.isNotEmpty && heardArtists.add(_artistKey(name))) {
      artists.add(
        HomeTile(
          kind: 'artist',
          id: '${song['artistId'] ?? name}',
          title: name,
          subtitle: 'New artist for you',
          image: cover,
          data: song,
          artist: name,
        ),
      );
    }
    final albumId = '${song['albumId'] ?? ''}';
    if (albumId.startsWith('MPRE') && heardAlbums.add(albumId)) {
      albums.add(
        HomeTile(
          kind: 'album',
          id: albumId,
          title: '${song['album'] ?? 'Album'}',
          subtitle: 'New album · $name',
          image: cover,
          artist: name,
        ),
      );
    }
  }
  final out = <HomeTile>[];
  for (
    var i = 0;
    out.length < count && i < max(artists.length, albums.length);
    i++
  ) {
    if (i < artists.length) out.add(artists[i]);
    if (i < albums.length && out.length < count) out.add(albums[i]);
  }
  return out;
}

// ---------------------------------------------------------------------------
// Radio mixes (from the user's playlists and favourite artists)
// ---------------------------------------------------------------------------

class HomeRadio {
  const HomeRadio({
    required this.title,
    required this.subtitle,
    required this.songs,
    this.playlistId,
  });

  /// The YouTube Music playlist behind the card, when it is one.
  final String? playlistId;

  final String title;
  final String subtitle;

  /// Seed first, then the radio. The first four covers make the card.
  final List<Map> songs;
}

/// Playlists to discover from Deezer: its chart where you are, then its
/// chart playlists (African music first) and public playlists with your
/// favourite artists in them, none you've saved.
Future<List<HomeRadio>> _deezerRadios(int count) async {
  final cached = _playlistCache;
  if (cached != null &&
      DateTime.now().difference(_playlistCacheAt) < const Duration(hours: 1)) {
    return cached;
  }
  final scores = _songScores().values.toList()
    ..sort((a, b) => b.score.compareTo(a.score));
  final artists = <String>[];
  final seen = <String>{};
  for (final s in scores) {
    final a = _primaryArtist(s.song);
    if (a.isNotEmpty && seen.add(_artistKey(a))) artists.add(a);
    if (artists.length == 2) break;
  }
  final lists = await Future.wait([
    deezerChartPlaylists(genre: 2).catchError((_) => <Map<String, dynamic>>[]),
    for (final a in artists)
      deezerArtistPlaylists(a).catchError((_) => <Map<String, dynamic>>[]),
    deezerChartPlaylists().catchError((_) => <Map<String, dynamic>>[]),
  ]);
  final saved = {for (final p in getUserCustomPlaylists()) '${p['ytid']}'};
  final picked = <Map<String, dynamic>>[];
  final ids = <String>{};
  // Round-robin over the lists so every one gets a card.
  for (var i = 0; picked.length < count - 1 && i < 6; i++) {
    for (final list in lists) {
      if (i < list.length &&
          !saved.contains(list[i]['ytid']) &&
          ids.add('${list[i]['ytid']}')) {
        picked.add(list[i]);
        if (picked.length == count - 1) break;
      }
    }
  }
  final radios = <HomeRadio?>[
    // The chart first: what's played most where you are.
    await deezerChartSongs(genre: 2)
        .then<HomeRadio?>(
          (songs) => songs.length < 8
              ? null
              : HomeRadio(
                  title: 'Top African songs',
                  subtitle: 'The chart on Deezer this week',
                  songs: songs,
                ),
        )
        .catchError((_) => null),
    ...await Future.wait([
      for (final p in picked)
        deezerPlaylist('${p['ytid']}')
            .then<HomeRadio?>((full) {
              final songs = [
                ...((full?['list'] as List?) ?? const []).whereType<Map>(),
              ];
              if (songs.length < 8) return null;
              return HomeRadio(
                title: '${p['title']}',
                subtitle: '${p['subtitle'] ?? 'Playlist'}',
                songs: songs,
                playlistId: '${p['ytid']}',
              );
            })
            .catchError((_) => null),
    ]),
  ];
  final result = radios.whereType<HomeRadio>().toList();
  if (result.isNotEmpty) {
    _playlistCache = result;
    _playlistCacheAt = DateTime.now();
  }
  return result;
}

// ---------------------------------------------------------------------------
// Daily Mixes
// ---------------------------------------------------------------------------

/// A mix around one of your favourite artists, as Spotify's Daily Mix: the
/// artist's photo (Deezer) and the artists like them in it.
class DailyMix {
  const DailyMix({
    required this.number,
    required this.artist,
    required this.related,
    this.photo,
  });

  final int number;
  final String artist;
  final List<String> related;
  final String? photo;

  String get title => 'Daily Mix ${number.toString().padLeft(2, '0')}';

  /// "Teddy Afro, Gossaye Tesfaye, Ephrem Tamiru and more".
  String get subtitle {
    final names = [artist, ...related.take(2)];
    return '${names.join(', ')} and more';
  }
}

/// Up to [count] mixes, one per favourite artist (artists already in an
/// earlier mix don't lead another).
Future<List<DailyMix>> dailyMixes({int count = 4}) async {
  final scores = _songScores().values.toList()
    ..sort((a, b) => b.score.compareTo(a.score));
  final leads = <String>[];
  final seen = <String>{};
  for (final s in scores) {
    final a = _primaryArtist(s.song);
    if (a.isNotEmpty && seen.add(_artistKey(a))) leads.add(a);
    if (leads.length == count * 2) break;
  }
  final mixes = <DailyMix>[];
  final inMix = <String>{};
  for (final artist in leads) {
    if (mixes.length == count) break;
    if (inMix.contains(_artistKey(artist))) continue;
    final related = await relatedArtists(artist)
        .catchError((_) => <RelatedArtist>[]);
    final photo = await deezerArtistPhoto(artist).catchError((_) => null);
    if (related.isEmpty && photo == null) continue;
    inMix.add(_artistKey(artist));
    for (final r in related.take(3)) {
      inMix.add(_artistKey(r.name));
    }
    mixes.add(
      DailyMix(
        number: mixes.length + 1,
        artist: artist,
        related: [for (final r in related) r.name],
        photo: photo,
      ),
    );
  }
  return mixes;
}

/// The songs of [mix]: yours by its artists first in the mix, then
/// Deezer's radio of the artist (theirs and songs like them), shuffled.
Future<List<Map>> dailyMixSongs(DailyMix mix) async {
  final artists = {
    _artistKey(mix.artist),
    for (final r in mix.related.take(5)) _artistKey(r),
  };
  final yours = [
    for (final s in _songScores().values)
      if (artists.contains(_artistKey(_primaryArtist(s.song)))) s.song,
  ]..shuffle();
  final radio = await deezerArtistRadio(mix.artist)
      .catchError((_) => <Map<String, dynamic>>[]);
  final ids = <String>{};
  final songs = <Map>[
    for (final s in [...yours.take(8), ...radio])
      if (ids.add(_songKey(s))) s,
  ]..shuffle();
  return songs.take(50).toList();
}

// ---------------------------------------------------------------------------
// New releases
// ---------------------------------------------------------------------------

/// The artists the user plays most (8) and artists like the first four
/// (4 each). [wanted] maps each one's key to which of the user's artists
/// it's like (null: one of the user's own).
Future<({List<String> yours, List<String> alike, Map<String, String?> wanted})>
_yourArtists() async {
  final scores = _songScores().values.toList()
    ..sort((a, b) => b.score.compareTo(a.score));
  final yours = <String>[];
  final seen = <String>{};
  for (final s in scores) {
    final a = _primaryArtist(s.song);
    if (a.isNotEmpty && seen.add(_artistKey(a))) yours.add(a);
    if (yours.length == 8) break;
  }
  final wanted = <String, String?>{for (final a in yours) _artistKey(a): null};
  final alike = <String>[];
  final related = await Future.wait([
    for (final a in yours.take(4))
      relatedArtists(a).catchError((_) => <RelatedArtist>[]),
  ]);
  for (final (i, list) in related.indexed) {
    for (final r in list.take(4)) {
      final key = _artistKey(r.name);
      if (key.length < 3 || wanted.containsKey(key)) continue;
      wanted[key] = yours[i];
      alike.add(r.name);
    }
  }
  return (yours: yours, alike: alike, wanted: wanted);
}

bool _isWanted(Map<String, String?> wanted, String artist) {
  final key = _artistKey(artist.split(RegExp(r',|&| x | and | feat\.?')).first);
  return key.length >= 3 && wanted.containsKey(key);
}

List<Map>? _newCache;
DateTime _newCacheAt = DateTime.fromMillisecondsSinceEpoch(0);

/// What came out in the last month by the artists the user plays, and by
/// artists like them (each such release says which of theirs it's like, in
/// `because`): every Deezer release of theirs, Deezer's editors' picks
/// (African music first) and NetEase's lists of new songs (Western, Korean,
/// Japanese, Chinese). Nothing unrelated: empty when none of them put
/// anything out, and Home leaves the shelf out.
Future<List<Map>> newReleasesForYou({int count = 12}) async {
  final cached = _newCache;
  if (cached != null &&
      DateTime.now().difference(_newCacheAt) < const Duration(hours: 1)) {
    return cached;
  }
  final (:yours, :alike, :wanted) = await _yourArtists();
  if (yours.isEmpty) return const [];
  bool isWanted(String artist) => _isWanted(wanted, artist);

  final found = <Map>[];
  // Each artist's own releases, a few at a time (Deezer turns bursts away).
  final names = [...yours, ...alike];
  for (var i = 0; i < names.length; i += 6) {
    final batch = await Future.wait([
      for (final n in names.skip(i).take(6))
        deezerArtistNewReleases(n).catchError((_) => <Map<String, dynamic>>[]),
    ]);
    for (final list in batch) {
      found.addAll(list);
    }
  }
  // Releases by the same artists that Deezer's editors picked or NetEase
  // lists as new (a collaboration, a single not yet on the artist's page).
  final picks = await Future.wait([
    deezerEditorialPicks(genre: 2).catchError((_) => <Map<String, dynamic>>[]),
    deezerEditorialPicks().catchError((_) => <Map<String, dynamic>>[]),
  ]);
  final netease = await neteaseNewSongs().catchError((_) => <NeteaseNewSong>[]);
  final monthAgo = DateTime.now().subtract(const Duration(days: 30));
  final more = await Future.wait([
    for (final a in picks.expand((p) => p).take(60))
      if (isWanted('${a['artist'] ?? ''}'))
        deezerNewRelease('${a['ytid']}').catchError((_) => null),
    for (final s in netease.take(400))
      if (s.released.isAfter(monthAgo) && isWanted(s.artist))
        deezerNewReleaseOfSong(s.title, s.artist).catchError((_) => null),
  ]);
  found.addAll(more.whereType<Map>());

  final ids = <String>{};
  final releases = [
    for (final r in found)
      if (isWanted('${r['artist'] ?? ''}') &&
          ids.add(
            '${_artistKey('${r['artist']}')}|'
            '${'${r['title']}'.toLowerCase().replaceAll(RegExp(r'\s*[\(\[].*'), '')}',
          ))
        {
          ...r,
          'because':
              wanted[_artistKey(
                '${r['artist']}'.split(RegExp(r',|&| x | feat\.?')).first,
              )],
        },
  ];
  // The user's own artists first, then artists like them; newest first.
  releases.sort((a, b) {
    final mine =
        (a['because'] == null ? 0 : 1) - (b['because'] == null ? 0 : 1);
    return mine != 0 ? mine : '${b['released']}'.compareTo('${a['released']}');
  });
  final result = releases.take(count).toList();
  _newCache = result;
  _newCacheAt = DateTime.now();
  return result;
}

// ---------------------------------------------------------------------------
// Stories
// ---------------------------------------------------------------------------

/// A story at the top of Home: an artist's new music video.
typedef HomeStory = ({
  TrendingVideo video,

  /// Why it's there: "Your artist", "Like Protoje", or null (trending).
  String? because,

  /// The song itself in the catalog (Deezer's or Apple's): what Play plays,
  /// with its cover and the official audio.
  Map song,
});

final _catalogSongs = <String, Future<Map?>>{};

/// The song of a music video in the catalog (Deezer, else Apple): the same
/// title and artist. Null when neither has it, which means it isn't a
/// release (a fan's upload, a song that isn't out). Looked up once per
/// video.
Future<Map?> catalogSongForVideo(TrendingVideo v) =>
    _catalogSongs[v.id] ??= () async {
      String key(Object? s) => '$s'
          .toLowerCase()
          .replaceAll(RegExp(r'\s*[\(\[][^\)\]]*[\)\]]'), '')
          .replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');
      final title = key(v.songTitle);
      final artist = key(v.artist);
      if (title.isEmpty || artist.isEmpty) return null;
      bool same(Map s) {
        final t = key(s['title']);
        final a = key(s['artist']);
        return t.isNotEmpty &&
            (t == title || t.contains(title) || title.contains(t)) &&
            (a.contains(artist) || artist.contains(a));
      }

      for (final search in [deezerSearchSongs, itunesSearchSongs]) {
        final found = await search('${v.artist} ${v.songTitle}')
            .timeout(const Duration(seconds: 10))
            .catchError((_) => <Map<String, dynamic>>[]);
        final hit = found.where(same).firstOrNull;
        if (hit != null) return hit;
      }
      return null;
    }();

List<HomeStory>? _storiesCache;

/// Home's stories as last picked (no download), or empty before then.
List<HomeStory> get pickedHomeStories => _storiesCache ?? const [];

final _artistStories = <String, Future<HomeStory?>>{};

/// Whose story it is: the stories of one artist play one after the other,
/// under one bubble.
String storyArtistKey(HomeStory story) => _artistKey(story.video.artist);

String _ageLabel(Duration age) {
  final days = age.inDays;
  return days <= 0
      ? 'Today'
      : days == 1
      ? '1 day ago'
      : days < 14
      ? '$days days ago'
      : '${days ~/ 7} weeks ago';
}

/// A story for a song with no video in the stories: its cover and Deezer's
/// 30 s of it. Null when Deezer has no preview.
HomeStory? _songStory(
  Map song, {
  String? released,
  String? photo,
  String? because,
}) {
  if (!'${song['preview'] ?? ''}'.startsWith('http')) return null;
  final date = DateTime.tryParse('${released ?? ''}');
  final age = date == null ? Duration.zero : DateTime.now().difference(date);
  final artist = '${song['artist'] ?? ''}';
  return (
    video: TrendingVideo(
      id: 'release:${song['ytid']}',
      title: '$artist - ${song['title']}',
      artists: artist,
      views: '',
      age: age,
      ageLabel: _ageLabel(age),
      avatar: photo,
      still: '${song['highResImage'] ?? song['image'] ?? ''}',
    ),
    because: because,
    song: song,
  );
}

/// The story of the artist called [name] when they've put something out in
/// the last four weeks: their first in Home's stories when they're there;
/// else made from their newest release on Deezer, its music video when it
/// has one (else its cover and 30 s preview). Null when nothing is new.
/// Once per artist a session (the lookups underneath are kept longer).
Future<HomeStory?> artistStory(String name) {
  final key = name.toLowerCase().trim();
  if (key.isEmpty) return Future.value();
  return _artistStories[key] ??= () async {
    String plain(String s) =>
        s.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');
    final wanted = plain(name);
    for (final s in pickedHomeStories) {
      if (s.video.collaborators.any((c) => plain(c) == wanted)) return s;
    }
    final releases = await deezerArtistNewReleases(
      name,
      days: 28,
    ).catchError((_) => <Map<String, dynamic>>[]);
    if (releases.isEmpty) return null;
    releases.sort((a, b) => '${b['released']}'.compareTo('${a['released']}'));
    final release = releases.first;
    final album = await deezerAlbum('${release['ytid']}')
        .catchError((_) => null);
    final tracks = [
      ...((album?['list'] as List?) ?? const []).whereType<Map>(),
    ];
    if (tracks.isEmpty) return null;
    // The lead song: a single's own, an album's most played.
    final song = Map<String, dynamic>.from(
      release['releaseType'] == 'album'
          ? (tracks..sort(
                  (a, b) => ((b['rank'] as num?) ?? 0).compareTo(
                    (a['rank'] as num?) ?? 0,
                  ),
                ))
                .first
          : tracks.first,
    );
    final released = DateTime.tryParse('${release['released']}');
    final age = released == null
        ? Duration.zero
        : DateTime.now().difference(released);
    final artistName = '${song['artist'] ?? name}';
    final photo = await deezerArtistPhoto(name).catchError((_) => null);
    final mv = await musicVideoFor(song).catchError((_) => null);
    if (mv != null) {
      return (
        video: TrendingVideo(
          id: mv.id,
          title: '$artistName - ${song['title']} (Official Video)',
          artists: artistName,
          views: '',
          age: age,
          ageLabel: _ageLabel(age),
          length: mv.length,
          avatar: photo,
        ),
        because: null,
        song: song,
      );
    }
    return _songStory(song, released: '${release['released']}', photo: photo);
  }();
}

DateTime _storiesCacheAt = DateTime.fromMillisecondsSinceEpoch(0);
Future<List<HomeStory>>? _storiesLoading;

/// Home's stories: only what's new from the user's artists and artists
/// like them, nothing generic. Every new music video of theirs on YouTube's
/// trending playlists (when the song is a real release), then every song of
/// what they put out on Deezer in the last month that has no video there
/// (cover and 30 s), so an album of nine songs is nine stories. Grouped by
/// artist (one bubble each, played in a row), the user's own artists
/// first, each artist's newest first. Fewer than eight artists: YouTube's
/// hottest new music videos fill it up to eight.
Future<List<HomeStory>> homeStories() {
  final cached = _storiesCache;
  if (cached != null &&
      DateTime.now().difference(_storiesCacheAt) < const Duration(hours: 1)) {
    return Future.value(cached);
  }
  return _storiesLoading ??= _pickStories().whenComplete(
    () => _storiesLoading = null,
  );
}

/// Each story artist's photo from Deezer, by [storyArtistKey]: what the
/// bubbles show when there is one.
final storyArtistPhotos = <String, String>{};

/// The row always has at least this many artists (when YouTube has them).
const _minStoryArtists = 8;

Future<List<HomeStory>> _pickStories() async {
  final (:yours, alike: _, :wanted) = await _yourArtists().catchError(
    (_) => (yours: <String>[], alike: <String>[], wanted: <String, String?>{}),
  );
  String because(String artist) {
    final like =
        wanted[_artistKey(
          artist.split(RegExp(r',|&| x | and | feat\.?')).first,
        )];
    return like == null ? 'Your artist' : 'Like $like';
  }

  // YouTube: each new music video by the user's artists or artists like
  // them, and only real releases (the song has to be in the catalog).
  final videos = await trendingMusicVideos().catchError(
    (_) => <TrendingVideo>[],
  );
  final wantedVideos = [
    for (final v in videos)
      if (_isWanted(wanted, v.artist)) v,
  ].take(40).toList();
  final catalog = await Future.wait([
    for (final v in wantedVideos)
      catalogSongForVideo(v).catchError((_) => null),
  ]);
  final stories = <HomeStory>[
    for (final (i, v) in wantedVideos.indexed)
      if (catalog[i] case final song?)
        (video: v, because: because(v.artist), song: song),
  ];
  final told = {for (final s in stories) _songKey(s.song)};

  // Deezer: every song of what they put out in the last month (twelve at
  // most from one release) not already there as a video.
  final releases = await newReleasesForYou(count: 30)
      .catchError((_) => <Map>[]);
  final albums = await Future.wait([
    for (final r in releases)
      deezerAlbum('${r['ytid']}').catchError((_) => null),
  ]);
  final photos = <String, Future<String?>>{};
  for (final (i, release) in releases.indexed) {
    final tracks = [
      ...((albums[i]?['list'] as List?) ?? const []).whereType<Map>(),
    ].take(12);
    for (final t in tracks) {
      if (!told.add(_songKey(t))) continue;
      // The photo of the song's own artist (whose bubble it goes under),
      // not the release's.
      final artist = '${t['artist'] ?? release['artist'] ?? ''}'
          .split(RegExp(r',|&| x | feat\.? '))
          .first
          .trim();
      final photo = await (photos[_artistKey(artist)] ??= deezerArtistPhoto(
        artist,
      ).catchError((_) => null));
      final story = _songStory(
        t,
        released: '${release['released'] ?? ''}',
        photo: photo,
        because: release['because'] == null
            ? 'Your artist'
            : 'Like ${release['because']}',
      );
      if (story != null) stories.add(story);
    }
  }

  // Fewer than eight artists (a new user, a quiet month): what's hottest
  // on YouTube's new music videos fills the row up to eight, after them.
  final artists = {for (final s in stories) storyArtistKey(s)};
  if (artists.length < _minStoryArtists) {
    final hot = [
      for (final v in videos)
        if (!_isWanted(wanted, v.artist)) v,
    ]..sort((a, b) => b.heat.compareTo(a.heat));
    final picked = <TrendingVideo>[];
    final pickedArtists = {...artists};
    for (final v in hot) {
      if (pickedArtists.add(_artistKey(v.artist))) picked.add(v);
    }
    for (
      var i = 0;
      i < picked.length && artists.length < _minStoryArtists;
      i += 6
    ) {
      final batch = picked.skip(i).take(6).toList();
      final songs = await Future.wait([
        for (final v in batch) catalogSongForVideo(v).catchError((_) => null),
      ]);
      for (final (j, v) in batch.indexed) {
        final song = songs[j];
        if (song == null || artists.length >= _minStoryArtists) continue;
        artists.add(_artistKey(v.artist));
        stories.add((video: v, because: null, song: song));
      }
    }
  }

  // One run per artist: the user's own artists first, then artists like
  // them, then the hottest; within each, newest first.
  final groups = <String, List<HomeStory>>{};
  for (final s in stories) {
    (groups[storyArtistKey(s)] ??= []).add(s);
  }
  final ordered = groups.values.toList()
    ..sort((a, b) {
      int rank(HomeStory s) => s.because == 'Your artist'
          ? 0
          : s.because == null
          ? 2
          : 1;
      return rank(a.first) - rank(b.first);
    });
  final result = [
    for (final g in ordered)
      ...(g..sort((a, b) => a.video.age.compareTo(b.video.age))),
  ];
  // Each bubble's photo: the artist's on Deezer (a video's own picture is
  // often a cover or a label's logo).
  final names = {for (final g in ordered) storyArtistKey(g.first): g.first};
  final found = await Future.wait([
    for (final s in names.values)
      deezerArtistPhoto(s.video.artist).catchError((_) => null),
  ]);
  for (final (i, key) in names.keys.indexed) {
    final photo = found[i];
    if (photo != null) storyArtistPhotos[key] = photo;
  }
  _storiesCache = result;
  _storiesCacheAt = DateTime.now();
  return result;
}

/// Home's "New releases for you": the stories' songs (the same picks:
/// the user's artists and artists like them, YouTube's new videos and
/// Deezer's releases), one artist at a time so no one fills the shelf.
/// Each keeps `because`.
Future<List<Map>> newReleaseSongs({int count = 16}) async {
  final stories = await homeStories();
  final groups = <String, List<HomeStory>>{};
  for (final s in stories) {
    // Not the row's fillers (trending, not related to the user).
    if (s.because == null) continue;
    (groups[storyArtistKey(s)] ??= []).add(s);
  }
  final songs = <Map>[];
  final ids = <String>{};
  for (var round = 0; songs.length < count; round++) {
    var any = false;
    for (final g in groups.values) {
      if (round >= g.length) continue;
      any = true;
      final s = g[round];
      if (!ids.add(_songKey(s.song))) continue;
      // The shelf's own form: null for the user's artist, else whose
      // artist it's like.
      final because = s.because;
      songs.add({
        ...s.song,
        'because': because == null || because == 'Your artist'
            ? null
            : because.replaceFirst('Like ', ''),
      });
      if (songs.length == count) break;
    }
    if (!any) break;
  }
  return songs;
}

List<HomeRadio>? _playlistCache;
DateTime _playlistCacheAt = DateTime.fromMillisecondsSinceEpoch(0);

/// Playlists to discover: community playlists around the user's favourite
/// artists and what people in their country listen to — not what they
/// already played.
Future<List<HomeRadio>> homeRadios({int count = 6}) async {
  if (!catalogRelayEnabled) return _deezerRadios(count);
  final cached = _playlistCache;
  if (cached != null &&
      DateTime.now().difference(_playlistCacheAt) < const Duration(hours: 1)) {
    return cached;
  }

  final scores = _songScores().values.toList()
    ..sort((a, b) => b.score.compareTo(a.score));
  final artists = <String>[];
  final seen = <String>{};
  for (final s in scores) {
    final a = _primaryArtist(s.song);
    if (a.isNotEmpty && seen.add(_artistKey(a))) artists.add(a);
    if (artists.length == 3) break;
  }
  final local = _localQuery(await userCountry());
  final queries = [
    for (final a in artists) '$a mix',
    '$local playlist',
    'new $local',
  ];
  final saved = {for (final p in getUserCustomPlaylists()) '${p['ytid']}'};

  final picked = <MusicCollection>[];
  final ids = <String>{};
  final found = await Future.wait([
    for (final q in queries)
      ytMusicClient.music
          .searchPlaylists(q)
          .timeout(const Duration(seconds: 15))
          .catchError((_) => <MusicCollection>[]),
  ]);
  // Round-robin over the queries so every taste gets a card.
  for (var i = 0; picked.length < count && i < 4; i++) {
    for (final list in found) {
      if (i < list.length &&
          !saved.contains(list[i].id) &&
          ids.add(list[i].id)) {
        picked.add(list[i]);
        if (picked.length == count) break;
      }
    }
  }

  final radios = await Future.wait([
    for (final p in picked)
      ytMusicClient.music
          .getPlaylistSongs(p.id)
          .timeout(const Duration(seconds: 15))
          .then<HomeRadio?>((tracks) {
            final songs = [
              for (final (i, t) in tracks.indexed) songMapFromCatalog(t, i),
            ];
            // Audio tracks only; a playlist that is mostly video uploads
            // isn't offered at all.
            final list = songs.where((s) => !isVideoArtSong(s)).toList();
            if (list.length < 6) return null;
            return HomeRadio(
              title: p.title,
              subtitle: {for (final s in list.take(8)) _primaryArtist(s)}
                  .where((a) => a.isNotEmpty)
                  .take(3)
                  .join(', '),
              songs: list,
              playlistId: p.id,
            );
          })
          .catchError((_) => null),
  ]);
  final result = radios.whereType<HomeRadio>().toList();
  if (result.isNotEmpty) {
    _playlistCache = result;
    _playlistCacheAt = DateTime.now();
  }
  return result;
}

/// The Home grid: what you play and what's new to you, taking turns, with
/// songs and playlists in the mix. Each artist appears once, and Liked Songs
/// only when it earns a place (few tiles of your own, or every other day).
List<HomeTile> homeGrid({int count = 8}) {
  final mine = forYouGrid(count: 12);
  final fresh = discoveryTiles(count: 8);
  final heard = {
    for (final s in userRecentlyPlayed.value.whereType<Map>()) '${s['ytid']}',
  };
  final freshSongs = [
    for (final s in discoveryPool)
      if (!heard.contains('${s['ytid']}'))
        HomeTile(
          kind: 'song',
          id: '${s['ytid']}',
          title: '${s['title'] ?? ''}',
          subtitle: 'New song · ${_primaryArtist(s)}',
          image: (s['lowResImage'] ?? s['image'])?.toString(),
          data: s,
          artist: _primaryArtist(s),
        ),
  ];
  final freshPlaylists = [
    for (final r in _playlistCache ?? const <HomeRadio>[])
      if (r.playlistId != null)
        HomeTile(
          kind: 'playlist',
          id: r.playlistId!,
          title: r.title,
          subtitle: 'Playlist',
          images: [
            for (final s in r.songs.take(4))
              ?(s['lowResImage'] ?? s['image'])?.toString(),
          ],
        ),
  ];

  final liked = userLikedSongsList.value.whereType<Map>().toList();
  final likedTile = liked.isEmpty
      ? null
      : HomeTile(
          kind: 'liked',
          id: 'liked',
          title: 'Liked Songs',
          subtitle: '${liked.length} songs',
          images: [
            for (final s in liked.take(4))
              ?(s['lowResImage'] ?? s['image'])?.toString(),
          ],
        );
  final showLiked =
      likedTile != null && (mine.length < 4 || DateTime.now().day.isEven);

  final tiles = <HomeTile>[];
  final ids = <String>{};
  final artists = <String>{};
  bool add(HomeTile t) {
    if (tiles.length >= count || !ids.add('${t.kind}:${t.id}')) return false;
    final key = _artistKey(t.artist);
    if (key.isNotEmpty && !artists.add(key)) return false;
    tiles.add(t);
    return true;
  }

  if (showLiked) add(likedTile);
  // Take turns: yours, a new artist or album, yours, a new song, yours, a
  // new playlist… then whatever is left.
  final pools = [mine, fresh, mine, freshSongs, mine, freshPlaylists];
  final cursors = List.filled(pools.length, 0);
  var progressed = true;
  while (tiles.length < count && progressed) {
    progressed = false;
    for (var p = 0; p < pools.length && tiles.length < count; p++) {
      final pool = pools[p];
      // Shared lists (mine) keep one cursor between their turns.
      final c = pools.indexOf(pool);
      while (cursors[c] < pool.length) {
        final t = pool[cursors[c]++];
        progressed = true;
        if (add(t)) break;
      }
    }
  }
  return tiles;
}

// ---------------------------------------------------------------------------
// Chips
// ---------------------------------------------------------------------------

class HomeChip {
  const HomeChip({required this.label, required this.query, this.seed});

  final String label;

  /// Playlist search behind a mood chip ("workout music"), so the chip
  /// finds music for the mood instead of an album called "Workout".
  final String query;

  /// For artist chips: a song of theirs to start a radio from.
  final Map? seed;
}

const _moodQueries = <String, String>{
  'Tizita': 'tizita ethiopian songs',
  'Ethio Jazz': 'ethio jazz classics',
  'Amharic hits': 'new amharic songs',
  'Oromo music': 'afaan oromo music',
  'Tigrigna': 'tigrigna music',
  'Mezmur': 'amharic mezmur',
  'Workout': 'workout music',
  'Relax': 'relaxing chill music',
  'Party': 'party hits',
  'Sad songs': 'sad songs',
  'Focus': 'focus music',
  'Reggae': 'reggae',
  'Love songs': 'ethiopian love songs',
};

/// Chips that play one of Deezer's ready mixes rather than a search (the
/// Ethiopian ones have no Deezer mix).
const _moodMixes = <String, String>{
  'Workout': 'Dance',
  'Relax': 'Acoustic Afternoon',
  'Party': 'Happy Hour',
  'Sad songs': 'Sad Songs',
  'Focus': 'Focus',
  'Reggae': 'Reggae',
};

/// Chips ordered by the user: their top two artists first, then the moods
/// they tap most. A chip tapped often moves left.
List<HomeChip> homeChips() {
  final taps = Map<String, int>.from(
    (Hive.box('user').get('chipTaps') as Map?)?.cast<String, int>() ?? {},
  );
  final scores = _songScores().values.toList()
    ..sort((a, b) => b.score.compareTo(a.score));
  final artistChips = <HomeChip>[];
  final seen = <String>{};
  for (final s in scores) {
    final artist = _primaryArtist(s.song);
    if (artist.isEmpty || !seen.add(_artistKey(artist))) continue;
    artistChips.add(HomeChip(label: artist, query: artist, seed: s.song));
    if (artistChips.length == 2) break;
  }
  final moods = _moodQueries.entries.toList()
    ..sort((a, b) => (taps[b.key] ?? 0).compareTo(taps[a.key] ?? 0));
  return [
    ...artistChips,
    for (final m in moods) HomeChip(label: m.key, query: m.value),
  ];
}

void recordChipTap(HomeChip chip) {
  final box = Hive.box('user');
  final taps = Map<String, int>.from(
    (box.get('chipTaps') as Map?)?.cast<String, int>() ?? {},
  );
  taps[chip.label] = (taps[chip.label] ?? 0) + 1;
  unawaited(box.put('chipTaps', taps));
}

final _chipCache = <String, List<Map>>{};

/// The songs behind a chip: an artist radio, or the best matching community
/// playlist for a mood (falling back to a song search).
Future<List<Map>> chipSongs(HomeChip chip) async {
  final cached = _chipCache[chip.label];
  if (cached != null) return cached;
  var songs = <Map>[];
  try {
    final mix = _moodMixes[chip.label];
    if (chip.seed == null && mix != null) {
      songs = [
        ...await deezerMoodMix(mix).catchError((_) => <Map<String, dynamic>>[]),
      ];
    }
    if (songs.isNotEmpty) {
      // Deezer's own mix for this mood.
    } else if (chip.seed != null) {
      songs = [chip.seed!, ...await getRelatedSongs('${chip.seed!['ytid']}')];
    } else if (catalogRelayEnabled && !useItunesCatalog) {
      // Community playlists are often video uploads (worship nights, live
      // sets): only their real audio tracks count.
      final playlists = await ytMusicClient.music
          .searchPlaylists(chip.query)
          .timeout(const Duration(seconds: 15));
      for (final p in playlists.take(3)) {
        final tracks = await ytMusicClient.music
            .getPlaylistSongs(p.id)
            .timeout(const Duration(seconds: 15));
        songs = [
          for (final (i, s) in tracks.indexed)
            if (songMapFromCatalog(s, i) case final m when !isVideoArtSong(m))
              m,
        ];
        if (songs.length >= 8) break;
      }
      if (songs.length < 8) {
        songs = [...(await fetchSongsList(chip.query)).whereType<Map>()];
      }
    } else {
      songs = [...(await fetchSongsList(chip.query)).whereType<Map>()];
    }
  } catch (e, st) {
    logger.log('Chip songs failed for ${chip.label}', error: e, stackTrace: st);
  }
  final keys = <String>{};
  songs = [
    for (final s in songs)
      if (keys.add(_songKey(s))) s,
  ].take(30).toList();
  if (songs.isNotEmpty) _chipCache[chip.label] = songs;
  return songs;
}
