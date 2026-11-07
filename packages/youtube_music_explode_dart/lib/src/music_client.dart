import 'package:youtube_explode_dart/youtube_explode_dart.dart';

typedef _JsonMap = Map<String, dynamic>;

/// A canonical YouTube Music artist result.
class MusicArtist {
  const MusicArtist({required this.id, required this.name, this.thumbnailUrl});

  /// Canonical `UC...` artist channel id.
  final String id;

  /// Display name returned by YouTube Music.
  final String name;

  /// Artist avatar URL, when YouTube Music exposes one.
  final String? thumbnailUrl;
}

/// Kind of a release listed on a YouTube Music artist page.
enum MusicReleaseType { album, single, ep, other }

/// A release (album, single or EP) as listed on a YouTube Music artist page.
class MusicAlbum {
  const MusicAlbum(
    this.id,
    this.title, {
    this.thumbnailUrl,
    this.type = MusicReleaseType.other,
    this.year,
  });

  /// Browse id of the release, e.g. `MPREb_...`.
  final String id;

  /// Display title of the release.
  final String title;

  /// Release artwork URL, when YouTube Music exposes one.
  final String? thumbnailUrl;

  /// Whether YouTube Music lists this release as a single or an EP. Album
  /// shelves only label their entries in the full grid, so an unlabelled
  /// release is [MusicReleaseType.other].
  final MusicReleaseType type;

  /// Release year, when YouTube Music exposes one.
  final String? year;

  @override
  String toString() => 'MusicAlbum($id, $title)';
}

/// A YouTube Music release page: the release itself plus its tracks.
class MusicReleasePage {
  const MusicReleasePage({
    required this.id,
    required this.title,
    this.artist,
    this.artistId,
    this.thumbnailUrl,
    this.year,
    this.tracks = const [],
  });

  /// Browse id of the release, e.g. `MPREb_...`.
  final String id;

  /// Display title of the release.
  final String title;

  /// Artist credited for the release, when YouTube Music exposes one.
  final String? artist;

  /// Channel id of that artist, when its name links to its page.
  final String? artistId;

  /// Release artwork URL, when YouTube Music exposes one.
  final String? thumbnailUrl;

  /// Release year, when YouTube Music exposes one.
  final String? year;

  /// The tracks of the release, in order.
  final List<Video> tracks;
}

/// A song from the YouTube Music catalog with its real metadata (Muzika).
class MusicSong {
  const MusicSong({
    required this.videoId,
    required this.title,
    required this.artist,
    this.artistId,
    this.album,
    this.albumId,
    this.duration,
    this.thumbnailUrl,
  });

  final String videoId;
  final String title;

  /// Credited artists, joined as YouTube Music displays them.
  final String artist;
  final String? artistId;
  final String? album;

  /// Browse id of the album, e.g. `MPREb_...`.
  final String? albumId;
  final Duration? duration;

  /// Square album artwork URL.
  final String? thumbnailUrl;

  @override
  String toString() => 'MusicSong($videoId, $title, $artist)';
}

/// An album or playlist from a YouTube Music search (Muzika).
class MusicCollection {
  const MusicCollection({
    required this.id,
    required this.title,
    this.subtitle,
    this.artist,
    this.year,
    this.thumbnailUrl,
    this.isAlbum = true,
  });

  /// `MPREb_…` browse id for albums, the bare playlist id (no `VL`) for
  /// playlists.
  final String id;
  final String title;

  /// The grey line under the title, e.g. `Album • Teddy Afro • 2017`.
  final String? subtitle;
  final String? artist;
  final String? year;

  /// Square artwork URL.
  final String? thumbnailUrl;
  final bool isAlbum;
}

/// What the "Top result" card of a YouTube Music search points to.
enum MusicTopResultKind { artist, album, playlist, song }

/// The "Top result" card of an unfiltered YouTube Music search (Muzika).
class MusicTopResult {
  const MusicTopResult({
    required this.kind,
    required this.id,
    required this.title,
    this.subtitle,
    this.thumbnailUrl,
  });

  final MusicTopResultKind kind;

  /// `UC…` artist, `MPRE…` album, playlist id (no `VL`) or video id.
  final String id;
  final String title;
  final String? subtitle;
  final String? thumbnailUrl;
}

/// A track of the artist page "Top songs" shelf.
class MusicTopSong {
  const MusicTopSong(this.video, this.playCount);

  /// The track itself.
  final Video video;

  /// Play count as displayed by YouTube Music, e.g. `1.2B plays`, when the
  /// shelf lists one.
  final String? playCount;
}

/// A YouTube Music artist page.
class MusicArtistProfile {
  const MusicArtistProfile({
    required this.id,
    required this.name,
    this.thumbnailUrl,
    this.description,
    this.monthlyListeners,
    this.topSongs = const [],
    this.releases = const [],
    this.relatedArtists = const [],
  });

  /// Canonical `UC...` artist channel id, not necessarily the one the page was
  /// asked for: see [MusicClient.getArtistProfile].
  final String id;

  /// Display name returned by YouTube Music.
  final String name;

  /// Header artwork URL, when YouTube Music exposes one.
  final String? thumbnailUrl;

