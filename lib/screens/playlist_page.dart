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

import 'package:muzika/widgets/muzika_song_actions.dart' show openArtistFor;
import 'package:muzika/services/router_service.dart';
import 'package:go_router/go_router.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:material_ui/material_ui.dart';
import 'package:muzika/extensions/l10n.dart';
import 'package:muzika/main.dart';
import 'package:muzika/screens/album_battle_page.dart';
import 'package:muzika/services/artist_service.dart';
import 'package:muzika/services/common_services.dart';
import 'package:muzika/services/cover_tint.dart';
import 'package:muzika/services/data_manager.dart';
import 'package:muzika/services/deezer_catalog.dart';
import 'package:muzika/services/playlist_download_service.dart';
import 'package:muzika/services/playlists_manager.dart';
import 'package:muzika/services/settings_manager.dart';
import 'package:muzika/theme/muzika_tokens.dart';
import 'package:muzika/utilities/app_utils.dart';
import 'package:muzika/utilities/async_loader.dart';
import 'package:muzika/utilities/flutter_toast.dart';
import 'package:muzika/utilities/playlist_utils.dart';
import 'package:muzika/utilities/song_filtering.dart';
import 'package:muzika/utilities/sort_utils.dart';
import 'package:muzika/widgets/edit_playlist_dialog.dart';
import 'package:muzika/widgets/muzika_back_page.dart';
import 'package:muzika/widgets/muzika_loading.dart';
import 'package:muzika/widgets/muzika_mosaic.dart';
import 'package:muzika/widgets/muzika_search_field.dart';
import 'package:muzika/widgets/muzika_section.dart';
import 'package:muzika/widgets/muzika_song_row.dart';
import 'package:muzika/widgets/playlist_page/add_to_playlist_button.dart';
import 'package:muzika/widgets/playlist_page/download_button.dart';
import 'package:muzika/widgets/playlist_page/like_button.dart';

enum PlaylistSortType { default_, title, artist, dateAdded }

class PlaylistPage extends StatefulWidget {
  const PlaylistPage({
    super.key,
    this.playlistId,
    this.playlistData,
    this.cubeIcon = FluentIcons.text_bullet_list_24_filled,
    this.isArtist = false,
    this.startSearching = false,
  });

  final String? playlistId;
  final dynamic playlistData;
  final IconData cubeIcon;
  final bool isArtist;

  /// Opens with the search field focused (the artist page's search icon).
  final bool startSearching;

  @override
  _PlaylistPageState createState() => _PlaylistPageState();
}

class _PlaylistPageState extends State<PlaylistPage> {
  dynamic _playlist;

  /// Canonical (storage) order; `_playlist['list']` is always derived from it.
  List<dynamic> _originalPlaylistList = [];

  bool _isInitializingPlaylist = true;

  /// Playlist-seeded recommendations for eligible online custom playlists.
  Future<List>? _recommendedSongsFuture;

  /// Ytids added during this visit, removed from the fetched recommendations immediately.
  final Set<String> _addedRecommendedSongIds = {};

  /// Maximum recommendations rendered at once to bound artwork loads per frame.
  static const _visibleRecommendedSongsCount = 5;

  String? get _resolvedPlaylistId =>
      _playlist?['ytid']?.toString() ??
      widget.playlistData?['ytid']?.toString() ??
      widget.playlistId;

  // Sorting
  late final PlaylistSortType _sortType = PlaylistSortType.values.firstWhere(
    (e) => e.name == playlistSortSetting,
    orElse: () => PlaylistSortType.default_,
  );

  // Search
  final ValueNotifier<String> _searchQueryNotifier = ValueNotifier('');
  late bool _searching = widget.startSearching;

