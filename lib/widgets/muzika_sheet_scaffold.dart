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

import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:material_ui/material_ui.dart';
import 'package:muzika/main.dart' show audioHandler;
import 'package:muzika/models/position_data.dart';
import 'package:muzika/screens/now_playing_page.dart';
import 'package:muzika/services/desktop_panels.dart';
import 'package:muzika/theme/muzika_tokens.dart';
import 'package:muzika/widgets/muzika_shimmer.dart';
import 'package:muzika/widgets/muzika_song_actions.dart';
import 'package:muzika/widgets/song_artwork.dart';

//// The layout every inner Muzika screen shares (Search, Artist, Album,
/// Playlist, Up Next…): the playing song on top, then a rounded sheet with a
/// handle that holds the screen's content.
///
/// The sheet follows the finger when dragged down by its handle or pulled
/// down past the top of its list, and slides away when released far or fast
/// enough. Back and the arrow beside the top player slide it away too.
class MuzikaSheetScaffold extends StatefulWidget {
  const MuzikaSheetScaffold({super.key, required this.child, this.onHandleTap});

  /// Usually a scroll view.
  final Widget child;

  /// What closing does once the sheet has slid away. Defaults to popping the
  /// route.
  final VoidCallback? onHandleTap;

  static final List<_MuzikaSheetScaffoldState> _mounted = [];

  /// Slides away the sheet currently on screen, if any, and returns whether
  /// one was found. The app shell uses it for Back on tab roots (Search),
  /// which the route itself never sees.
  static bool dismissVisible() {
    for (final state in _mounted.reversed) {
      if (state.mounted && state._isOnScreen) {
        unawaited(state.dismiss());
        return true;
      }
    }
    return false;
  }

  @override
  State<MuzikaSheetScaffold> createState() => _MuzikaSheetScaffoldState();
}