  /// Artist biography, when YouTube Music exposes one.
  final String? description;

  /// Monthly listeners as displayed by YouTube Music, e.g.
  /// `331M monthly audience`.
  final String? monthlyListeners;

  /// The tracks of the artist page "Top songs" shelf.
  final List<MusicTopSong> topSongs;

  /// Every release of the artist: albums, singles and EPs.
  final List<MusicAlbum> releases;

  /// Artists the "Fans might also like" shelf points to.
  final List<MusicArtist> relatedArtists;
}

/// A song's lyrics from YouTube Music: timed lines when it has them,
/// otherwise the plain text.
class MusicLyrics {
  const MusicLyrics({this.timed, this.plain, this.source});

  /// Each line with when it starts; null when the lyrics have no timing.
  final List<({Duration start, String text})>? timed;
  final String? plain;

  /// e.g. "Source: Musixmatch".
  final String? source;

  bool get isSynced => timed != null && timed!.isNotEmpty;
}

/// Queries the YouTube Music (`WEB_REMIX`) browse endpoints.
class MusicClient {
  /// Initializes an instance of [MusicClient].
  const MusicClient(this._httpClient);

  final YoutubeHttpClient _httpClient;

  static const _remixContext = {
    'client': {
      'clientName': 'WEB_REMIX',
      'clientVersion': '1.20261008.01.00',
      'hl': 'en',
    },
  };

  /// The YouTube Music Android app: the only client whose lyrics carry
  /// line timings.
  static const _androidContext = {
    'client': {
      'clientName': 'ANDROID_MUSIC',
      'clientVersion': '7.21.50',
      'androidSdkVersion': 30,
      'hl': 'en',
    },
  };

  static const _newline = '\n';

  /// Lyrics of [videoId] from its "Lyrics" tab, or null when it has none.
  Future<MusicLyrics?> getLyrics(String videoId) async {
    final next = await _httpClient.sendPost('next', {
      'context': _remixContext,
      'videoId': videoId,
    });
    final browseId = _findAll(next, 'browseId').whereType<String>().firstWhere(
      (id) => id.startsWith('MPLY'),
      orElse: () => '',
    );
    if (browseId.isEmpty) return null;

    final root = await _httpClient.sendPost('browse', {
      'context': _androidContext,
      'browseId': browseId,
    });
    final source = _findAll(root, 'footer')
        .whereType<_JsonMap>()
        .expand((f) => (f['runs'] as List? ?? const []).whereType<_JsonMap>())
        .map((r) => r['text']?.toString() ?? '')
        .firstWhere((t) => t.isNotEmpty, orElse: () => '');

    final lines = _findAll(
      root,
      'timedLyricsData',
    ).whereType<List>().expand((l) => l.whereType<_JsonMap>()).toList();
    if (lines.isNotEmpty) {
      final text = [for (final l in lines) l['lyricLine']?.toString() ?? ''];
      final hasTimes = lines.every((l) => l['cueRange'] is _JsonMap);
      if (hasTimes) {
        return MusicLyrics(
          timed: [
            for (final l in lines)
              (
                start: Duration(
                  milliseconds:
                      int.tryParse(
                        '${(l['cueRange'] as _JsonMap)['startTimeMilliseconds']}',
                      ) ??
                      0,
                ),
                text: l['lyricLine']?.toString() ?? '',
              ),
          ],
          plain: text.join(_newline),
          source: source.isEmpty ? null : source,
        );
      }
      return MusicLyrics(
        plain: text.join(_newline),
        source: source.isEmpty ? null : source,
      );
    }

    // Some songs only have the text block.
    final plain = _findAll(root, 'description')
        .whereType<_JsonMap>()
        .expand((d) => (d['runs'] as List? ?? const []).whereType<_JsonMap>())
        .map((r) => r['text']?.toString() ?? '')
        .join();
    if (plain.trim().isEmpty) return null;
    return MusicLyrics(plain: plain, source: source.isEmpty ? null : source);
  }

  /// Every value stored under [key] anywhere in [node].
  static Iterable<Object?> _findAll(Object? node, String key) sync* {
    if (node is Map) {
      for (final entry in node.entries) {
        if (entry.key == key) yield entry.value;
        yield* _findAll(entry.value, key);
      }
    } else if (node is List) {
      for (final item in node) {
        yield* _findAll(item, key);
      }
    }
  }

  /// Search filter that restricts results to artists only.
  static const _artistsSearchParams = 'EgWKAQIgAWoMEA4QChADEAQQCRAF';

  /// Search filter for the dedicated "Songs" shelf.
  static const _songsSearchParams = 'EgWKAQIIAWoMEA4QChADEAQQCRAF';

  /// Search filters for the "Albums" and "Community playlists" shelves.
  static const _albumsSearchParams = 'EgWKAQIYAWoMEA4QChADEAQQCRAF';
  static const _playlistsSearchParams = 'EgeKAQQoAEABagwQDhAKEAMQBBAJEAU%3D';

  static const _artistPageType = 'MUSIC_PAGE_TYPE_ARTIST';

  /// Stands in for the channel of a track whose artist page is unknown.
  static const _unknownChannelId = 'UC0000000000000000000000';