  void _toggleSearch() {
    setState(() => _searching = !_searching);
    if (_searching) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _searchFocusNode.requestFocus(),
      );
    } else {
      _searchController.clear();
      _searchQueryNotifier.value = '';
      _searchFocusNode.unfocus();
    }
  }

  late final TextEditingController _searchController;
  late final FocusNode _searchFocusNode;

  List _getSourceList(String searchQuery) {
    final list = _playlist?['list'] as List? ?? [];
    return filterSongsByQuery(list, searchQuery);
  }

  bool get _isArtistCatalogFailed =>
      widget.isArtist && _playlist?['catalogStatus'] == 'failed';

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController();
    _searchFocusNode = FocusNode();
    _initializePlaylist();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();
    _searchQueryNotifier.dispose();
    super.dispose();
  }

  Future<void> _initializePlaylist() async {
    try {
      final initialPlaylist = widget.playlistData;
      final resolvedId =
          initialPlaylist?['ytid']?.toString() ?? widget.playlistId;

      if (initialPlaylist != null) {
        _playlist = initialPlaylist;
        final playlistList = _playlist?['list'] as List?;
        final shouldFetchInitialPlaylist =
            playlistList == null || (!widget.isArtist && playlistList.isEmpty);
        if (shouldFetchInitialPlaylist && resolvedId != null) {
          _playlist =
              await getPlaylistInfoForWidget(
                resolvedId,
                isArtist: widget.isArtist,
                artistName: initialPlaylist?['title']?.toString(),
                artistImage: initialPlaylist?['image']?.toString(),
                sourceSongId: initialPlaylist?['sourceSongId']?.toString(),
                sourceVideoAuthor: initialPlaylist?['videoAuthor']?.toString(),
                preferredVerified: initialPlaylist?['isVerifiedArtist'] == true,
              ) ??
              initialPlaylist;
        }
      } else {
        _playlist = await getPlaylistInfoForWidget(
          resolvedId,
          isArtist: widget.isArtist,
          artistName: initialPlaylist?['title']?.toString(),
          artistImage: initialPlaylist?['image']?.toString(),
          sourceSongId: initialPlaylist?['sourceSongId']?.toString(),
          sourceVideoAuthor: initialPlaylist?['videoAuthor']?.toString(),
          preferredVerified: initialPlaylist?['isVerifiedArtist'] == true,
        );
      }

      if (_playlist != null && _playlist['list'] != null) {
        _adoptPlaylist(_playlist);
      }
      _maybeLoadRecommendations();
    } catch (e, stackTrace) {
      logger.log(
        'Error initializing playlist:',
        error: e,
        stackTrace: stackTrace,
      );
      if (mounted) {
        showToast(context, context.l10n!.error);
      }
    } finally {
      _isInitializingPlaylist = false;
      if (mounted) {
        setState(() {});
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isInitializingPlaylist) {
      return const MuzikaBackPage(child: MuzikaLoading());
    }
    if (_playlist == null) {
      return MuzikaBackPage(child: _emptyMessage(context.l10n!.error));
    }
    final songs = _playlist['list'] as List? ?? const [];
    // The bar floats over the page so the header's colour runs up behind it.
    // Back (the arrow or the phone's) closes a search before the page.
    return PopScope(
      canPop: !_searching,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _searching) _toggleSearch();
      },
      child: MuzikaBackPage(
        barOverContent: true,
        // Searching floats a field in the top bar, in place of the button.
        center: _searching ? _searchField() : null,
        onBack: _searching ? _toggleSearch : null,
        actions: [
          if (songs.isNotEmpty && !_searching)
            IconButton(
              tooltip: context.l10n!.search,
              icon: const Icon(FluentIcons.search_24_regular),
              onPressed: _toggleSearch,
            ),
        ],
        child: CustomScrollView(
          slivers: [
            // Searching shows the songs only, under the field (as Spotify).
            if (_searching)
              SliverToBoxAdapter(
                child: SizedBox(height: MuzikaBackPage.topSpace(context) + 4),
              )
            else ...[
              SliverToBoxAdapter(child: _buildHeaderSection()),
              const SliverToBoxAdapter(child: MuzikaDivider()),
              const SliverToBoxAdapter(child: SizedBox(height: 8)),
            ],
            if (songs.isNotEmpty)
              ValueListenableBuilder<String>(
                valueListenable: _searchQueryNotifier,
                builder: (context, searchQuery, _) {
                  final sourceList = _getSourceList(searchQuery);
                  final isRemovable = _playlist['source'] == 'user-created';
                  return SliverList.builder(
                    itemCount: sourceList.length,
                    itemBuilder: (context, index) => _buildSongListItem(
                      sourceList[index],
                      index,
                      isRemovable,
                      sourceList,
                    ),
                  );
                },
              )
            else
              SliverToBoxAdapter(
                child: _emptyMessage(
                  _isArtistCatalogFailed
                      ? context.l10n!.error
                      : context.l10n!.noSongsInPlaylist,
                ),
              ),
            if (!_searching) _buildRecommendedSongsSliver(),
            _buildAlbumExtrasSliver(),
            const SliverToBoxAdapter(child: SizedBox(height: 32)),
          ],
        ),
      ),
    );
  }

  Widget _emptyMessage(String text) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 48),
    child: Center(
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: muzikaBody(
          15,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    ),
  );

  Widget _buildRecommendedSongsSliver() {
    final future = _recommendedSongsFuture;
    if (future == null) return const SliverToBoxAdapter();

    return SliverToBoxAdapter(
      child: AsyncLoader<List<dynamic>>(
        future: future,
        // Keep the section hidden when recommendations fail or are empty.
        loadingWidget: const SizedBox.shrink(),
        errorBuilder: (_, _, _) => const SizedBox.shrink(),
        builder: (context, data) {
          // Cap rendered rows to limit simultaneous artwork loads; do not refetch or backfill.
          final visibleSongs = data
              .whereType<Map>()
              .where(
                (song) => !_addedRecommendedSongIds.contains(
                  song['ytid']?.toString(),
                ),
              )
              .take(_visibleRecommendedSongsCount)
              .toList();
          if (visibleSongs.isEmpty) return const SizedBox.shrink();

          return Column(
            children: [
              // A section heading, like the others ("Or listen again").
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 24, 20, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    context.l10n!.recommendedSongs,
                    style: muzikaHeading(
                      20,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                ),
              ),
              for (final (i, song) in visibleSongs.indexed)
                MuzikaSongRow(
                  key: listItemKey('playlist_recommended', i, song),
                  song: song,
                  queue: visibleSongs,
                  index: i,
                  onAdd: () => _handleAddRecommendedSong(song),
                ),
            ],
          );
        },
      ),
    );
  }

  /// Adds a recommendation directly to the current playlist with one tap.
  void _handleAddRecommendedSong(Map song) {
    final playlistId = _resolvedPlaylistId;
    if (playlistId == null) return;

    final result = addSongInCustomPlaylist(context, playlistId, song);
    showToast(context, result);

    if (result == context.l10n!.songAdded) {
      setState(() {
        _addedRecommendedSongIds.add(song['ytid']?.toString() ?? '');
        _originalPlaylistList.add(song);
        _applySort();
      });
    }
  }

  String get _playlistTitle => widget.isArtist
      ? normalizeArtistDisplayTitle(_playlist['title']?.toString() ?? '')
      : _playlist['title']?.toString() ?? '';

  bool get _isAlbum =>
      _playlist['isAlbum'] == true ||
      (_resolvedPlaylistId?.startsWith('MPRE') ?? false);

  String _metaLine(int songsLength) {
    final count = '$songsLength ${songsLength == 1 ? 'song' : 'songs'}';
    if (widget.isArtist) return '${context.l10n!.artist} · $count';
    if (_isAlbum) {
      return [
        _playlist['artist']?.toString(),
        context.l10n!.album,
        _playlist['year']?.toString(),
        count,
      ].where((p) => p != null && p.isNotEmpty).join(' · ');
    }
    return '${context.l10n!.playlist} · $count';
  }

  /// The album's artist: small round photo and name; a tap opens them.
  Widget _albumArtistRow(ColorScheme scheme) {
    final artist = '${_playlist['artist']}';
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: () => openArtistFor(context, {
        'artist': artist,
        if (_playlist['artistId'] != null) 'artistId': _playlist['artistId'],
      }),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            FutureBuilder<String?>(
              future: _artistPhoto ??= deezerArtistPhoto(artist)
                  .catchError((_) => null),
              builder: (context, photo) => CircleAvatar(
                radius: 12,
                backgroundColor: scheme.surfaceContainerHigh,
                backgroundImage: photo.data == null
                    ? null
                    : CachedNetworkImageProvider(photo.data!),
              ),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                artist,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: muzikaBody(15, weight: 700, color: scheme.onSurface),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<String?>? _artistPhoto;

  /// "2024 · 12 songs, 48 min".
  String _albumMeta(int songsLength) {
    final seconds = (_playlist['list'] as List? ?? const [])
        .whereType<Map>()
        .fold<int>(0, (n, s) => n + ((s['duration'] as num?)?.toInt() ?? 0));
    final minutes = (seconds / 60).round();
    final length = minutes <= 0
        ? ''
        : minutes < 60
        ? ', $minutes min'
        : ', ${minutes ~/ 60} h ${minutes % 60} min';
    return [
      _playlist['year']?.toString(),
      '$songsLength ${songsLength == 1 ? 'song' : 'songs'}$length',
    ].where((p) => p != null && p.isNotEmpty).join(' · ');
  }

  // 10: after an album's songs, more by its artist and albums like it.
  Future<({List<Map> more, List<Map> alike})>? _albumExtras;

  Future<({List<Map> more, List<Map> alike})> _loadAlbumExtras() async {
    final artist = '${_playlist['artist'] ?? ''}';
    if (artist.isEmpty) return (more: <Map>[], alike: <Map>[]);
    final id = '${_playlist['artistId'] ?? ''}';
    final profile = id.startsWith(deezerArtistPrefix)
        ? await deezerArtistProfile(id, name: artist).catchError((_) => null)
        : await deezerArtistByName(artist).catchError((_) => null);
    if (profile == null) return (more: <Map>[], alike: <Map>[]);
    String key(Object? t) => '$t'.toLowerCase().replaceAll(
      RegExp(r'[^\p{L}\p{N}]', unicode: true),
      '',
    );
    final here = key(_playlist['title']);
    final more = [
      for (final r
          in ((profile['releases'] as List?) ?? const []).whereType<Map>())
        if (key(r['title']) != here) r,
    ].take(10).toList();
    // Albums like it: the newest of each artist like this one.
    final related = ((profile['relatedArtists'] as List?) ?? const [])
        .whereType<Map>()
        .take(6)
        .toList();
    final found = await Future.wait([
      for (final a in related)
        deezerSearchAlbums('${a['title'] ?? ''}')
            .catchError((_) => <Map<String, dynamic>>[]),
    ]);
    final alike = <Map>[];
    for (final (i, albums) in found.indexed) {
      final name = key(related[i]['title']);
      final hit = albums.where((a) => key(a['artist']) == name).firstOrNull;
      if (hit != null) alike.add(hit);
    }
    return (more: more, alike: alike);
  }

  Widget _buildAlbumExtrasSliver() {
    if (!_isAlbum || _searching) return const SliverToBoxAdapter();
    final scheme = Theme.of(context).colorScheme;
    return SliverToBoxAdapter(
      child: FutureBuilder<({List<Map> more, List<Map> alike})>(
        future: _albumExtras ??= _loadAlbumExtras(),
        builder: (context, snapshot) {
          final extras = snapshot.data;
          if (extras == null) return const SizedBox.shrink();
          Widget shelf(String title, List<Map> albums) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 24, 20, 10),
                child: Text(
                  title,
                  style: muzikaHeading(20, color: scheme.onSurface),
                ),
              ),
              SizedBox(
                height: 186,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  itemCount: albums.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 14),
                  itemBuilder: (context, i) {
                    final album = albums[i];
                    final cover =
                        '${album['image'] ?? album['lowResImage'] ?? ''}';
                    return InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: () => context.push(
                        NavigationManager.albumPath(
                          context,
                          '${album['ytid']}',
                        ),
                        extra: album,
                      ),
                      child: SizedBox(
                        width: 130,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(10),
                              child: SizedBox(
                                width: 130,
                                height: 130,
                                child: cover.startsWith('http')
                                    ? CachedNetworkImage(
                                        imageUrl: cover,
                                        fit: BoxFit.cover,
                                      )
                                    : ColoredBox(
                                        color: scheme.surfaceContainerHigh,
                                      ),
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              '${album['title'] ?? ''}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: muzikaBody(
                                13,
                                weight: 600,
                                color: scheme.onSurface,
                              ),
                            ),
                            Text(
                              [
                                if (title.startsWith('You'))
                                  '${album['artist'] ?? ''}',
                                '${album['year'] ?? ''}',
                              ].where((t) => t.isNotEmpty).join(' · '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: muzikaBody(
                                12,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          );
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (extras.more.isNotEmpty)
                shelf('More by ${_playlist['artist']}', extras.more),
              if (extras.alike.isNotEmpty)
                shelf('You might also like', extras.alike),
            ],
          );
        },
      ),
    );
  }

  Widget _buildHeaderSection() {
    final scheme = Theme.of(context).colorScheme;
    final songsLength = (_playlist['list'] as List? ?? const []).length;
    final isUserCreated = _playlist['source'] == 'user-created';

    // The cover's colour, carried on from the top bar and fading into the
    // page; it scrolls away with the header.
    final art = _tintSource();
    return FutureBuilder<Color?>(
      future: art == null ? null : imageColor(Uri.parse(art)),
      builder: (context, tint) => DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              _tinted(tint.data, scheme) ?? scheme.surface,
              scheme.surface,
            ],
          ),
        ),
        child: Padding(
          padding: EdgeInsets.only(top: MuzikaBackPage.topSpace(context)),
          child: _header(scheme, songsLength, isUserCreated),
        ),
      ),
    );
  }

  Color? _tinted(Color? cover, ColorScheme scheme) => cover == null
      ? null
      : coverTinted(
          cover,
          scheme,
          amount: scheme.brightness == Brightness.dark ? 0.45 : 0.32,
        );

  /// The grey search box of the design (the same grey as the name boxes),
  /// sized to sit level with the back arrow.
  Widget _searchField() => MuzikaSearchField(
    hint: widget.isArtist
        ? "Search $_playlistTitle's songs"
        : _isAlbum
        ? 'Search this album'
        : 'Search this playlist',
    controller: _searchController,
    focusNode: _searchFocusNode,
    onChanged: (value) => _searchQueryNotifier.value = value,
  );

  /// The picture the header takes its colour from.
  String? _tintSource() {
    for (final s in [_playlist, ...(_playlist['list'] as List? ?? const [])]) {
      if (s is! Map) continue;
      for (final k in ['image', 'highResImage', 'lowResImage']) {
        final v = s[k]?.toString() ?? '';
        if (v.startsWith('http') || v.startsWith('file')) return v;
      }
    }
    return null;
  }

  Widget _header(ColorScheme scheme, int songsLength, bool isUserCreated) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(child: _buildCover()),
          const SizedBox(height: 18),
          Text(
            _playlistTitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: muzikaHeading(26, color: scheme.onSurface),
          ),
          const SizedBox(height: 4),
          if (_isAlbum && '${_playlist['artist'] ?? ''}'.isNotEmpty) ...[
            _albumArtistRow(scheme),
            const SizedBox(height: 4),
          ],
          Text(
            _isAlbum ? _albumMeta(songsLength) : _metaLine(songsLength),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: muzikaBody(13, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 14),
          // Play stays a filled circle; the rest are plain icons.
          IconButtonTheme(
            data: IconButtonThemeData(
              style: IconButton.styleFrom(
                backgroundColor: Colors.transparent,
                foregroundColor: scheme.onSurface,
                iconSize: 24,
              ),
            ),
            child: Wrap(
              spacing: 4,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (songsLength > 0) ...[
                  MuzikaRoundButton(
                    icon: FluentIcons.play_24_filled,
                    filled: true,
                    tooltip: context.l10n!.play,
                    onPressed: () => audioHandler.playPlaylistSong(
                      playlist: _playlist,
                      songIndex: 0,
                      shuffle: false,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(FluentIcons.arrow_shuffle_24_regular),
                    tooltip: context.l10n!.shuffle,
                    onPressed: () async {
                      final songs = _playlist['list'] as List? ?? [];
                      if (songs.isEmpty) return;
                      await audioHandler.addPlaylistToQueue(
                        List<Map>.from(songs.whereType<Map>()),
                        replace: true,
                        shuffle: true,
                      );
                    },
                  ),
                ],
                if (widget.playlistId != null &&
                    !isUserCreated &&
                    !offlineMode.value)
                  PlaylistLikeButton(
                    playlistId: _resolvedPlaylistId ?? '',
                    playlistData: () => _playlist,
                  ),
                if (!offlineMode.value) ...[
                  PlaylistAddToPlaylistButton(
                    resolvePlaylist: () async => _playlist,
                  ),
                  // A Daily mix is made fresh each day: nothing to update.
                  if (!isUserCreated &&
                      !'${_playlist?['ytid'] ?? ''}'.startsWith('dailymix_'))
                    _buildSyncButton(),
                ],
                if (songsLength > 0) _buildDownloadButton(),
                if (isUserCreated) _buildEditButton(),
                // Game mode (Settings): match this album against another.
                if (_isAlbum && songsLength > 0)
                  ValueListenableBuilder<bool>(
                    valueListenable: gameMode,
                    builder: (context, on, _) => on
                        ? IconButton.filledTonal(
                            icon: const Icon(Icons.compare_arrows_rounded),
                            iconSize: 24,
                            tooltip: 'Compare',
                            onPressed: () =>
                                showAlbumOpponents(context, _playlist as Map),
                          )
                        : const SizedBox.shrink(),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Playlists show the covers of their first four songs; albums and artists
  /// keep their own picture.
  Widget _buildCover() {
    const side = 200.0;
    final covers = [
      for (final s in (_playlist['list'] as List? ?? const []).whereType<Map>())
        if ((s['lowResImage'] ?? s['image'])?.toString() case final String c
            when c.isNotEmpty && c != 'null')
          c,
    ];
    final mosaic = !widget.isArtist && !_isAlbum && covers.toSet().length >= 4;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.18),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: mosaic
          ? MuzikaMosaic(
              images: covers.take(4).toList(),
              size: side,
              radius: 16,
            )
          : MuzikaCover(song: _playlist, size: side, radius: 16, highRes: true),
    );
  }

  Widget _buildSyncButton() {
    return IconButton.filledTonal(
      icon: const Icon(FluentIcons.arrow_sync_24_filled),
      iconSize: 24,
      onPressed: _handleSyncPlaylist,
      tooltip: context.l10n!.update,
    );
  }

  Widget _buildEditButton() {
    return IconButton.filledTonal(
      icon: const Icon(FluentIcons.edit_24_filled),
      iconSize: 24,
      onPressed: () async {
        final result = await showEditPlaylistSheet(context, _playlist);

        if (result != null) {
          final resolvedPlaylistYtid =
              _playlist['ytid']?.toString() ?? widget.playlistId;
          if (resolvedPlaylistYtid == null ||
              resolvedPlaylistYtid.isEmpty ||
              resolvedPlaylistYtid == 'null') {
            showToast(context, context.l10n!.error);
            return;
          }

          final updatedPlaylist = {
            ..._playlist,
            ...result,
            'ytid': resolvedPlaylistYtid,
            'source': _playlist['source'] ?? result['source'],
            'list': result['list'] ?? _playlist['list'],
          };

          // Search root list first, then inside folders.
          final rootIndex = userCustomPlaylists.value.indexWhere(
            (p) => p['ytid'] == resolvedPlaylistYtid,
          );

          if (rootIndex != -1) {
            final updatedPlaylists = List<Map>.from(userCustomPlaylists.value);
            updatedPlaylists[rootIndex] = updatedPlaylist;
            userCustomPlaylists.value = updatedPlaylists;
            unawaited(
              addOrUpdateData<List>(
                'user',
                'customPlaylists',
                userCustomPlaylists.value,
              ),
            );
          } else {
            // Playlist lives inside a folder - update it there.
            final updatedFolders = List<Map>.from(userPlaylistFolders.value);
            for (final folder in updatedFolders) {
              final folderPlaylists = List<Map>.from(
                folder['playlists'] as List? ?? [],
              );
              final fi = folderPlaylists.indexWhere(
                (p) => p['ytid'] == resolvedPlaylistYtid,
              );
              if (fi != -1) {
                folderPlaylists[fi] = updatedPlaylist;
                folder['playlists'] = folderPlaylists;
                break;
              }
            }
            userPlaylistFolders.value = updatedFolders;
            unawaited(
              addOrUpdateData<List>(
                'user',
                'playlistFolders',
                userPlaylistFolders.value,
              ),
            );
          }

          // Update offline playlist if it exists
          unawaited(syncOfflinePlaylistMetadata(updatedPlaylist));

          setState(() => _adoptPlaylist(updatedPlaylist));
          showToast(context, context.l10n!.playlistUpdated);
        }
      },
      tooltip: context.l10n!.editPlaylist,
    );
  }

  Widget _buildDownloadButton() {
    final playlistId = _playlist?['ytid']?.toString() ?? widget.playlistId;
    if (playlistId == null || playlistId.isEmpty) {
      return const SizedBox.shrink();
    }

    return PlaylistDownloadButton(
      playlistId: playlistId,
      songs: _playlist?['list'] as List? ?? const [],
      resolvePlaylist: () async => _playlist,
    );
  }

  void _handleSyncPlaylist() async {
    final playlistId = _playlist?['ytid']?.toString();
    if (playlistId == null || playlistId.isEmpty) return;

    if (offlineMode.value &&
        offlinePlaylistService.isPlaylistDownloaded(playlistId)) {
      if (mounted) {
        showToast(context, context.l10n!.removeOffline);
      }
      return;
    }

    // Artists/releases aren't built-in playlists; refresh by dropping their cache entry.
    final isCachedPage = widget.isArtist || playlistId.startsWith('MPRE');
    final updated = widget.isArtist
        ? await getPlaylistInfoForWidget(
            playlistId,
            isArtist: true,
            artistName: _playlist?['title']?.toString(),
            artistImage: _playlist?['image']?.toString(),
            preferredVerified: _playlist?['isVerifiedArtist'] == true,
            forceRefresh: true,
          )
        : isCachedPage
        ? await getPlaylistInfoForWidget(playlistId, forceRefresh: true)
        : await updatePlaylistList(context, playlistId);
    if (updated?['catalogStatus'] == 'failed') {
      if (mounted) showToast(context, context.l10n!.error);
      return;
    }
    if (updated != null && mounted) {
      setState(() => _adoptPlaylist(updated));
      if (isCachedPage) {
        showToast(context, context.l10n!.playlistUpdated);
      }
    }
  }

  /// Removes [song] from the canonical list (and storage), then re-derives the view.
  void _removeSong(Map song) {
    final canonicalIndex = _originalPlaylistList.indexWhere(
      (s) => s is Map && s['ytid'] == song['ytid'],
    );
    if (canonicalIndex == -1) return;

    // Persist in canonical order, never the sorted view order.
    final canonicalPlaylist = {..._playlist, 'list': _originalPlaylistList};
    if (!removeSongFromPlaylist(
      canonicalPlaylist,
      song,
      removeOneAtIndex: canonicalIndex,
    )) {
      return;
    }
    _updateSongsListOnRemove(canonicalIndex, song);
  }

  void _updateSongsListOnRemove(int indexToRestore, dynamic songToRemove) {
    _originalPlaylistList = List<dynamic>.from(_originalPlaylistList)
      ..removeAt(indexToRestore);
    _applySort();
    final playlistId = _playlist['ytid'];
    if (mounted) {
      setState(() {});
      showToastWithButton(
        context,
        context.l10n!.songRemoved,
        context.l10n!.undo.toUpperCase(),
        () {
          final result = addSongInCustomPlaylist(
            context,
            playlistId,
            songToRemove,
            indexToInsert: indexToRestore,
          );
          if (result == context.l10n!.songAdded &&
              !_originalPlaylistList.any(
                (song) => song['ytid'] == songToRemove['ytid'],
              )) {
            final safeIndex = indexToRestore.clamp(
              0,
              _originalPlaylistList.length,
            );
            _originalPlaylistList.insert(safeIndex, songToRemove);
            _applySort();
          }
          if (mounted) setState(() {});
        },
      );
    } else {
      logger.log(
        '(_updateSongsListOnRemove): Widget not mounted, cannot show undo toast.',
      );
    }
  }

  /// Loads recommendations only for non-empty online user-created playlists.
  void _maybeLoadRecommendations() {
    final isUserCreated = _playlist?['source'] == 'user-created';
    final songs = _playlist?['list'] as List? ?? const [];
    final playlistId = _resolvedPlaylistId;

    if (isUserCreated &&
        !offlineMode.value &&
        songs.isNotEmpty &&
        playlistId != null) {
      _recommendedSongsFuture = getRecommendedSongsForPlaylist(
        playlistId,
        songs,
      );
    } else {
      _recommendedSongsFuture = null;
    }
  }

  /// Copy source, snapshot its canonical order and apply the current sort.
  /// Prevents sorting changes from affecting shared cached playlist data.
  void _adoptPlaylist(dynamic source) {
    if (source is! Map) {
      _playlist = source;
      _originalPlaylistList = <dynamic>[];
      return;
    }
    _playlist = Map<String, dynamic>.from(source);
    final list = source['list'];
    _originalPlaylistList = list is List
        ? List<dynamic>.from(list)
        : <dynamic>[];
    _applySort();
  }

  /// Rebuilds the displayed list from the canonical list for [_sortType].
  void _applySort() {
    if (_playlist is! Map || _playlist['list'] == null) return;

    _playlist['list'] = switch (_sortType) {
      PlaylistSortType.default_ => List<dynamic>.of(_originalPlaylistList),
      PlaylistSortType.title => sortSongsByKey(_originalPlaylistList, 'title'),
      PlaylistSortType.artist => sortSongsByKey(
        _originalPlaylistList,
        'artist',
      ),
      PlaylistSortType.dateAdded => sortSongsNewestFirst(_originalPlaylistList),
    };
  }

  Widget _buildSongListItem(
    Map song,
    int index,
    bool isRemovable,
    List sourceList,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final isSearching = _searchQueryNotifier.value.isNotEmpty;
    final fullIndex = isSearching
        ? PlaylistUtils.findSongIndexByYtid(_playlist, song['ytid'])
        : index;

    if (isSearching && fullIndex == -1) {
      logger.log('Warning: Song ${song['ytid']} not found in full playlist');
    }

    final queue = List<Map>.from(
      (_playlist['list'] as List? ?? const []).whereType<Map>(),
    );
    final row = MuzikaSongRow(
      key: listItemKey('playlist_song', index, song),
      song: song,
      queue: queue,
      index: fullIndex != -1 ? fullIndex : index,
      // Albums list a track's length, playlists who sings it.
      subtitle: _isAlbum
          ? _formatDuration(song['duration'])
          // An artist's songs: who sings it and how popular it is on Deezer.
          : widget.isArtist && deezerPopularityLabel(song) != null
          ? '${song['artist'] ?? ''} · ${deezerPopularityLabel(song)}'
          : null,
      leading: _isAlbum
          ? SizedBox(
              width: 28,
              child: Text(
                '${index + 1}',
                textAlign: TextAlign.center,
                style: muzikaBody(15, color: scheme.onSurfaceVariant),
              ),
            )
          : null,
    );
    if (!isRemovable || isSearching) return row;
    return Dismissible(
      key: ValueKey('dismiss_${song['ytid']}_$index'),
      direction: DismissDirection.endToStart,
      background: ColoredBox(
        color: scheme.errorContainer,
        child: Align(
          alignment: Alignment.centerRight,
          child: Padding(
            padding: const EdgeInsets.only(right: 24),
            child: Icon(
              FluentIcons.delete_24_regular,
              color: scheme.onErrorContainer,
            ),
          ),
        ),
      ),
      onDismissed: (_) => _removeSong(song),
      child: row,
    );
  }

  String? _formatDuration(dynamic value) {
    final seconds = switch (value) {
      final int v => v,
      final num v => v.toInt(),
      final String v => int.tryParse(v),
      _ => null,
    };
    if (seconds == null || seconds <= 0) return null;
    final m = seconds ~/ 60;
    final s = (seconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}
