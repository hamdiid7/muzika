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

import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:muzika/extensions/l10n.dart';
import 'package:muzika/main.dart';
import 'package:muzika/screens/playlist_page.dart';
import 'package:muzika/services/artist_service.dart';
import 'package:muzika/services/common_services.dart';
import 'package:muzika/services/deezer_catalog.dart';
import 'package:muzika/services/itunes_catalog.dart';
import 'package:muzika/services/playlists_manager.dart';
import 'package:muzika/services/router_service.dart';
import 'package:muzika/services/settings_manager.dart';
import 'package:muzika/services/smart_shuffle.dart';
import 'package:muzika/theme/muzika_tokens.dart';
import 'package:muzika/utilities/app_utils.dart';
import 'package:muzika/utilities/async_loader.dart';
import 'package:muzika/utilities/flutter_toast.dart';
import 'package:muzika/widgets/clips_shelf.dart';
import 'package:muzika/widgets/muzika_back_page.dart';
import 'package:muzika/widgets/muzika_loading.dart';
import 'package:muzika/widgets/muzika_mosaic.dart';
import 'package:muzika/widgets/muzika_section.dart';
import 'package:muzika/widgets/muzika_song_row.dart';
import 'package:muzika/widgets/playlist_page/like_button.dart';
import 'package:muzika/widgets/shelf_arrows.dart';
import 'package:muzika/widgets/muzika_share.dart' show showArtistShare;
import 'package:muzika/widgets/song_rows_shelf.dart';
import 'package:muzika/widgets/story_row.dart';

/// The page an artist opens on: who the artist is, its top songs, its releases
/// and related artists.
class ArtistPage extends StatefulWidget {
  const ArtistPage({super.key, required this.artistId, this.artistData});

  final String artistId;
  final Map? artistData;

  @override
  State<ArtistPage> createState() => _ArtistPageState();
}

class _ArtistPageState extends State<ArtistPage> {
  /// Read the first time the page is shown online, and left alone offline,
  /// where the artist is its downloaded songs and there is nothing to read.
  Future<Map<String, dynamic>?>? _artistFuture;

  Map<String, dynamic>? _artist;
  Map<String, dynamic>? _catalog;
  Future<Map?>? _catalogFuture;
  List<Map<String, dynamic>> _topSongs = const [];
  List<String?> _topSongPlayCounts = const [];
  List<Map<String, dynamic>> _albums = const [];
  List<Map<String, dynamic>> _singles = const [];
  List<Map<String, dynamic>> _relatedArtists = const [];

  /// The artist's clips (Apple's music videos), read after the page.
  List<AppleClip> _clips = const [];
  String? _clipsFor;

  void _loadClips() {
    final name = _artistTitle;
    if (name.isEmpty || name == _clipsFor) return;
    _clipsFor = name;
    unawaited(
      appleArtistClips(name)
          .then((clips) {
            if (mounted && name == _artistTitle) setState(() => _clips = clips);
          })
          .catchError((_) {}),
    );
  }

  /// Whether the songs of the artist are being read for the play buttons.
  final _isLoadingCatalog = ValueNotifier<bool>(false);

  /// Cache for the resolved artist ID to avoid repeated lookups.
  String? _cachedResolvedArtistId;

  /// Cache for the artist title to avoid repeated lookups.
  String? _cachedArtistTitle;

  int _artistLoadGeneration = 0;

  /// Refresh artist data, preserving current state on failure.
  Future<void> _refresh() async {
    final generation = ++_artistLoadGeneration;
    final loaded = _artistFuture;
    _catalogFuture = null;
    final refreshed = _loadArtist(forceRefresh: true, refreshCatalog: true);
    // Block syntax: setState doesn't accept Future-returning callbacks
    setState(() {
      _artistFuture = refreshed;
    });

    Map<String, dynamic>? refreshedArtist;
    try {
      refreshedArtist = await refreshed;
    } catch (_) {
      refreshedArtist = null;
    }
    if (!mounted ||
        generation != _artistLoadGeneration ||
        refreshedArtist != null) {
      return;
    }
    setState(() {
      _artistFuture = loaded;
    });
    showToast(context, context.l10n!.error);
  }