  /// Matches the play count of a top song, e.g. `1.2B plays`. The client asks
  /// for `hl: en`, so the wording is stable.
  static final _playCountPattern = RegExp(
    r'^[\d.,]+\s?[KMB]?\s+plays$',
    caseSensitive: false,
  );

  /// Searches YouTube Music for canonical artist entries matching [query].
  Future<List<MusicArtist>> searchArtists(String query) async {
    final normalizedQuery = query.trim();
    if (normalizedQuery.isEmpty) return [];

    final root = await _httpClient.sendPost('search', {
      'context': _remixContext,
      'query': normalizedQuery,
      'params': _artistsSearchParams,
    });

    final results = <MusicArtist>[];
    final seen = <String>{};
    for (final item in _findRenderers(
      root,
      'musicResponsiveListItemRenderer',
    )) {
      final endpoint = item
          .getMap('navigationEndpoint')
          ?.getMap('browseEndpoint');
      final id = endpoint?.getValue<String>('browseId');
      if (id == null || !id.startsWith('UC') || !seen.add(id)) continue;

      final pageType = endpoint
          ?.getMap('browseEndpointContextSupportedConfigs')
          ?.getMap('browseEndpointContextMusicConfig')
          ?.getValue<String>('pageType');
      if (pageType != _artistPageType) continue;

      final name = _flexColumnText(item, 0) ?? '';
      if (name.trim().isEmpty) continue;

      results.add(
        MusicArtist(
          id: id,
          name: name.trim(),
          thumbnailUrl: _thumbnailUrl(item, 'thumbnail'),
        ),
      );
    }
    return results;
  }

  /// Searches the YouTube Music "Songs" shelf for [query].
  ///
  /// When supplied, [expectedArtist] and [expectedTitle] must loosely match
  /// the result's credited artist and title. This prevents common-title
  /// searches from returning the wrong recording.
  Future<Video?> searchSong(
    String query, {
    String? expectedArtist,
    String? expectedTitle,
  }) async {
    final normalizedQuery = query.trim();
    if (normalizedQuery.isEmpty) return null;

    final root = await _httpClient.sendPost('search', {
      'context': _remixContext,
      'query': normalizedQuery,
      'params': _songsSearchParams,
    }, validate: true);

    final isValidating = expectedArtist != null || expectedTitle != null;
    Video? fallback;
    for (final item in _findRenderers(
      root,
      'musicResponsiveListItemRenderer',
    )) {
      final videoId = _trackVideoId(item);
      if (videoId == null) continue;

      final title = _flexColumnText(item, 0);
      if (title == null || title.isEmpty) continue;

      final subtitleParts = _splitBullets(_flexColumnText(item, 1));
      final artist = subtitleParts.isNotEmpty ? subtitleParts.first : '';

      final video = _trackVideo(item, videoId, title, artist, null);
      fallback ??= video;

      if (expectedArtist != null && !_looselyMatch(artist, expectedArtist)) {
        continue;
      }
      if (expectedTitle != null && !_looselyMatch(title, expectedTitle)) {
        continue;
      }

      return video;
    }

    // Only use the first result when no expected values were provided.
    return isValidating ? null : fallback;
  }

  /// Searches the YouTube Music "Songs" shelf and returns every song with its
  /// catalog metadata: clean title, artists, album and square artwork.
  Future<List<MusicSong>> searchSongs(String query) async {
    final normalizedQuery = query.trim();
    if (normalizedQuery.isEmpty) return [];

    final root = await _httpClient.sendPost('search', {
      'context': _remixContext,
      'query': normalizedQuery,
      'params': _songsSearchParams,
    });

    final songs = <MusicSong>[];
    final seen = <String>{};
    for (final item in _findRenderers(
      root,
      'musicResponsiveListItemRenderer',
    )) {
      final videoId = _trackVideoId(item);
      if (videoId == null || !seen.add(videoId)) continue;
      final title = _flexColumnText(item, 0);
      if (title == null || title.trim().isEmpty) continue;

      // Subtitle runs: artists (linked to UC… pages), album (MPRE…), length.
      final runs = _flexColumnRuns(item, 1);
      final artists = <String>[];
      String? artistId;
      String? album;
      String? albumId;
      String? length;
      for (final run in runs) {
        final text = (run.getValue<String>('text') ?? '').trim();
        final browseId = run
            .getMap('navigationEndpoint')
            ?.getMap('browseEndpoint')
            ?.getValue<String>('browseId');
        if (browseId != null && browseId.startsWith('UC')) {
          artists.add(text);
          artistId ??= browseId;
        } else if (browseId != null && browseId.startsWith('MPRE')) {
          album = text;
          albumId = browseId;
        } else if (RegExp(r'^\d+(:\d{2}){1,2}$').hasMatch(text)) {
          length = text;
        }
      }
      if (artists.isEmpty) {
        final parts = _splitBullets(_flexColumnText(item, 1));
        if (parts.isNotEmpty) artists.add(parts.first);
      }

      songs.add(
        MusicSong(
          videoId: videoId,
          title: title.trim(),
          artist: artists.join(', '),
          artistId: artistId,
          album: album,
          albumId: albumId,
          duration:
              _parseDuration(length) ?? _parseDuration(_fixedColumnText(item)),
          thumbnailUrl: _thumbnailUrl(item, 'thumbnail'),
        ),
      );
    }
    return songs;
  }

