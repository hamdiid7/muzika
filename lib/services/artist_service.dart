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

import 'package:muzika/constants/artist_constants.dart';
import 'package:muzika/constants/clients.dart';
import 'package:muzika/main.dart' show logger;
import 'package:muzika/services/catalog_relay.dart';
import 'package:muzika/services/data_manager.dart';
import 'package:muzika/services/deezer_catalog.dart';
import 'package:muzika/services/itunes_catalog.dart';
import 'package:muzika/services/proxy_manager.dart';
import 'package:muzika/utilities/app_utils.dart';
import 'package:muzika/utilities/formatter.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'package:youtube_music_explode_dart/youtube_music_explode_dart.dart';

/// Goes through the catalog relay when configured (YouTube Music hides its
/// catalog from Ethiopian IPs).
final ytMusicClient = createMusicClient();
final Map<String, Future<void>> _artistCatalogOperationTails = {};

Future<List<Map<String, dynamic>>> searchVerifiedArtists(
  String query, {
  int limit = 5,
}) async {
  final normalizedQuery = query.trim();
  if (normalizedQuery.isEmpty) return [];
  // Deezer first (real photos), Apple when Deezer has nothing.
  try {
    final found = await deezerSearchArtists(normalizedQuery, limit: limit);
    if (found.isNotEmpty) return found;
  } catch (e, stackTrace) {
    logger.log('Deezer artist search failed', error: e, stackTrace: stackTrace);
  }
  if (useItunesCatalog) {
    try {
      return await itunesSearchArtists(normalizedQuery, limit: limit);
    } catch (e, stackTrace) {
      logger.log(
        'iTunes artist search failed',
        error: e,
        stackTrace: stackTrace,
      );
      return [];
    }
  }

  final cacheKey =
      'search_music_artists_v${artistSearchCacheVersion}_l$limit'
      '_${normalizedQuery.toLowerCase()}';
  final cachedArtists = await getData('cache', cacheKey);
  if (cachedArtists is List) {
    return asMapList(cachedArtists).take(limit).toList();
  }

  try {
    final artists = _dedupeResolvedArtists(
      (await ytMusicClient.music
              .searchArtists(normalizedQuery)
              .timeout(artistRequestTimeout))
          .where((artist) => !looksUnofficialArtistName(artist.name))
          .map(_artistMapFromMusicArtist),
    ).take(limit).toList();

    if (artists.isNotEmpty) {
      unawaited(addOrUpdateData<List>('cache', cacheKey, artists));
    }
    return artists;
  } catch (e, stackTrace) {
    logger.log(
      'Error while searching YouTube Music artists for "$normalizedQuery"',
      error: e,
      stackTrace: stackTrace,
    );
    return [];
  }
}

