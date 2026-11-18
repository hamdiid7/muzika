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

import 'package:cached_network_image/cached_network_image.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart' as mk;
import 'package:media_kit_video/media_kit_video.dart';
import 'package:muzika/extensions/l10n.dart';
import 'package:muzika/main.dart';
import 'package:muzika/screens/playlist_page.dart';
import 'package:muzika/screens/story_viewer_page.dart' show openStories;
import 'package:muzika/services/artist_service.dart';
import 'package:muzika/services/common_services.dart';
import 'package:muzika/services/data_saver.dart' show dataSaverOn;
import 'package:muzika/services/deezer_catalog.dart';
import 'package:muzika/services/itunes_catalog.dart';
import 'package:muzika/services/muzika_home.dart'
    show HomeStory, artistStory, pickedHomeStories;
import 'package:muzika/services/playlist_download_service.dart';
import 'package:muzika/services/playlists_manager.dart';
import 'package:muzika/services/router_service.dart';
import 'package:muzika/services/settings_manager.dart';
import 'package:muzika/services/smart_shuffle.dart';
import 'package:muzika/services/youtube_canvas.dart'
    show sliceStart, youtubeStreamsFor;
import 'package:muzika/services/youtube_trending.dart' show TrendingVideo;
import 'package:muzika/theme/muzika_tokens.dart';
import 'package:muzika/utilities/app_utils.dart';
import 'package:muzika/utilities/async_loader.dart';
import 'package:muzika/utilities/flutter_toast.dart';
import 'package:muzika/widgets/clips_shelf.dart';
import 'package:muzika/widgets/muzika_back_page.dart';
import 'package:muzika/widgets/muzika_loading.dart';
import 'package:muzika/widgets/muzika_song_row.dart';
import 'package:muzika/widgets/overflow_menu_button.dart';
import 'package:muzika/widgets/playlist_page/like_button.dart';
import 'package:muzika/widgets/popup_menu_item.dart';
import 'package:muzika/widgets/shelf_arrows.dart';
import 'package:muzika/widgets/muzika_share.dart' show showArtistShare;
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
    final title = '${artist['title'] ?? ''}';
    final photo =
        artist['image']?.toString() ?? widget.artistData?['image']?.toString();
    _heroPhoto = photo != null && photo.startsWith('http')
        ? Future.value(photo)
        : deezerArtistPhoto(title).catchError((_) => null);
    _story = artistStory(title).catchError((_) => null);
    _loadClips();
    return artist;
  }

  @override
  Widget build(BuildContext context) {
    // Offline the page is what was kept from the last visit; an artist
    // never opened before is their saved songs instead.
    final offline = offlineMode.value;
    return AsyncLoader<Map<String, dynamic>?>(
      future: _artistFuture ??= _loadArtist(),
      loadingWidget: const MuzikaBackPage(child: MuzikaLoading()),
      emptyWidget: offline ? _buildAllSongsPage() : _buildLoadFailedPage(),
      errorBuilder: (_, _, _) =>
          offline ? _buildAllSongsPage() : _buildLoadFailedPage(),
      builder: (context, _) => _buildLoadedPage(),
    );
  }

  /// The hero's height under the status bar.
  static const _heroHeight = 300.0;

  Widget _buildLoadedPage() {
    final scheme = Theme.of(context).colorScheme;
    final top = MediaQuery.paddingOf(context).top;
    return Scaffold(
      backgroundColor: scheme.surface,
      body: Stack(
        children: [
          Positioned.fill(
            // Pull down to refresh, where the refresh button used to be.
            child: RefreshIndicator(
              onRefresh: _refresh,
              edgeOffset: top + 52,
              child: NotificationListener<ScrollNotification>(
                onNotification: (n) {
                  if (n.depth == 0) {
                    _collapsed.value = n.metrics.pixels > _heroHeight - 64;
                  }
                  return false;
                },
                child: ListView(
                  padding: const EdgeInsets.only(bottom: 32),
                  children: [_buildHero(), ..._buildAll()],
                ),
              ),
            ),
          ),
          Positioned(top: 0, left: 0, right: 0, child: _buildTopBar()),
        ],
      ),
    );
  }

  /// Back, search and the menu: round see-through buttons on the photo;
  /// once the photo has scrolled away, a solid bar with the artist's small
  /// photo, name and Play.
  Widget _buildTopBar() {
    final scheme = Theme.of(context).colorScheme;
    final top = MediaQuery.paddingOf(context).top;
    return ValueListenableBuilder<bool>(
      valueListenable: _collapsed,
      builder: (context, collapsed, _) {
        Widget button(IconData icon, String tooltip, VoidCallback onPressed) =>
            Padding(
              padding: const EdgeInsets.all(4),
              child: IconButton(
                tooltip: tooltip,
                style: IconButton.styleFrom(
                  backgroundColor: collapsed
                      ? Colors.transparent
                      : Colors.black.withValues(alpha: 0.35),
                  foregroundColor: collapsed ? scheme.onSurface : Colors.white,
                ),
                icon: Icon(icon, size: 22),
                onPressed: onPressed,
              ),
            );
        return AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: EdgeInsets.fromLTRB(4, top + 2, 4, 2),
          decoration: BoxDecoration(
            color: collapsed ? scheme.surface : Colors.transparent,
            border: Border(
              bottom: BorderSide(
                width: 0.5,
                color: collapsed ? scheme.outlineVariant : Colors.transparent,
              ),
            ),
          ),
          child: Row(
            children: [
              button(
                Icons.arrow_back_rounded,
                'Back',
                () => Navigator.of(context).maybePop(),
              ),
              Expanded(child: _buildCollapsedTitle()),
              button(
                FluentIcons.search_24_regular,
                context.l10n!.search,
                // Search inside this artist's songs.
                () => context.push(
                  '${NavigationManager.artistSongsPath(context, _resolvedArtistId)}'
                  '?search=1',
                  extra: artistPlaylistData(_artist!),
                ),
              ),
              button(
                FluentIcons.more_horizontal_24_regular,
                'More',
                _showArtistMenu,
              ),
            ],
          ),
        );
      },
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

  /// Nothing came back for this artist. A dropped line and an artist that
  /// isn't there look the same from here, so the page says what it knows
  /// and offers to try again.
  Widget _buildLoadFailedPage() {
    final scheme = Theme.of(context).colorScheme;
    return MuzikaBackPage(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                FluentIcons.wifi_off_24_regular,
                size: 32,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(height: 14),
              Text(
                'Couldn’t load this artist',
                textAlign: TextAlign.center,
                style: muzikaBody(17, weight: 700, color: scheme.onSurface),
              ),
              const SizedBox(height: 6),
              Text(
                'Check your connection and try again.',
                textAlign: TextAlign.center,
                style: muzikaBody(14, color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 18),
              OutlinedButton.icon(
                onPressed: _retry,
                icon: const Icon(FluentIcons.arrow_clockwise_20_regular),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _retry() {
    _artistLoadGeneration++;
    setState(() {
      _artistFuture = _loadArtist(forceRefresh: true);
    });
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
              IconButton(
                tooltip: context.l10n!.play,
                icon: Icon(FluentIcons.play_24_filled, color: scheme.onSurface),
                onPressed: _playArtist,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The hero's picture: the artist's photo (Deezer's when the page has
  /// none).
  Future<String?>? _heroPhoto;

  /// Their story, when they've put something out in the last four weeks.
  Future<HomeStory?>? _story;

  void _openStory(HomeStory story) {
    // Home's own list when it's one of them, so the rest follow.
    final all = pickedHomeStories;
    final at = all.indexWhere((s) => s.video.id == story.video.id);
    unawaited(
      at >= 0
          ? openStories(context, all, at)
          : openStories(context, [story], 0),
    );
  }

  /// The top of the page: the artist's photo across the whole width (their
  /// story's video looping silently in its place when they have one), the
  /// name and fans on it, and Like, Radio, Shuffle and Play beside them.
  Widget _buildHero() {
    final scheme = Theme.of(context).colorScheme;
    final top = MediaQuery.paddingOf(context).top;
    final fans = _artist?['monthlyListeners']?.toString();
    return SizedBox(
      height: _heroHeight + top,
      child: FutureBuilder<HomeStory?>(
        future: _story,
        builder: (context, snapshot) {
          final story = snapshot.data;
          // The video only when the Canvas is on and data isn't saved.
          final playsStory =
              story != null &&
              story.video.isVideo &&
              canvasEnabled.value &&
              !dataSaverOn;
          return Stack(
            fit: StackFit.expand,
            children: [
              const ColoredBox(color: Color(0xFF2B2B2B)),
              FutureBuilder<String?>(
                future: _heroPhoto,
                builder: (context, photo) {
                  final url = photo.data;
                  if (url == null || url.isEmpty) {
                    return const SizedBox.shrink();
                  }
                  return CachedNetworkImage(
                    imageUrl: url,
                    fit: BoxFit.cover,
                    // Faces sit high in most artist photos.
                    alignment: const Alignment(0, -0.35),
                    fadeInDuration: const Duration(milliseconds: 250),
                    errorWidget: (_, _, _) => const SizedBox.shrink(),
                  );
                },
              ),
              if (playsStory)
                _HeroStoryVideo(
                  key: ValueKey(story.video.id),
                  video: story.video,
                ),
              // Dark at the top for the buttons; at the foot the photo melts
              // into the page's own colour (the playing song's tint), so
              // there's no edge between them.
              IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      stops: const [0, 0.25, 0.42, 0.86, 1],
                      colors: [
                        const Color(0x66000000),
                        const Color(0x00000000),
                        scheme.surface.withValues(alpha: 0),
                        scheme.surface.withValues(alpha: 0.92),
                        scheme.surface,
                      ],
                    ),
                  ),
                ),
              ),
              // With a story, the picture opens it.
              if (story != null)
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _openStory(story),
                  ),
                ),
              if (story != null)
                Positioned(
                  top: top + 62,
                  right: 14,
                  child: _StoryPill(
                    playing: playsStory,
                    onTap: () => _openStory(story),
                  ),
                ),
              Positioned(
                left: 20,
                right: 8,
                bottom: 14,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (fans != null && fans.isNotEmpty)
                            Text(
                              fans.toLowerCase().contains('fan')
                                  ? fans
                                  : '$fans fans',
                              style: muzikaBody(
                                13,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          Text(
                            _artistTitle,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: muzikaHeading(
                              34,
                              color: scheme.onSurface,
                            ).copyWith(height: 1.05),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    _buildHeroActions(),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// Like, Radio, Shuffle and Play: plain icons where the photo has faded
  /// into the page, in the page's text colour.
  Widget _buildHeroActions() {
    final scheme = Theme.of(context).colorScheme;
    return Theme(
      data: Theme.of(context).copyWith(
        colorScheme: scheme.copyWith(
          onSurfaceVariant: scheme.onSurface,
          primary: scheme.onSurface,
        ),
      ),
      child: ValueListenableBuilder<bool>(
        valueListenable: _isLoadingCatalog,
        builder: (context, isLoading, _) => IconButtonTheme(
          data: IconButtonThemeData(
            style: IconButton.styleFrom(
              backgroundColor: Colors.transparent,
              foregroundColor: scheme.onSurface,
              disabledForegroundColor: scheme.onSurface.withValues(alpha: 0.4),
              iconSize: 24,
              minimumSize: const Size(40, 40),
              padding: EdgeInsets.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              PlaylistLikeButton(
                playlistId: _resolvedArtistId,
                playlistData: () =>
                    artistPlaylistData(_artist!, songs: const []),
              ),
              if (_topSongs.isNotEmpty)
                IconButton(
                  tooltip: '$_artistTitle Radio',
                  icon: const Icon(Icons.sensors_rounded),
                  onPressed: _playRadio,
                ),
              IconButton(
                tooltip: context.l10n!.shuffle,
                icon: const Icon(FluentIcons.arrow_shuffle_24_regular),
                onPressed: isLoading ? null : () => _playArtist(shuffle: true),
              ),
              IconButton(
                tooltip: context.l10n!.play,
                icon: Icon(
                  isLoading
                      ? FluentIcons.hourglass_24_regular
                      : FluentIcons.play_24_filled,
                ),
                onPressed: isLoading ? null : _playArtist,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Play next · Add to queue · Share.
  void _showArtistMenu() {
    final scheme = Theme.of(context).colorScheme;
    showMuzikaMenu<String>(
      context,
      title: _artistTitle,
      items: [
        if (_topSongs.isNotEmpty) ...[
          buildPopupMenuItem<String>(
            value: 'next',
            icon: Icons.playlist_play_rounded,
            label: 'Play next',
            colorScheme: scheme,
          ),
          buildPopupMenuItem<String>(
            value: 'queue',
            icon: Icons.queue_music_rounded,
            label: 'Add to queue',
            colorScheme: scheme,
          ),
        ],
        buildPopupMenuItem<String>(
          value: 'share',
          icon: FluentIcons.share_24_regular,
          label: 'Share',
          colorScheme: scheme,
        ),
      ],
      onSelected: (value) {
        switch (value) {
          case 'next':
            _queueSongs(_topSongs, next: true, of: _artistTitle);
          case 'queue':
            _queueSongs(_topSongs, next: false, of: _artistTitle);
          case 'share':
            // The artist as a card to send: photo, name and fans.
            showArtistShare(
              context,
              name: _artistTitle,
              image:
                  _artist?['image']?.toString() ??
                  widget.artistData?['image']?.toString(),
              fans: _artist?['monthlyListeners']?.toString(),
            );
        }
      },
    );
  }

  /// Puts [songs] behind the playing song ([next]) or at the end of the
  /// queue, leaving what is playing alone. With nothing queued they play.
  Future<void> _queueSongs(
    List<Map> songs, {
    required bool next,
    required String of,
  }) async {
    final list = List<Map>.from(songs);
    if (list.isEmpty) {
      showToast(context, context.l10n!.error);
      return;
    }
    if (audioHandler.queueAsMapStreamValue.isEmpty) {
      await audioHandler.addPlaylistToQueue(list, replace: true, startIndex: 0);
      return;
    }
    if (next) {
      // Last first: each goes right behind the playing song.
      for (final song in list.reversed) {
        await audioHandler.playNext(song);
      }
    } else {
      await audioHandler.addPlaylistToQueue(list);
    }
    if (!mounted) return;
    final count = list.length == 1 ? '1 song' : '${list.length} songs';
    showToast(
      context,
      next
          ? '$count from $of will play next'
          : 'Added $count from $of to queue',
    );
  }

  /// Hold or right-click an album or single: play it, queue it, download it.
  void _showReleaseMenu(Map<String, dynamic> release) {
    final scheme = Theme.of(context).colorScheme;
    showMuzikaMenu<String>(
      context,
      title: release['title']?.toString(),
      items: [
        buildPopupMenuItem<String>(
          value: 'play',
          icon: FluentIcons.play_24_regular,
          label: context.l10n!.play,
          colorScheme: scheme,
        ),
        buildPopupMenuItem<String>(
          value: 'next',
          icon: Icons.playlist_play_rounded,
          label: 'Play next',
          colorScheme: scheme,
        ),
        buildPopupMenuItem<String>(
          value: 'queue',
          icon: Icons.queue_music_rounded,
          label: 'Add to queue',
          colorScheme: scheme,
        ),
        buildPopupMenuItem<String>(
          value: 'download',
          icon: FluentIcons.arrow_download_24_regular,
          label: 'Download',
          colorScheme: scheme,
        ),
      ],
      onSelected: (action) => _runReleaseAction(release, action),
    );
  }

  Future<void> _runReleaseAction(
    Map<String, dynamic> release,
    String action,
  ) async {
    final id = release['ytid']?.toString();
    if (id == null || id.isEmpty) return;
    final title = release['title']?.toString() ?? '';
    // What's playing stops now, not once the album has been read.
    if (action == 'play') audioHandler.silenceForSwitch();
    try {
      final album = await getPlaylistInfoForWidget(id);
      if (!mounted) return;
      final songs = [
        for (final song in album?['list'] as List? ?? const [])
          if (song is Map) song,
      ];
      if (album == null || songs.isEmpty) {
        showToast(context, context.l10n!.error);
        return;
      }
      switch (action) {
        case 'play':
          await audioHandler.playPlaylistSong(
            playlist: album,
            songIndex: 0,
            shuffle: false,
          );
        case 'next':
          await _queueSongs(songs, next: true, of: title);
        case 'queue':
          await _queueSongs(songs, next: false, of: title);
        case 'download':
          await offlinePlaylistService.downloadPlaylist(context, album);
      }
    } catch (e, stackTrace) {
      logger.log(
        'Artist page: $action failed',
        error: e,
        stackTrace: stackTrace,
      );
      if (mounted) showToast(context, context.l10n!.error);
    } finally {
      if (action == 'play') audioHandler.endPendingSwitch();
    }
  }

  /// The page under the photo: the five most popular songs and a row to
  /// all of them, then clips, albums, singles and related artists as rows
  /// that scroll sideways.
  List<Widget> _buildAll() {
    final scheme = Theme.of(context).colorScheme;
    Widget heading(String title) => Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 16, 10),
      child: Text(title, style: muzikaHeading(20, color: scheme.onSurface)),
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
            return _PressableCard(
              onTap: () => round ? _openArtist(item) : _openRelease(item),
              onMenu: round ? null : () => _showReleaseMenu(item),
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

    return [
      if (_topSongs.isNotEmpty) ...[
        heading('Popular'),
        _buildTopSongsSection(max: 5),
        _buildAllSongsButton(),
      ],
      // A clip opens the Clips tab on it.
      ClipsShelf(clips: _clips),
      if (_albums.isNotEmpty) ...[
        heading(context.l10n!.albums),
        shelf(_albums),
      ],
      if (_singles.isNotEmpty) ...[heading('Singles'), shelf(_singles)],
      if (_relatedArtists.isNotEmpty) ...[
        heading('Fans also like'),
        _buildFansAlsoLike(),
      ],
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

  /// The top songs, numbered; [max] of them on the overview.
  Widget _buildTopSongsSection({int? max}) {
    final scheme = Theme.of(context).colorScheme;
    final queue = List<Map>.from(_topSongs);
    final shown = max == null ? _topSongs : _topSongs.take(max).toList();
    return Column(
      children: [
        for (final (index, song) in shown.indexed)
          MuzikaSongRow(
            key: listItemKey('artist_top_song', index, song),
            song: song,
            queue: queue,
            index: index,
            dense: true,
            showAddButton: false,
            showDownloadButton: false,
            showMoreButton: true,
            leading: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 22,
                  child: Text(
                    '${index + 1}',
                    textAlign: TextAlign.right,
                    style: muzikaBody(14, color: scheme.onSurfaceVariant),
                  ),
                ),
                const SizedBox(width: 12),
                MuzikaCover(song: song, size: 44),
              ],
            ),
            subtitle:
                _playsLabel(_topSongPlayCounts.elementAtOrNull(index)) ??
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

  /// The last row of Popular: every song of the artist. It lines up with
  /// the numbered rows above (an empty number, a square where the cover
  /// goes) and says how many there are once that's known.
  Widget _buildAllSongsButton() {
    final scheme = Theme.of(context).colorScheme;
    final count = (_catalog?['list'] as List?)?.length;
    return InkWell(
      onTap: () => context.push(
        NavigationManager.artistSongsPath(context, _resolvedArtistId),
        extra: artistPlaylistData(_artist!),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
        child: Row(
          children: [
            const SizedBox(width: 34),
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(
                FluentIcons.text_bullet_list_ltr_24_regular,
                size: 22,
                color: scheme.onSurface,
              ),
            ),
            const SizedBox(width: 14),
            Text(
              count == null || count == 0
                  ? context.l10n!.allSongs
                  : 'All $count songs',
              style: muzikaBody(16, weight: 600, color: scheme.onSurface),
            ),
          ],
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

  /// Play: the top songs start at once, most popular first, and the rest of
  /// the artist's songs join the queue behind them once they have been read.
  /// Shuffle, and an artist with no top songs, read every song first: to mix
  /// them all, or to have something to play.
  Future<void> _playArtist({bool shuffle = false}) async {
    final hits = List<Map>.from(_topSongs);
    if (!shuffle && hits.isNotEmpty) {
      await audioHandler.addPlaylistToQueue(
        hits,
        replace: true,
        startIndex: 0,
        shuffle: false,
      );
      unawaited(_queueRestAfter(hits));
      return;
    }

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

  /// The artist's other songs, added behind [hits] once read. Left out when
  /// something else has been put on meanwhile: that queue isn't this one.
  Future<void> _queueRestAfter(List<Map> hits) async {
    try {
      final catalog = await _loadCatalog();
      if (!mounted) return;
      final ids = {for (final song in hits) '${song['ytid']}'};
      final titles = {
        for (final song in hits) '${song['title']}'.toLowerCase(),
      };
      final rest = <Map>[
        for (final song in catalog?['list'] as List? ?? const [])
          if (song is Map &&
              !ids.contains('${song['ytid']}') &&
              !titles.contains('${song['title']}'.toLowerCase()))
            song,
      ];
      if (rest.isEmpty) return;
      if (!ids.contains('${audioHandler.currentSong?['ytid']}')) return;
      await audioHandler.addPlaylistToQueue(rest);
    } catch (e, stackTrace) {
      logger.log(
        'Artist page: queueing the rest failed',
        error: e,
        stackTrace: stackTrace,
      );
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

/// A cover that answers to the pointer: it grows a little under the mouse,
/// gives a little under a press, and opens its menu on a hold or a
/// right-click.
class _PressableCard extends StatefulWidget {
  const _PressableCard({required this.child, required this.onTap, this.onMenu});

  final Widget child;
  final VoidCallback onTap;
  final VoidCallback? onMenu;

  @override
  State<_PressableCard> createState() => _PressableCardState();
}

class _PressableCardState extends State<_PressableCard> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.disableAnimationsOf(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        onLongPress: widget.onMenu,
        onSecondaryTap: widget.onMenu,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        child: AnimatedScale(
          duration: Duration(milliseconds: still ? 0 : 140),
          curve: Curves.easeOut,
          scale: _pressed
              ? 0.96
              : _hovered
              ? 1.03
              : 1,
          child: widget.child,
        ),
      ),
    );
  }
}

/// The artist's story in the hero: a few seconds of its video looping
/// silently over their photo. It fades in once the picture arrives, plays
/// only while the page is in front, and stops after a minute and a half so
/// it doesn't use data for ever.
class _HeroStoryVideo extends StatefulWidget {
  const _HeroStoryVideo({super.key, required this.video});

  final TrendingVideo video;

  @override
  State<_HeroStoryVideo> createState() => _HeroStoryVideoState();
}

class _HeroStoryVideoState extends State<_HeroStoryVideo> {
  static const _loop = Duration(seconds: 8);
  static const _maxPlay = Duration(seconds: 90);

  mk.Player? _player;
  VideoController? _controller;
  StreamSubscription<Duration>? _watch;
  Timer? _check;
  final _played = Stopwatch();
  bool _shown = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final streams = await youtubeStreamsFor(widget.video.id)
        .catchError((_) => null);
    if (streams == null || !mounted) return;
    // Only the loop is needed: a small read-ahead, as the player's Canvas.
    final player = mk.Player(
      configuration: const mk.PlayerConfiguration(bufferSize: 4 * 1024 * 1024),
    );
    _player = player;
    _controller = VideoController(player);
    await player.setVolume(0);
    final start = sliceStart(widget.video.length ?? Duration.zero, _loop);
    await player.open(
      mk.Media(streams.video, httpHeaders: streams.headers, start: start),
      play: false,
    );
    if (!mounted || _player != player) return;
    await player.setPlaylistMode(mk.PlaylistMode.single);
    _watch = player.stream.position.listen((p) {
      if (p >= start + _loop) unawaited(player.seek(start));
    });
    await player.play();
    _played.start();
    await player.stream.width
        .firstWhere((w) => (w ?? 0) > 0, orElse: () => 0)
        .timeout(const Duration(seconds: 20), onTimeout: () => 0);
    if (!mounted || _player != player) return;
    setState(() => _shown = true);
    _check = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      final front =
          (ModalRoute.of(context)?.isCurrent ?? true) &&
          TickerMode.valuesOf(context).enabled;
      if (front) {
        _played.start();
      } else {
        _played.stop();
      }
      final wanted = front && _played.elapsed < _maxPlay;
      if (wanted != player.state.playing) {
        unawaited(wanted ? player.play() : player.pause());
      }
    });
  }

  @override
  void dispose() {
    _check?.cancel();
    unawaited(_watch?.cancel());
    unawaited(_player?.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return IgnorePointer(
      child: AnimatedOpacity(
        opacity: _shown ? 1 : 0,
        duration: const Duration(milliseconds: 600),
        child: controller == null
            ? const SizedBox.shrink()
            : Video(
                controller: controller,
                fit: BoxFit.cover,
                controls: NoVideoControls,
                fill: Colors.transparent,
              ),
      ),
    );
  }
}

/// On the hero when the artist has a story: what it is, and that a tap
/// opens it (with sound).
class _StoryPill extends StatelessWidget {
  const _StoryPill({required this.playing, required this.onTap});

  /// Its video is already looping silently behind.
  final bool playing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.45),
      shape: const StadiumBorder(),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                playing
                    ? FluentIcons.speaker_mute_16_regular
                    : FluentIcons.play_16_filled,
                size: 14,
                color: Colors.white,
              ),
              const SizedBox(width: 6),
              Text(
                playing ? 'Story · tap for sound' : 'New story',
                style: muzikaBody(12, weight: 600, color: Colors.white),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