  /// The "Top result" card YouTube Music shows for [query], if any. It copes
  /// with misspellings ("buzatew demesse" finds Bezuayehu Demissie).
  Future<MusicTopResult?> searchTopResult(String query) async {
    final normalizedQuery = query.trim();
    if (normalizedQuery.isEmpty) return null;
    final root = await _httpClient.sendPost('search', {
      'context': _remixContext,
      'query': normalizedQuery,
    });
    final card = _findRenderers(root, 'musicCardShelfRenderer').firstOrNull;
    if (card == null) return null;

    final title = _runsText(card.getMap('title'))?.trim();
    if (title == null || title.isEmpty) return null;
    final subtitle = _runsText(card.getMap('subtitle'))?.trim();
    final thumbnail = _thumbnailUrl(card, 'thumbnail');

    final titleRun = card.getMap('title')?.getList('runs')?.firstOrNull;
    final endpoint = titleRun is Map
        ? titleRun.cast<String, dynamic>().getMap('navigationEndpoint')
        : null;
    final videoId = endpoint
        ?.getMap('watchEndpoint')
        ?.getValue<String>('videoId');
    final browseId = endpoint
        ?.getMap('browseEndpoint')
        ?.getValue<String>('browseId');

    final MusicTopResultKind kind;
    final String id;
    if (videoId != null) {
      kind = MusicTopResultKind.song;
      id = videoId;
    } else if (browseId != null && browseId.startsWith('UC')) {
      kind = MusicTopResultKind.artist;
      id = browseId;
    } else if (browseId != null && browseId.startsWith('MPRE')) {
      kind = MusicTopResultKind.album;
      id = browseId;
    } else if (browseId != null && browseId.startsWith('VL')) {
      kind = MusicTopResultKind.playlist;
      id = browseId.substring(2);
    } else {
      return null;
    }
    return MusicTopResult(
      kind: kind,
      id: id,
      title: title,
      subtitle: subtitle,
      thumbnailUrl: thumbnail,
    );
  }

  /// Searches YouTube Music albums for [query] (Muzika).
  Future<List<MusicCollection>> searchAlbums(String query) =>
      _searchCollections(query, _albumsSearchParams, albums: true);

  /// Searches YouTube Music community playlists for [query] (Muzika).
  Future<List<MusicCollection>> searchPlaylists(String query) =>
      _searchCollections(query, _playlistsSearchParams, albums: false);

  Future<List<MusicCollection>> _searchCollections(
    String query,
    String params, {
    required bool albums,
  }) async {
    final normalizedQuery = query.trim();
    if (normalizedQuery.isEmpty) return [];
    final root = await _httpClient.sendPost('search', {
      'context': _remixContext,
      'query': normalizedQuery,
      'params': Uri.decodeComponent(params),
    });

    final results = <MusicCollection>[];
    final seen = <String>{};
    for (final item in _findRenderers(
      root,
      'musicResponsiveListItemRenderer',
    )) {
      final browseId = item
          .getMap('navigationEndpoint')
          ?.getMap('browseEndpoint')
          ?.getValue<String>('browseId');
      if (browseId == null) continue;
      final isAlbum = browseId.startsWith('MPRE');
      final isPlaylist = browseId.startsWith('VL');
      if (albums ? !isAlbum : !isPlaylist) continue;
      final id = isPlaylist ? browseId.substring(2) : browseId;
      if (!seen.add(id)) continue;

      final title = _flexColumnText(item, 0)?.trim();
      if (title == null || title.isEmpty) continue;
      final parts = _splitBullets(_flexColumnText(item, 1));
      String? artist;
      String? year;
      for (final part in parts.skip(1)) {
        if (RegExp(r'^\d{4}$').hasMatch(part)) {
          year = part;
        } else {
          artist ??= part;
        }
      }
      results.add(
        MusicCollection(
          id: id,
          title: title,
          subtitle: parts.join(' • '),
          artist: artist,
          year: year,
          thumbnailUrl: _thumbnailUrl(item, 'thumbnail'),
          isAlbum: isAlbum,
        ),
      );
    }
    return results;
  }

