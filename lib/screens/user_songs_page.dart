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

import 'dart:io';

import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/foundation.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:muzika/utilities/undo.dart';
import 'package:muzika/widgets/settings_icon_button.dart';
import 'package:muzika/extensions/l10n.dart';
import 'package:muzika/main.dart' show logger, audioHandler;
import 'package:muzika/screens/liked_songs_transfer_page.dart';
import 'package:muzika/services/clip_requests.dart';
import 'package:muzika/services/common_services.dart';
import 'package:muzika/services/data_manager.dart';
import 'package:muzika/services/itunes_catalog.dart';
import 'package:muzika/services/muzika_downloads.dart';
import 'package:muzika/services/playlist_download_service.dart';
import 'package:muzika/services/router_service.dart';
import 'package:muzika/services/settings_manager.dart';
import 'package:muzika/theme/muzika_tokens.dart';
import 'package:muzika/utilities/app_utils.dart';
import 'package:muzika/utilities/playlist_utils.dart';
import 'package:muzika/utilities/song_filtering.dart';
import 'package:muzika/utilities/sort_utils.dart';
import 'package:muzika/widgets/clips_shelf.dart';
import 'package:muzika/widgets/muzika_back_page.dart';
import 'package:muzika/widgets/muzika_mosaic.dart';
import 'package:muzika/widgets/muzika_search_field.dart';
import 'package:muzika/widgets/muzika_section.dart';
import 'package:muzika/widgets/muzika_song_row.dart';
import 'package:muzika/widgets/playlist_page/search_bar_section.dart';

enum OfflineSortType { default_, title, artist, dateAdded }

class UserSongsPage extends StatefulWidget {
  const UserSongsPage({super.key, required this.page});

  final String page;

  @override
  State<UserSongsPage> createState() => _UserSongsPageState();
}

class _UserSongsPageState extends State<UserSongsPage> {
  final ValueNotifier<String> _searchQueryNotifier = ValueNotifier('');
  late final TextEditingController _searchController;
  late final FocusNode _searchFocusNode;

  List _getDisplayList(List songsList) {
    var list = filterSongsByQuery(songsList, _searchQueryNotifier.value);
    if (widget.page == 'offline') {
      list = _sortOfflineSongsLocal(list, _getCurrentOfflineSortType());
    }
    return list;
  }

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController();
    _searchFocusNode = FocusNode();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();
    _searchQueryNotifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final title = getTitle(widget.page, context);
    final content = ValueListenableBuilder(
      valueListenable: _source,
      builder: (_, songsList, _) =>
          _buildCustomScrollView(title, _visible(songsList)),
    );

