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

import 'package:audio_service/audio_service.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:muzika/main.dart' show audioHandler;
import 'package:muzika/screens/lyrics_page.dart';
import 'package:muzika/screens/now_playing_page.dart';
import 'package:muzika/services/common_services.dart';
import 'package:muzika/services/desktop_panels.dart';
import 'package:muzika/services/playlists_manager.dart';
import 'package:muzika/services/router_service.dart';
import 'package:muzika/theme/muzika_tokens.dart';
import 'package:muzika/widgets/muzika_nav_bar.dart';
import 'package:muzika/widgets/muzika_song_row.dart';
import 'package:muzika/widgets/playlist_bar.dart';

/// The Windows layout when the window is wide (Muzika): the tabs down the
/// left, the page in the middle, and the player always open on the right
/// (the lyrics, full height, when tapped).
class DesktopShell extends StatelessWidget {
  const DesktopShell({
    super.key,
    required this.current,
    required this.onSelect,
    required this.showSearch,
    required this.child,
  });

  final MuzikaTab? current;
  final ValueChanged<MuzikaTab> onSelect;
  final bool showSearch;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([desktopSidebarWidth, desktopPanelWidth]),
      builder: (context, _) => Row(
        children: [
          SizedBox(
            width: desktopSidebarWidth.value,
            child: _Sidebar(
              current: current,
              onSelect: (tab) {
                desktopLyricsOpen.value = false;
                onSelect(tab);
              },
              showSearch: showSearch,
            ),
          ),
          _DragLine(
            onDrag: (dx) =>
                desktopSidebarWidth.value = (desktopSidebarWidth.value + dx)
                    .clamp(desktopSidebarMin, desktopSidebarMax),
          ),
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [child, const _MiddleLyrics()],
            ),
          ),
          _DragLine(
            onDrag: (dx) =>
                desktopPanelWidth.value = (desktopPanelWidth.value - dx).clamp(
                  desktopPanelMin,
                  desktopPanelMax,
                ),
          ),
          SizedBox(
            width: desktopPanelWidth.value,
            child: const _Region(child: _PlayerPanel()),
          ),
        ],
      ),
    );
  }
}

/// The lyrics, in the song's colour, over the middle page once they're
/// tapped: they rise and fade in, and sink away again on the back arrow
/// (or Esc, or another tab).
class _MiddleLyrics extends StatelessWidget {
  const _MiddleLyrics();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: desktopLyricsOpen,
      builder: (context, open, _) => AnimatedSwitcher(
        duration: const Duration(milliseconds: 420),
        reverseDuration: const Duration(milliseconds: 280),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        transitionBuilder: (child, animation) => FadeTransition(
          opacity: animation,
          child: SlideTransition(
            position: Tween(
              begin: const Offset(0, 0.06),
              end: Offset.zero,
            ).animate(animation),
            child: ScaleTransition(
              scale: Tween<double>(begin: 0.97, end: 1).animate(animation),
              child: child,
            ),
          ),
        ),
        child: open ? const _LyricsView() : const SizedBox.shrink(),
      ),
    );
  }
}