  @override
  void didUpdateWidget(covariant ArtistPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Artist identity is determined by ID only (data seed changes on rebuild)
    if (oldWidget.artistId != widget.artistId) {
      _artistLoadGeneration++;
      _artistFuture = null;
      _catalog = null;
      _catalogFuture = null;
      _cachedResolvedArtistId = null;
      _cachedArtistTitle = null;
    }
  }

  @override
  void dispose() {
    _isLoadingCatalog.dispose();
    super.dispose();
  }

  String get _resolvedArtistId => _cachedResolvedArtistId ??=
      _artist?['ytid']?.toString() ?? widget.artistId;

  String get _artistTitle => _cachedArtistTitle ??=
      _artist?['title']?.toString() ??
      widget.artistData?['title']?.toString() ??
      '';

  Future<Map<String, dynamic>?> _loadArtist({
    bool forceRefresh = false,
    bool refreshCatalog = false,
  }) async {
    final generation = _artistLoadGeneration;
    final artistData = widget.artistData;
    final artist = await getArtistProfile(
      widget.artistId,
      forceRefresh: forceRefresh,
      cacheResult: !refreshCatalog,
      preferredName: artistData?['title']?.toString(),
      preferredImage: artistData?['image']?.toString(),
      sourceSongId: artistData?['sourceSongId']?.toString(),
      sourceVideoAuthor: artistData?['videoAuthor']?.toString(),
      preferredVerified: artistData?['isVerifiedArtist'] == true,
    );
    if (artist == null || !mounted || generation != _artistLoadGeneration) {
      return null;
    }

    Map<String, dynamic>? catalog;
    if (refreshCatalog) {
      catalog = await getArtistCatalogFromProfile(artist, forceRebuild: true);
      if (catalog == null ||
          catalog['catalogStatus'] == 'failed' ||
          !mounted ||
          generation != _artistLoadGeneration) {
        return null;
      }
      cacheArtistProfileInBackground(artist);
    }

    _artist = artist;
    if (refreshCatalog) {
      _catalog = catalog;
      _catalogFuture = null;
    }
    // Clear caches when artist data updates
    _cachedResolvedArtistId = null;
    _cachedArtistTitle = null;
    // Each entry of the shelf is a song and its play count, side by side.
    final topSongs = asMapList(artist['topSongs'])
        .where((entry) => entry['song'] is Map)
        .toList();
    _topSongs = [
      for (final entry in topSongs)
        Map<String, dynamic>.from(entry['song'] as Map),
    ];
    // Deezer's popularity where there's no play count.
    _topSongPlayCounts = [
      for (final entry in topSongs)
        entry['playCount']?.toString() ??
            deezerPopularityLabel(entry['song'] as Map),
    ];
    _relatedArtists = asMapList(artist['relatedArtists']);
    // Split the discography once per load: the two shelves are rebuilt on every
    // frame and would otherwise filter it again each time.
    final releases = asMapList(artist['releases']);
    _albums = releases.where((r) => !isSingleOrEpRelease(r)).toList();
    _singles = releases.where(isSingleOrEpRelease).toList();
    _loadClips();
    return artist;
  }

