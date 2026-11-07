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
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:muzika/utilities/undo.dart';
import 'package:muzika/widgets/settings_icon_button.dart';
import 'package:muzika/extensions/l10n.dart';
import 'package:muzika/main.dart' show audioHandler, logger;
import 'package:muzika/screens/liked_songs_transfer_page.dart';
import 'package:muzika/services/common_services.dart';
import 'package:muzika/services/playlist_download_service.dart';
import 'package:muzika/services/playlists_manager.dart';
import 'package:muzika/services/settings_manager.dart';
import 'package:muzika/services/song_battles.dart';
import 'package:muzika/theme/muzika_tokens.dart';
import 'package:muzika/utilities/app_utils.dart';
import 'package:muzika/utilities/flutter_toast.dart';
import 'package:muzika/utilities/offline_playlist_dialogs.dart';
import 'package:muzika/utilities/playlist_utils.dart';
import 'package:muzika/widgets/mini_player_bottom_space.dart';
import 'package:muzika/widgets/muzika_mosaic.dart';
import 'package:muzika/widgets/muzika_playlist_picker.dart';
import 'package:muzika/widgets/playlist_bar.dart';

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});

  @override
  _LibraryPageState createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  @override
  Widget build(BuildContext context) {
    // Show offline mode message if there is no content
    if (offlineMode.value) {
      final hasUserContent =
          userPlaylistFolders.value.isNotEmpty ||
          userPlaylists.value.isNotEmpty ||
          userCustomPlaylists.value.isNotEmpty;
      final hasOfflinePlaylists = offlinePlaylistService.offlinePlaylists.value
          .any((p) => p is Map && !PlaylistUtils.isArtistPlaylist(p));
      final hasOfflineArtists = getLikedArtistItems(offlineOnly: true)
          .isNotEmpty;
      final hasOfflineSongs = userOfflineSongs.value.isNotEmpty;

      if (!hasUserContent &&
          !hasOfflinePlaylists &&
          !hasOfflineArtists &&
          !hasOfflineSongs) {
        final colorScheme = Theme.of(context).colorScheme;
        return Scaffold(
          appBar: AppBar(
            title: Text(context.l10n!.library),
            actions: [
              IconButton(
                tooltip: 'Sync library',
                icon: const Icon(Icons.qr_code_2_rounded),
                onPressed: () => openLikedSongsTransfer(context),
              ),
            ],
          ),
          body: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: colorScheme.primaryContainer,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.cloud_off_outlined,
                      size: 40,
                      color: colorScheme.onPrimaryContainer,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    context.l10n!.offlineMode,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      color: colorScheme.onSurface,
                      fontWeight: FontWeight.w600,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    context.l10n!.noOfflineLibraryContent,
                    style: Theme.of(context).textTheme.bodyMedium
                        ?.copyWith(color: colorScheme.onSurfaceVariant),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        );
      }
    }

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: AnimatedBuilder(
          animation: Listenable.merge([
            pinnedPlaylistIds,
            offlineMode,
            userCustomPlaylists,
            userPlaylistFolders,
            offlinePlaylistService.offlinePlaylists,
            userLikedPlaylists,
            onlinePlaylists,
            userPlaylists,
            userOfflineSongs,
            userLikedSongsList,
            userRecentlyPlayed,
            SongBattles.changes,
          ]),
          builder: (context, _) {
            final entries = _entries();
            final kinds = {for (final e in entries) e.kind};
            final shown = _filter == null
                ? entries
                : entries.where((e) => e.kind == _filter).toList();
            final ranks = _filter == 'ranks' ? SongBattles.ranked() : null;
            return CustomScrollView(
              slivers: [
                SliverToBoxAdapter(child: _buildHeader()),
                // The chips stay at the top while the list scrolls under.
                SliverPersistentHeader(
                  pinned: true,
                  delegate: _PinnedChips(
                    height: _hasChips(kinds) ? 60 : 8,
                    child: _buildChips(kinds),
                  ),
                ),
                // Liked and Recently played lead the list, pinned.
                if (!offlineMode.value &&
                    (_filter == null || _filter == 'playlist'))
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    sliver: SliverList.list(children: _buildPinnedSongs()),
                  ),
                if (ranks != null)
                  SliverList.builder(
                    itemCount: ranks.length,
                    itemBuilder: (context, i) => _buildRank(ranks, i),
                  )
                else
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    sliver: SliverList.builder(
                      itemCount: shown.length,
                      itemBuilder: (context, i) => _buildEntry(shown[i], i),
                    ),
                  ),
                const SliverMiniPlayerBottomSpace(),
              ],
            );
          },
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Muzika: one flat list (pinned first), filtered by a chip
  // ---------------------------------------------------------------------------

  /// `playlist`, `album` or `artist`; null shows everything.
  String? _filter;

  /// Playlists added from YouTube, read once and again when they change.
  List _added = const [];

  @override
  void initState() {
    super.initState();
    userPlaylists.addListener(_loadAdded);
    _loadAdded();
  }

  @override
  void dispose() {
    userPlaylists.removeListener(_loadAdded);
    super.dispose();
  }

  void _loadAdded() {
    if (offlineMode.value || userPlaylists.value.isEmpty) {
      if (_added.isNotEmpty && mounted) setState(() => _added = const []);
      return;
    }
    unawaited(
      getUserPlaylistsNotInFolders().then((list) {
        if (mounted) setState(() => _added = list);
      }),
    );
  }

  String _kindOf(Map p) {
    if (PlaylistUtils.isFolder(p)) return 'folder';
    if (p['source']?.toString() == 'youtube-artist' || isArtistPlaylist(p)) {
      return 'artist';
    }
    if (p['isAlbum'] == true || '${p['ytid']}'.startsWith('MPRE')) {
      return 'album';
    }
    return 'playlist';
  }

  List<_LibraryEntry> _entries() {
    final isOffline = offlineMode.value;
    final offlinePlaylists = offlinePlaylistService.offlinePlaylists.value
        .where((p) => p is Map && !PlaylistUtils.isArtistPlaylist(p))
        .toList();
    final folders = isOffline
        ? userPlaylistFolders.value
              .where(PlaylistUtils.folderHasOfflinePlaylists)
              .toList()
        : userPlaylistFolders.value;
    final offlineNotInFolders =
        PlaylistUtils.filterOfflinePlaylistsNotInFolders(
          offlinePlaylists,
          folders,
        );
    final custom = PlaylistUtils.excludePlaylistsWithIds(
      getPlaylistsNotInFolders(),
      PlaylistUtils.offlinePlaylistIdsNotInFolders(offlinePlaylists, folders),
    );

    final out = <_LibraryEntry>[];
    final ids = <String>{};
    void add(Map p, {bool removable = false, bool offline = false}) {
      final id = '${p['ytid'] ?? p['id'] ?? p['name']}';
      if (!ids.add(id)) return;
      out.add(_LibraryEntry(p, _kindOf(p), removable, offline));
    }

    for (final f in folders.whereType<Map>()) {
      add(f, removable: true);
    }
    // Newest first: what you added last is at the top (pinned ones stay
    // above everything).
    for (final p in custom.whereType<Map>().toList().reversed) {
      final source = p['source'];
      add(p, removable: source == 'user-created' || source == 'user-youtube');
    }
    for (final p in offlineNotInFolders.whereType<Map>()) {
      add(p, removable: true, offline: true);
    }
    if (!isOffline) {
      for (final p in _added.whereType<Map>().toList().reversed) {
        add(p, removable: true);
      }
      for (final p in getLikedPlaylistItems().reversed) {
        add(p);
      }
    }
    for (final p in getLikedArtistItems(offlineOnly: isOffline)) {
      add(p);
    }

    // Pinned first, in the order they were pinned.
    final pinned = pinnedPlaylistIds.value;
    int rank(_LibraryEntry e) {
      final i = pinned.indexOf('${e.data['ytid']}');
      return i == -1 ? pinned.length : i;
    }

    final indexed = out.indexed.toList()
      ..sort((a, b) {
        final r = rank(a.$2).compareTo(rank(b.$2));
        return r != 0 ? r : a.$1.compareTo(b.$1);
      });
    return [for (final (_, e) in indexed) e];
  }

  Widget _buildHeader() {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 8, 8),
      child: Row(
        children: [
          const SettingsIconButton(),
          Expanded(
            child: Text(
              context.l10n!.library,
              style: muzikaHeading(29, color: scheme.onSurface),
            ),
          ),
          IconButton(
            onPressed: () => openLikedSongsTransfer(context),
            icon: Icon(Icons.qr_code_2_rounded, color: scheme.onSurface),
            tooltip: 'Sync library',
          ),
          if (!offlineMode.value) ...[
            IconButton(
              onPressed: _showCreateFolderSheet,
              icon: Icon(
                Icons.create_new_folder_outlined,
                color: scheme.onSurface,
              ),
              tooltip: context.l10n!.createFolder,
            ),
            IconButton(
              onPressed: _showCreatePlaylistSheet,
              icon: Icon(Icons.playlist_add_rounded, color: scheme.onSurface),
              tooltip: 'New playlist',
            ),
          ],
        ],
      ),
    );
  }

  /// Liked songs and Recently played as the first rows of the list, with
  /// the pin of pinned playlists.
  List<Widget> _buildPinnedSongs() {
    final scheme = Theme.of(context).colorScheme;
    Widget row(String title, List songs, IconData icon, String path) {
      final covers = [
        for (final s in songs.whereType<Map>())
          if ((s['lowResImage'] ?? s['image'])?.toString() case final String c
              when c.startsWith('http'))
            c,
      ];
      final cover = covers.toSet().length >= 4
          ? MuzikaMosaic(images: covers.take(4).toList(), size: 52, radius: 10)
          : Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: scheme.onSurface,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: scheme.surface),
            );
      return Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => context.push(path),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 14),
            child: Row(
              children: [
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    cover,
                    Positioned(
                      right: -3,
                      bottom: -3,
                      child: Container(
                        width: 20,
                        height: 20,
                        decoration: BoxDecoration(
                          color: scheme.onSurface,
                          shape: BoxShape.circle,
                          border: Border.all(color: scheme.surface, width: 2),
                        ),
                        child: Icon(
                          Icons.push_pin_rounded,
                          size: 11,
                          color: scheme.surface,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 15,
                          color: scheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        'Playlist · ${songs.length} songs',
                        style: TextStyle(
                          fontSize: 13,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return [
      row(
        context.l10n!.likedSongs,
        userLikedSongsList.value,
        Icons.favorite_rounded,
        '/library/userSongs/liked',
      ),
      row(
        context.l10n!.recentlyPlayed,
        userRecentlyPlayed.value,
        Icons.history_rounded,
        '/library/userSongs/recents',
      ),
    ];
  }

  bool _hasChips(Set<String> kinds) =>
      kinds.contains('playlist') ||
      kinds.contains('album') ||
      kinds.contains('artist') ||
      !SongBattles.isEmpty;

  Widget _buildChips(Set<String> kinds) {
    final scheme = Theme.of(context).colorScheme;
    final chips = [
      if (kinds.contains('playlist')) ('playlist', 'Playlists'),
      if (kinds.contains('album')) ('album', 'Albums'),
      if (kinds.contains('artist')) ('artist', 'Artists'),
      // Album matches rank every song they played.
      if (!SongBattles.isEmpty) ('ranks', 'Song ranks'),
    ];
    if (chips.isEmpty) return const SizedBox(height: 8);
    return SizedBox(
      height: 60,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        children: [
          for (final (kind, label) in chips)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Builder(
                builder: (context) {
                  final active = _filter == kind;
                  return AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    decoration: BoxDecoration(
                      color: active
                          ? scheme.onSurface
                          : scheme.surfaceContainer,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Material(
                      type: MaterialType.transparency,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(8),
                        onTap: () =>
                            setState(() => _filter = active ? null : kind),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                          child: Center(
                            child: Text(
                              label,
                              style: muzikaBody(
                                14,
                                weight: 600,
                                color: active
                                    ? scheme.surface
                                    : scheme.onSurface,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  /// A song in "Song ranks": its place (shared on equal wins) and wins.
  Widget _buildRank(
    List<({int rank, Map song, int wins, int rounds})> ranks,
    int i,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final r = ranks[i];
    final image = [r.song['lowResImage'], r.song['image']]
        .map((e) => '${e ?? ''}')
        .firstWhere((e) => e.startsWith('http'), orElse: () => '');
    return ListTile(
      contentPadding: const EdgeInsets.fromLTRB(20, 2, 20, 2),
      leading: SizedBox(
        width: 96,
        child: Row(
          children: [
            SizedBox(
              width: 36,
              child: Text(
                '${r.rank}',
                textAlign: TextAlign.center,
                style: muzikaHeading(18, color: scheme.onSurface),
              ),
            ),
            const SizedBox(width: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 48,
                height: 48,
                child: image.isEmpty
                    ? ColoredBox(color: scheme.surfaceContainerHigh)
                    : Image(
                        image: CachedNetworkImageProvider(image),
                        fit: BoxFit.cover,
                      ),
              ),
            ),
          ],
        ),
      ),
      title: Text(
        '${r.song['title'] ?? ''}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: muzikaBody(15, weight: 600, color: scheme.onSurface),
      ),
      subtitle: Text(
        '${r.song['artist'] ?? ''}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: muzikaBody(13, color: scheme.onSurfaceVariant),
      ),
      trailing: Text(
        r.wins == 1 ? '1 win' : '${r.wins} wins',
        style: muzikaBody(13, weight: 600, color: scheme.onSurfaceVariant),
      ),
      onTap: () => audioHandler.addPlaylistToQueue(
        [for (final x in ranks) x.song],
        replace: true,
        startIndex: i,
      ),
    );
  }

  Widget _buildEntry(_LibraryEntry e, int index) {
    final p = e.data;
    if (e.kind == 'folder') {
      return PlaylistBar(
        p['name'],
        playlistData: p,
        background: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        onDelete: () => _showDeleteFolderDialog(p),
      );
    }
    final count = (p['list'] as List?)?.length;
    final subtitle = switch (e.kind) {
      'artist' => 'Artist',
      'album' => [
        'Album',
        p['artist']?.toString(),
      ].whereType<String>().where((s) => s.isNotEmpty).join(' · '),
      _ => count == null ? 'Playlist' : 'Playlist · $count songs',
    };
    final isArtist = e.kind == 'artist';
    return PlaylistBar(
      key: listItemKey('library_playlist', index, p),
      p['title'],
      playlistId: p['ytid'],
      playlistArtwork: p['image'],
      cubeIcon: isArtist
          ? Icons.person_outline_rounded
          : Icons.queue_music_rounded,
      isAlbum: isArtist ? false : p['isAlbum'],
      playlistData:
          isArtist ||
              p['source'] == 'user-created' ||
              p['source'] == 'user-youtube' ||
              e.offline
          ? p
          : null,
      subtitle: subtitle,
      background: Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      onDelete: e.removable
          ? () => e.offline
                ? _showRemoveOfflinePlaylistDialog(p)
                : _showRemovePlaylistDialog(p)
          : null,
    );
  }

  void _showRemoveOfflinePlaylistDialog(Map playlist) {
    final playlistId = playlist['ytid']?.toString() ?? '';
    if (playlistId.isEmpty) return;
    showRemoveOfflinePlaylistDialog(context, playlistId);
  }

  /// Out of the library at once; its downloaded copy (if any) is erased
  /// only once the Undo bar has gone.
  void _showRemovePlaylistDialog(Map playlist) {
    final playlistId = playlist['ytid']?.toString() ?? '';
    if (playlistId.isEmpty) {
      logger.log('Playlist ID is missing, cannot remove playlist.');
      showToast(context, context.l10n!.error);
      return;
    }
    final restore = keepLibraryForUndo();
    removeUserPlaylistEntry(playlist);
    doWithUndo(
      context,
      'Playlist removed',
      undo: restore,
      commit: () async {
        if (offlinePlaylistService.isPlaylistDownloaded(playlistId)) {
          await offlinePlaylistService.removeOfflinePlaylist(playlistId);
        }
      },
    );
  }

  void _showCreateFolderSheet() => showMuzikaNameSheet(
    context,
    title: context.l10n!.createFolder,
    hint: context.l10n!.folderName,
    onSubmit: (name) => showToast(context, createPlaylistFolder(name, context)),
  );

  void _showCreatePlaylistSheet() => showMuzikaNameSheet(
    context,
    title: 'New playlist',
    hint: 'Playlist name',
    onSubmit: (name) => createCustomPlaylist(name, null, context),
  );

  void _showDeleteFolderDialog(Map folder) {
    final restore = keepLibraryForUndo();
    deletePlaylistFolder(folder['id'], context);
    doWithUndo(context, 'Folder deleted', undo: restore);
  }
}

/// The filter chips as a header that stays put, over the page's colour.
class _PinnedChips extends SliverPersistentHeaderDelegate {
  _PinnedChips({required this.height, required this.child});

  final double height;
  final Widget child;

  @override
  double get minExtent => height;

  @override
  double get maxExtent => height;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlaps) =>
      ColoredBox(color: Theme.of(context).colorScheme.surface, child: child);

  @override
  bool shouldRebuild(_PinnedChips old) => true;
}

class _LibraryEntry {
  const _LibraryEntry(this.data, this.kind, this.removable, this.offline);

  final Map data;

  /// `folder`, `playlist`, `album` or `artist`.
  final String kind;
  final bool removable;

  /// A downloaded copy (removing it removes the download).
  final bool offline;
}