  /// The songs of a YouTube Music playlist ([playlistId] without `VL`), with
  /// catalog metadata (Muzika). Only the first page (about 100 songs).
  Future<List<MusicSong>> getPlaylistSongs(String playlistId) async {
    final root = await _browse('VL$playlistId');
    final songs = <MusicSong>[];
    final seen = <String>{};
    for (final item in _findRenderers(
      root,
      'musicResponsiveListItemRenderer',
    )) {
      final videoId = _trackVideoId(item);
      if (videoId == null || !seen.add(videoId)) continue;
      final title = _flexColumnText(item, 0)?.trim();
      if (title == null || title.isEmpty) continue;

      final artists = <String>[];
      String? artistId;
      String? album;
      String? albumId;
      for (var column = 1; column < 4; column++) {
        for (final run in _flexColumnRuns(item, column)) {
          final text = (run.getValue<String>('text') ?? '').trim();
          final browseId = run
              .getMap('navigationEndpoint')
              ?.getMap('browseEndpoint')
              ?.getValue<String>('browseId');
          if (browseId != null && browseId.startsWith('UC')) {
            artists.add(text);
            artistId ??= browseId;
          } else if (browseId != null && browseId.startsWith('MPRE')) {
            album = text;
            albumId = browseId;
          }
        }
      }
      if (artists.isEmpty) {
        final parts = _splitBullets(_flexColumnText(item, 1));
        if (parts.isNotEmpty) artists.add(parts.first);
      }
      songs.add(
        MusicSong(
          videoId: videoId,
          title: title,
          artist: artists.join(', '),
          artistId: artistId,
          album: album,
          albumId: albumId,
          duration: _parseDuration(_fixedColumnText(item)),
          thumbnailUrl: _thumbnailUrl(item, 'thumbnail'),
        ),
      );
    }
    return songs;
  }

  /// The YouTube Music radio ("Up next" automix) for [videoId]: songs that
  /// sound like it, with catalog metadata. The seed itself is skipped.
  Future<List<MusicSong>> getRadio(String videoId) async {
    final root = await _httpClient.sendPost('next', {
      'context': _remixContext,
      'videoId': videoId,
      'playlistId': 'RDAMVM$videoId',
      'isAudioOnly': true,
    });

    final songs = <MusicSong>[];
    final seen = <String>{videoId};
    for (final item in _findRenderers(root, 'playlistPanelVideoRenderer')) {
      final id = item.getValue<String>('videoId');
      if (id == null || !seen.add(id)) continue;
      final title = _runsText(item.getMap('title'))?.trim();
      if (title == null || title.isEmpty) continue;

      final artists = <String>[];
      String? artistId;
      String? album;
      String? albumId;
      final runs = item.getMap('longBylineText')?.getList('runs');
      for (final run in runs?.whereType<Map>() ?? const <Map>[]) {
        final r = run.cast<String, dynamic>();
        final text = (r.getValue<String>('text') ?? '').trim();
        final browseId = r
            .getMap('navigationEndpoint')
            ?.getMap('browseEndpoint')
            ?.getValue<String>('browseId');
        if (browseId != null && browseId.startsWith('UC')) {
          artists.add(text);
          artistId ??= browseId;
        } else if (browseId != null && browseId.startsWith('MPRE')) {
          album = text;
          albumId = browseId;
        }
      }
      if (artists.isEmpty) {
        final byline = _runsText(item.getMap('shortBylineText'));
        if (byline != null) artists.add(byline.trim());
      }

      final thumbs = item.getMap('thumbnail')?.getList('thumbnails');
      final thumb = (thumbs != null && thumbs.isNotEmpty && thumbs.last is Map)
          ? (thumbs.last as Map).cast<String, dynamic>().getValue<String>('url')
          : null;

      songs.add(
        MusicSong(
          videoId: id,
          title: title,
          artist: artists.join(', '),
          artistId: artistId,
          album: album,
          albumId: albumId,
          duration: _parseDuration(_runsText(item.getMap('lengthText'))),
          thumbnailUrl: thumb,
        ),
      );
    }
    return songs;
  }

  List<_JsonMap> _flexColumnRuns(_JsonMap item, int index) {
    final columns = item.getList('flexColumns');
    if (columns == null || columns.length <= index) return const [];
    final column = columns[index];
    if (column is! Map) return const [];
    final runs = column
        .cast<String, dynamic>()
        .getMap('musicResponsiveListItemFlexColumnRenderer')
        ?.getMap('text')
        ?.getList('runs');
    return runs
            ?.whereType<Map>()
            .map((r) => r.cast<String, dynamic>())
            .toList() ??
        const [];
  }

  /// Splits a `Song • Artist • Album` style subtitle line on its bullet
  /// separators.
  List<String> _splitBullets(String? text) {
    if (text == null) return const [];
    return text
        .split('•')
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .toList();
  }

  /// Compares normalized word sets, allowing word-order and credit changes.
  bool _looselyMatch(String candidate, String expected) {
    final a = _wordsForMatch(candidate);
    final b = _wordsForMatch(expected);
    if (a.isEmpty || b.isEmpty) return true;
    final shorter = a.length <= b.length ? a : b;
    final longer = identical(shorter, a) ? b : a;
    return shorter.every(longer.contains);
  }

  Set<String> _wordsForMatch(String input) =>
      _foldDiacritics(input.toLowerCase())
          // Keep Unicode letters and numbers so non-Latin titles remain
          // matchable.
          .replaceAll(RegExp(r'[^\p{L}\p{N}\s]', unicode: true), ' ')
          .split(RegExp(r'\s+'))
          .where((word) => word.isNotEmpty)
          .toSet();

  /// Folds common Latin accents to improve matching across spellings.
  String _foldDiacritics(String input) {
    final buffer = StringBuffer();
    for (final rune in input.runes) {
      final char = String.fromCharCode(rune);
      buffer.write(_diacriticFold[char] ?? char);
    }
    return buffer.toString();
  }