  @override
  Widget build(BuildContext context) {
    // Offline: show downloaded songs only; online: fetch full profile
    if (offlineMode.value) return _buildAllSongsPage();

    return AsyncLoader<Map<String, dynamic>?>(
      future: _artistFuture ??= _loadArtist(),
      loadingWidget: const MuzikaBackPage(child: MuzikaLoading()),
      emptyWidget: _buildNotFoundPage(),
      builder: (context, _) => MuzikaBackPage(
        center: _buildCollapsedTitle(),
        actions: [
          IconButton(
            tooltip: context.l10n!.search,
            icon: const Icon(FluentIcons.search_24_regular),
            // Search inside this artist's songs.
            onPressed: () => context.push(
              '${NavigationManager.artistSongsPath(context, _resolvedArtistId)}'
              '?search=1',
              extra: artistPlaylistData(_artist!),
            ),
          ),
        ],
        // Pull down to refresh, where the refresh button used to be.
        child: Column(
          children: [
            // A hairline under the bar once the header has gone into it.
            ValueListenableBuilder<bool>(
              valueListenable: _collapsed,
              builder: (context, collapsed, _) => Divider(
                height: 1,
                thickness: 0.5,
                color: collapsed
                    ? Theme.of(context).colorScheme.outlineVariant
                    : Colors.transparent,
              ),
            ),
            Expanded(
              child: RefreshIndicator(
                onRefresh: _refresh,
                child: NotificationListener<ScrollNotification>(
                  onNotification: (n) {
                    if (n.depth == 0) _collapsed.value = n.metrics.pixels > 150;
                    return false;
                  },
                  child: ListView(
                    padding: const EdgeInsets.only(bottom: 32),
                    children: [
                      _buildHeaderSection(),
                      // Everything by default; a chip shows one section in full.
                      _buildSectionChips(),
                      ...switch (_section) {
                        'songs' => [
                          _buildTopSongsSection(),
                          _buildAllSongsButton(),
                        ],
                        'albums' => [_buildReleaseGrid(_albums)],
                        'singles' => [_buildReleaseGrid(_singles)],
                        'related' => [
                          for (final artist in _relatedArtists.take(20))
                            MuzikaEntityRow.artist(
                              artist: artist,
                              onTap: () => _openArtist(artist),
                            ),
                        ],
                        _ => _buildAll(),
                      },
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The artist as its song list, which offline is the whole page.
  Widget _buildAllSongsPage() {
    return PlaylistPage(
      playlistId: widget.artistId,
      playlistData: artistPlaylistData({
        'ytid': widget.artistId,
        'title': _artistTitle,
        'image': _artist?['image'] ?? widget.artistData?['image'],
      }),
      cubeIcon: FluentIcons.person_24_filled,
      isArtist: true,
    );
  }

  Widget _buildNotFoundPage() {
    final scheme = Theme.of(context).colorScheme;
    return MuzikaBackPage(
      child: Center(
        child: Text(
          context.l10n!.artistNotFound,
          style: muzikaBody(15, color: scheme.onSurfaceVariant),
        ),
      ),
    );
  }

  /// Scrolled past the header: its photo and name shown in the bar.
  final _collapsed = ValueNotifier<bool>(false);

  Widget _buildCollapsedTitle() {
    final scheme = Theme.of(context).colorScheme;
    final image =
        _artist?['image']?.toString() ??
        widget.artistData?['image']?.toString();
    return ValueListenableBuilder<bool>(
      valueListenable: _collapsed,
      builder: (context, collapsed, _) => AnimatedOpacity(
        duration: const Duration(milliseconds: 180),
        opacity: collapsed ? 1 : 0,
        child: IgnorePointer(
          ignoring: !collapsed,
          child: Row(
            children: [
              // The header's own photo (Deezer's when the page has none),
              // small, and ringed when they have a story.
              ArtistStoryAvatar(
                key: ValueKey('bar $_artistTitle'),
                name: _artistTitle,
                image: image,
                size: 30,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  _artistTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: muzikaBody(16, weight: 700, color: scheme.onSurface),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeaderSection() {
    final scheme = Theme.of(context).colorScheme;
    final image =
        _artist!['image']?.toString() ??
        widget.artistData?['image']?.toString();
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
      child: Row(
        children: [
          // Round, as Instagram's; ringed when the artist has a story.
          // As tall as the name, fans and buttons beside it, so their top
          // and bottom line up with its own.
          ArtistStoryAvatar(name: _artistTitle, image: image, size: 92),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _artistTitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: muzikaHeading(26, color: scheme.onSurface),
                ),
                const SizedBox(height: 8),
                _buildPlaybackButtons(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Play (all the artist's songs, the same queue as "All songs"), then
  /// shuffle, like and share as plain icons.
  Widget _buildPlaybackButtons() {
    final scheme = Theme.of(context).colorScheme;
    return ValueListenableBuilder<bool>(
      valueListenable: _isLoadingCatalog,
      builder: (_, isLoading, _) => IconButtonTheme(
        data: IconButtonThemeData(
          style: IconButton.styleFrom(
            backgroundColor: Colors.transparent,
            foregroundColor: scheme.onSurface,
            iconSize: 24,
          ),
        ),
        child: Row(
          spacing: 4,
          children: [
            MuzikaRoundButton(
              icon: isLoading
                  ? FluentIcons.hourglass_24_regular
                  : FluentIcons.play_24_filled,
              filled: true,
              size: 44,
              tooltip: context.l10n!.play,
              onPressed: isLoading ? () {} : _playArtist,
            ),
            const SizedBox(width: 4),
            IconButton(
              tooltip: context.l10n!.shuffle,
              icon: const Icon(FluentIcons.arrow_shuffle_24_regular),
              onPressed: isLoading ? null : () => _playArtist(shuffle: true),
            ),
            PlaylistLikeButton(
              playlistId: _resolvedArtistId,
              playlistData: () => artistPlaylistData(_artist!, songs: const []),
            ),
            // The artist as a card to send: photo, name and fans.
            IconButton(
              tooltip: 'Share',
              icon: const Icon(FluentIcons.share_24_regular),
              onPressed: () => showArtistShare(
                context,
                name: _artistTitle,
                image:
                    _artist?['image']?.toString() ??
                    widget.artistData?['image']?.toString(),
                fans: _artist?['monthlyListeners']?.toString(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Songs · Albums · Singles · Related artists; null shows them all.
  String? _section;

  void _pick(String? key) => setState(() => _section = key);

  /// The chips of the Home page: grey, the picked one white with a small x
  /// (tap it again for everything).
  Widget _buildSectionChips() {
    final scheme = Theme.of(context).colorScheme;
    final sections = [
      if (_topSongs.isNotEmpty) ('songs', context.l10n!.songs),
      if (_albums.isNotEmpty) ('albums', context.l10n!.albums),
      if (_singles.isNotEmpty) ('singles', 'Singles'),
      if (_relatedArtists.isNotEmpty) ('related', 'Fans also like'),
    ];
    if (sections.isEmpty) return const SizedBox.shrink();
    if (!sections.any((s) => s.$1 == _section)) _section = null;
    return SizedBox(
      height: 64,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
        itemCount: sections.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final (key, label) = sections[i];
          final active = key == _section;
          return AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            decoration: BoxDecoration(
              color: active ? scheme.onSurface : scheme.surfaceContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => _pick(active ? null : key),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        label,
                        style: muzikaBody(
                          14,
                          weight: 600,
                          color: active ? scheme.surface : scheme.onSurface,
                        ),
                      ),
                      if (active) ...[
                        const SizedBox(width: 6),
                        Icon(
                          FluentIcons.dismiss_16_regular,
                          size: 14,
                          color: scheme.surface,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// Everything at once: a few top songs, the radio, then albums, singles
  /// and related artists as rows that scroll sideways. A section's title
  /// opens it in full.
  List<Widget> _buildAll() {
    final scheme = Theme.of(context).colorScheme;
    Widget heading(String title, String key) => InkWell(
      onTap: () => _pick(key),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 16, 10),
        child: Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: muzikaHeading(20, color: scheme.onSurface),
              ),
            ),
            Icon(
              FluentIcons.chevron_right_20_regular,
              color: scheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );

    Widget shelf(
      List<Map<String, dynamic>> items, {
      bool round = false,
    }) => SizedBox(
      height: round ? 168 : 196,
      child: ShelfArrows(
        pictureHeight: round ? 128 : 140,
        builder: (controller) => ListView.separated(
          controller: controller,
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 20),
          itemCount: items.length,
          separatorBuilder: (_, _) => const SizedBox(width: 14),
          itemBuilder: (context, i) {
            final item = items[i];
            return GestureDetector(
              onTap: () => round ? _openArtist(item) : _openRelease(item),
              child: SizedBox(
                width: 140,
                child: Column(
                  crossAxisAlignment: round
                      ? CrossAxisAlignment.center
                      : CrossAxisAlignment.start,
                  children: [
                    if (round)
                      ClipOval(
                        child: MuzikaCover(song: item, size: 128, radius: 0),
                      )
                    else
                      MuzikaCover(
                        song: item,
                        size: 140,
                        radius: 10,
                        highRes: true,
                      ),
                    const SizedBox(height: 8),
                    Text(
                      item['title']?.toString() ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: round ? TextAlign.center : TextAlign.start,
                      style: muzikaBody(
                        14,
                        weight: 600,
                        color: scheme.onSurface,
                      ),
                    ),
                    if (!round)
                      Text(
                        _releaseSubtitle(item),
                        maxLines: 1,
                        style: muzikaBody(12, color: scheme.onSurfaceVariant),
                      ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );

    final top = _topSongs.take(10).toList();
    return [
      if (top.isNotEmpty) ...[
        heading(context.l10n!.songs, 'songs'),
        // Two rows sliding sideways, as Home's New releases: under each
        // title its plays (or popularity), else its album.
        SongRowsShelf(
          songs: top,
          subtitle: (song, i) =>
              _playsLabel(_topSongPlayCounts.elementAtOrNull(i)) ??
              song['album']?.toString() ??
              _artistTitle,
        ),
        _buildAllSongsButton(),
      ],
      // A clip opens the Clips tab on it.
      ClipsShelf(clips: _clips),
      if (_albums.isNotEmpty) ...[
        heading(context.l10n!.albums, 'albums'),
        shelf(_albums),
      ],
      if (_singles.isNotEmpty) ...[
        heading('Singles', 'singles'),
        shelf(_singles),
      ],
      if (_relatedArtists.isNotEmpty) ...[
        heading('Fans also like', 'related'),
        _buildFansAlsoLike(),
      ],
      if (_topSongs.isNotEmpty) ..._buildRadio(),
    ];
  }

  /// Artists like this one, as round photos: ringed when they have a
  /// story (a tap on the photo plays it), the name opens their page.
  Widget _buildFansAlsoLike() {
    final scheme = Theme.of(context).colorScheme;
    final artists = _relatedArtists.take(12).toList();
    return SizedBox(
      height: 140,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        itemCount: artists.length,
        separatorBuilder: (_, _) => const SizedBox(width: 14),
        itemBuilder: (context, i) {
          final artist = artists[i];
          final name = '${artist['title'] ?? ''}';
          return SizedBox(
            width: 96,
            child: Column(
              children: [
                ArtistStoryAvatar(
                  key: ValueKey('fans $name'),
                  name: name,
                  image: (artist['image'] ?? artist['lowResImage'])?.toString(),
                  onTap: () => _openArtist(artist),
                ),
                const SizedBox(height: 8),
                GestureDetector(
                  onTap: () => _openArtist(artist),
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: muzikaBody(13, weight: 600, color: scheme.onSurface),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// The artist's radio at the bottom, as a playlist cover like Home's: a
  /// tap opens it as a playlist (their songs and songs like them), the play
  /// button starts it with smart shuffle.
  List<Widget> _buildRadio() {
    final scheme = Theme.of(context).colorScheme;
    const side = 150.0;
    final covers = <String>[
      for (final s in _topSongs)
        if ((s['lowResImage'] ?? s['image'])?.toString() case final String c
            when c.startsWith('http'))
          c,
    ];
    final names = [
      for (final a in _relatedArtists.take(2)) '${a['title'] ?? ''}',
    ].where((n) => n.isNotEmpty).toList();
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 10),
        child: Text('Radio', style: muzikaHeading(20, color: scheme.onSurface)),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: SizedBox(
          width: side,
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: _openRadio,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Stack(
                  children: [
                    MuzikaMosaic(
                      images: covers.toSet().take(4).toList(),
                      size: side,
                      radius: 12,
                    ),
                    Positioned(
                      right: 8,
                      bottom: 8,
                      child: Material(
                        color: scheme.surface,
                        shape: const CircleBorder(),
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: _playRadio,
                          child: SizedBox(
                            width: 36,
                            height: 36,
                            child: Icon(
                              FluentIcons.play_20_filled,
                              size: 18,
                              color: scheme.onSurface,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  '$_artistTitle Radio',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: muzikaBody(14, weight: 700, color: scheme.onSurface),
                ),
                Text(
                  names.isEmpty
                      ? 'Their songs and songs like them'
                      : 'With ${names.join(', ')} and more',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: muzikaBody(12, color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ),
      ),
    ];
  }

  /// The radio's songs, read once per page: the artist's top songs and the
  /// radios of a few of them (related artists' songs among them).
  Future<List<Map>>? _radio;

  Future<List<Map>> _radioSongs() => _radio ??= () async {
    final seeds = _topSongs.take(3).toList();
    final lists = await Future.wait([
      for (final seed in seeds)
        getRelatedSongs(
          '${seed['ytid']}',
          seed: seed,
        ).catchError((_) => <Map>[]),
    ]);
    final ids = <String>{};
    final songs = <Map>[
      for (final s in [..._topSongs, for (final l in lists) ...l])
        if (ids.add('${s['ytid']}')) s,
    ];
    if (songs.length <= _topSongs.length) _radio = null;
    return songs;
  }();

  Map _radioPlaylist(List<Map> songs) => {
    'ytid': 'radio_$_resolvedArtistId',
    'title': '$_artistTitle Radio',
    'image': _artist?['image'],
    'list': songs,
  };

  Future<void> _openRadio() async {
    final songs = await _radioSongs();
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PlaylistPage(playlistData: _radioPlaylist(songs)),
      ),
    );
  }

  Future<void> _playRadio() async {
    if (_topSongs.isEmpty) return;
    audioHandler.silenceForSwitch();
    showToast(context, 'Starting $_artistTitle Radio…');
    final songs = await _radioSongs();
    if (!mounted || songs.isEmpty) {
      audioHandler.endPendingSwitch();
      return;
    }
    await audioHandler.addPlaylistToQueue(songs, replace: true, shuffle: true);
    await startSmartShuffle();
  }

  /// Albums or singles as a two-column grid.
  Widget _buildReleaseGrid(List<Map<String, dynamic>> releases) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
      child: LayoutBuilder(
        builder: (context, box) {
          final side = (box.maxWidth - 14) / 2;
          return Wrap(
            spacing: 14,
            runSpacing: 16,
            children: [
              for (final release in releases)
                GestureDetector(
                  onTap: () => _openRelease(release),
                  child: SizedBox(
                    width: side,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        MuzikaCover(
                          song: release,
                          size: side,
                          radius: 10,
                          highRes: true,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          release['title']?.toString() ?? '',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: muzikaBody(
                            14,
                            weight: 600,
                            color: scheme.onSurface,
                          ),
                        ),
                        Text(
                          _releaseSubtitle(release),
                          maxLines: 1,
                          style: muzikaBody(12, color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildTopSongsSection() {
    final queue = List<Map>.from(_topSongs);
    return Column(
      children: [
        for (final (index, song) in _topSongs.indexed)
          MuzikaSongRow(
            key: listItemKey('artist_top_song', index, song),
            song: song,
            queue: queue,
            index: index,
            subtitle:
                _playsLabel(_topSongPlayCounts[index]) ??
                song['album']?.toString() ??
                _artistTitle,
          ),
      ],
    );
  }

  String? _playsLabel(String? playCount) {
    if (playCount == null || playCount.isEmpty) return null;
    final text = playCount.toLowerCase();
    return text.contains('play') || text.contains('popular')
        ? playCount
        : '$playCount plays';
  }

  Widget _buildAllSongsButton() {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          icon: Icon(
            FluentIcons.arrow_right_20_regular,
            color: scheme.onSurface,
          ),
          iconAlignment: IconAlignment.end,
          label: Text(
            context.l10n!.allSongs,
            style: muzikaBody(14, weight: 600, color: scheme.onSurface),
          ),
          onPressed: () => context.push(
            NavigationManager.artistSongsPath(context, _resolvedArtistId),
            extra: artistPlaylistData(_artist!),
          ),
        ),
      ),
    );
  }

  String _releaseSubtitle(Map<String, dynamic> release) {
    final year = release['year']?.toString();
    final type = switch (release['releaseType']?.toString()) {
      'single' => context.l10n!.single,
      'ep' => 'EP',
      _ => context.l10n!.album,
    };
    return year == null || year.isEmpty ? type : '$type • $year';
  }

  // Shares the complete catalog with "All songs" and keeps it after the first
  // action so play, add and download cannot resolve different song snapshots.
  Future<Map?> _loadCatalog() async {
    final loadedCatalog = _catalog;
    if (loadedCatalog != null) return loadedCatalog;

    final inFlight = _catalogFuture;
    if (inFlight != null) return inFlight;

    final generation = _artistLoadGeneration;
    final artistId = _resolvedArtistId;
    final future = _resolveCatalog();
    _catalogFuture = future;
    final catalog = await future;

    final ownsFuture = identical(_catalogFuture, future);
    final isCurrent =
        mounted &&
        generation == _artistLoadGeneration &&
        artistId == _resolvedArtistId &&
        ownsFuture;
    if (ownsFuture) _catalogFuture = null;
    if (!isCurrent) return null;

    if (catalog != null && catalog['catalogStatus'] != 'failed') {
      setState(() {
        _catalog = Map<String, dynamic>.from(catalog);
      });
    }
    return catalog;
  }

  Future<Map?> _resolveCatalog() {
    final artist = _artist;
    if (artist != null) return getArtistCatalogFromProfile(artist);

    return getPlaylistInfoForWidget(
      _resolvedArtistId,
      isArtist: true,
      artistName: _artistTitle,
      artistImage: _artist?['image']?.toString(),
      preferredVerified: _artist?['isVerifiedArtist'] == true,
    );
  }

  Future<void> _playArtist({bool shuffle = false}) async {
    // What's playing stops now, not once every album has been read.
    audioHandler.silenceForSwitch();
    _isLoadingCatalog.value = true;
    try {
      final catalog = await _loadCatalog();
      if (!mounted) return;

      final songs = catalog?['list'] as List? ?? const [];
      if (songs.isEmpty) {
        showToast(context, context.l10n!.error);
        return;
      }

      if (shuffle) {
        await audioHandler.addPlaylistToQueue(
          List<Map>.from(songs.whereType<Map>()),
          replace: true,
          shuffle: true,
        );
      } else {
        await audioHandler.playPlaylistSong(
          playlist: catalog,
          songIndex: 0,
          shuffle: false,
        );
      }
    } finally {
      // Nothing came to play (no songs read): Play works again.
      audioHandler.endPendingSwitch();
      if (mounted) _isLoadingCatalog.value = false;
    }
  }

  void _openArtist(Map<String, dynamic> artist) {
    final artistId = artist['ytid']?.toString();
    if (artistId == null || artistId.isEmpty) return;

    context.push(
      NavigationManager.artistPath(context, artistId),
      extra: artist,
    );
  }

  void _openRelease(Map<String, dynamic> release) {
    final releaseId = release['ytid']?.toString();
    if (releaseId == null || releaseId.isEmpty) return;

    context.push(
      NavigationManager.albumPath(context, releaseId),
      extra: release,
    );
  }
}