class _MuzikaSheetScaffoldState extends State<MuzikaSheetScaffold>
    with SingleTickerProviderStateMixin {
  /// 0 = resting, 1 = moved down by its whole height.
  late final AnimationController _offset = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  );
  double _sheetHeight = 1;
  bool _dismissing = false;

  bool get _isOnScreen =>
      TickerMode.valuesOf(context).enabled &&
      (ModalRoute.of(context)?.isCurrent ?? true);

  @override
  void initState() {
    super.initState();
    MuzikaSheetScaffold._mounted.add(this);
  }

  @override
  void dispose() {
    MuzikaSheetScaffold._mounted.remove(this);
    _offset.dispose();
    super.dispose();
  }

  Future<void> dismiss() async {
    if (_dismissing) return;
    _dismissing = true;
    await _offset.animateTo(1, curve: Curves.easeInCubic);
    if (!mounted) return;
    final close = widget.onHandleTap;
    if (close != null) {
      close();
      // A tab root stays alive offstage: put the sheet back for next time.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _offset.value = 0;
        _dismissing = false;
      });
    } else {
      Navigator.of(context).pop();
    }
  }

  void _dragBy(double dy) {
    if (_dismissing) return;
    _offset.value = (_offset.value + dy / _sheetHeight).clamp(0.0, 1.0);
  }

  void _release(double velocity) {
    if (_dismissing || _offset.value == 0) return;
    if (velocity > 700 || _offset.value > 0.28) {
      unawaited(dismiss());
    } else {
      unawaited(_offset.animateTo(0, curve: Curves.easeOutBack));
    }
  }

  bool _onScroll(ScrollNotification n) {
    if (n.depth != 0 || n.metrics.axis != Axis.vertical) return false;
    if (n is OverscrollNotification &&
        n.overscroll < 0 &&
        n.dragDetails != null) {
      _dragBy(-n.overscroll);
    } else if (n is ScrollUpdateNotification &&
        n.dragDetails != null &&
        _offset.value > 0 &&
        (n.scrollDelta ?? 0) > 0) {
      // Pushing the sheet back up before the list scrolls again.
      _dragBy(-(n.scrollDelta ?? 0));
    } else if (n is ScrollEndNotification) {
      _release(n.dragDetails?.velocity.pixelsPerSecond.dy ?? 0);
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(dismiss());
      },
      child: Scaffold(
        backgroundColor: scheme.surface,
        body: SafeArea(
          bottom: false,
          child: Column(
            children: [
              StreamBuilder<MediaItem?>(
                stream: audioHandler.mediaItem,
                initialData: audioHandler.mediaItem.valueOrNull,
                builder: (context, snapshot) {
                  final item = snapshot.data;
                  if (item == null) return _BackBar(onTap: dismiss);
                  return MuzikaTopPlayer(metadata: item, onBack: dismiss);
                },
              ),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    _sheetHeight = constraints.maxHeight;
                    return AnimatedBuilder(
                      animation: _offset,
                      builder: (context, child) => Transform.translate(
                        offset: Offset(0, _offset.value * _sheetHeight),
                        child: child,
                      ),
                      child: NotificationListener<ScrollNotification>(
                        onNotification: _onScroll,
                        child:
                            NotificationListener<
                              OverscrollIndicatorNotification
                            >(
                              // No stretch at the top: pulling there moves
                              // the sheet instead.
                              onNotification: (n) {
                                if (n.leading && n.depth == 0) {
                                  n.disallowIndicator();
                                }
                                return false;
                              },
                              child: MuzikaSheet(
                                onHandleTap: dismiss,
                                onHandleDrag: _dragBy,
                                onHandleRelease: _release,
                                child: widget.child,
                              ),
                            ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Rounded sheet with a drag handle, light grey fading into the page.
class MuzikaSheet extends StatelessWidget {
  const MuzikaSheet({
    super.key,
    required this.child,
    this.onHandleTap,
    this.onHandleDrag,
    this.onHandleRelease,
  });

  final Widget child;
  final VoidCallback? onHandleTap;

  /// Vertical drag on the handle, in pixels (down is positive).
  final ValueChanged<double>? onHandleDrag;

  /// End of a handle drag, with its vertical velocity.
  final ValueChanged<double>? onHandleRelease;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = scheme.brightness == Brightness.dark;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          stops: const [0, 0.55],
          colors: isDark
              ? [scheme.surfaceContainer, scheme.surfaceContainerLow]
              : [const Color(0xFFF3F3F5), scheme.surface],
        ),
      ),
      child: Column(
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onHandleTap,
            onVerticalDragUpdate: onHandleDrag == null
                ? null
                : (d) => onHandleDrag!(d.delta.dy),
            onVerticalDragEnd: (d) {
              final v = d.primaryVelocity ?? 0;
              if (onHandleRelease != null) {
                onHandleRelease!(v);
              } else if (v > 300) {
                onHandleTap?.call();
              }
            },
            child: SizedBox(
              height: 28,
              width: double.infinity,
              child: Center(
                child: Container(
                  width: 38,
                  height: 4,
                  decoration: BoxDecoration(
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.45),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),
          ),
          Expanded(child: child),
        ],
      ),
    );
  }
}

class _BackBar extends StatelessWidget {
  const _BackBar({this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
        child: IconButton(
          icon: const Icon(FluentIcons.arrow_left_24_regular),
          onPressed: onTap ?? () => Navigator.of(context).maybePop(),
        ),
      ),
    );
  }
}

/// The compact player row from the design: cover, title, artist, a thin
/// progress line, play/pause and next. Tapping opens the full player.
/// With [onBack], a back arrow sits before the cover.
class MuzikaTopPlayer extends StatelessWidget {
  const MuzikaTopPlayer({
    super.key,
    required this.metadata,
    this.onTap,
    this.onBack,
  });

  final MediaItem metadata;
  final VoidCallback? onTap;
  final VoidCallback? onBack;

  static void openNowPlaying(BuildContext context) {
    // The wide Windows layout shows the player all the time.
    if (desktopPanels.value) return;
    Navigator.of(context, rootNavigator: true).push(
      PageRouteBuilder<void>(
        pageBuilder: (_, _, _) => const NowPlayingPage(),
        transitionsBuilder: (_, animation, _, child) => SlideTransition(
          position: Tween(begin: const Offset(0, 1), end: Offset.zero).animate(
            CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
          ),
          child: child,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap ?? () => openNowPlaying(context),
      child: Padding(
        padding: EdgeInsets.fromLTRB(onBack == null ? 20 : 4, 12, 12, 14),
        child: Row(
          children: [
            if (onBack != null)
              IconButton(
                tooltip: 'Back',
                icon: Icon(
                  FluentIcons.arrow_left_24_regular,
                  color: scheme.onSurface,
                ),
                onPressed: onBack,
              ),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SongArtworkWidget(metadata: metadata, size: 52),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    metadata.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: muzikaBody(14, weight: 700, color: scheme.onSurface),
                  ),
                  MuzikaArtistLink(
                    song: {
                      'artist': metadata.artist ?? '',
                      'artistId': metadata.extras?['artistId'],
                    },
                    style: muzikaBody(13, color: scheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 6),
                  SizedBox(
                    width: 130,
                    child: StreamBuilder<PositionData>(
                      stream: audioHandler.positionDataStream,
                      builder: (context, snap) {
                        final p = snap.data;
                        final total = p?.duration ?? metadata.duration;
                        final v =
                            (p == null ||
                                total == null ||
                                total == Duration.zero)
                            ? 0.0
                            : (p.position.inMilliseconds / total.inMilliseconds)
                                  .clamp(0.0, 1.0);
                        return ClipRRect(
                          borderRadius: BorderRadius.circular(2),
                          child: LinearProgressIndicator(
                            value: v,
                            minHeight: 3,
                            color: scheme.onSurface,
                            backgroundColor: scheme.surfaceContainerHighest,
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
            StreamBuilder<PlaybackState>(
              stream: audioHandler.playbackState,
              builder: (context, snap) {
                final state = snap.data;
                final playing = state?.playing ?? false;
                final loading =
                    state?.processingState == AudioProcessingState.loading ||
                    state?.processingState == AudioProcessingState.buffering;
                return SizedBox(
                  width: 44,
                  height: 44,
                  child: loading
                      ? MuzikaPulse(
                          child: Icon(
                            FluentIcons.play_24_filled,
                            color: scheme.onSurface,
                          ),
                        )
                      : IconButton(
                          icon: Icon(
                            playing
                                ? FluentIcons.pause_24_filled
                                : FluentIcons.play_24_filled,
                            color: scheme.onSurface,
                          ),
                          onPressed: playing
                              ? audioHandler.pause
                              : audioHandler.play,
                        ),
                );
              },
            ),
            IconButton(
              icon: Icon(FluentIcons.next_24_filled, color: scheme.onSurface),
              onPressed: audioHandler.skipToNext,
            ),
          ],
        ),
      ),
    );
  }
}