Future<Map<String, dynamic>?> resolveArtist(
  String lookup, {
  String? sourceSongId,
  String? sourceVideoAuthor,
  String? preferredName,
  String? preferredImage,
  bool preferredVerified = false,
}) async {
  final normalizedLookup = lookup.trim();
  if (normalizedLookup.isEmpty || normalizedLookup == 'null') return null;

  final displayName = preferredName?.trim();
  if (preferredVerified &&
      _isChannelId(normalizedLookup) &&
      displayName != null &&
      displayName.isNotEmpty) {
    return _artistMapFromMusicArtist(
      MusicArtist(
        id: normalizedLookup,
        name: displayName,
        thumbnailUrl: preferredImage,
      ),
      preferredImage: preferredImage,
    );
  }

  final normalizedSourceSongId = sourceSongId?.trim();
  final terms = <String>{};

  void addAliases(String? value) {
    if (value == null) return;
    terms.addAll(_artistSearchAliases(value));
  }

  addAliases(displayName);
  addAliases(sourceVideoAuthor);

  if (normalizedSourceSongId != null && normalizedSourceSongId.isNotEmpty) {
    try {
      final sourceVideo = await ytClient.videos
          .get(normalizedSourceSongId)
          .timeout(artistRequestTimeout);
      addAliases(_artistNameFromVideoTitle(sourceVideo.title));
      addAliases(sourceVideo.author);
      for (final musicData in sourceVideo.musicData) {
        addAliases(musicData.artist);
      }
    } catch (e, stackTrace) {
      logger.log(
        'Could not load source video $normalizedSourceSongId for artist lookup',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  if (_isChannelId(normalizedLookup)) {
    try {
      final channel = await ytClient.channels
          .get(normalizedLookup)
          .timeout(artistRequestTimeout);
      addAliases(channel.title);
    } catch (e, stackTrace) {
      logger.log(
        'Could not load seeded artist channel $normalizedLookup',
        error: e,
        stackTrace: stackTrace,
      );
    }
  } else if (normalizedLookup != normalizedSourceSongId) {
    addAliases(normalizedLookup);
  }

  final artist = await _resolveMusicArtistFromTerms(
    terms,
    trustedLookupId: normalizedLookup,
    preferredImage: preferredImage,
    allowFirstResultForTrustedSeed: preferredVerified && displayName != null,
  );

  if (artist == null) {
    logger.log(
      'Artist lookup rejected: no canonical YouTube Music artist for '
      '"$normalizedLookup"; sourceSongId=$normalizedSourceSongId; '
      'preferredName=$displayName; terms=${terms.join(' | ')}',
    );
  }

  return artist;
}

/// An Apple artist or album page from the device for a week (Muzika), read
/// again only when it is not there or on a pull to refresh. Artist pages
/// only three hours: a new album shows the same day.
Future<Map<String, dynamic>?> _keptAWeek(
  String key,
  bool forceRefresh,
  Future<Map<String, dynamic>?> Function() read,
) async {
  if (!forceRefresh) {
    final kept = await getData(
      'cache',
      key,
      cachingDuration: key.startsWith('artist_page_')
          ? const Duration(hours: 3)
          : const Duration(days: 7),
    );
    if (kept is Map) return Map<String, dynamic>.from(_plain(kept) as Map);
  }
  final page = await read();
  if (page != null) unawaited(addOrUpdateData<Map>('cache', key, page));
  return page;
}

/// Hive gives maps back as Map<dynamic, dynamic>, all the way down.
Object? _plain(Object? v) => switch (v) {
  final Map m => <String, dynamic>{
    for (final e in m.entries) '${e.key}': _plain(e.value),
  },
  final List l => [for (final e in l) _plain(e)],
  _ => v,
};

/// Entry point for artist profile: page info, top songs, releases, and suggestions.
Future<Map<String, dynamic>?> getArtistProfile(
  String artistId, {
  bool forceRefresh = false,
  bool cacheResult = true,
  String? sourceSongId,
  String? sourceVideoAuthor,
  String? preferredName,
  String? preferredImage,
  bool preferredVerified = false,
}) async {
  try {
    final lookup = artistId.trim();
    // Muzika: Apple's catalog, without the relay. A page once read is kept
    // a week, so opening the artist again shows it at once.
    if (lookup.startsWith(deezerArtistPrefix)) {
      return await _keptAWeek(
        'artist_page_v6_$lookup',
        forceRefresh,
        () => deezerArtistProfile(lookup),
      );
    }
    if (lookup.startsWith(itunesArtistPrefix)) {
      return await _keptAWeek(
        'artist_page_v1_$lookup',
        forceRefresh,
        () => itunesArtistProfile(lookup),
      );
    }
    if (useItunesCatalog) {
      // An artist saved from YouTube Music, or opened from an older song:
      // the same artist on Apple, by name.
      final name = preferredName?.trim().isNotEmpty == true
          ? preferredName!.trim()
          : _isChannelId(lookup)
          ? null
          : lookup;
      if (name != null) {
        // Deezer by name, Apple when Deezer doesn't know them.
        return await _keptAWeek(
          'artist_page_v6_name_${name.toLowerCase()}',
          forceRefresh,
          () async =>
              await deezerArtistByName(name).catchError((_) => null) ??
              await itunesArtistByName(name),
        );
      }
    }
    final isChannelLookup = _isChannelId(lookup);

    // A channel id is read straight away: one browse answers both who the
    // artist is and what its page holds. The search that turns a name into a
    // channel is only paid when that browse comes back with a channel that has
    // no artist page of its own, e.g. the label that uploaded the song.
    if (isChannelLookup) {
      final knownChannel = await getData(
        'cache',
        _artistChannelCacheKey(lookup),
      );
      final profile = await _artistPageOf(
        knownChannel?.toString() ?? lookup,
        forceRefresh: forceRefresh,
        cacheResult: cacheResult,
        preferredName: preferredName,
        preferredImage: preferredImage,
      );
      if (profile != null) return profile;
    }

    final artist = await resolveArtist(
      lookup,
      preferredName: preferredName,
      preferredImage: preferredImage,
      sourceSongId: sourceSongId,
      sourceVideoAuthor: sourceVideoAuthor,
      preferredVerified: preferredVerified,
    );

    if (artist == null) {
      logger.log(
        'Artist profile not found: lookup=$artistId; '
        'sourceSongId=$sourceSongId; preferredName=$preferredName',
      );
      return null;
    }

    // Where this landed is deliberately not remembered for the channel that was
    // looked up: a channel that has no artist page of its own is a channel that
    // uploads for many artists, and which one this is was decided by the name
    // of the song it was opened from, not by the channel.
    return await _artistPageOf(
      artist['ytid']?.toString() ?? lookup,
      forceRefresh: forceRefresh,
      cacheResult: cacheResult,
      artist: artist,
    );
  } catch (e, stackTrace) {
    logger.log(
      'Error fetching artist profile for $artistId',
      error: e,
      stackTrace: stackTrace,
    );
    return null;
  }
}

/// Loads the artist page from cache or API.
/// Returns null if [artistId] has no artist page (e.g., a generic upload channel).
Future<Map<String, dynamic>?> _artistPageOf(
  String artistId, {
  required bool forceRefresh,
  Map<String, dynamic>? artist,
  String? preferredName,
  String? preferredImage,
  bool followCanonical = true,
  bool cacheResult = true,
}) async {
  // Nothing is dropped before the page is in hand: a refresh that fails on a
  // bad connection would otherwise leave the artist with no page at all.
  final cacheKey = _artistProfileCacheKey(artistId);
  if (!forceRefresh) {
    final cachedProfile = await getData('cache', cacheKey);
    if (cachedProfile is Map) {
      return Map<String, dynamic>.from(cachedProfile);
    }
  }

  final profile = await ytMusicClient.music
      .getArtistProfile(artistId)
      .timeout(artistProfileTimeout);

  // Non-artist channels are cached to avoid repeated lookups
  if (followCanonical && profile.id != artistId) {
    unawaited(
      addOrUpdateData<String>(
        'cache',
        _artistChannelCacheKey(artistId),
        profile.id,
      ),
    );
    return _artistPageOf(
      profile.id,
      forceRefresh: forceRefresh,
      cacheResult: cacheResult,
      artist: artist,
      preferredName: preferredName,
      preferredImage: preferredImage,
      followCanonical: false,
    );
  }

  final knownArtist =
      artist ??
      _artistMapFromMusicArtist(
        MusicArtist(
          id: profile.id,
          name: profile.name.isEmpty ? (preferredName ?? '') : profile.name,
          thumbnailUrl: profile.thumbnailUrl,
        ),
        preferredImage: preferredImage,
      );

  final artistName = normalizeArtistDisplayTitle(
    knownArtist['title']?.toString() ?? profile.name,
  );
  final artistProfile = {
    ...knownArtist,
    'title': artistName.isEmpty ? profile.name : artistName,
    'image':
        knownArtist['image']?.toString() ??
        normalizeArtistThumbnailUrl(profile.thumbnailUrl),
    'description': profile.description,
    'monthlyListeners': _extractCountToken(profile.monthlyListeners),
    // The play count is kept next to the song, never inside it: song maps
    // travel into the queue and into the library of the user, where the
    // counter of an artist shelf has no meaning.
    'topSongs': [
      for (final (index, song) in profile.topSongs.indexed)
        {
          'song': returnSongLayout(index, song.video),
          'playCount': _extractCountToken(song.playCount),
        },
    ],
    'releases': [
      for (final release in profile.releases)
        _releaseMapFromMusicAlbum(release, knownArtist),
    ],
    'relatedArtists': [
      for (final related in profile.relatedArtists)
        _artistMapFromMusicArtist(related),
    ],
  };

  // Don't cache empty pages from unverified channels
  if ((artistProfile['topSongs'] as List).isEmpty &&
      (artistProfile['releases'] as List).isEmpty) {
    logger.log('Artist page empty: $artistId (${profile.name})');
    return artist == null ? null : artistProfile;
  }

  if (cacheResult) {
    cacheArtistProfileInBackground(artistProfile);
  }
  return artistProfile;
}

Future<void> cacheArtistProfile(Map artist) async {
  final artistId = artist['ytid']?.toString();
  if (artistId == null || artistId.isEmpty) return;
  await addOrUpdateData<Map>(
    'cache',
    _artistProfileCacheKey(artistId),
    Map<String, dynamic>.from(artist),
  );
}

void cacheArtistProfileInBackground(Map artist) {
  unawaited(
    cacheArtistProfile(artist).catchError((error, stackTrace) {
      logger.log(
        'Failed to cache artist profile',
        error: error,
        stackTrace: stackTrace,
      );
    }),
  );
}

/// Artist catalog: all songs from the discography as a single playlist.
Future<Map<String, dynamic>?> getArtistCatalog(
  String artistId, {
  bool forceRefresh = false,
  String? sourceSongId,
  String? sourceVideoAuthor,
  String? preferredName,
  String? preferredImage,
  bool preferredVerified = false,
}) async {
  try {
    final artist = await getArtistProfile(
      artistId,
      forceRefresh: forceRefresh,
      cacheResult: !forceRefresh,
      preferredName: preferredName,
      preferredImage: preferredImage,
      sourceSongId: sourceSongId,
      sourceVideoAuthor: sourceVideoAuthor,
      preferredVerified: preferredVerified,
    );
    if (artist == null) return null;

    final catalog = await getArtistCatalogFromProfile(
      artist,
      forceRebuild: forceRefresh,
    );
    if (forceRefresh &&
        catalog != null &&
        catalog['catalogStatus'] != 'failed') {
      cacheArtistProfileInBackground(artist);
    }
    return catalog;
  } catch (e, stackTrace) {
    logger.log(
      'Error fetching artist catalog for $artistId',
      error: e,
      stackTrace: stackTrace,
    );
    return null;
  }
}

/// Builds the song catalog from the already-loaded profile to keep the release snapshot consistent.
Future<Map<String, dynamic>?> getArtistCatalogFromProfile(
  Map artist, {
  bool forceRebuild = false,
}) async {
  final artistId = artist['ytid']?.toString();
  if (artistId == null || artistId.isEmpty) return null;

  return _serializeArtistCatalogOperation(
    artistId,
    () => _getArtistCatalogFromProfile(
      artist,
      artistId: artistId,
      forceRebuild: forceRebuild,
    ),
  );
}

Future<Map<String, dynamic>?> _getArtistCatalogFromProfile(
  Map artist, {
  required String artistId,
  required bool forceRebuild,
}) async {
  try {
    final cacheKey = _artistCatalogCacheKey(artistId);
    if (!forceRebuild) {
      final cachedArtist = await getData('cache', cacheKey);
      if (cachedArtist is Map &&
          cachedArtist['list'] is List &&
          (cachedArtist['list'] as List).isNotEmpty) {
        return Map<String, dynamic>.from(cachedArtist);
      }
    }

    final catalog = await _catalogSongsOf(Map<String, dynamic>.from(artist));
    if ((forceRebuild && !catalog.isComplete) || catalog.songs.isEmpty) {
      logger.log(
        'Artist catalog incomplete: one or more YouTube Music releases could '
        'not be read for ${artist['title']} ($artistId)',
      );
      return {
        ...artistPlaylistData(artist, songs: const []),
        'catalogStatus': 'failed',
      };
    }

    if (!catalog.isComplete) {
      logger.log(
        'Artist catalog partially loaded for ${artist['title']} ($artistId)',
      );
    }

    // Most popular first (Deezer's rank), not album by album.
    final byPopularity = [...catalog.songs]
      ..sort(
        (a, b) =>
            ((b['rank'] as num?) ?? -1).compareTo((a['rank'] as num?) ?? -1),
      );
    final artistPlaylist = artistPlaylistData(artist, songs: byPopularity);
    // A refresh may immediately read this key to update another view. Finish
    // the local write before exposing the new catalog so stale data cannot win
    // that race.
    await addOrUpdateData<Map>('cache', cacheKey, artistPlaylist);
    return artistPlaylist;
  } catch (e, stackTrace) {
    logger.log(
      'Error building artist catalog from refreshed profile',
      error: e,
      stackTrace: stackTrace,
    );
    return null;
  }
}

/// Serializes catalog builds per artist so refreshes cannot be overwritten by older operations.
Future<T> _serializeArtistCatalogOperation<T>(
  String artistId,
  Future<T> Function() operation,
) async {
  final previous = _artistCatalogOperationTails[artistId];
  final completion = Completer<void>();
  final tail = completion.future;
  _artistCatalogOperationTails[artistId] = tail;

  if (previous != null) {
    try {
      await previous;
    } catch (_) {
      // The next materialization should still run after a failed predecessor.
    }
  }

  try {
    return await operation();
  } finally {
    completion.complete();
    if (identical(_artistCatalogOperationTails[artistId], tail)) {
      unawaited(_artistCatalogOperationTails.remove(artistId));
    }
  }
}

/// Artist as playlist (for library storage, downloads, and song lists).
Map<String, dynamic> artistPlaylistData(Map artist, {List? songs}) {
  return {
    'ytid': artist['ytid']?.toString(),
    'title': artist['title']?.toString() ?? '',
    'image': artist['image'],
    'source': 'youtube-artist',
    'isArtist': true,
    'isVerifiedArtist': true,
    'list': songs,
  };
}

/// Collects all songs from artist's discography in batches.
Future<({List<Map<String, dynamic>> songs, bool isComplete})> _catalogSongsOf(
  Map<String, dynamic> artist,
) async {
  final artistId = artist['ytid']?.toString();
  final artistName = artist['title']?.toString() ?? '';
  // Apple answers every song of the artist in one call.
  if (artistId != null && artistId.startsWith(itunesArtistPrefix)) {
    final all = artist['allSongs'] is List
        ? asMapList(artist['allSongs'])
        : asMapList((await itunesArtistProfile(artistId))?['allSongs']);
    return (songs: dedupeArtistCatalogSongs(all), isComplete: all.isNotEmpty);
  }
  final releases = asMapList(artist['releases']);

  final songs = <Map<String, dynamic>>[];
  var isComplete = true;
  for (var index = 0; index < releases.length; index += musicAlbumBatchSize) {
    final albums = await Future.wait([
      for (final release in releases.skip(index).take(musicAlbumBatchSize))
        getArtistAlbum(release['ytid']?.toString() ?? ''),
    ]);
    for (final album in albums) {
      if (album == null) {
        isComplete = false;
        continue;
      }
      // Credit songs to the artist, not the release owner (compilations, features)
      for (final song in asMapList(album['list'])) {
        songs.add({
          ...song,
          if (artistName.isNotEmpty) 'artist': artistName,
          if (artistId != null && artistId.isNotEmpty) 'artistId': artistId,
        });
      }
    }
  }

  return (songs: dedupeArtistCatalogSongs(songs), isComplete: isComplete);
}

/// Load release as standalone playlist (crediting happens later in catalog builder).
Future<Map<String, dynamic>?> getArtistAlbum(
  String albumId, {
  bool forceRefresh = false,
}) async {
  final normalizedAlbumId = albumId.trim();
  if (normalizedAlbumId.isEmpty) return null;
  if (normalizedAlbumId.startsWith(deezerAlbumPrefix)) {
    try {
      return await _keptAWeek(
        'album_page_v2_$normalizedAlbumId',
        forceRefresh,
        () => deezerAlbum(normalizedAlbumId),
      );
    } catch (e, stackTrace) {
      logger.log(
        'Could not load Deezer album $normalizedAlbumId',
        error: e,
        stackTrace: stackTrace,
      );
      return null;
    }
  }
  if (normalizedAlbumId.startsWith(itunesAlbumPrefix)) {
    try {
      return await _keptAWeek(
        'album_page_v1_$normalizedAlbumId',
        forceRefresh,
        () => itunesAlbum(normalizedAlbumId),
      );
    } catch (e, stackTrace) {
      logger.log(
        'Could not load iTunes album $normalizedAlbumId',
        error: e,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  final cacheKey =
      'artist_album_v${artistAlbumCacheVersion}_$normalizedAlbumId';
  if (!forceRefresh) {
    final cachedAlbum = await getData('cache', cacheKey);
    if (cachedAlbum is Map &&
        cachedAlbum['list'] is List &&
        (cachedAlbum['list'] as List).isNotEmpty) {
      return Map<String, dynamic>.from(cachedAlbum);
    }
  } else {
    await _dropFromCache(cacheKey);
  }

  try {
    final release = await ytMusicClient.music
        .getAlbum(normalizedAlbumId)
        .timeout(musicAlbumTimeout);

    for (final track in release.tracks) {
      registerSongHint(
        track.id.value,
        title: track.title,
        artist: release.artist ?? track.author,
        duration: track.duration,
      );
    }

    final album = {
      'ytid': normalizedAlbumId,
      'title': release.title,
      'image': normalizeArtistThumbnailUrl(release.thumbnailUrl),
      'artist': release.artist,
      'artistId': release.artistId,
      'year': release.year,
      'source': 'youtube-album',
      'isAlbum': true,
      'list': [
        for (final (index, track) in release.tracks.indexed)
          {
            // Square album art instead of the 16:9 video frame (Muzika).
            ...returnSongLayout(
              index,
              track,
              playlistImage: squareArt(release.thumbnailUrl, 544),
            ),
            'album': release.title,
            'albumId': normalizedAlbumId,
          },
      ],
    };

    if (release.tracks.isNotEmpty) {
      unawaited(addOrUpdateData<Map>('cache', cacheKey, album));
    }
    return album;
  } catch (e, stackTrace) {
    logger.log(
      'Could not load YouTube Music album $normalizedAlbumId',
      error: e,
      stackTrace: stackTrace,
    );
    return null;
  }
}

/// Check if release is single/EP (YouTube Music explicitly labels only these).
bool isSingleOrEpRelease(Map release) {
  final type = release['releaseType']?.toString();
  return type == 'single' || type == 'ep';
}

String _artistCatalogCacheKey(String artistId) =>
    'artist_catalog_v${artistCatalogCacheVersion}_$artistId';

String _artistProfileCacheKey(String artistId) =>
    'artist_profile_v${artistProfileCacheVersion}_$artistId';

/// Canonical artist page for a channel (channels may host multiple artists).
String _artistChannelCacheKey(String channelId) =>
    'artist_channel_v${artistChannelCacheVersion}_$channelId';

Future<void> _dropFromCache(String cacheKey) async {
  await deleteData('cache', cacheKey);
  await deleteData('cache', '${cacheKey}_date');
}

Map<String, dynamic> _releaseMapFromMusicAlbum(MusicAlbum album, Map artist) {
  return {
    'ytid': album.id,
    'title': album.title,
    'image': normalizeArtistThumbnailUrl(album.thumbnailUrl),
    'year': album.year,
    'releaseType': album.type.name,
    'artist': artist['title']?.toString(),
    'artistId': artist['ytid']?.toString(),
    'source': 'youtube-album',
    'isAlbum': true,
  };
}

/// Reduces YouTube Music counters like `331M monthly audience` to `331M`.
String? _extractCountToken(String? value) {
  final text = value?.trim();
  if (text == null || text.isEmpty) return null;

  final match = ArtistPatterns.countToken.firstMatch(text);
  final token = match?.group(0)?.trim();
  return (token == null || token.isEmpty) ? text : token;
}

String? normalizeArtistThumbnailUrl(String? value) {
  final thumbnail = value?.trim();
  if (thumbnail == null || thumbnail.isEmpty) return null;

  late final String normalized;
  if (thumbnail.startsWith('//')) {
    normalized = 'https:$thumbnail';
  } else if (thumbnail.startsWith('https:') &&
      !thumbnail.startsWith('https://')) {
    normalized =
        'https://${thumbnail.substring(6).replaceFirst(RegExp('^/+'), '')}';
  } else if (thumbnail.startsWith('http:') &&
      !thumbnail.startsWith('http://')) {
    normalized =
        'https://${thumbnail.substring(5).replaceFirst(RegExp('^/+'), '')}';
  } else if (thumbnail.startsWith('http://') ||
      thumbnail.startsWith('https://')) {
    normalized = thumbnail;
  } else if (thumbnail.startsWith('/')) {
    normalized = 'https://www.youtube.com$thumbnail';
  } else {
    normalized = 'https://$thumbnail';
  }

  return _upgradeArtistThumbnailResolution(normalized);
}

String _upgradeArtistThumbnailResolution(String thumbnail) {
  final uri = Uri.tryParse(thumbnail);
  final host = uri?.host.toLowerCase() ?? '';
  if (!host.endsWith('googleusercontent.com') && !host.endsWith('ggpht.com')) {
    return thumbnail;
  }

  return thumbnail
      .replaceFirst(RegExp(r'=w\d+-h\d+'), '=w544-h544')
      .replaceFirst(RegExp(r'=s\d+'), '=s544');
}

String normalizeArtistDisplayTitle(String value) =>
    _cleanArtistSearchTerm(value).replaceAll(RegExp(r'\s+'), ' ').trim();

bool looksUnofficialArtistName(String name) {
  final lowerName = name.toLowerCase();
  return lowerName.contains('cover') ||
      lowerName.contains('lyrics') ||
      lowerName.contains('lyric') ||
      lowerName.contains('reaction') ||
      lowerName.contains('fan') ||
      lowerName.contains('tribute') ||
      lowerName.contains('karaoke') ||
      lowerName.contains('parody') ||
      lowerName.contains('nightcore') ||
      lowerName.contains('sped up') ||
      lowerName.contains('slowed');
}

List<Map<String, dynamic>> dedupeArtistCatalogSongs(
  List<Map<String, dynamic>> songs,
) {
  final seenIds = <String>{};
  final seenTitles = <String>{};
  final unique = <Map<String, dynamic>>[];
  for (final song in songs) {
    final id = song['ytid']?.toString();
    if (id == null || id.isEmpty || !seenIds.add(id)) continue;

    final title = formatSongTitle(song['title']?.toString() ?? '');
    final artist = song['artist']?.toString() ?? '';
    if (title.trim().isEmpty || _sameArtistPageSongTitle(title, artist)) {
      continue;
    }

    final titleKey =
        '${_canonicalArtistName(artist)}:${_canonicalSongTitle(title)}';
    if (!seenTitles.add(titleKey)) {
      continue;
    }

    unique.add({...song, 'id': unique.length, 'title': title});
  }
  return unique;
}

Future<Map<String, dynamic>?> _resolveMusicArtistFromTerms(
  Set<String> terms, {
  required String trustedLookupId,
  required String? preferredImage,
  required bool allowFirstResultForTrustedSeed,
}) async {
  final normalizedTerms = terms
      .map(normalizeArtistDisplayTitle)
      .where((term) => term.isNotEmpty)
      .toList();
  final searched = <String>{};

  for (final term in normalizedTerms) {
    if (!searched.add(term.toLowerCase())) continue;

    List<MusicArtist> candidates;
    try {
      candidates = await ytMusicClient.music
          .searchArtists(term)
          .timeout(artistRequestTimeout);
    } catch (e, stackTrace) {
      logger.log(
        'YouTube Music artist search failed for "$term"',
        error: e,
        stackTrace: stackTrace,
      );
      continue;
    }

    for (final candidate in candidates) {
      if (candidate.id == trustedLookupId ||
          _canAcceptMusicArtist(
            candidate,
            term,
            allowFirstResultForTrustedSeed: allowFirstResultForTrustedSeed,
          )) {
        return _artistMapFromMusicArtist(
          candidate,
          preferredImage: preferredImage,
        );
      }
    }
  }

  return null;
}

bool _canAcceptMusicArtist(
  MusicArtist candidate,
  String term, {
  required bool allowFirstResultForTrustedSeed,
}) {
  if (candidate.id.isEmpty ||
      candidate.name.trim().isEmpty ||
      looksUnofficialArtistName(candidate.name)) {
    return false;
  }

  if (_strictSameArtistTitle(candidate.name, term)) return true;

  final termKey = _strictArtistTitleKey(term);
  final candidateKey = _strictArtistTitleKey(candidate.name);
  if (termKey.length >= 4 &&
      candidateKey.isNotEmpty &&
      (candidateKey.contains(termKey) || termKey.contains(candidateKey))) {
    return true;
  }

  return allowFirstResultForTrustedSeed;
}

Map<String, dynamic> _artistMapFromMusicArtist(
  MusicArtist artist, {
  String? preferredImage,
}) {
  return {
    'ytid': artist.id,
    'title': normalizeArtistDisplayTitle(artist.name),
    'image': normalizeArtistThumbnailUrl(artist.thumbnailUrl ?? preferredImage),
    'source': 'youtube-artist',
    'isArtist': true,
    'isVerifiedArtist': true,
    'list': [],
  };
}

List<Map<String, dynamic>> _dedupeResolvedArtists(
  Iterable<Map<String, dynamic>> artists,
) {
  final seenIds = <String>{};
  final seenTitles = <String>{};
  final unique = <Map<String, dynamic>>[];

  for (final artist in artists) {
    final id = artist['ytid']?.toString() ?? '';
    final titleKey = _strictArtistTitleKey(artist['title']?.toString() ?? '');
    if (id.isNotEmpty && !seenIds.add(id)) continue;
    if (titleKey.isNotEmpty && !seenTitles.add(titleKey)) continue;
    unique.add(artist);
  }

  return unique;
}

bool _sameArtistPageSongTitle(String title, String artist) {
  final canonicalTitle = _canonicalSongTitle(title);
  final canonicalArtist = _canonicalArtistName(artist);
  return canonicalTitle.isNotEmpty && canonicalTitle == canonicalArtist;
}

String _artistNameFromVideoTitle(String title) {
  final sep = title.indexOf(' - ');
  if (sep <= 0) return '';
  return title.substring(0, sep).trim();
}

Set<String> _artistSearchAliases(String value) {
  final cleaned = _cleanArtistSearchTerm(value);
  if (cleaned.isEmpty) return {};

  final aliases = <String>{cleaned, _spaceCamelCaseArtistTitle(cleaned)};

  void _addAlias(String term) {
    final trimmed = term.trim();
    if (trimmed.isNotEmpty) {
      aliases
        ..add(trimmed)
        ..add(_spaceCamelCaseArtistTitle(trimmed));
    }
  }

  // Handle featuring artists
  final featureSplit = cleaned.split(ArtistPatterns.feature);
  if (featureSplit.isNotEmpty) {
    _addAlias(featureSplit.first);
  }

  // Handle collaborations (featured artists joined with &, x, +)
  final joinedArtists = cleaned.split(ArtistPatterns.collaboration);
  if (joinedArtists.isNotEmpty) {
    _addAlias(joinedArtists.first);
  }

  // Handle comma-separated artists
  final commaParts = cleaned.split(',');
  if (commaParts.length > 1 && commaParts.first.trim().length > 3) {
    _addAlias(commaParts.first);
  }

  return aliases;
}

String _spaceCamelCaseArtistTitle(String value) {
  final trimmed = value.trim();
  if (trimmed.length < 2) return trimmed;

  final buffer = StringBuffer(trimmed[0]);
  for (var index = 1; index < trimmed.length; index++) {
    final previous = trimmed.codeUnitAt(index - 1);
    final current = trimmed.codeUnitAt(index);
    final previousIsLower = previous >= 97 && previous <= 122;
    final currentIsUpper = current >= 65 && current <= 90;
    if (previousIsLower && currentIsUpper) {
      buffer.write(' ');
    }
    buffer.writeCharCode(current);
  }

  return buffer.toString().trim();
}

String _cleanArtistSearchTerm(String value) {
  return _normalizeArtistText(value)
      .replaceAll(ArtistPatterns.topicChannel, '')
      .replaceAll(ArtistPatterns.topicSuffix, '')
      .replaceAll(ArtistPatterns.vevo, '')
      .replaceAll(ArtistPatterns.officialArtistChannel, '')
      .trim();
}

bool _strictSameArtistTitle(String left, String right) {
  final leftKey = _strictArtistTitleKey(left);
  final rightKey = _strictArtistTitleKey(right);

  return leftKey.isNotEmpty && leftKey == rightKey;
}

String _strictArtistTitleKey(String value) {
  return _cleanArtistSearchTerm(value)
      .toLowerCase()
      .replaceAll('&amp;', '&')
      .replaceAll(ArtistPatterns.officialChannel, '')
      .replaceAll(ArtistPatterns.musicChannel, '')
      .replaceAll(ArtistPatterns.official, '')
      .replaceAll(ArtistPatterns.vevoWord, '')
      .replaceAll(ArtistPatterns.nonAlphanumeric, ' ')
      .replaceAll(ArtistPatterns.multipleSpaces, ' ')
      .trim();
}

String _normalizeArtistText(String value) {
  final buffer = StringBuffer();
  for (final rune in value.runes) {
    buffer.writeCharCode(_normalizeStyledRune(rune) ?? rune);
  }
  return buffer.toString();
}

int? _normalizeStyledRune(int rune) {
  int? mapLetters(int upperStart, int lowerStart) {
    if (rune >= upperStart && rune <= upperStart + 25) {
      return 0x41 + rune - upperStart;
    }
    if (rune >= lowerStart && rune <= lowerStart + 25) {
      return 0x61 + rune - lowerStart;
    }
    return null;
  }

  int? mapDigits(int digitStart) {
    if (rune >= digitStart && rune <= digitStart + 9) {
      return 0x30 + rune - digitStart;
    }
    return null;
  }

  for (final (upperStart, lowerStart) in StyledCharacterRanges.charRanges) {
    final mapped = mapLetters(upperStart, lowerStart);
    if (mapped != null) return mapped;
  }

  for (final digitStart in StyledCharacterRanges.digitStarts) {
    final mapped = mapDigits(digitStart);
    if (mapped != null) return mapped;
  }

  return null;
}

String _canonicalSongTitle(String value) {
  return formatSongTitle(value)
      .toLowerCase()
      .replaceAll('&amp;', '&')
      .replaceAll(ArtistPatterns.audioVideoLyrics, '')
      .replaceAll(ArtistPatterns.nonAlphanumeric, '');
}

String _canonicalArtistName(String value) {
  final lower = _normalizeArtistText(value)
      .toLowerCase()
      .replaceAll('&amp;', '&')
      .replaceAll(ArtistPatterns.topicSuffix, '')
      .replaceAll(ArtistPatterns.officialChannel, '')
      .replaceAll(ArtistPatterns.musicChannel, '')
      .replaceAll(ArtistPatterns.official, '')
      .trim();

  var cleaned = lower.replaceAll(ArtistPatterns.nonAlphanumeric, '');
  var previous = '';
  while (cleaned != previous) {
    previous = cleaned;
    cleaned = cleaned.replaceAll(
      RegExp(r'(official|music|channel|topic|vevo)$'),
      '',
    );
  }

  if (cleaned.isNotEmpty) return cleaned;

  return lower.replaceAll(ArtistPatterns.multipleSpaces, '');
}

bool _isChannelId(String value) => ChannelId.validateChannelId(value);

/// A related artist on an artist's page: name, channel id and photo.
typedef ArtistSummaryEntry = ({String name, String id, String? photo});

/// An artist's photo and related artists (Discover's Clips feed).
typedef ArtistSummary = ({String? photo, List<ArtistSummaryEntry> related});

/// [channelId]'s photo and the artists YouTube Music shows as related: one
/// call through the relay (the page's discography is not read), kept a
/// week. Null when it can't be read.
Future<ArtistSummary?> artistSummary(String channelId) async {
  final key = 'artist_summary_v1_$channelId';
  final cached = await getData(
    'cache',
    key,
    cachingDuration: const Duration(days: 7),
  );
  if (cached is Map) {
    return (
      photo: cached['photo'] as String?,
      related: [
        for (final r in (cached['related'] as List? ?? const []))
          if (r is Map)
            (
              name: '${r['name']}',
              id: '${r['id']}',
              photo: r['photo'] as String?,
            ),
      ],
    );
  }
  try {
    final summary = await ytMusicClient.music
        .getArtistSummary(channelId)
        .timeout(artistRequestTimeout);
    // Big enough to fill a Discover card.
    String? large(String? url) =>
        normalizeArtistThumbnailUrl(url)
            ?.replaceFirst(RegExp(r'=w\d+-h\d+'), '=w1080-h1080');
    final result = (
      photo: large(summary.artist.thumbnailUrl),
      related: [
        for (final r in summary.related)
          (
            name: normalizeArtistDisplayTitle(r.name),
            id: r.id,
            photo: large(r.thumbnailUrl),
          ),
      ],
    );
    unawaited(
      addOrUpdateData<Map>('cache', key, {
        'photo': result.photo,
        'related': [
          for (final r in result.related)
            {'name': r.name, 'id': r.id, 'photo': r.photo},
        ],
      }),
    );
    return result;
  } catch (e) {
    logger.log('Artist summary failed for $channelId', error: e);
    return null;
  }
}
