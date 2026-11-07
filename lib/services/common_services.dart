/*
 *     Copyright (C) 2026 Valeri Gokadze
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
import 'dart:io';
import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:hive/hive.dart';
import 'package:http/http.dart' as http;
import 'package:muzika/constants/clients.dart';
import 'package:muzika/main.dart' show audioHandler, logger;
import 'package:muzika/services/artist_service.dart' show ytMusicClient;
import 'package:muzika/services/catalog_relay.dart';
import 'package:muzika/services/data_manager.dart';
import 'package:muzika/services/deezer_catalog.dart';
import 'package:muzika/services/deezer_related.dart';
import 'package:muzika/services/io_service.dart';
import 'package:muzika/services/itunes_catalog.dart';
import 'package:muzika/services/lyrics_manager.dart';
import 'package:muzika/services/playlists_manager.dart';
import 'package:muzika/services/proxy_manager.dart';
import 'package:muzika/services/settings_manager.dart';
import 'package:muzika/services/tunnel_service.dart';
import 'package:muzika/utilities/app_utils.dart';
import 'package:muzika/utilities/formatter.dart';
import 'package:muzika/utilities/map_utils.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

List globalSongs = [];

ValueNotifier<List> userLikedSongsList = ValueNotifier<List>(
  Hive.box('user').get('likedSongs', defaultValue: []),
);

ValueNotifier<List<String>> userLikedRadioStations =
    ValueNotifier<List<String>>(
      List<String>.from(
        Hive.box('user').get('likedRadioStations', defaultValue: []),
      ),
    );

ValueNotifier<List> userRecentlyPlayed = ValueNotifier<List>(
  Hive.box('user').get('recentlyPlayedSongs', defaultValue: []),
);
ValueNotifier<List> userOfflineSongs = ValueNotifier<List>(
  Hive.box('userNoBackup').get('offlineSongs', defaultValue: []),
);

Set<String> _createSongIdCache(ValueNotifier<List> source) {
  final cache = _songIds(source.value);

  source.addListener(() {
    cache
      ..clear()
      ..addAll(_songIds(source.value));
  });

  return cache;
}

Set<String> _songIds(Iterable songs) =>
    songs.whereType<Map>().map(songYtid).whereType<String>().toSet();

final _cachedLikedSongIds = _createSongIdCache(userLikedSongsList);
final _cachedOfflineSongIds = _createSongIdCache(userOfflineSongs);

var _songLikeUpdateToken = 0;
final _latestSongLikeUpdateTokens = <String, int>{};

final lyrics = ValueNotifier<String?>(null);
String? lastFetchedLyrics;

void reloadSongLibraryStateFromStorage() {
  final userBox = Hive.box('user');
  userLikedSongsList.value = List.from(
    userBox.get('likedSongs', defaultValue: []),
  );
  userRecentlyPlayed.value = List.from(
    userBox.get('recentlyPlayedSongs', defaultValue: []),
  );
}

// Timeouts and durations used across manifest fetching and cache validation.
const Duration _manifestTimeout = Duration(seconds: 30);
const Duration _cacheValidationDuration = Duration(hours: 1);

/// Fetches a stream manifest for a song. The request leaves through the
/// active tunnel (see TunnelService), the same exit the audio bytes use.
Future<StreamManifest?> _fetchStreamManifest(String songId) async {
  await TunnelService.instance.ready();
  return getManifestWithFallback(ytClient, songId, timeout: _manifestTimeout);
}

/// Returns a cached song URL if present and still valid.
Future<String?> _getCachedSongUrl(
  String songId,
  String cacheKey,
  Duration cacheDuration,
) async {
  final cachedUrl = await getData(
    'cache',
    cacheKey,
    cachingDuration: cacheDuration,
  );

  if (cachedUrl is! String || cachedUrl.isEmpty) {
    return null;
  }

  final cacheBox = await Hive.openBox('cache');
  final cacheDate = cacheBox.get('${cacheKey}_date') as DateTime?;
  final now = DateTime.now();
  final isOld =
      cacheDate != null && now.difference(cacheDate) > _cacheValidationDuration;

  if (!isOld) {
    return cachedUrl;
  }

  if (await _validateCachedUrl(songId, cachedUrl)) {
    return cachedUrl;
  }

  await deleteData('cache', cacheKey);
  await deleteData('cache', '${cacheKey}_date');
  return null;
}

/// Checks if a cached URL still responds successfully.
Future<bool> _validateCachedUrl(String songId, String cachedUrl) async {
  try {
    final response = await http.head(
      Uri.parse(cachedUrl),
      headers: streamPlaybackHeaders(songId),
    );
    return response.statusCode >= 200 && response.statusCode < 300;
  } catch (_) {
    return false;
  }
}

Future<List> fetchSongsList(String searchQuery) async {
  // Muzika: prefer the YouTube Music catalog (clean titles, album, square
  // art), or Apple's without the relay; fall back to plain YouTube video
  // search.
  // Deezer, with Apple's songs that Deezer doesn't have (Madingo's
  // Swedlat, Vol. 3) mixed in.
  if (useItunesCatalog) {
    final (deezer, apple) = await (
      deezerSearchSongs(searchQuery).catchError((Object e) {
        logger.log('Deezer search failed', error: e);
        return <Map<String, dynamic>>[];
      }),
      itunesSearchSongs(searchQuery).catchError((Object e) {
        logger.log('iTunes search failed', error: e);
        return <Map<String, dynamic>>[];
      }),
    ).wait;
    final songs = mergeCatalogResults(searchQuery, deezer, apple);
    if (songs.isNotEmpty) return songs;
    // A misspelt name ("buzayew demise"): YouTube knows who was meant, by
    // the channels that answer. The catalog is searched again under that
    // name; failing that, only the artists' own "- Topic" uploads are shown.
    try {
      final videos = await ytClient.search.search(searchQuery);
      final name = _likelyArtist(searchQuery, [
        for (final v in videos) v.author,
      ]);
      if (name != null) {
        final (d2, a2) = await (
          deezerSearchSongs(name).catchError((_) => <Map<String, dynamic>>[]),
          itunesSearchSongs(name).catchError((_) => <Map<String, dynamic>>[]),
        ).wait;
        final again = mergeCatalogResults(name, d2, a2);
        if (again.isNotEmpty) return again;
      }
      final topic = [
        for (final v in videos)
          if (v.author.endsWith(' - Topic')) returnSongLayout(0, v),
      ];
      if (topic.isNotEmpty) return topic;
    } catch (e, stackTrace) {
      logger.log('Search respelling failed', error: e, stackTrace: stackTrace);
    }
  } else if (catalogRelayEnabled) {
    try {
      final songs = await ytMusicClient.music
          .searchSongs(searchQuery)
          .timeout(const Duration(seconds: 15));
      if (songs.isNotEmpty) {
        final all = [
          for (final (i, song) in songs.indexed) songMapFromCatalog(song, i),
        ];
        // Real tracks only, unless that would leave almost nothing.
        final audio = all.where((s) => !_isVideoArt(s)).toList();
        return audio.length >= 5 ? audio : all;
      }
    } catch (e, stackTrace) {
      logger.log('Catalog search failed', error: e, stackTrace: stackTrace);
    }
  }
  try {
    // If not in cache, perform the search
    final List<Video> searchResults = await ytClient.search.search(searchQuery);
    final songsList = searchResults
        .map((video) => returnSongLayout(0, video))
        .toList();

    return songsList;
  } catch (e, stackTrace) {
    logger.log('Error in fetchSongsList', error: e, stackTrace: stackTrace);
    return [];
  }
}

/// The artist most of [channels] belong to, cleaned of "- Topic",
/// "Official" and Ge'ez script: "Bezuayehu Demissie - Topic", "Bizuayehu
/// Demissie" and "Bezuayehu Demissie Official ብዙአየሁ ደምሴ" give "Bezuayehu
/// Demissie". A "- Topic" channel (the artist's own) counts most. Only a
/// name that sounds like [query] counts: labels that post the artist's
/// songs ("Nahom Records Inc") don't.
String? _likelyArtist(String query, List<String> channels) {
  // Consonant pairs: "buzayew demise" and "Bezuayehu Demissie" share bz,
  // dm, ms.
  Set<String> pairs(String s) {
    final c = s
        .toLowerCase()
        .replaceAll(RegExp('[^a-z]'), '')
        .replaceAll(RegExp('[aeiouyhw]'), '')
        .replaceAllMapped(RegExp(r'(.)\1+'), (m) => m[1]!);
    return {for (var i = 0; i + 1 < c.length; i++) c.substring(i, i + 2)};
  }

  final wanted = pairs(query);
  if (wanted.isEmpty) return null;
  final votes = <String, int>{};
  final names = <String, String>{};
  for (final c in channels) {
    final topic = c.endsWith(' - Topic');
    final name = c
        .replaceAll(RegExp(r'\s*-\s*Topic$'), '')
        .replaceAll(
          RegExp(
            r'\b(official|music|channel|vevo|tv|records|entertainment)\b',
            caseSensitive: false,
          ),
          '',
        )
        .replaceAll(RegExp('[ሀ-፿]+'), '')
        .replaceAll(RegExp(r"[^\w\s.&'-]"), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (name.length < 3) continue;
    final shared = pairs(name).intersection(wanted).length;
    if (shared / wanted.length < 0.4) continue;
    final key = name.toLowerCase().replaceAll(RegExp('[aeiouy ]'), '');
    votes[key] = (votes[key] ?? 0) + (topic ? 3 : 1);
    if (topic || !names.containsKey(key)) names[key] = name;
  }
  if (votes.isEmpty) return null;
  final best = votes.entries.reduce((a, b) => b.value > a.value ? b : a);
  return best.value >= 2 ? names[best.key] : null;
}

/// Deezer's results, plus Apple's that Deezer doesn't have (same title and
/// artist). Those matching the search come first, from either, in turns.
List<Map> mergeCatalogResults(String query, List<Map> deezer, List<Map> apple) {
  String key(Object? s) =>
      '${s ?? ''}'.toLowerCase().replaceAll(RegExp('[^a-z0-9ሀ-፿]+'), '');
  String id(Map m) =>
      '${key(m['title'])}|${key('${m['artist'] ?? ''}'.split(RegExp('[,&]')).first)}';
  final seen = {for (final m in deezer) id(m)};
  final extra = [
    for (final m in apple)
      if (seen.add(id(m))) m,
  ];
  final words = query
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .map(key)
      .where((w) => w.isNotEmpty)
      .toList();
  bool matches(Map m) {
    final text = key('${m['title']} ${m['artist']}');
    return words.isNotEmpty && words.every(text.contains);
  }

  // The two take turns, so Apple's aren't pushed past the first screenful.
  List<Map> turns(List<Map> a, List<Map> b) => [
    for (var i = 0; i < a.length || i < b.length; i++) ...[
      if (i < a.length) a[i],
      if (i < b.length) b[i],
    ],
  ];

  return [
    ...turns(deezer.where(matches).toList(), extra.where(matches).toList()),
    ...deezer.where((m) => !matches(m)),
    ...extra.where((m) => !matches(m)),
  ];
}

/// Songs related to `ytid` (Muzika): its YouTube Music radio, real audio
/// tracks only — no music videos with video-frame thumbnails.
final Map<String, List<Map>> _relatedSongsCache = {};

bool _isVideoArt(Map song) => isVideoArtSong(song);

/// A YouTube video upload (music video, fan upload) rather than an audio
/// track: those carry i.ytimg.com thumbnails instead of square covers.
bool isVideoArtSong(Map song) =>
    '${song['image'] ?? song['lowResImage'] ?? ''}'.contains('ytimg.com');

/// Title and artist of a song we know about, to find its audio version.
Map? _knownSong(String ytid) {
  for (final source in [
    audioHandler.queueAsMapStreamValue,
    userRecentlyPlayed.value,
    userLikedSongsList.value,
  ]) {
    for (final s in source) {
      if (s is Map && s['ytid'] == ytid) return s;
    }
  }
  return null;
}

Future<List<Map>> _catalogRadio(String ytid) async {
  final radio = await ytMusicClient.music
      .getRadio(ytid)
      .timeout(const Duration(seconds: 15));
  return [
    for (final (i, s) in radio.take(40).indexed) songMapFromCatalog(s, i),
  ];
}

Future<List<Map>> getRelatedSongs(String songId, {Map? seed}) async {
  final cached = _relatedSongsCache[songId];
  if (cached != null) return cached;
  final ytid = youtubeIdOf(songId);
  // (Apple songs get the Apple radio below.)
  if (catalogRelayEnabled) {
    try {
      var songs = await _catalogRadio(ytid);
      var audio = songs.where((s) => !_isVideoArt(s)).toList();
      // A radio started from a music video is all videos: start it again
      // from the song's audio version.
      if (audio.length < 8) {
        final known = seed ?? _knownSong(songId);
        final title = '${known?['title'] ?? ''}'.trim();
        if (title.isNotEmpty) {
          final artist = '${known?['artist'] ?? ''}'.split(',').first.trim();
          final matches = await ytMusicClient.music
              .searchSongs('$title $artist')
              .timeout(const Duration(seconds: 15));
          final atv = matches
              .where((m) => !(m.thumbnailUrl ?? '').contains('ytimg.com'))
              .firstOrNull;
          if (atv != null && atv.videoId != ytid) {
            songs = await _catalogRadio(atv.videoId);
            audio = songs
                .where((s) => !_isVideoArt(s) && s['ytid'] != ytid)
                .toList();
          }
        }
      }
      // Real songs only: a video upload is never a "similar song".
      final result = audio.where(_isSong).toList();
      if (result.isNotEmpty) {
        _relatedSongsCache[songId] = result.take(25).toList();
        return _relatedSongsCache[songId]!;
      }
    } catch (e, stackTrace) {
      logger.log('Catalog radio failed', error: e, stackTrace: stackTrace);
    }
  }
  // A radio from Apple: some of the same artist's songs and those of the
  // artists most like them (Deezer), never YouTube's "related videos".
  try {
    final known = seed ?? _knownSong(songId);
    final artist = '${known?['artist'] ?? ''}'.split(',').first.trim();
    if (artist.isEmpty) return const [];
    // Deezer's own radio of the artist: theirs and songs like them.
    final radio = [
      for (final s in await deezerArtistRadio(
        artist,
      ).catchError((_) => <Map<String, dynamic>>[]))
        if (_isSong(s) && s['ytid'] != songId) s,
    ];
    if (radio.length >= 8) {
      final result = (radio..shuffle()).take(25).toList();
      _relatedSongsCache[songId] = result;
      return result;
    }
    final related = await relatedArtists(artist);
    final lists = await Future.wait([
      appleArtistSongs(artist),
      for (final r in related.take(4))
        appleArtistSongs(r.name).catchError((_) => <Map<String, dynamic>>[]),
    ]);
    final mine = [
      for (final s in lists.first)
        if (_isSong(s) && s['ytid'] != songId) s,
    ]..shuffle();
    final others = [
      for (final l in lists.skip(1))
        [
          for (final s in l.take(8))
            if (_isSong(s)) s,
        ]..shuffle(),
    ];
    // Theirs and the others' taken in turn, so it isn't one artist at a time.
    final songs = <Map>[...mine.take(6)];
    for (var i = 0; i < 6; i++) {
      for (final l in others) {
        if (i < l.length) songs.add(l[i]);
      }
    }
    songs.shuffle();
    final result = songs.take(25).toList();
    if (result.isNotEmpty) _relatedSongsCache[songId] = result;
    return result;
  } catch (e, stackTrace) {
    logger.log('Error loading related songs', error: e, stackTrace: stackTrace);
    return [];
  }
}

/// A single song rather than a compilation or mix upload ("Full Album",
/// "Greatest Hits", "Top music", an hour of nonstop…).
bool _isSong(Map song) {
  final seconds = (song['duration'] as num?)?.toInt() ?? 0;
  if (seconds > 600) return false;
  return !RegExp(
    'full album|greatest hits|best songs|top music|top songs|nonstop|'
    r'non-stop|playlist|compilation|\bmix\b|megamix|mashup|\bhours?\b|'
    'cocomelon|nursery|for kids',
    caseSensitive: false,
  ).hasMatch('${song['title'] ?? ''} ${song['artist'] ?? ''}');
}

Future<List> getRecommendedSongs() async {
  try {
    if (externalRecommendations.value && userRecentlyPlayed.value.isNotEmpty) {
      return await _getRecommendationsFromRecentlyPlayed();
    } else {
      return await _getRecommendationsFromMixedSources();
    }
  } catch (e, stackTrace) {
    logger.log(
      'Error in getRecommendedSongs',
      error: e,
      stackTrace: stackTrace,
    );
    return [];
  }
}

Future<List> _getRecommendationsFromRecentlyPlayed() async {
  final recent = (List.from(
    userRecentlyPlayed.value,
  )..shuffle()).take(5).toList();

  return _getRecommendationsFromSeedSongs(recent);
}

/// Expands seed songs into related videos and ranks them for home and playlist recommendations.
Future<List> _getRecommendationsFromSeedSongs(List seedSongs) async {
  final seeds = seedSongs
      .whereType<Map>()
      .where((song) => (song['ytid']?.toString() ?? '').isNotEmpty)
      .toList();
  if (seeds.isEmpty) return [];

  final scores = <String, double>{};
  final songMap = <String, Map>{};

  final futures = seeds.asMap().entries.map((entry) async {
    final seedIndex = entry.key;
    final songData = entry.value;
    try {
      final song = await ytClient.videos.get(
        youtubeIdOf('${songData['ytid']}'),
      );
      final related = await ytClient.videos.getRelatedVideos(song) ?? [];
      for (var i = 0; i < related.length && i < 8; i++) {
        final s = returnSongLayout(0, related[i]);
        final id = s['ytid'];
        final positionWeight = 1.0 - (i / 8);
        final recencyWeight = 1.0 - (seedIndex / seeds.length);
        scores[id] = (scores[id] ?? 0) + positionWeight * recencyWeight;
        songMap[id] = s;
      }
    } catch (e, st) {
      logger.log(
        'related videos error for ${songData['ytid']}',
        error: e,
        stackTrace: st,
      );
    }
  }).toList();

  await Future.wait(futures);

  final sorted = scores.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  return sorted.take(15).map((e) => songMap[e.key]!).toList();
}

/// Songs for a playlist (Muzika): the YouTube Music radio of a few of its
/// songs ([getRelatedSongs]: real tracks, no music videos), ranked by how
/// many seeds bring them up and how high. YouTube's related videos (mixes,
/// full albums, fan uploads) are not songs to add to a playlist; uploads
/// with a video frame for a cover and anything over 10 minutes are left out.
Future<List<Map>> _playlistRadio(List<Map> seeds) async {
  final scores = <String, double>{};
  final byId = <String, Map>{};
  await Future.wait([
    for (final (seedIndex, seed) in seeds.indexed)
      getRelatedSongs('${seed['ytid']}', seed: seed)
          .then((related) {
            for (final (i, song) in related.take(15).indexed) {
              final id = '${song['ytid'] ?? ''}';
              final seconds = song['duration'] is num
                  ? (song['duration'] as num).toInt()
                  : 0;
              if (id.isEmpty || isVideoArtSong(song) || seconds > 600) continue;
              byId[id] = song;
              scores[id] =
                  (scores[id] ?? 0) +
                  (1 - i / 15) * (1 - seedIndex / seeds.length);
            }
          })
          .catchError((Object _) {}),
  ]);
  final ranked = scores.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  return [for (final e in ranked.take(15)) byId[e.key]!];
}

/// Number of playlist tracks used to seed recommendations while keeping network cost bounded.
const _playlistRecommendationSeedCount = 5;

/// In-memory recommendations cache keyed by playlist ytid and cleared on app restart.
final Map<String, List> _playlistRecommendationsCache = {};

/// Gets playlist-seeded recommendations, reusing cached results and returning an empty list on failure.
Future<List> getRecommendedSongsForPlaylist(
  String playlistId,
  List playlistSongs,
) async {
  try {
    final existingIds = playlistSongs
        .whereType<Map>()
        .map((song) => song['ytid']?.toString())
        .toSet();

    final cached = _playlistRecommendationsCache[playlistId];
    if (cached != null) {
      final stillFresh = cached
          .where((song) => !existingIds.contains(song['ytid']?.toString()))
          .toList();
      if (stillFresh.isNotEmpty) return stillFresh;
    }

    final seeds = _sampleSeedSongs(
      playlistSongs,
      _playlistRecommendationSeedCount,
    );
    final recommendations = await _playlistRadio(seeds);
    final filtered = recommendations
        .where((song) => !existingIds.contains(song['ytid']?.toString()))
        .toList();

    _playlistRecommendationsCache[playlistId] = filtered;
    return filtered;
  } catch (e, stackTrace) {
    logger.log(
      'Error in getRecommendedSongsForPlaylist',
      error: e,
      stackTrace: stackTrace,
    );
    return [];
  }
}

/// Uniformly samples up to [count] valid songs in one pass without copying or shuffling the playlist.
List<Map> _sampleSeedSongs(List songs, int count) {
  final random = Random();
  final reservoir = <Map>[];
  var seen = 0;

  for (final song in songs) {
    if (song is! Map || (song['ytid']?.toString() ?? '').isEmpty) continue;
    seen++;
    if (reservoir.length < count) {
      reservoir.add(song);
    } else {
      final slot = random.nextInt(seen);
      if (slot < count) reservoir[slot] = song;
    }
  }

  return reservoir;
}

Future<List> _getRecommendationsFromMixedSources() async {
  final recommendationSources = <Iterable<dynamic>>[
    userLikedSongsList.value,
    userRecentlyPlayed.value,
  ];

  if (globalSongs.isEmpty) {
    const playlistId = 'PLgzTt0k8mXzEk586ze4BjvDXR7c-TUSnx';
    globalSongs = await getSongsFromPlaylist(playlistId);
  }
  recommendationSources.add(globalSongs.take(10));

  if (userCustomPlaylists.value.isNotEmpty) {
    for (final userPlaylist in userCustomPlaylists.value) {
      final playlistSongs = userPlaylist['list'] as List;
      recommendationSources.add(_sampleSeedSongs(playlistSongs, 5));
    }
  }

  return sampleUniqueSongs(recommendationSources, 15);
}

Future<void> updateSongLikeStatus(
  dynamic songId,
  bool add, {
  Map? songData,
}) async {
  try {
    final normalizedSongId = songId?.toString().trim() ?? '';
    if (normalizedSongId.isEmpty) return;

    final updateToken = ++_songLikeUpdateToken;
    _latestSongLikeUpdateTokens[normalizedSongId] = updateToken;

    final songToAdd = add
        ? await _resolveSongForLikedStatus(normalizedSongId, songData)
        : null;

    if (_latestSongLikeUpdateTokens[normalizedSongId] != updateToken) {
      return;
    }

    final updatedLikedSongs = _deduplicateLikedSongs(userLikedSongsList.value);

    if (add) {
      if (songToAdd != null &&
          !updatedLikedSongs.any(
            (song) => song['ytid']?.toString() == normalizedSongId,
          )) {
        updatedLikedSongs.insert(0, songToAdd);
      }
    } else {
      updatedLikedSongs.removeWhere(
        (song) => song['ytid']?.toString() == normalizedSongId,
      );
    }

    if (_likedSongIdsAreEqual(userLikedSongsList.value, updatedLikedSongs))
      return;

    userLikedSongsList.value = updatedLikedSongs;
    unawaited(
      addOrUpdateData<List>('user', 'likedSongs', userLikedSongsList.value),
    );
  } catch (e, stackTrace) {
    logger.log(
      'Error updating song like status',
      error: e,
      stackTrace: stackTrace,
    );
  }
}

Future<Map?> _resolveSongForLikedStatus(String songId, Map? songData) async {
  if (songData?['ytid']?.toString() == songId) {
    return Map<String, dynamic>.from(songData!);
  }

  final cachedSong = findSongByYtid(userLikedSongsList.value, songId);
  if (cachedSong != null) return Map<String, dynamic>.from(cachedSong);

  return getSongDetails(userLikedSongsList.value.length, songId);
}

List _deduplicateLikedSongs(Iterable<dynamic> likedSongs) {
  final seenSongIds = <String>{};
  final deduplicatedSongs = [];

  for (final song in likedSongs) {
    if (song is! Map) {
      deduplicatedSongs.add(song);
      continue;
    }

    final songId = song['ytid']?.toString();
    if (songId == null || songId.isEmpty) {
      deduplicatedSongs.add(song);
      continue;
    }

    if (seenSongIds.add(songId)) {
      deduplicatedSongs.add(song);
    }
  }

  return deduplicatedSongs;
}

bool _likedSongIdsAreEqual(List previous, List updated) {
  if (previous.length != updated.length) return false;

  for (var i = 0; i < previous.length; i++) {
    final previousSong = previous[i];
    final updatedSong = updated[i];
    if (previousSong is! Map || updatedSong is! Map) {
      if (previousSong != updatedSong) return false;
      continue;
    }

    if (previousSong['ytid']?.toString() != updatedSong['ytid']?.toString()) {
      return false;
    }
  }

  return true;
}

Future<void> renameSongInLikedSongs(
  dynamic songId,
  String newTitle,
  String newArtist,
) async {
  try {
    final songIndex = userLikedSongsList.value.indexWhere(
      (song) => song['ytid'] == songId,
    );

    if (songIndex != -1) {
      final updatedList = List.from(userLikedSongsList.value);
      updatedList[songIndex] = Map.from(updatedList[songIndex] as Map)
        ..['title'] = newTitle
        ..['artist'] = newArtist;
      userLikedSongsList.value = updatedList;

      unawaited(
        addOrUpdateData<List>('user', 'likedSongs', userLikedSongsList.value),
      );
    }
  } catch (e, stackTrace) {
    logger.log(
      'Error renaming song in liked songs',
      error: e,
      stackTrace: stackTrace,
    );
    rethrow;
  }
}

bool isSongAlreadyLiked(songIdToCheck) {
  final songId = songIdToCheck?.toString();
  return songId != null && _cachedLikedSongIds.contains(songId);
}

bool isPlaylistAlreadyLiked(playlistIdToCheck) {
  final playlistId = playlistIdToCheck?.toString();
  if (playlistId == null || playlistId.isEmpty) return false;
  return userLikedPlaylists.value.any(
    (playlist) => playlist['ytid']?.toString() == playlistId,
  );
}

bool isRadioStationLiked(String radioStationId) {
  return userLikedRadioStations.value.contains(radioStationId);
}

Future<void> addRadioStationToLiked(String radioStationId) async {
  if (!userLikedRadioStations.value.contains(radioStationId)) {
    final updatedList = List<String>.from(userLikedRadioStations.value)
      ..add(radioStationId);
    userLikedRadioStations.value = updatedList;
    await addOrUpdateData<List<String>>(
      'user',
      'likedRadioStations',
      updatedList,
    );
  }
}

Future<void> removeRadioStationFromLiked(String radioStationId) async {
  if (userLikedRadioStations.value.contains(radioStationId)) {
    final updatedList = List<String>.from(userLikedRadioStations.value)
      ..remove(radioStationId);
    userLikedRadioStations.value = updatedList;
    unawaited(
      addOrUpdateData<List<String>>('user', 'likedRadioStations', updatedList),
    );
  }
}

bool isSongAlreadyOffline(songIdToCheck) {
  final songId = songIdToCheck?.toString();
  return songId != null && _cachedOfflineSongIds.contains(songId);
}

bool isPlaylistFullyOffline(List songs) {
  if (songs.isEmpty) return false;
  final offlineIds = userOfflineSongs.value.map((s) => s['ytid']).toSet();
  return songs.every((s) => offlineIds.contains(s['ytid']));
}

Map<String, dynamic> getOfflineSongByYtid(String ytid) {
  try {
    final song = userOfflineSongs.value.firstWhere(
      (s) => s['ytid'] == ytid,
      orElse: () => <String, dynamic>{},
    );
    return Map<String, dynamic>.from(song);
  } catch (_) {
    return <String, dynamic>{};
  }
}

Future<List<String>> getSearchSuggestions(String query) async {
  // Custom implementation:

  // const baseUrl = 'https://suggestqueries.google.com/complete/search';
  // final parameters = {
  //   'client': 'firefox',
  //   'ds': 'yt',
  //   'q': query,
  // };

  // final uri = Uri.parse(baseUrl).replace(queryParameters: parameters);

  // try {
  //   final response = await http.get(
  //     uri,
  //     headers: {
  //       'User-Agent':
  //           'Mozilla/5.0 (Windows NT 10.0; rv:96.0) Gecko/20100101 Firefox/96.0',
  //     },
  //   );

  //   if (response.statusCode == 200) {
  //     final suggestions = jsonDecode(response.body)[1] as List<dynamic>;
  //     final suggestionStrings = suggestions.cast<String>().toList();
  //     return suggestionStrings;
  //   }
  // } catch (e, stackTrace) {
  //   logger.log('Error in getSearchSuggestions:$e\n$stackTrace');
  // }

  // Built-in implementation:

  final suggestions = await ytClient.search.getQuerySuggestions(query);

  return suggestions;
}

// Throws on network, HTTP and parsing failure instead of swallowing it, so
// callers that need to tell "confirmed no segments" apart from "failed to
// fetch" (e.g. the offline cache, which must not persist a false negative)
// can do so.
Future<List<Map<String, int>>> _fetchSkipSegments(String id) async {
  final res = await ProxyManager().getProxiedResponse(
    Uri(
      scheme: 'https',
      host: 'sponsor.ajay.app',
      path: '/api/skipSegments',
      queryParameters: {
        'videoID': youtubeIdOf(id),
        'category': [
          'sponsor',
          'selfpromo',
          'interaction',
          'intro',
          'outro',
          'music_offtopic',
        ],
        'actionType': 'skip',
      },
    ),
  );
  // 404 is how the API answers "this video has no segments", so it is a real
  // empty result and safe to remember. Any other non-200 is a failure, and
  // throwing keeps it from being stored as a confirmed "no segments".
  if (res.statusCode == 404 || res.body == 'Not Found') return [];
  if (res.statusCode != 200) {
    throw HttpException('SponsorBlock responded ${res.statusCode} for $id');
  }

  final data = jsonDecode(res.body);
  final segments = data.map((obj) {
    return Map.castFrom<String, dynamic, String, int>({
      'start': obj['segment'].first.toInt(),
      'end': obj['segment'].last.toInt(),
    });
  }).toList();
  return List.castFrom<dynamic, Map<String, int>>(segments);
}

Future<List<Map<String, int>>> getSkipSegments(String id) async {
  try {
    return await _fetchSkipSegments(id);
  } catch (e, stackTrace) {
    logger.log('Error in getSkipSegments', error: e, stackTrace: stackTrace);
    return [];
  }
}

/// The first song related to [songYtId] whose ytid is not in [excludedYtIds].
Future<Map<String, dynamic>?> getSimilarSong(
  String songYtId, {
  Set<String> excludedYtIds = const {},
}) async {
  try {
    final song = await ytClient.videos.get(youtubeIdOf(songYtId));
    final relatedSongs = await ytClient.videos.getRelatedVideos(song) ?? [];

    for (final video in relatedSongs) {
      final candidate = returnSongLayout(0, video);
      if (!excludedYtIds.contains(candidate['ytid']?.toString())) {
        return candidate;
      }
    }
    logger.log('No new related songs found for $songYtId');
  } catch (e, stackTrace) {
    logger.log(
      'Error while fetching next similar song:',
      error: e,
      stackTrace: stackTrace,
    );
  }
  return null;
}

/// In-memory cache of the audio stream picked for a song at the current
/// quality setting. The Hive cache only keeps the URL, so without this every
/// caller that needs the stream itself (bitrate, codec) would fetch the
/// manifest again right after playback already resolved it.
final Map<String, ({AudioOnlyStreamInfo stream, DateTime resolvedAt})>
_selectedAudioStreams = {};

const _maxSelectedAudioStreams = 50;

String _selectedAudioStreamKey(String songId) =>
    '${songId}_${audioQualitySetting.value}';

/// Returns the stream resolved earlier for a song, unless it is old enough
/// that its URL may have expired.
AudioOnlyStreamInfo? _getSelectedAudioStream(String songId) {
  final key = _selectedAudioStreamKey(songId);
  final entry = _selectedAudioStreams[key];
  if (entry == null) return null;

  if (DateTime.now().difference(entry.resolvedAt) > _cacheValidationDuration) {
    _selectedAudioStreams.remove(key);
    return null;
  }

  return entry.stream;
}

void _cacheSelectedAudioStream(String songId, AudioOnlyStreamInfo stream) {
  if (_selectedAudioStreams.length >= _maxSelectedAudioStreams) {
    _selectedAudioStreams.remove(_selectedAudioStreams.keys.first);
  }

  _selectedAudioStreams[_selectedAudioStreamKey(songId)] = (
    stream: stream,
    resolvedAt: DateTime.now(),
  );
}

/// Drops both cached forms of a song's stream, so the next request resolves
/// it again. Used when a cached URL turns out to be dead.
Future<void> invalidateSongStreamCache(String songId) async {
  _selectedAudioStreams.remove(_selectedAudioStreamKey(songId));
  await deleteData('cache', 'song_${songId}_${audioQualitySetting.value}_url');
}

/// Fetches the best available audio stream for a song.
Future<AudioOnlyStreamInfo?> fetchBestAudioStream(String? songId) async {
  try {
    if (songId == null || songId.isEmpty) {
      logger.log('fetchBestAudioStream: songId is null or empty');
      return null;
    }

    final cachedStream = _getSelectedAudioStream(songId);
    if (cachedStream != null) return cachedStream;

    final manifest = await _fetchStreamManifest(songId);
    final audioStream = manifest?.audioOnly;
    if (audioStream == null || audioStream.isEmpty) {
      logger.log('fetchBestAudioStream: no audio streams for $songId');
      return null;
    }

    final selectedStream = selectAudioOnlyStreamForQuality(audioStream);
    if (selectedStream == null) {
      logger.log(
        'fetchBestAudioStream: no compatible audio streams for $songId',
      );
      return null;
    }

    _cacheSelectedAudioStream(songId, selectedStream);
    return selectedStream;
  } on TimeoutException catch (_) {
    logger.log('fetchBestAudioStream request timed out for $songId');
    return null;
  } catch (e, stackTrace) {
    logger.log(
      'Error while fetching best audio stream',
      error: e,
      stackTrace: stackTrace,
    );
    return null;
  }
}

/// Resolves a playable stream URL for a song (cached when possible).
Future<String?> fetchSongStreamUrl(String songId, bool isLive) async {
  try {
    if (songId.isEmpty) {
      logger.log('fetchSongStreamUrl: songId is empty');
      return null;
    }
    if (isLive) {
      final streamInfo = await ytClient.videos.streamsClient
          .getHttpLiveStreamUrl(VideoId(songId));
      return streamInfo;
    }

    const _cacheDuration = Duration(hours: 3);
    final cacheKey = 'song_${songId}_${audioQualitySetting.value}_url';

    // Try to get from cache
    final cachedUrl = await _getCachedSongUrl(songId, cacheKey, _cacheDuration);
    if (cachedUrl != null) {
      return cachedUrl;
    }

    // Get fresh URL, reusing the stream already resolved for this song.
    final selectedStream = await fetchBestAudioStream(songId);
    if (selectedStream == null) {
      logger.log('fetchSongStreamUrl: no audio streams for $songId');
      return null;
    }

    final url = selectedStream.url.toString();

    unawaited(addOrUpdateData<String>('cache', cacheKey, url));

    return url;
  } on TimeoutException catch (_) {
    logger.log('fetchSongStreamUrl request timed out for $songId');
    return null;
  } catch (e, stackTrace) {
    logger.log(
      'Error in fetchSongStreamUrl for $songId:',
      error: e,
      stackTrace: stackTrace,
    );
    return null;
  }
}

Future<Map<String, dynamic>> getSongDetails(
  int songIndex,
  String songId,
) async {
  try {
    final song = await ytClient.videos.get(songId);
    return returnSongLayout(songIndex, song);
  } catch (e, stackTrace) {
    logger.log(
      'Error while getting song details',
      error: e,
      stackTrace: stackTrace,
    );
    rethrow;
  }
}

Future<String?> getSongLyrics(String? artist, String title) async {
  if (artist == null) return null;
  if (lastFetchedLyrics != '$artist - $title') {
    lyrics.value = null;
    var _lyrics = await LyricsManager().fetchLyrics(artist, title);
    if (_lyrics != null) {
      _lyrics = _lyrics.replaceAll(RegExp(r'\n{4}'), '\n\n');
      _lyrics = _lyrics.replaceAll(RegExp(r'\n{2}'), '\n');
      lyrics.value = _lyrics;
    } else {
      return null;
    }

    lastFetchedLyrics = '$artist - $title';
    return _lyrics;
  }

  return lyrics.value;
}

Future<bool> makeSongOffline(
  dynamic song, {
  void Function(double progress)? onProgress,
}) async {
  try {
    final String? ytid = song['ytid'];

    if (ytid == null || ytid.isEmpty) {
      logger.log('makeSongOffline: song["ytid"] is null or empty');
      return false;
    }

    if (isSongAlreadyOffline(ytid)) {
      final existingPath = FilePaths.getAudioPath(ytid);
      if (await File(existingPath).exists()) {
        unawaited(cacheSponsorBlockSegments(ytid));
        return true;
      }
    }

    final offlineSong = Map<String, dynamic>.from(song as Map);

    final audioPath = FilePaths.getAudioPath(ytid);
    final audioFile = File(audioPath);
    final artworkPath = FilePaths.getArtworkPath(ytid);

    await audioFile.parent.create(recursive: true);

    int? audioBitrateKbps;
    String? audioCodec;
    IOSink? fileStream;
    try {
      final audioManifest = await fetchBestAudioStream(ytid);
      if (audioManifest == null) {
        logger.log('makeSongOffline: audioManifest is null for $ytid');
        return false;
      }
      audioBitrateKbps = audioManifest.bitrate.kiloBitsPerSecond.round();
      audioCodec = audioManifest.audioCodec;

      final total = audioManifest.size.totalBytes;
      var received = 0;
      final stream = ytClient.videos.streamsClient.get(audioManifest).map((
        chunk,
      ) {
        received += chunk.length;
        if (onProgress != null && total > 0) {
          onProgress((received / total).clamp(0.0, 1.0));
        }
        return chunk;
      });
      fileStream = audioFile.openWrite();
      await stream.pipe(fileStream);
      await fileStream.flush();
      await fileStream.close();
      fileStream = null;
    } catch (e, stackTrace) {
      logger.log(
        'Error downloading audio file',
        error: e,
        stackTrace: stackTrace,
      );
      try {
        await fileStream?.close();
      } catch (_) {}
      if (await audioFile.exists()) {
        await audioFile.delete();
      }
      return false;
    }

    try {
      if (offlineSong['highResImage'] != null &&
          offlineSong['highResImage'].toString().isNotEmpty) {
        final _artworkFile = await _downloadAndSaveArtworkFile(
          offlineSong['highResImage'],
          artworkPath,
        );

        if (_artworkFile != null && await _artworkFile.exists()) {
          offlineSong['artworkPath'] = artworkPath;
        } else {
          logger.log(
            'Artwork download failed or file does not exist for $ytid',
          );
          offlineSong['artworkPath'] = null;
        }
      }
    } catch (e, stackTrace) {
      logger.log('Error downloading artwork', error: e, stackTrace: stackTrace);
      offlineSong['artworkPath'] = null;
    }

    offlineSong['audioPath'] = audioFile.path;
    offlineSong['audioBitrateKbps'] = audioBitrateKbps;
    offlineSong['audioCodec'] = audioCodec;
    offlineSong['dateAdded'] = DateTime.now().millisecondsSinceEpoch;

    try {
      final existingIndex = userOfflineSongs.value.indexWhere(
        (s) => s['ytid'] == ytid,
      );

      final updatedOfflineSongs = List.from(userOfflineSongs.value);
      if (existingIndex != -1) {
        updatedOfflineSongs[existingIndex] = offlineSong;
      } else {
        updatedOfflineSongs.add(offlineSong);
      }
      userOfflineSongs.value = updatedOfflineSongs;

      unawaited(
        addOrUpdateData<List>(
          'userNoBackup',
          'offlineSongs',
          userOfflineSongs.value,
        ),
      );

      unawaited(cacheSponsorBlockSegments(ytid));
    } catch (e, st) {
      logger.log(
        'Error updating global offline songs list',
        error: e,
        stackTrace: st,
      );
    }

    return true;
  } catch (e, stackTrace) {
    logger.log('Error making song offline', error: e, stackTrace: stackTrace);
    return false;
  }
}

Future<void> _deleteFileIfExists(File file, String errorDescription) async {
  try {
    if (await file.exists()) {
      await file.delete(recursive: true);
    }
  } catch (e, stackTrace) {
    logger.log(
      'Error deleting $errorDescription',
      error: e,
      stackTrace: stackTrace,
    );
  }
}

/// Once: songs that played through the old choice of substitute (for a
/// song blocked here) may have played a live or TV version, which was then
/// saved to Cached and its link kept. Those cached copies and links are
/// dropped so the song is fetched again through the better choice. Songs
/// downloaded on purpose stay; they are only logged.
Future<void> dropOldSubstitutePlays() async {
  const done = 'migrated:substitutes:v3';
  try {
    final cache = Hive.box('cache');
    if (cache.get(done) == true) return;
    // Picks made before the latest matching rules (v1: live versions,
    // v2: music videos longer than the album track).
    final old = RegExp(r'^subst:v[12]:(.+)$');
    final ids = {
      for (final k in cache.keys)
        if (old.firstMatch('$k') case final m?) m[1]!,
    };
    var kept = 0;
    for (final id in ids) {
      for (final k in cache.keys.toList()) {
        final key = '$k';
        if (key.startsWith('song_${id}_') ||
            old.hasMatch(key) && key.endsWith(':$id')) {
          await cache.delete(k);
        }
      }
      final offline = userOfflineSongs.value.whereType<Map>().where(
        (s) => s['ytid'] == id,
      );
      for (final song in offline.toList()) {
        if (song['autoCached'] == true) {
          await removeSongFromOffline(id);
        } else {
          kept++;
        }
      }
    }
    if (kept > 0) {
      logger.log(
        '$kept downloaded songs may be a live version; download them again',
      );
    }
    await cache.put(done, true);
  } catch (e, st) {
    logger.log('Substitute clean-up failed', error: e, stackTrace: st);
  }
}

Future<bool> removeSongFromOffline(dynamic songId) async {
  try {
    final audioPath = FilePaths.getAudioPath(songId);
    final artworkPath = FilePaths.getArtworkPath(songId);

    await Future.wait([
      _deleteFileIfExists(File(audioPath), 'audio file'),
      _deleteFileIfExists(File(artworkPath), 'artwork file'),
    ]);

    try {
      userOfflineSongs.value = List.from(userOfflineSongs.value)
        ..removeWhere((song) => song['ytid'] == songId);
      unawaited(
        addOrUpdateData<List>(
          'userNoBackup',
          'offlineSongs',
          userOfflineSongs.value,
        ),
      );
    } catch (e, st) {
      logger.log(
        'Error updating offline songs registry after removal',
        error: e,
        stackTrace: st,
      );
    }

    return true;
  } catch (e, stackTrace) {
    logger.log(
      'Error removing song from offline storage',
      error: e,
      stackTrace: stackTrace,
    );
    return false;
  }
}

const _sponsorCallSpacing = Duration(seconds: 1);
Future<void> _sponsorSerialChain = Future.value();

/// Runs SponsorBlock lookups one at a time, spaced out, so that a playlist
/// download finishing several songs at once does not fire them all together.
Future<T> _sponsorSerialCall<T>(Future<T> Function() action) {
  final result = _sponsorSerialChain.then((_) => action());
  _sponsorSerialChain = result
      .then((_) {}, onError: (_) {})
      .then((_) => Future<void>.delayed(_sponsorCallSpacing));
  return result;
}

/// Stores the SponsorBlock segments of a downloaded song next to the download
/// itself, so they last exactly as long as it does: they are not backed up,
/// they never expire, and removing the song removes them.
///
/// Looked up once per song: a stored result — including a confirmed empty one —
/// is never fetched again.
Future<void> cacheSponsorBlockSegments(String ytid) async {
  try {
    if (getOfflineSongByYtid(ytid)['sponsorSegments'] != null) return;

    // Two attempts, spaced out by the queue above; a failure stores nothing so
    // it is not mistaken for a confirmed "no segments", and is looked up again
    // the next time the song plays.
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final segments = await _sponsorSerialCall(
          () => _fetchSkipSegments(ytid),
        );
        await _storeSponsorBlockSegments(ytid, segments);
        return;
      } catch (_) {
        continue;
      }
    }
  } catch (e, stackTrace) {
    logger.log(
      'Error caching sponsor block for $ytid',
      error: e,
      stackTrace: stackTrace,
    );
  }
}

Future<void> _storeSponsorBlockSegments(
  String ytid,
  List<Map<String, int>> segments,
) async {
  final index = userOfflineSongs.value.indexWhere((s) => s['ytid'] == ytid);
  // The song was removed while the lookup was in flight.
  if (index == -1) return;

  final updatedOfflineSongs = List.from(userOfflineSongs.value);
  updatedOfflineSongs[index] = {
    ...Map<String, dynamic>.from(updatedOfflineSongs[index] as Map),
    'sponsorSegments': segments,
  };
  userOfflineSongs.value = updatedOfflineSongs;
  await addOrUpdateData<List>(
    'userNoBackup',
    'offlineSongs',
    userOfflineSongs.value,
  );
}

/// The stored segments of a downloaded song, or null when it has none stored
/// yet. An empty list means the song was looked up and has no segments.
List<Map<String, int>>? getCachedSponsorBlockSegments(String ytid) {
  final stored = getOfflineSongByYtid(ytid)['sponsorSegments'];
  if (stored is! List) return null;
  return [for (final segment in stored) Map<String, int>.from(segment as Map)];
}

Future<File?> _downloadAndSaveArtworkFile(String url, String filePath) async {
  try {
    final response = await ProxyManager().getProxiedResponse(Uri.parse(url));

    if (response.statusCode == 200) {
      final file = File(filePath);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(response.bodyBytes);

      // Validate that the file was actually written
      if (await file.exists() && await file.length() > 0) {
        return file;
      } else {
        logger.log('Artwork file was not written properly: $filePath');
        return null;
      }
    } else {
      logger.log(
        'Failed to download file. Status code: ${response.statusCode}',
      );
    }
  } catch (e, stackTrace) {
    logger.log(
      'Error downloading and saving file',
      error: e,
      stackTrace: stackTrace,
    );
  }

  return null;
}

const recentlyPlayedSongsLimit = 100;

/// Updates the recently played list and listening count for [songId].
///
/// When [songFallback] is provided, its metadata is used to seed the history
/// entry if the song has never been played before. This avoids a network
/// request when registering offline songs whose metadata is already available
/// locally (e.g. from [userOfflineSongs]).
Future<void> updateRecentlyPlayed(dynamic songId, {Map? songFallback}) async {
  try {
    final now = DateTime.now();

    if (userRecentlyPlayed.value.isNotEmpty &&
        userRecentlyPlayed.value[0]['ytid'] == songId) {
      final updatedList = List.from(userRecentlyPlayed.value);
      final existing = Map.from(updatedList[0] as Map);
      existing['listeningCount'] = (existing['listeningCount'] ?? 0) + 1;
      existing['lastPlayed'] = now;
      updatedList[0] = existing;
      userRecentlyPlayed.value = updatedList;
      unawaited(
        addOrUpdateData<List>(
          'user',
          'recentlyPlayedSongs',
          userRecentlyPlayed.value,
        ),
      );
      return;
    }

    final existingIndex = userRecentlyPlayed.value.indexWhere(
      (song) => song['ytid'] == songId,
    );

    final updatedList = List.from(userRecentlyPlayed.value);

    if (existingIndex == -1 && updatedList.length >= recentlyPlayedSongsLimit) {
      updatedList.removeLast();
    }

    if (existingIndex != -1) {
      final song = Map.from(updatedList.removeAt(existingIndex) as Map);
      song['listeningCount'] = (song['listeningCount'] ?? 0) + 1;
      song['lastPlayed'] = now;
      updatedList.insert(0, song);
    } else {
      final dynamic fetchedSongDetails = songFallback != null
          ? Map<String, dynamic>.from(songFallback)
          : await getSongDetails(0, songId);

      if (fetchedSongDetails is! Map) {
        logger.log('Failed to update recently played: invalid song details');
        return;
      }

      final newSongDetails = Map<String, dynamic>.from(fetchedSongDetails);
      newSongDetails['ytid'] ??= songId;
      newSongDetails['listeningCount'] = 1;
      newSongDetails['lastPlayed'] = now;
      updatedList.insert(0, newSongDetails);
    }

    userRecentlyPlayed.value = updatedList;
    unawaited(
      addOrUpdateData<List>(
        'user',
        'recentlyPlayedSongs',
        userRecentlyPlayed.value,
      ),
    );
  } catch (e, stackTrace) {
    logger.log(
      'Error updating recently played',
      error: e,
      stackTrace: stackTrace,
    );
  }
}

Future<void> removeFromRecentlyPlayed(dynamic songId) async {
  if (userRecentlyPlayed.value.any((song) => song['ytid'] == songId)) {
    userRecentlyPlayed.value = List.from(userRecentlyPlayed.value)
      ..removeWhere((song) => song['ytid'] == songId);
    unawaited(
      addOrUpdateData<List>(
        'user',
        'recentlyPlayedSongs',
        userRecentlyPlayed.value,
      ),
    );
  }
}