  static const _diacriticFold = {
    'á': 'a',
    'à': 'a',
    'â': 'a',
    'ã': 'a',
    'ä': 'a',
    'å': 'a',
    'é': 'e',
    'è': 'e',
    'ê': 'e',
    'ë': 'e',
    'í': 'i',
    'ì': 'i',
    'î': 'i',
    'ï': 'i',
    'ó': 'o',
    'ò': 'o',
    'ô': 'o',
    'õ': 'o',
    'ö': 'o',
    'ú': 'u',
    'ù': 'u',
    'û': 'u',
    'ü': 'u',
    'ý': 'y',
    'ÿ': 'y',
    'ç': 'c',
    'ñ': 'n',
  };

  /// Returns a YouTube Music artist page: header details, top songs, the full
  /// discography and the artists it points to.
  ///
  /// [channelId] does not have to be the channel of the artist itself: the
  /// channel that uploads its videos — a label, a VEVO channel — answers with
  /// a partial page of the same artist, whose header still points at the
  /// canonical channel. [MusicArtistProfile.id] holds that one, so a caller
  /// that asked with an uploader can tell and read the real page instead.
  Future<MusicArtistProfile> getArtistProfile(dynamic channelId) async {
    final id = ChannelId.fromString(channelId).value;
    final root = await _browse(id);

    final header =
        _firstRenderer(root, 'musicImmersiveHeaderRenderer') ??
        _firstRenderer(root, 'musicVisualHeaderRenderer');
    final name = (_runsText(header?.getMap('title')) ?? '').trim();
    final canonicalId = _headerChannelId(header) ?? id;

    return MusicArtistProfile(
      id: canonicalId,
      name: name,
      thumbnailUrl: _thumbnailUrl(header, 'thumbnail'),
      description: _runsText(header?.getMap('description')),
      monthlyListeners: _runsText(header?.getMap('monthlyListenerCount')),
      topSongs: _parseTopSongs(root, channelId: canonicalId, author: name),
      releases: await _collectDiscography(root),
      relatedArtists: _collectRelatedArtists(
        root,
      ).where((artist) => artist.id != canonicalId).toList(),
    );
  }

  /// The artist behind [channelId] (photo, name) and the artists of its
  /// "Fans might also like" shelf, from one browse: unlike
  /// [getArtistProfile] the page's discography is not read.
  Future<({MusicArtist artist, List<MusicArtist> related})> getArtistSummary(
    dynamic channelId,
  ) async {
    final id = ChannelId.fromString(channelId).value;
    final root = await _browse(id);
    final header =
        _firstRenderer(root, 'musicImmersiveHeaderRenderer') ??
        _firstRenderer(root, 'musicVisualHeaderRenderer');
    final canonicalId = _headerChannelId(header) ?? id;
    return (
      artist: MusicArtist(
        id: canonicalId,
        name: (_runsText(header?.getMap('title')) ?? '').trim(),
        thumbnailUrl: _thumbnailUrl(header, 'thumbnail'),
      ),
      related: _collectRelatedArtists(
        root,
      ).where((a) => a.id != canonicalId).toList(),
    );
  }

  /// Channel the subscribe button of a page header subscribes to, which is the
  /// artist itself even on the page of a channel that only uploads for it.
  String? _headerChannelId(_JsonMap? header) {
    final channelId = header
        ?.getMap('subscriptionButton')
        ?.getMap('subscribeButtonRenderer')
        ?.getValue<String>('channelId');
    return (channelId != null && channelId.startsWith('UC')) ? channelId : null;
  }

  /// Returns a release with its tracks, credited to the artist its own header
  /// names.
  Future<MusicReleasePage> getAlbum(String albumBrowseId) async {
    final root = await _browse(albumBrowseId);
    final header =
        _firstRenderer(root, 'musicResponsiveHeaderRenderer') ??
        _firstRenderer(root, 'musicDetailHeaderRenderer');
    final albumArtist = _runsText(header?.getMap('straplineTextOne'))?.trim();
    final albumArtistId = _straplineChannelId(header);

    final videos = <Video>[];
    final seen = <String>{};
    for (final item in _findRenderers(
      root,
      'musicResponsiveListItemRenderer',
    )) {
      final videoId = _trackVideoId(item);
      if (videoId == null || !seen.add(videoId)) continue;

      final title = _flexColumnText(item, 0);
      if (title == null || title.isEmpty) continue;

      videos.add(
        _trackVideo(item, videoId, title, albumArtist ?? '', albumArtistId),
      );
    }

    return MusicReleasePage(
      id: albumBrowseId,
      title: _runsText(header?.getMap('title'))?.trim() ?? '',
      artist: albumArtist,
      artistId: albumArtistId,
      thumbnailUrl: _thumbnailUrl(header, 'thumbnail'),
      year: _releaseYearOf(_subtitleParts(header)),
      tracks: videos,
    );
  }

  /// Channel id behind the artist name of a release header, when it links to
  /// the page of that artist.
  String? _straplineChannelId(_JsonMap? header) {
    final runs = header?.getMap('straplineTextOne')?.getList('runs');
    for (final run in runs?.whereType<Map>() ?? const <Map>[]) {
      final browseId = run
          .cast<String, dynamic>()
          .getMap('navigationEndpoint')
          ?.getMap('browseEndpoint')
          ?.getValue<String>('browseId');
      if (browseId != null && browseId.startsWith('UC')) return browseId;
    }
    return null;
  }