class _LyricsView extends StatelessWidget {
  const _LyricsView();

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            desktopLyricsOpen.value = false,
      },
      child: Focus(
        autofocus: true,
        child: ColoredBox(
          color: Theme.of(context).colorScheme.surface,
          child: Stack(
            children: [
              const Positioned.fill(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(12, 12, 12, 12),
                  child: LyricsPanel(),
                ),
              ),
              Positioned(
                top: 20,
                right: 24,
                child: IconButton.filledTonal(
                  tooltip: 'Close lyrics',
                  style: IconButton.styleFrom(
                    backgroundColor: Colors.black26,
                    foregroundColor: Colors.white,
                  ),
                  icon: const Icon(FluentIcons.dismiss_24_regular, size: 20),
                  onPressed: () => desktopLyricsOpen.value = false,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A part of the layout with its own navigator, so a sheet opened in it
/// (a song's menu, the queue) comes up there rather than over the window.
class _Region extends StatelessWidget {
  const _Region({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: Navigator(
        onGenerateRoute: (settings) => PageRouteBuilder<void>(
          settings: settings,
          pageBuilder: (_, _, _) => child,
        ),
      ),
    );
  }
}

/// The line between two parts of the layout: drag it to make them wider or
/// narrower.
class _DragLine extends StatefulWidget {
  const _DragLine({required this.onDrag});

  final ValueChanged<double> onDrag;

  @override
  State<_DragLine> createState() => _DragLineState();
}

class _DragLineState extends State<_DragLine> {
  bool _hot = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      onEnter: (_) => setState(() => _hot = true),
      onExit: (_) => setState(() => _hot = false),
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragUpdate: (d) => widget.onDrag(d.delta.dx),
        onHorizontalDragEnd: (_) => saveDesktopWidths(),
        child: SizedBox(
          width: 7,
          child: Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: _hot ? 3 : 1,
              color: _hot
                  ? scheme.onSurface.withValues(alpha: 0.5)
                  : scheme.outlineVariant.withValues(alpha: 0.5),
            ),
          ),
        ),
      ),
    );
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.current,
    required this.onSelect,
    required this.showSearch,
  });

  final MuzikaTab? current;
  final ValueChanged<MuzikaTab> onSelect;
  final bool showSearch;

  static const _tabs = [
    (
      MuzikaTab.home,
      'Home',
      FluentIcons.home_24_regular,
      FluentIcons.home_24_filled,
    ),
    (
      MuzikaTab.search,
      'Search',
      FluentIcons.search_24_regular,
      FluentIcons.search_24_filled,
    ),
    (
      MuzikaTab.discover,
      'Clips',
      FluentIcons.video_clip_24_regular,
      FluentIcons.video_clip_24_filled,
    ),
    (
      MuzikaTab.library,
      'Library',
      FluentIcons.library_24_regular,
      FluentIcons.library_24_filled,
    ),
    (
      MuzikaTab.offline,
      'Offline',
      FluentIcons.arrow_download_24_regular,
      FluentIcons.arrow_download_24_filled,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final compact = desktopSidebarWidth.value < desktopSidebarCompact;
    Widget item(
      MuzikaTab tab,
      String label,
      IconData icon,
      IconData activeIcon,
    ) {
      final active = tab == current;
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
        child: Material(
          color: active ? scheme.onSurface : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => onSelect(tab),
            child: Tooltip(
              message: compact ? label : '',
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 11,
                ),
                child: Row(
                  mainAxisAlignment: compact
                      ? MainAxisAlignment.center
                      : MainAxisAlignment.start,
                  children: [
                    Icon(
                      active ? activeIcon : icon,
                      size: 22,
                      color: active ? scheme.surface : scheme.onSurfaceVariant,
                    ),
                    if (!compact) ...[
                      const SizedBox(width: 14),
                      Expanded(
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.clip,
                          softWrap: false,
                          style: muzikaBody(
                            15,
                            weight: active ? 700 : 500,
                            color: active ? scheme.surface : scheme.onSurface,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    return SafeArea(
      right: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 16),
          for (final (tab, label, icon, active) in _tabs)
            if (tab != MuzikaTab.search || showSearch)
              item(tab, label, icon, active),
          Expanded(
            child: compact
                ? const _PinnedIcons()
                : const Column(
                    children: [
                      Expanded(child: _Region(child: _SidebarLibrary())),
                      Expanded(child: _Region(child: _RecentSongs())),
                    ],
                  ),
          ),
          item(
            MuzikaTab.settings,
            'Settings',
            FluentIcons.settings_24_regular,
            FluentIcons.settings_24_filled,
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}

/// The player, full height.
class _PlayerPanel extends StatelessWidget {
  const _PlayerPanel();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return StreamBuilder<MediaItem?>(
      stream: audioHandler.mediaItem,
      initialData: audioHandler.mediaItem.valueOrNull,
      builder: (context, snapshot) {
        if (snapshot.data == null) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Text(
                'Play a song and it shows here, with its lyrics.',
                textAlign: TextAlign.center,
                style: muzikaBody(14, color: scheme.onSurfaceVariant),
              ),
            ),
          );
        }
        return const NowPlayingPage(embedded: true);
      },
    );
  }
}

/// Recently played songs under the tabs; tap one to play from there.
class _RecentSongs extends StatelessWidget {
  const _RecentSongs();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List>(
      valueListenable: userRecentlyPlayed,
      builder: (context, recent, _) {
        final songs = recent.whereType<Map>().take(30).toList();
        if (songs.isEmpty) return const SizedBox();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SidebarHeading(
              'Recently played',
              onTap: () => context.go('/library/userSongs/recents'),
            ),
            Expanded(
              child: ListView.builder(
                padding: EdgeInsets.zero,
                itemCount: songs.length,
                itemBuilder: (context, i) => MuzikaSongRow(
                  song: songs[i],
                  queue: songs,
                  index: i,
                  showAddButton: false,
                  showDownloadButton: false,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Your library, Spotify's way: Liked songs first, then your playlists,
/// albums and artists, newest first. Tap one to open it.
class _SidebarLibrary extends StatelessWidget {
  const _SidebarLibrary();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: Listenable.merge([
        userCustomPlaylists,
        userLikedPlaylists,
        userLikedSongsList,
        pinnedPlaylistIds,
      ]),
      builder: (context, _) {
        final seen = <String>{};
        final items = [
          for (final p in [
            ...resolvePinnedPlaylists(pinnedPlaylistIds.value),
            ...getPlaylistsNotInFolders().reversed,
            ...getLikedPlaylistItems().reversed,
            ...getLikedArtistItems(),
          ])
            if (seen.add('${p['ytid'] ?? p['title']}')) p,
        ];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SidebarHeading(
              'Your Library',
              onTap: () => context.go(NavigationManager.libraryPath),
            ),
            Expanded(
              child: ListView(
                padding: EdgeInsets.zero,
                children: [
                  _SidebarRow(
                    title: 'Liked Songs',
                    subtitle: '${userLikedSongsList.value.length} songs',
                    leading: DecoratedBox(
                      decoration: BoxDecoration(
                        color: scheme.onSurface,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Icon(
                        Icons.favorite_rounded,
                        size: 20,
                        color: scheme.surface,
                      ),
                    ),
                    onTap: () => context.go('/library/userSongs/liked'),
                  ),
                  for (final p in items)
                    PlaylistBar(
                      '${p['title'] ?? p['name'] ?? ''}',
                      playlistId: p['ytid']?.toString(),
                      playlistArtwork: p['image']?.toString(),
                      playlistData: p,
                      isAlbum: p['isAlbum'] == true,
                      cubeIcon: isArtistPlaylist(p)
                          ? Icons.person_outline_rounded
                          : Icons.queue_music_rounded,
                      subtitle: isArtistPlaylist(p)
                          ? 'Artist'
                          : p['isAlbum'] == true
                          ? 'Album'
                          : 'Playlist',
                      showBuildActions: false,
                      background: Colors.transparent,
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _SidebarHeading extends StatelessWidget {
  const _SidebarHeading(this.label, {this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(26, 18, 16, 6),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.clip,
          softWrap: false,
          style: muzikaBody(13, weight: 700, color: scheme.onSurfaceVariant),
        ),
      ),
    );
  }
}

class _SidebarRow extends StatelessWidget {
  const _SidebarRow({
    required this.title,
    required this.subtitle,
    required this.leading,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final Widget leading;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            SizedBox(width: 48, height: 48, child: leading),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: muzikaBody(15, weight: 600, color: scheme.onSurface),
                  ),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: muzikaBody(13, color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The narrow sidebar's library: Liked Songs and the pinned playlists,
/// albums and artists as covers (their names on hover).
class _PinnedIcons extends StatelessWidget {
  const _PinnedIcons();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget tile(
      String name,
      Widget cover,
      VoidCallback onTap, {
      bool round = false,
    }) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Tooltip(
          message: name,
          child: InkWell(
            onTap: onTap,
            customBorder: round
                ? const CircleBorder()
                : RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(round ? 24 : 8),
              child: SizedBox(width: 44, height: 44, child: cover),
            ),
          ),
        ),
      );
    }

    return AnimatedBuilder(
      animation: Listenable.merge([pinnedPlaylistIds, userLikedSongsList]),
      builder: (context, _) {
        final pinned = resolvePinnedPlaylists(pinnedPlaylistIds.value);
        return ListView(
          padding: const EdgeInsets.only(top: 14),
          children: [
            Center(
              child: tile(
                'Liked Songs',
                ColoredBox(
                  color: scheme.onSurface,
                  child: Icon(
                    Icons.favorite_rounded,
                    size: 20,
                    color: scheme.surface,
                  ),
                ),
                () => context.go('/library/userSongs/liked'),
              ),
            ),
            for (final p in pinned)
              if ('${p['ytid'] ?? ''}' case final id when id.isNotEmpty)
                Center(
                  child: tile(
                    '${p['title'] ?? p['name'] ?? ''}',
                    '${p['image'] ?? ''}'.startsWith('http')
                        ? CachedNetworkImage(
                            imageUrl: '${p['image']}',
                            fit: BoxFit.cover,
                            errorWidget: (_, _, _) =>
                                ColoredBox(color: scheme.surfaceContainerHigh),
                          )
                        : ColoredBox(
                            color: scheme.surfaceContainerHigh,
                            child: Icon(
                              Icons.queue_music_rounded,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                    () => isArtistPlaylist(p)
                        ? context.push(
                            NavigationManager.artistPath(context, id),
                            extra: p,
                          )
                        : context.push('/home/playlist/$id'),
                    round: isArtistPlaylist(p),
                  ),
                ),
          ],
        );
      },
    );
  }
}
