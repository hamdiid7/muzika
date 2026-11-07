/*
 *     Copyright (C) 2026 Valeri Gokadze
 *     Rewritten for Muzika, 2026.
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
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:muzika/widgets/settings_icon_button.dart';
import 'package:muzika/main.dart' show audioHandler;
import 'package:muzika/screens/onboarding_page.dart';
import 'package:muzika/screens/search_page.dart' show pendingSearchQuery;
import 'package:muzika/screens/playlist_page.dart';
import 'package:muzika/services/common_services.dart';
import 'package:muzika/services/desktop_panels.dart';
import 'package:muzika/services/muzika_home.dart';
import 'package:muzika/services/playlists_manager.dart';
import 'package:muzika/services/router_service.dart';
import 'package:muzika/services/tunnel_service.dart';
import 'package:muzika/theme/muzika_tokens.dart';
import 'package:muzika/utilities/image_size.dart';
import 'package:muzika/utilities/playlist_dialogs.dart';
import 'package:muzika/widgets/mini_player_bottom_space.dart';
import 'package:muzika/widgets/muzika_mosaic.dart';
import 'package:muzika/widgets/muzika_shimmer.dart';
import 'package:muzika/widgets/muzika_song_actions.dart';
import 'package:muzika/widgets/muzika_song_row.dart';
import 'package:muzika/widgets/playlist_page/download_button.dart';
import 'package:muzika/widgets/shelf_arrows.dart';
import 'package:muzika/widgets/song_rows_shelf.dart';
import 'package:muzika/widgets/story_row.dart';

/// Home: chips that follow the user's taste, a grid of what they play most,
/// "Or listen again", "For you" and radio mixes.
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late Future<List<Map>> _forYou = forYouSongs();
  late Future<List<HomeRadio>> _radios = homeRadios();
  late Future<List<DailyMix>> _mixes = dailyMixes();
  late Future<List<Map>> _newReleases = newReleaseSongs();
  late Future<List<HomeStory>> _stories = homeStories();

  /// The grid fills in its new picks as For you and the playlists arrive.
  late Future<void> _gridReady = Future.wait([_forYou, _radios]);
  HomeChip? _chip;
  Future<List<Map>>? _chipSongs;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) maybeShowOnboarding(context);
    });
  }

  Future<void> _refresh() async {
    setState(() {
      _forYou = forYouSongs();
      _radios = homeRadios();
      _mixes = dailyMixes();
      _newReleases = newReleaseSongs();
      _stories = homeStories();
      _gridReady = Future.wait([_forYou, _radios]);
      if (_chip != null) _chipSongs = chipSongs(_chip!);
    });
    await Future.wait([_forYou, _radios]);
  }

  void _selectChip(HomeChip chip) {
    setState(() {
      if (_chip?.label == chip.label) {
        _chip = null;
        _chipSongs = null;
      } else {
        recordChipTap(chip);
        _chip = chip;
        _chipSongs = chipSongs(chip);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          onRefresh: _refresh,
          child: AnimatedBuilder(
            animation: Listenable.merge([
              userRecentlyPlayed,
              userCustomPlaylists,
              userLikedSongsList,
            ]),
            builder: (context, _) {
              final grid = forYouGrid();
              final gridSongIds = {
                for (final t in grid)
                  if (t.kind == 'song') t.id,
              };
              // Five, so Home stays short.
              final again = listenAgain(exclude: gridSongIds).take(5).toList();
              final isNew = grid.isEmpty && again.isEmpty;
              return CustomScrollView(
                slivers: [
                  const SliverToBoxAdapter(child: _Header()),
                  // New music videos, as Instagram's stories.
                  SliverToBoxAdapter(child: StoryRow(future: _stories)),
                  // Once a chip is picked the row stays on top while you
                  // scroll its mix, so switching is one tap away.
                  SliverPersistentHeader(
                    pinned: _chip != null,
                    delegate: _ChipsHeader(
                      chips: homeChips(),
                      selected: _chip?.label,
                      onTap: _selectChip,
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 250),
                      switchInCurve: Curves.easeOutCubic,
                      child: _chip != null
                          ? _ChipMix(
                              key: ValueKey(_chip!.label),
                              chip: _chip!,
                              future: _chipSongs!,
                            )
                          : Column(
                              key: const ValueKey('feed'),
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (isNew)
                                  _EmptyState(
                                    onCreatePlaylist: () =>
                                        showCreatePlaylistDialog(context),
                                  ),
                                // Half the grid is what you play, half is new
                                // to you (once For you has found it).
                                FutureBuilder<void>(
                                  future: _gridReady,
                                  builder: (context, _) {
                                    final tiles = homeGrid();
                                    if (tiles.isEmpty) {
                                      return const SizedBox.shrink();
                                    }
                                    return _ForYouGrid(tiles: tiles);
                                  },
                                ),
                                // Spotify-style mixes of your artists.
                                _DailyMixes(future: _mixes),
                                if (again.isNotEmpty) ...[
                                  const _SectionTitle('Or listen again'),
                                  for (final (i, song) in again.indexed)
                                    MuzikaSongRow(
                                      song: song,
                                      queue: again,
                                      index: i,
                                    ),
                                ],
                                // Only what relates to what you play; no
                                // shelf at all when none of it does.
                                _NewReleases(future: _newReleases),
                                _ForYouSongs(future: _forYou),
                                _Radios(future: _radios),
                              ],
                            ),
                    ),
                  ),
                  const SliverToBoxAdapter(child: SizedBox(height: 12)),
                  const SliverToBoxAdapter(child: MiniPlayerBottomSpace()),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // The wide Windows layout: no title (the window has it), and search is
    // an icon here beside the ring rather than in the sidebar.
    return ValueListenableBuilder<bool>(
      valueListenable: desktopPanels,
      builder: (context, desktop, _) => Padding(
        // 20 on the left, like every shelf below it.
        padding: const EdgeInsets.fromLTRB(20, 12, 12, 4),
        child: Row(
          children: [
            const SettingsIconButton(),
            if (!desktop) ...[
              Text('Muzika', style: muzikaHeading(29, color: scheme.onSurface)),
              const SizedBox(width: 10),
            ],
            const _TunnelBadge(),
            const Spacer(),
            if (desktop) ...[
              Tooltip(
                message: 'Search',
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () {
                    // Straight to typing.
                    pendingSearchQuery.value = '';
                    context.go(NavigationManager.searchPath);
                  },
                  child: CircleAvatar(
                    radius: 22,
                    backgroundColor: scheme.surfaceContainerHigh,
                    child: Icon(
                      FluentIcons.search_24_regular,
                      size: 20,
                      color: scheme.onSurface,
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Small pill that only shows while the tunnel is not ready, so users know
/// why the first search may take a moment.
class _TunnelBadge extends StatelessWidget {
  const _TunnelBadge();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ValueListenableBuilder<TunnelState>(
      valueListenable: TunnelService.instance.state,
      builder: (context, state, _) {
        final label = switch (state.status) {
          TunnelStatus.connecting => 'Connecting…',
          TunnelStatus.error => 'Offline',
          _ => null,
        };
        if (label == null) return const SizedBox.shrink();
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: scheme.surfaceContainer,
            borderRadius: BorderRadius.circular(100),
          ),
          child: Text(
            label,
            style: muzikaBody(12, weight: 500, color: scheme.onSurfaceVariant),
          ),
        );
      },
    );
  }
}

class _ChipsHeader extends SliverPersistentHeaderDelegate {
  _ChipsHeader({
    required this.chips,
    required this.selected,
    required this.onTap,
  });

  final List<HomeChip> chips;
  final String? selected;
  final ValueChanged<HomeChip> onTap;

  @override
  double get minExtent => 64;
  @override
  double get maxExtent => 64;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlaps) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      decoration: BoxDecoration(
        color: scheme.surface,
        boxShadow: overlaps
            ? [
                BoxShadow(
                  color: scheme.shadow.withValues(alpha: 0.08),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ]
            : null,
      ),
      child: _Chips(chips: chips, selected: selected, onTap: onTap),
    );
  }

  @override
  bool shouldRebuild(_ChipsHeader old) =>
      old.selected != selected || old.chips != chips;
}

class _Chips extends StatelessWidget {
  const _Chips({
    required this.chips,
    required this.selected,
    required this.onTap,
  });

  final List<HomeChip> chips;
  final String? selected;
  final ValueChanged<HomeChip> onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 64,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
        itemCount: chips.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final chip = chips[i];
          final active = chip.label == selected;
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
                onTap: () => onTap(chip),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        chip.label,
                        style: muzikaBody(
                          14,
                          weight: 600,
                          color: active ? scheme.surface : scheme.onSurface,
                        ),
                      ),
                      // The picked chip shows a small x; tapping it (or the
                      // chip) goes back to the feed.
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
}

/// What a selected chip shows instead of the feed.
class _ChipMix extends StatelessWidget {
  const _ChipMix({super.key, required this.chip, required this.future});

  final HomeChip chip;
  final Future<List<Map>> future;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return FutureBuilder<List<Map>>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const MuzikaSkeletonRows();
        }
        final songs = snapshot.data ?? const <Map>[];
        if (songs.isEmpty) {
          return Padding(
            padding: const EdgeInsets.all(32),
            child: Text(
              'Couldn’t load ${chip.label} right now. Pull to retry.',
              textAlign: TextAlign.center,
              style: muzikaBody(15, color: scheme.onSurfaceVariant),
            ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      chip.seed != null ? '${chip.label} Radio' : chip.label,
                      style: muzikaHeading(24, color: scheme.onSurface),
                    ),
                  ),
                  MuzikaRoundButton(
                    icon: FluentIcons.arrow_shuffle_24_regular,
                    tooltip: 'Shuffle',
                    onPressed: () => audioHandler.addPlaylistToQueue(
                      songs,
                      replace: true,
                      shuffle: true,
                    ),
                  ),
                  const SizedBox(width: 8),
                  MuzikaRoundButton(
                    icon: FluentIcons.play_24_filled,
                    filled: true,
                    tooltip: 'Play',
                    onPressed: () =>
                        audioHandler.addPlaylistToQueue(songs, replace: true),
                  ),
                ],
              ),
            ),
            for (final (i, song) in songs.indexed)
              MuzikaSongRow(song: song, queue: songs, index: i),
          ],
        );
      },
    );
  }
}

/// "Made for you": a Daily Mix per favourite artist, as on Spotify: the
/// artist's photo with the mix's tag and number, the artists in it below.
/// A tap opens the mix as a playlist.
class _DailyMixes extends StatelessWidget {
  const _DailyMixes({required this.future});

  final Future<List<DailyMix>> future;

  static const _card = 150.0;

  /// One colour per mix, as Spotify's.
  static const _colors = [
    Color(0xFF2BD96B),
    Color(0xFFF2E23A),
    Color(0xFFFF5A36),
    Color(0xFF52A8FF),
  ];

  /// Opens at once: the mix's page with placeholder rows, its songs in as
  /// soon as they're picked.
  Future<void> _open(BuildContext context, DailyMix mix) => Navigator.of(
    context,
  ).push(MaterialPageRoute<void>(builder: (_) => _DailyMixPage(mix: mix)));

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return FutureBuilder<List<DailyMix>>(
      future: future,
      builder: (context, snapshot) {
        final mixes = snapshot.data ?? const <DailyMix>[];
        if (mixes.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _SectionTitle('Made for you'),
            SizedBox(
              height: _card + 64,
              child: ShelfArrows(
                pictureHeight: _card,
                builder: (controller) => ListView.separated(
                  controller: controller,
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  itemCount: mixes.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 14),
                  itemBuilder: (context, i) {
                    final mix = mixes[i];
                    final color = _colors[i % _colors.length];
                    return SizedBox(
                      width: _card,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(8),
                        onTap: () => _open(context, mix),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: SizedBox(
                                width: _card,
                                height: _card,
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    if (mix.photo == null)
                                      ColoredBox(
                                        color: scheme.surfaceContainerHigh,
                                      )
                                    else
                                      CachedNetworkImage(
                                        // The card's size, not 1000 px.
                                        imageUrl: sizedImageUrl(
                                          mix.photo!,
                                          _DailyMixes._card *
                                              MediaQuery.devicePixelRatioOf(
                                                context,
                                              ),
                                        ),
                                        fit: BoxFit.cover,
                                      ),
                                    // The mix's colour along the bottom.
                                    Align(
                                      alignment: Alignment.bottomCenter,
                                      child: Container(height: 6, color: color),
                                    ),
                                    Positioned(
                                      left: 8,
                                      right: 8,
                                      bottom: 12,
                                      child: Row(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.end,
                                        children: [
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 5,
                                              vertical: 2,
                                            ),
                                            color: color,
                                            child: Text(
                                              'Daily Mix',
                                              style: muzikaBody(
                                                12,
                                                weight: 700,
                                                color: Colors.black,
                                              ),
                                            ),
                                          ),
                                          const Spacer(),
                                          Text(
                                            mix.number.toString().padLeft(
                                              2,
                                              '0',
                                            ),
                                            style:
                                                muzikaHeading(
                                                  30,
                                                  weight: 800,
                                                  color: color,
                                                ).copyWith(
                                                  height: 1,
                                                  shadows: const [
                                                    Shadow(
                                                      color: Color(0xAA000000),
                                                      blurRadius: 6,
                                                    ),
                                                  ],
                                                ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              mix.subtitle,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: muzikaBody(
                                13,
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
            ),
          ],
        );
      },
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 6),
      child: Text(
        text,
        style: muzikaHeading(
          24,
          color: Theme.of(context).colorScheme.onSurface,
        ),
      ),
    );
  }
}

/// Two columns of compact tiles: artists, albums, playlists and songs the
/// user plays most.
class _ForYouGrid extends StatelessWidget {
  const _ForYouGrid({required this.tiles});

  final List<HomeTile> tiles;

  void _open(BuildContext context, HomeTile tile) {
    switch (tile.kind) {
      case 'artist':
        openArtistFor(context, tile.data ?? {'artist': tile.title});
      case 'album' || 'playlist':
        context.push('/home/playlist/${Uri.encodeComponent(tile.id)}');
      case 'liked':
        context.push('/home/userSongs/liked');
      default:
        if (tile.data != null) {
          unawaited(
            audioHandler.addPlaylistToQueue([tile.data!], replace: true),
          );
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
      child: GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        padding: EdgeInsets.zero,
        itemCount: tiles.length,
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          mainAxisExtent: 60,
        ),
        itemBuilder: (context, i) {
          final tile = tiles[i];
          final round = tile.kind == 'artist';
          return Material(
            color: scheme.surfaceContainer,
            borderRadius: BorderRadius.circular(10),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => _open(context, tile),
              onLongPress: tile.kind == 'song' && tile.data != null
                  ? () => showSongOptions(context, tile.data!)
                  : null,
              // Right-click (Windows) does what a long press does.
              onSecondaryTap: tile.kind == 'song' && tile.data != null
                  ? () => showSongOptions(context, tile.data!)
                  : null,
              child: Row(
                children: [
                  if (tile.kind == 'liked')
                    Container(
                      width: 60,
                      height: 60,
                      color: scheme.onSurface,
                      child: Icon(
                        FluentIcons.heart_24_filled,
                        color: scheme.surface,
                      ),
                    )
                  else if (tile.image == null && tile.images.isNotEmpty)
                    MuzikaMosaic(images: tile.images, size: 60, radius: 0)
                  else
                    Padding(
                      padding: EdgeInsets.all(round ? 6 : 0),
                      child: MuzikaCover(
                        song: {'image': tile.image, 'lowResImage': tile.image},
                        size: round ? 48 : 60,
                        radius: round ? 24 : 0,
                      ),
                    ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          tile.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: muzikaBody(
                            13.5,
                            weight: 700,
                            color: scheme.onSurface,
                          ).copyWith(height: 1.15),
                        ),
                        Text(
                          tile.subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: muzikaBody(
                            11.5,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _ForYouSongs extends StatelessWidget {
  const _ForYouSongs({required this.future});

  final Future<List<Map>> future;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Map>>(
      future: future,
      builder: (context, snapshot) {
        final songs = snapshot.data ?? const <Map>[];
        if (snapshot.connectionState != ConnectionState.done && songs.isEmpty) {
          return const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [_SectionTitle('For you'), MuzikaSkeletonRows(count: 4)],
          );
        }
        if (songs.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _SectionTitle('For you'),
            for (final (i, song) in songs.indexed)
              MuzikaSongRow(song: song, queue: songs, index: i),
          ],
        );
      },
    );
  }
}

/// Radio mixes as cards sliding sideways; each cover is a 2×2 grid of four
/// of its songs.
class _Radios extends StatelessWidget {
  const _Radios({required this.future});

  final Future<List<HomeRadio>> future;

  void _openRadio(BuildContext context, HomeRadio radio) {
    unawaited(
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => PlaylistPage(
            playlistData: {
              'ytid': radio.playlistId ?? 'home_${radio.title}',
              'title': radio.title,
              'image':
                  radio.songs.first['highResImage'] ??
                  radio.songs.first['image'],
              'list': radio.songs,
            },
          ),
        ),
      ),
    );
  }

  static const _card = 150.0;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return FutureBuilder<List<HomeRadio>>(
      future: future,
      builder: (context, snapshot) {
        final radios = snapshot.data ?? const <HomeRadio>[];
        if (radios.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _SectionTitle('Playlists to discover'),
            SizedBox(
              height: _card + 64,
              child: ShelfArrows(
                pictureHeight: _card,
                builder: (controller) => ListView.separated(
                  controller: controller,
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  itemCount: radios.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 14),
                  itemBuilder: (context, i) {
                    final radio = radios[i];
                    return SizedBox(
                      width: _card,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        // A tap opens the playlist; its ▶ plays it.
                        onTap: () => _openRadio(context, radio),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Stack(
                              children: [
                                MuzikaMosaic(
                                  images: [
                                    for (final s in radio.songs.take(4))
                                      ?(s['lowResImage'] ?? s['image'])
                                          ?.toString(),
                                  ],
                                  size: _card,
                                  radius: 12,
                                ),
                                if (radio.playlistId != null)
                                  Positioned(
                                    right: 6,
                                    top: 6,
                                    child: DecoratedBox(
                                      decoration: BoxDecoration(
                                        color: scheme.surface.withValues(
                                          alpha: 0.9,
                                        ),
                                        shape: BoxShape.circle,
                                      ),
                                      child: PlaylistDownloadButton(
                                        playlistId: radio.playlistId!,
                                        compact: true,
                                        songs: radio.songs,
                                        resolvePlaylist: () async => {
                                          'ytid': radio.playlistId,
                                          'title': radio.title,
                                          'image':
                                              radio
                                                  .songs
                                                  .first['highResImage'] ??
                                              radio.songs.first['image'],
                                          'list': radio.songs,
                                        },
                                      ),
                                    ),
                                  ),
                                Positioned(
                                  right: 8,
                                  bottom: 8,
                                  child: Material(
                                    color: scheme.surface,
                                    shape: const CircleBorder(),
                                    child: InkWell(
                                      customBorder: const CircleBorder(),
                                      onTap: () =>
                                          audioHandler.addPlaylistToQueue(
                                            radio.songs,
                                            replace: true,
                                          ),
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
                              radio.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: muzikaBody(
                                14,
                                weight: 700,
                                color: scheme.onSurface,
                              ),
                            ),
                            Text(
                              radio.subtitle,
                              maxLines: 2,
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
            ),
          ],
        );
      },
    );
  }
}

/// New songs by the user's artists and artists like them, in two rows
/// sliding sideways; ⋮ beside each opens its options. Left out while it
/// loads and when there are none.
class _NewReleases extends StatelessWidget {
  const _NewReleases({required this.future});

  final Future<List<Map>> future;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Map>>(
      future: future,
      builder: (context, snapshot) {
        final songs = snapshot.data ?? const <Map>[];
        if (songs.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _SectionTitle('New releases for you'),
            // Who it's by, and when it came out (or which of the user's
            // artists it's like).
            SongRowsShelf(
              songs: songs,
              subtitle: (song, _) {
                final because = song['because'];
                // Why it's here, in plain words.
                final when = because == null
                    ? 'Your artist'
                    : 'Because you play $because';
                return [
                  '${song['artist'] ?? ''}',
                  if (when.isNotEmpty) when,
                ].join(' · ');
              },
            ),
          ],
        );
      },
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onCreatePlaylist});

  final VoidCallback onCreatePlaylist;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 12, 32, 8),
      child: Column(
        children: [
          Text(
            'Welcome to Muzika',
            style: muzikaHeading(24, color: scheme.onSurface),
          ),
          const SizedBox(height: 8),
          Text(
            'Play a few songs and this page fills with your artists, albums '
            'and mixes. Here is what people near you are listening to.',
            textAlign: TextAlign.center,
            style: muzikaBody(15, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 14),
          OutlinedButton(
            style: OutlinedButton.styleFrom(
              foregroundColor: scheme.onSurface,
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
            ),
            onPressed: onCreatePlaylist,
            child: Text(
              'Create a playlist',
              style: muzikaBody(15, weight: 700),
            ),
          ),
        ],
      ),
    );
  }
}

/// A Daily Mix while its songs are picked: its cover, name and artists and
/// placeholder rows, then the playlist itself.
class _DailyMixPage extends StatefulWidget {
  const _DailyMixPage({required this.mix});

  final DailyMix mix;

  @override
  State<_DailyMixPage> createState() => _DailyMixPageState();
}

class _DailyMixPageState extends State<_DailyMixPage> {
  late final Future<List<Map>> _songs = dailyMixSongs(widget.mix);

  @override
  Widget build(BuildContext context) {
    final mix = widget.mix;
    final scheme = Theme.of(context).colorScheme;
    return FutureBuilder<List<Map>>(
      future: _songs,
      builder: (context, snapshot) {
        final songs = snapshot.data;
        if (songs != null && songs.isNotEmpty) {
          return PlaylistPage(
            playlistData: {
              'ytid': 'dailymix_${mix.number}_${mix.artist}',
              'title': mix.title,
              'image': mix.photo,
              'list': songs,
            },
          );
        }
        final failed =
            snapshot.connectionState == ConnectionState.done &&
            (songs == null || songs.isEmpty);
        return Scaffold(
          appBar: AppBar(),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
            children: [
              Center(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: SizedBox(
                    width: 220,
                    height: 220,
                    child: mix.photo == null
                        ? ColoredBox(color: scheme.surfaceContainerHigh)
                        : CachedNetworkImage(
                            imageUrl: mix.photo!,
                            fit: BoxFit.cover,
                          ),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Text(
                mix.title,
                style: muzikaHeading(26, color: scheme.onSurface),
              ),
              const SizedBox(height: 4),
              Text(
                mix.subtitle,
                style: muzikaBody(14, color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 18),
              if (failed)
                Text(
                  "Couldn't make this mix right now. Check your connection "
                  'and try again.',
                  style: muzikaBody(14, color: scheme.onSurfaceVariant),
                )
              else
                const MuzikaSkeletonRows(count: 8),
            ],
          ),
        );
      },
    );
  }
}