  Future<_JsonMap> _browse(String browseId, {String? params}) {
    return _httpClient.sendPost('browse', {
      'context': _remixContext,
      'browseId': browseId,
      if (params != null) 'params': params,
    });
  }

  /// Every release of the artist page: the grid behind each shelf's "More"
  /// button, plus the entries only shown inline.
  Future<List<MusicAlbum>> _collectDiscography(_JsonMap root) async {
    final grids = await Future.wait([
      for (final more in _collectMoreReleaseBrowses(root))
        _browse(
          more.$1,
          params: more.$2,
        ).catchError((_) => <String, dynamic>{}),
    ]);

    // Grids first: they label the release type, the inline previews of an
    // album shelf do not, and [_collectReleases] keeps the first entry seen.
    final releases = <String, MusicAlbum>{};
    for (final grid in grids) {
      _collectReleases(grid, releases);
    }
    _collectReleases(root, releases);
    return releases.values.toList();
  }

  List<MusicTopSong> _parseTopSongs(
    _JsonMap root, {
    required String channelId,
    required String author,
  }) {
    final shelf = _firstRenderer(root, 'musicShelfRenderer');
    if (shelf == null) return const [];

    final songs = <MusicTopSong>[];
    final seen = <String>{};
    for (final item in _findRenderers(
      shelf,
      'musicResponsiveListItemRenderer',
    )) {
      final videoId = _trackVideoId(item);
      if (videoId == null || !seen.add(videoId)) continue;

      final title = _flexColumnText(item, 0);
      if (title == null || title.isEmpty) continue;

      final trackAuthor = _flexColumnText(item, 1);
      songs.add(
        MusicTopSong(
          _trackVideo(
            item,
            videoId,
            title,
            (trackAuthor == null || trackAuthor.isEmpty) ? author : trackAuthor,
            channelId,
          ),
          _playCountText(item),
        ),
      );
    }

    return songs;
  }

  /// One track row of a shelf or of a release, as a [Video]. Only the fields
  /// YouTube Music lists in a row are known, the rest is left empty.
  Video _trackVideo(
    _JsonMap item,
    String videoId,
    String title,
    String author,
    String? channelId,
  ) {
    return Video(
      VideoId(videoId),
      title,
      author,
      ChannelId.fromString(channelId ?? _unknownChannelId),
      null,
      null,
      null,
      '',
      _parseDuration(_fixedColumnText(item)),
      ThumbnailSet(videoId),
      null,
      const Engagement(0, null, null),
      false,
    );
  }

  /// The play count column of a top song, when the shelf lists one. Its
  /// position varies, so every column after the title is probed.
  String? _playCountText(_JsonMap item) {
    for (var index = 1; index < 4; index++) {
      final text = _flexColumnText(item, index);
      if (text != null && _playCountPattern.hasMatch(text)) return text;
    }
    return null;
  }

  void _collectReleases(dynamic root, Map<String, MusicAlbum> into) {
    for (final item in _findRenderers(root, 'musicTwoRowItemRenderer')) {
      final browseId = item
          .getMap('navigationEndpoint')
          ?.getMap('browseEndpoint')
          ?.getValue<String>('browseId');
      if (browseId == null || !browseId.startsWith('MPRE')) continue;

      final title = _runsText(item.getMap('title'));
      // `Album • 2019`, `Single • 2021`, or just the year when the entry is an
      // inline preview.
      final subtitle = _subtitleParts(item);
      into.putIfAbsent(
        browseId,
        () => MusicAlbum(
          browseId,
          title?.trim() ?? '',
          thumbnailUrl: _thumbnailUrl(item, 'thumbnailRenderer'),
          type: _releaseTypeOf(subtitle),
          year: _releaseYearOf(subtitle),
        ),
      );
    }
  }

  /// Collects the artists of the "Fans might also like" shelf. They sit in the
  /// same rows as the releases, told apart by their channel browse id.
  List<MusicArtist> _collectRelatedArtists(dynamic root) {
    final artists = <String, MusicArtist>{};
    for (final item in _findRenderers(root, 'musicTwoRowItemRenderer')) {
      final endpoint = item
          .getMap('navigationEndpoint')
          ?.getMap('browseEndpoint');
      final browseId = endpoint?.getValue<String>('browseId');
      if (browseId == null || !browseId.startsWith('UC')) continue;

      final pageType = endpoint
          ?.getMap('browseEndpointContextSupportedConfigs')
          ?.getMap('browseEndpointContextMusicConfig')
          ?.getValue<String>('pageType');
      if (pageType != _artistPageType) continue;

      final name = _runsText(item.getMap('title'))?.trim();
      if (name == null || name.isEmpty) continue;

      artists.putIfAbsent(
        browseId,
        () => MusicArtist(
          id: browseId,
          name: name,
          thumbnailUrl: _thumbnailUrl(item, 'thumbnailRenderer'),
        ),
      );
    }
    return artists.values.toList();
  }