    // Offline is a tab of its own: a plain page like Home. Liked songs and
    // recently played are pages of their own with a back arrow.
    if (widget.page == 'offline') {
      return Scaffold(body: SafeArea(bottom: false, child: content));
    }
    // Search floats in the top bar, as on playlists; back closes it first.
    return PopScope(
      canPop: !_searching,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _searching) _toggleSearch();
      },
      child: MuzikaBackPage(
        center: _searching
            ? MuzikaSearchField(
                controller: _searchController,
                focusNode: _searchFocusNode,
                onChanged: (value) => _searchQueryNotifier.value = value,
              )
            : null,
        onBack: _searching ? _toggleSearch : null,
        actions: [
          if (!_searching)
            IconButton(
              tooltip: context.l10n!.search,
              icon: const Icon(FluentIcons.search_24_regular),
              onPressed: _toggleSearch,
            ),
        ],
        child: content,
      ),
    );
  }

  bool _searching = false;

  void _toggleSearch() {
    setState(() => _searching = !_searching);
    if (!_searching) {
      _searchController.clear();
      _searchQueryNotifier.value = '';
      _searchFocusNode.unfocus();
    }
  }

  /// Offline only: downloaded Songs, songs Cached from playing, or
  /// downloaded Playlists & albums.
  _OfflineTab _tab = _OfflineTab.songs;
  bool get _showPlaylists => _tab == _OfflineTab.playlists;

  /// The songs this page lists: Offline splits downloads from cached songs.
  List _visible(List songs) {
    if (widget.page != 'offline') return songs;
    final cached = _tab == _OfflineTab.cached;
    return songs
        .where((s) => s is Map && isAutoCachedSong(s) == cached)
        .toList();
  }

  ValueListenable<List> get _source => widget.page == 'liked'
      ? userLikedSongsList
      : widget.page == 'offline'
      ? userOfflineSongs
      : userRecentlyPlayed;

  OfflineSortType _getCurrentOfflineSortType() {
    return OfflineSortType.values.firstWhere(
      (e) => e.name == offlineSortSetting,
      orElse: () => OfflineSortType.default_,
    );
  }

  /// The list in play order (offline songs follow the chosen sort).
  List _playOrder(List songs) => widget.page == 'offline'
      ? _sortOfflineSongsLocal(songs, _getCurrentOfflineSortType())
      : songs;

  Widget _buildCustomScrollView(String title, List songsList) {
    return CustomScrollView(
      slivers: [
        // Searching shows the songs only, under the field.
        if (!_searching) ...[
          SliverToBoxAdapter(child: _buildHeaderSection(title, songsList)),
          // Clips liked in the Clips tab, over the songs.
          if (widget.page == 'liked')
            SliverToBoxAdapter(
              child: ValueListenableBuilder<List<AppleClip>>(
                valueListenable: likedClips,
                builder: (_, clips, _) => clips.isEmpty
                    ? const SizedBox.shrink()
                    : Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: ClipsShelf(clips: clips, title: 'Liked clips'),
                      ),
              ),
            ),
          const SliverToBoxAdapter(child: MuzikaDivider()),
        ],
        const SliverToBoxAdapter(child: SizedBox(height: 8)),
        if (widget.page == 'offline' && _showPlaylists)
          const _OfflinePlaylists()
        else
          buildSongList(title),
        const SliverToBoxAdapter(child: SizedBox(height: 32)),
      ],
    );
  }

  String getTitle(String page, BuildContext context) {
    return switch (page) {
      'liked' => context.l10n!.likedSongs,
      'offline' => 'Offline',
      'recents' => context.l10n!.recentlyPlayed,
      _ => context.l10n!.playlist,
    };
  }

  String _meta(List songsList) {
    final count = songsList.length;
    final songs = '$count ${count == 1 ? 'song' : 'songs'}';
    return switch (widget.page) {
      // Offline: just how many and how much room they take.
      'offline' => '$songs · ${_sizeMb(songsList)}',
      'recents' => '$songs played lately',
      _ => songs,
    };
  }

  String _sizeMb(List songsList) {
    var bytes = 0;
    for (final song in songsList) {
      final path = (song is Map ? song['audioPath'] : null)?.toString() ?? '';
      if (path.isEmpty) continue;
      try {
        bytes += File(path).lengthSync();
      } catch (_) {}
    }
    final mb = bytes / (1024 * 1024);
    return '${mb < 10 ? mb.toStringAsFixed(1) : mb.round()} MB';
  }

  Widget _buildHeaderSection(String title, List songsList) {
    final scheme = Theme.of(context).colorScheme;
    final isTab = widget.page == 'offline';
    final count = songsList.length;

    return Padding(
      padding: EdgeInsets.fromLTRB(20, isTab ? 16 : 4, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // The Downloads tab: its gear, as on every tab.
              if (isTab) ...[const SettingsIconButton()],
              Flexible(
                child: Text(
                  title,
                  style: muzikaHeading(
                    isTab ? 29 : 24,
                    color: scheme.onSurface,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            _meta(songsList),
            style: muzikaBody(13, color: scheme.onSurfaceVariant),
          ),
          if (widget.page == 'liked')
            TextButton.icon(
              onPressed: () => openLikedSongsTransfer(context),
              icon: const Icon(Icons.qr_code_2_rounded),
              label: const Text('Sync library'),
            ),
          if (count > 0) ...[
            const SizedBox(height: 14),
            Row(
              spacing: 8,
              children: [
                MuzikaRoundButton(
                  icon: FluentIcons.play_24_filled,
                  filled: true,
                  tooltip: context.l10n!.play,
                  onPressed: () => audioHandler.playPlaylistSong(
                    playlist: {
                      'ytid': '',
                      'title': title,
                      'source': 'user-created',
                      'list': _playOrder(songsList),
                    },
                    songIndex: 0,
                    shuffle: false,
                  ),
                ),
                MuzikaRoundButton(
                  icon: FluentIcons.arrow_shuffle_24_regular,
                  tooltip: context.l10n!.shuffle,
                  onPressed: () => audioHandler.addPlaylistToQueue(
                    List<Map>.from(songsList.whereType<Map>()),
                    replace: true,
                    shuffle: true,
                  ),
                ),
                if (widget.page == 'recents') _buildClearRecentsButton(),
                if (widget.page == 'offline' && _tab == _OfflineTab.cached)
                  _buildClearCachedButton(),
              ],
            ),
          ],
          if (widget.page == 'offline') ...[
            const SizedBox(height: 14),
            _OfflineTabs(
              current: _tab,
              onChanged: (v) => setState(() => _tab = v),
            ),
          ],
          // Offline keeps its own search; Liked and Recent use the bar's.
          if (widget.page == 'offline' && count > 30) ...[
            const SizedBox(height: 12),
            SearchBarSection(
              controller: _searchController,
              focusNode: _searchFocusNode,
              onSearchChanged: (value) => _searchQueryNotifier.value = value,
              labelText: context.l10n!.search,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildClearCachedButton() {
    return MuzikaRoundButton(
      icon: FluentIcons.delete_24_regular,
      tooltip: 'Clear cached songs',
      // Your downloads stay; the cached ones go once the Undo bar has.
      onPressed: () => doWithUndo(
        context,
        'Cached songs cleared',
        commit: () async {
          await clearCachedSongs();
        },
      ),
    );
  }

  Widget _buildClearRecentsButton() {
    return MuzikaRoundButton(
      icon: FluentIcons.delete_24_regular,
      tooltip: context.l10n!.clear,
      onPressed: () {
        final before = userRecentlyPlayed.value;
        userRecentlyPlayed.value = [];
        doWithUndo(
          context,
          'Recently played cleared',
          undo: () => userRecentlyPlayed.value = before,
          commit: () =>
              addOrUpdateData<List>('user', 'recentlyPlayedSongs', []),
        );
      },
    );
  }

  Widget buildSongList(String title) {
    final scheme = Theme.of(context).colorScheme;
    return ValueListenableBuilder<String>(
      valueListenable: _searchQueryNotifier,
      builder: (_, searchQuery, _) {
        final songsList = _visible(_source.value);
        final displayList = _getDisplayList(songsList);
        final queue = List<Map>.from(_playOrder(songsList).whereType<Map>());

        if (displayList.isEmpty) {
          return SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 48, 20, 48),
              child: Text(
                switch (widget.page) {
                  'offline' => 'Songs you download play here without internet.',
                  'liked' => 'Tap ♥ on any song to keep it here.',
                  _ => context.l10n!.playlistEmpty,
                },
                textAlign: TextAlign.center,
                style: muzikaBody(15, color: scheme.onSurfaceVariant),
              ),
            ),
          );
        }

        return SliverList.builder(
          key: widget.page == 'offline' && searchQuery.isEmpty
              ? ValueKey(_getCurrentOfflineSortType())
              : null,
          itemCount: displayList.length,
          itemBuilder: (context, index) {
            final song = displayList[index] as Map;
            final fullIndex = queue.indexWhere(
              (s) => s['ytid'] == song['ytid'],
            );
            if (fullIndex == -1) {
              logger.log('Warning: Song ${song['ytid']} not found in list');
            }
            return MuzikaSongRow(
              key: listItemKey('user_song_${widget.page}', index, song),
              song: song,
              queue: queue,
              index: fullIndex != -1 ? fullIndex : index,
              // Offline: who sings it and how much room it takes.
              subtitle: widget.page == 'offline'
                  ? '${song['artist'] ?? ''} · ${_sizeMb([song])}'
                  : null,
            );
          },
        );
      },
    );
  }

  List _sortOfflineSongsLocal(List list, OfflineSortType type) {
    return switch (type) {
      OfflineSortType.default_ => List<dynamic>.of(list),
      OfflineSortType.title => sortSongsByKey(list, 'title'),
      OfflineSortType.artist => sortSongsByKey(list, 'artist'),
      OfflineSortType.dateAdded => sortSongsByDateAdded(list),
    };
  }
}

/// Small monochrome pills for the offline sort order.
/// Songs | Playlists switch at the top of Offline.
enum _OfflineTab { songs, cached, playlists }

class _OfflineTabs extends StatelessWidget {
  const _OfflineTabs({required this.current, required this.onChanged});

  final _OfflineTab current;
  final ValueChanged<_OfflineTab> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget tab(String label, _OfflineTab value) {
      final active = current == value;
      return AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        decoration: BoxDecoration(
          color: active ? scheme.onSurface : scheme.surfaceContainer,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => onChanged(value),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
              child: Text(
                label,
                style: muzikaBody(
                  14,
                  weight: 600,
                  color: active ? scheme.surface : scheme.onSurface,
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Row(
      spacing: 8,
      children: [
        tab('Songs', _OfflineTab.songs),
        tab('Cached', _OfflineTab.cached),
        tab('Playlists & albums', _OfflineTab.playlists),
      ],
    );
  }
}

/// Downloaded playlists and albums, each opening its own page.
class _OfflinePlaylists extends StatelessWidget {
  const _OfflinePlaylists();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ValueListenableBuilder<List<dynamic>>(
      valueListenable: offlinePlaylistService.offlinePlaylists,
      builder: (context, playlists, _) {
        final items = playlists
            .whereType<Map>()
            .where((p) => !PlaylistUtils.isArtistPlaylist(p))
            .toList();
        if (items.isEmpty) {
          return SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 48, 20, 48),
              child: Text(
                'Download a playlist or album and it shows up here.',
                textAlign: TextAlign.center,
                style: muzikaBody(15, color: scheme.onSurfaceVariant),
              ),
            ),
          );
        }
        return SliverList.builder(
          itemCount: items.length,
          itemBuilder: (context, i) {
            final p = items[i];
            final songs = (p['list'] as List? ?? const []).whereType<Map>();
            final kind = p['isAlbum'] == true ? 'Album' : 'Playlist';
            return InkWell(
              onTap: () => context.push(
                '${NavigationManager.offlinePath}/playlist/'
                '${Uri.encodeComponent('${p['ytid']}')}',
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    if (p['image'] != null)
                      MuzikaCover(song: {'image': p['image']})
                    else
                      MuzikaMosaic(
                        images: [
                          for (final s in songs.take(4))
                            ?(s['lowResImage'] ?? s['image'])?.toString(),
                        ],
                        size: 56,
                      ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${p['title'] ?? ''}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: muzikaBody(
                              16,
                              weight: 500,
                              color: scheme.onSurface,
                            ),
                          ),
                          Text(
                            '$kind · ${songs.length} songs',
                            style: muzikaBody(
                              12.5,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}