  List<(String, String?)> _collectMoreReleaseBrowses(_JsonMap root) {
    final result = <(String, String?)>[];
    for (final header in _findRenderers(
      root,
      'musicCarouselShelfBasicHeaderRenderer',
    )) {
      final endpoint = header
          .getMap('moreContentButton')
          ?.getMap('buttonRenderer')
          ?.getMap('navigationEndpoint')
          ?.getMap('browseEndpoint');
      final browseId = endpoint?.getValue<String>('browseId');
      if (browseId == null || !browseId.startsWith('MPAD')) continue;
      result.add((browseId, endpoint?.getValue<String>('params')));
    }
    return result;
  }

  List<String> _subtitleParts(_JsonMap? item) {
    final subtitle = _runsText(item?.getMap('subtitle'));
    if (subtitle == null) return const [];
    return subtitle
        .split('•')
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .toList();
  }

  MusicReleaseType _releaseTypeOf(List<String> subtitleParts) {
    for (final part in subtitleParts) {
      switch (part.toLowerCase()) {
        case 'album':
          return MusicReleaseType.album;
        case 'single':
          return MusicReleaseType.single;
        case 'ep':
          return MusicReleaseType.ep;
      }
    }
    return MusicReleaseType.other;
  }

  String? _releaseYearOf(List<String> subtitleParts) {
    for (final part in subtitleParts) {
      if (RegExp(r'^(19|20)\d{2}$').hasMatch(part)) return part;
    }
    return null;
  }

  String? _trackVideoId(_JsonMap item) {
    return item
        .getMap('overlay')
        ?.getMap('musicItemThumbnailOverlayRenderer')
        ?.getMap('content')
        ?.getMap('musicPlayButtonRenderer')
        ?.getMap('playNavigationEndpoint')
        ?.getMap('watchEndpoint')
        ?.getValue<String>('videoId');
  }

  String? _flexColumnText(_JsonMap item, int index) {
    final columns = item.getList('flexColumns');
    if (columns == null || columns.length <= index) return null;
    final column = columns[index];
    if (column is! Map) return null;
    return _runsText(
      column
          .cast<String, dynamic>()
          .getMap('musicResponsiveListItemFlexColumnRenderer')
          ?.getMap('text'),
    );
  }

  String? _runsText(_JsonMap? node) {
    final runs = node?.getList('runs')?.whereType<Map>().parseRuns();
    return (runs == null || runs.isEmpty) ? null : runs;
  }

  String? _fixedColumnText(_JsonMap item) {
    final columns = item.getList('fixedColumns');
    if (columns == null || columns.isEmpty) return null;
    final lastColumn = columns.last;
    if (lastColumn is! Map) return null;
    return lastColumn
        .cast<String, dynamic>()
        .getMap('musicResponsiveListItemFixedColumnRenderer')
        ?.getMap('text')
        ?.getList('runs')
        ?.whereType<Map>()
        .parseRuns();
  }

  /// The largest artwork URL under [key], which holds a thumbnail renderer:
  /// `thumbnail` on headers and list items, `thumbnailRenderer` on shelf rows.
  String? _thumbnailUrl(_JsonMap? node, String key) {
    final thumbnails = node
        ?.getMap(key)
        ?.getMap('musicThumbnailRenderer')
        ?.getMap('thumbnail')
        ?.getList('thumbnails');
    if (thumbnails == null || thumbnails.isEmpty) return null;
    final thumbnail = thumbnails.last;
    if (thumbnail is! Map) return null;
    return thumbnail.cast<String, dynamic>().getValue<String>('url');
  }

  Duration? _parseDuration(String? value) {
    if (value == null) return null;
    final parts = value.trim().split(':');
    if (parts.isEmpty || parts.length > 3) return null;

    var seconds = 0;
    for (final part in parts) {
      final n = int.tryParse(part.trim());
      if (n == null) return null;
      seconds = seconds * 60 + n;
    }
    return Duration(seconds: seconds);
  }

  _JsonMap? _firstRenderer(dynamic node, String rendererKey) {
    for (final renderer in _findRenderers(node, rendererKey)) {
      return renderer;
    }
    return null;
  }

  Iterable<_JsonMap> _findRenderers(dynamic node, String rendererKey) sync* {
    if (node is Map) {
      final match = node[rendererKey];
      if (match is Map) yield match.cast<String, dynamic>();
      for (final value in node.values) {
        yield* _findRenderers(value, rendererKey);
      }
    } else if (node is List) {
      for (final value in node) {
        yield* _findRenderers(value, rendererKey);
      }
    }
  }
}

extension _MapReader on Map<String, dynamic> {
  Map<String, dynamic>? getMap(String key) {
    final value = this[key];
    return value is Map ? value.cast<String, dynamic>() : null;
  }

  List<dynamic>? getList(String key) {
    final value = this[key];
    return value is List ? value : null;
  }

  T? getValue<T>(String key) {
    final value = this[key];
    return value is T ? value : null;
  }
}

extension _RunsParser on Iterable<Map<dynamic, dynamic>> {
  String parseRuns() {
    return map((run) => run['text']?.toString() ?? '').join();
  }
}
