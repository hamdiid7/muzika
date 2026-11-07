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

import 'package:audio_service/audio_service.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:muzika/main.dart';
import 'package:muzika/models/full_player_state.dart';
import 'package:muzika/models/position_data.dart';
import 'package:muzika/screens/now_playing_page.dart';
import 'package:muzika/services/cover_tint.dart';
import 'package:muzika/services/synced_lyrics.dart';
import 'package:muzika/theme/muzika_tokens.dart';
import 'package:muzika/utilities/song_credits.dart';
import 'package:muzika/widgets/marquee.dart';
import 'package:muzika/widgets/muzika_player_options.dart';
import 'package:muzika/widgets/muzika_queue_sheet.dart';
import 'package:muzika/widgets/muzika_shimmer.dart';
import 'package:muzika/widgets/song_artwork.dart';
import 'package:rxdart/rxdart.dart';

final Stream<FullPlayerState> _fullPlayerStateStream =
    Rx.combineLatest3(
          audioHandler.playbackStateStream,
          audioHandler.queue.distinct(),
          audioHandler.positionDataStream,
          (PlaybackState state, List<MediaItem> queue, PositionData pos) =>
              FullPlayerState(
                playbackState: state,
                queue: queue,
                position: pos,
              ),
        )
        .throttleTime(const Duration(milliseconds: 120), trailing: true)
        .asBroadcastStream();

class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key});

  static const double playerHeight = 72;
  static const double _borderRadius = 0;
  static const double _artworkSize = 52;
  static const double _artworkRadius = 8;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return AnimatedSize(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
      child: StreamBuilder<MediaItem?>(
        stream: audioHandler.mediaItem,
        builder: (context, mediaSnapshot) {
          final metadata = mediaSnapshot.data;
          if (metadata == null) return const SizedBox.shrink();

          return StreamBuilder<FullPlayerState>(
            stream: _fullPlayerStateStream,
            builder: (context, stateSnapshot) {
              final state = stateSnapshot.data;
              if (state == null) return const SizedBox.shrink();

              final hasNext =
                  state.queue.length > 1 &&
                  (state.playbackState.queueIndex ?? 0) <
                      state.queue.length - 1;

              return _MiniPlayerBody(
                colorScheme: colorScheme,
                metadata: metadata,
                state: state,
                hasNext: hasNext,
              );
            },
          );
        },
      ),
    );
  }
}

class _MiniPlayerBody extends StatefulWidget {
  const _MiniPlayerBody({
    required this.colorScheme,
    required this.metadata,
    required this.state,
    required this.hasNext,
  });

  final ColorScheme colorScheme;
  final MediaItem metadata;
  final FullPlayerState state;
  final bool hasNext;

  @override
  State<_MiniPlayerBody> createState() => _MiniPlayerBodyState();
}

class _MiniPlayerBodyState extends State<_MiniPlayerBody>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animationController;
  late final Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 100),
      vsync: this,
    );
    _scaleAnimation = Tween<double>(begin: 1, end: 0.98).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  static const double _dragThresholdForNavigation = 10;

  /// How far the bar follows a sideways swipe (next / previous song).
  double _dx = 0;
  bool _armed = false;
  bool _dragging = false;
  bool _settling = false;
  MediaItem? _settlingPreview;
  int _swipeEpoch = 0;
  int _swipeOperation = 0;
  String? _browsedId;

  int? get _browseIndex {
    final index = widget.state.queue.indexWhere(
      (item) => item.id == _browsedId,
    );
    return index < 0 ? null : index;
  }

  @override
  void didUpdateWidget(_MiniPlayerBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_browsedId == widget.metadata.id || _browseIndex == null) {
      _browsedId = null;
    }
    // Playback metadata can arrive before the stream finishes buffering.
    // Reveal the selected song immediately and allow another swipe.
    if (_settling && oldWidget.metadata.id != widget.metadata.id) {
      _settling = false;
      _settlingPreview = null;
      _dx = 0;
      _swipeEpoch++;
      _swipeOperation++;
    }
  }

  MediaItem? _adjacentSong(bool next) {
    final queue = widget.state.queue;
    final index = _browseIndex ?? widget.state.playbackState.queueIndex;
    if (index == null || queue.isEmpty) return null;
    var target = index + (next ? 1 : -1);
    if (next &&
        target == queue.length &&
        widget.state.playbackState.repeatMode == AudioServiceRepeatMode.all) {
      target = 0;
    }
    return target >= 0 && target < queue.length ? queue[target] : null;
  }

  void _cancelSwipe() {
    _armed = false;
    setState(() {
      _dragging = false;
      _dx = 0;
    });
  }

  void _onSwipeUpdate(DragUpdateDetails d) {
    if (_settling) return;
    final width = context.size?.width ?? 360;
    setState(() {
      _dragging = true;
      _dx = (_dx + d.delta.dx).clamp(-width, width);
    });
    // A light tick the moment the swipe is far enough to count.
    final armed = _dx.abs() > width * 0.25;
    if (armed != _armed) {
      _armed = armed;
      if (armed) unawaited(HapticFeedback.selectionClick());
    }
  }

  Future<void> _onSwipeEnd(DragEndDetails d) async {
    if (_settling) return;
    final width = context.size?.width ?? 360;
    final v = d.primaryVelocity ?? 0;
    final next = _dx < -width * 0.25 || v < -700;
    final previous = _dx > width * 0.25 || v > 700;
    final target = _adjacentSong(next);
    if ((next || previous) && target != null) {
      final operation = ++_swipeOperation;
      unawaited(HapticFeedback.mediumImpact());
      setState(() {
        _dragging = false;
        _settling = true;
        _settlingPreview = _adjacentSong(next);
        _dx = next ? -width : width;
      });
      try {
        if (!MediaQuery.disableAnimationsOf(context)) {
          await Future<void>.delayed(const Duration(milliseconds: 220));
        }
        if (!mounted) return;
        if (operation == _swipeOperation) {
          setState(
            () =>
                _browsedId = target.id == widget.metadata.id ? null : target.id,
          );
        }
      } finally {
        if (mounted && operation == _swipeOperation) {
          setState(() {
            _settling = false;
            _settlingPreview = null;
            _dx = 0;
            _swipeEpoch++;
          });
        }
      }
    } else {
      _cancelSwipe();
    }
    _armed = false;
  }

  void _handleVerticalDrag(DragUpdateDetails details) {
    if ((details.primaryDelta ?? 0) < -_dragThresholdForNavigation) {
      _navigateToNowPlaying();
    }
  }

  void _navigateToNowPlaying() {
    setState(() => _browsedId = null);
    Navigator.of(context).push(_createSlideTransition());
  }

  Future<void> _playBrowsed() async {
    final index = _browseIndex;
    if (index == null) return;
    await audioHandler.skipToQueueItem(index);
  }

  Future<void> _returnToCurrent() async {
    if (_settling || _browseIndex == null) return;
    final operation = ++_swipeOperation;
    final width = context.size?.width ?? 360;
    final currentIndex = widget.state.playbackState.queueIndex ?? 0;
    final next = currentIndex > _browseIndex!;
    setState(() {
      _dragging = false;
      _settling = true;
      _settlingPreview = widget.metadata;
      _dx = next ? -width : width;
    });
    if (!MediaQuery.disableAnimationsOf(context)) {
      await Future<void>.delayed(const Duration(milliseconds: 220));
    }
    if (!mounted || operation != _swipeOperation) return;
    setState(() {
      _browsedId = null;
      _settling = false;
      _settlingPreview = null;
      _dx = 0;
      _swipeEpoch++;
    });
  }

  PageRoute<void> _createSlideTransition() {
    return PageRouteBuilder<void>(
      pageBuilder: (context, animation, _) => const NowPlayingPage(),
      reverseTransitionDuration: const Duration(milliseconds: 250),
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        final tween = Tween(
          begin: const Offset(0, 1),
          end: Offset.zero,
        ).chain(CurveTween(curve: Curves.easeInOut));
        return SlideTransition(position: animation.drive(tween), child: child);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = widget.colorScheme;
    final browseIndex = _browseIndex;
    final preview = browseIndex != null;
    final metadata = preview
        ? widget.state.queue[browseIndex]
        : widget.metadata;
    final state = widget.state;

    final totalDuration = state.position.duration > Duration.zero
        ? state.position.duration
        : (widget.metadata.duration ?? Duration.zero);
    final progress = totalDuration.inMilliseconds == 0
        ? 0.0
        : (state.position.position.inMilliseconds /
                  totalDuration.inMilliseconds)
              .clamp(0.0, 1.0);

    return AnimatedBuilder(
      animation: _scaleAnimation,
      builder: (context, child) {
        return Transform.scale(
          scale: _scaleAnimation.value,
          child: GestureDetector(
            onTapDown: (_) => _animationController.forward(),
            onTapUp: (_) => _animationController.reverse(),
            onTapCancel: () => _animationController.reverse(),
            onVerticalDragUpdate: _handleVerticalDrag,
            onHorizontalDragUpdate: _onSwipeUpdate,
            onHorizontalDragEnd: _onSwipeEnd,
            onHorizontalDragCancel: _cancelSwipe,
            onTap: _navigateToNowPlaying,
            onLongPress: () => showPlayerOptions(context),
            // Right-click (Windows) does what a long press does.
            onSecondaryTap: () => showPlayerOptions(context),
            // Muzika: a flat bar on the page background with a hairline on
            // top, as in the design (no floating card).
            child: ValueListenableBuilder<Color?>(
              valueListenable: coverTint,
              builder: (context, cover, _) => AnimatedContainer(
                duration: const Duration(milliseconds: 400),
                height: MiniPlayer.playerHeight,
                decoration: BoxDecoration(
                  color: coverTinted(cover, colorScheme),
                  // No radius: a one-sided border can't be rounded.
                  border: Border(
                    top: BorderSide(color: colorScheme.outlineVariant),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: colorScheme.shadow.withValues(alpha: 0.06),
                      blurRadius: 16,
                      offset: const Offset(0, -2),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(MiniPlayer._borderRadius),
                  child: Stack(
                    children: [
                      Positioned.fill(
                        top: 1,
                        child: TweenAnimationBuilder<double>(
                          key: ValueKey(_swipeEpoch),
                          // Follows the finger, springs back when let go.
                          tween: Tween<double>(end: _dx),
                          duration:
                              _dragging ||
                                  MediaQuery.disableAnimationsOf(context)
                              ? Duration.zero
                              : const Duration(milliseconds: 220),
                          curve: Curves.easeOutCubic,
                          builder: (context, dx, child) => LayoutBuilder(
                            builder: (context, constraints) => Stack(
                              children: [
                                Positioned.fill(
                                  child: Transform.translate(
                                    offset: Offset(dx, 0),
                                    child: child,
                                  ),
                                ),
                                if (dx != 0)
                                  Positioned.fill(
                                    child: Transform.translate(
                                      offset: Offset(
                                        dx +
                                            (dx < 0
                                                ? constraints.maxWidth
                                                : -constraints.maxWidth),
                                        0,
                                      ),
                                      child: IgnorePointer(
                                        child: _QueuePreview(
                                          onClose: _returnToCurrent,
                                          position: state.position.position,
                                          playbackState: state.playbackState,
                                          metadata: _settling
                                              ? _settlingPreview
                                              : _adjacentSong(dx < 0),
                                          next: dx < 0,
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            child: Row(
                              children: [
                                _ArtworkWidget(metadata: metadata),
                                Expanded(
                                  child: _MetadataWidget(
                                    key: ValueKey(metadata.id),
                                    metadata: metadata,
                                    position: preview
                                        ? Duration.zero
                                        : state.position.position,
                                    colorScheme: colorScheme,
                                    preview: preview,
                                  ),
                                ),
                                _ControlsWidget(
                                  colorScheme: colorScheme,
                                  playbackState: state.playbackState,
                                  hasNext: widget.hasNext,
                                  progress: progress,
                                  onPlay: preview ? _playBrowsed : null,
                                  onClose: preview ? _returnToCurrent : null,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        top: 0,
                        left: 0,
                        right: 0,
                        child: LinearProgressIndicator(
                          value: progress,
                          minHeight: 1,
                          color: colorScheme.onSurface,
                          backgroundColor: colorScheme.surfaceContainerHighest,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ArtworkWidget extends StatelessWidget {
  const _ArtworkWidget({required this.metadata});
  final MediaItem metadata;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 12),
      child: Hero(
        tag: 'now_playing_artwork',
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(MiniPlayer._artworkRadius),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.1),
                blurRadius: 4,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: SongArtworkWidget(
            metadata: metadata,
            size: MiniPlayer._artworkSize,
            errorWidgetIconSize: 24,
            borderRadius: MiniPlayer._artworkRadius,
          ),
        ),
      ),
    );
  }
}

/// A neighbour entering from the edge while the current song slides away.
/// It previews metadata only, without starting playback or loading lyrics.
class _QueuePreview extends StatelessWidget {
  const _QueuePreview({
    required this.metadata,
    required this.next,
    required this.playbackState,
    required this.position,
    required this.onClose,
  });

  final MediaItem? metadata;
  final bool next;
  final PlaybackState playbackState;
  final Duration position;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final item = metadata;
    return ColoredBox(
      color: coverTinted(coverTint.value, scheme),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            if (item != null)
              SongArtworkWidget(
                metadata: item,
                size: MiniPlayer._artworkSize,
                borderRadius: MiniPlayer._artworkRadius,
              )
            else
              SizedBox(
                width: MiniPlayer._artworkSize,
                child: Icon(
                  next ? Icons.skip_next_rounded : Icons.skip_previous_rounded,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            const SizedBox(width: 12),
            Expanded(
              child: item != null
                  ? _MetadataWidget(
                      metadata: item,
                      position: position,
                      colorScheme: scheme,
                      preview:
                          item.id != audioHandler.mediaItem.valueOrNull?.id,
                    )
                  : Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          next ? 'Up next' : 'Previous song',
                          style: muzikaBody(11, color: scheme.onSurfaceVariant),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          item == null
                              ? (next ? 'Next song' : 'Previous song')
                              : () {
                                  final c = songCredits(
                                    item.title,
                                    item.artist ?? '',
                                  );
                                  return '${c.title}${c.artist.isNotEmpty ? ' · ${c.artist}' : ''}';
                                }(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: muzikaBody(
                            14,
                            weight: 700,
                            color: scheme.onSurface,
                          ),
                        ),
                      ],
                    ),
            ),
            _ControlsWidget(
              colorScheme: scheme,
              playbackState: playbackState,
              hasNext: false,
              progress: 0,
              onPlay: item?.id == audioHandler.mediaItem.valueOrNull?.id
                  ? null
                  : () {},
              onClose: item?.id == audioHandler.mediaItem.valueOrNull?.id
                  ? null
                  : onClose,
            ),
          ],
        ),
      ),
    );
  }
}

class _MetadataWidget extends StatelessWidget {
  const _MetadataWidget({
    super.key,
    required this.metadata,
    required this.position,
    required this.colorScheme,
    this.preview = false,
  });

  final MediaItem metadata;
  final Duration position;
  final ColorScheme colorScheme;
  final bool preview;

  @override
  Widget build(BuildContext context) {
    final credits = songCredits(metadata.title, metadata.artist ?? '');
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MarqueeWidget(
            manualScrollEnabled: false,
            animationDuration: const Duration(seconds: 8),
            backDuration: const Duration(seconds: 2),
            pauseDuration: const Duration(seconds: 2),
            child: Text.rich(
              TextSpan(
                text: credits.title,
                children: [
                  if (credits.artist.isNotEmpty)
                    TextSpan(
                      text: ' · ${credits.artist}',
                      style: muzikaBody(
                        13,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
              style: muzikaBody(14, weight: 700, color: colorScheme.onSurface),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(height: 2),
          if (preview)
            Text(
              'Preview · Tap play',
              style: muzikaBody(
                12,
                color: colorScheme.onSurfaceVariant.withValues(alpha: 0.72),
              ),
            )
          else
            _MiniLyrics(
              key: ValueKey(
                '${metadata.id}|${metadata.artist}|${metadata.title}',
              ),
              metadata: metadata,
              position: position,
            ),
        ],
      ),
    );
  }
}

/// Fetch once per song; the existing playback updates select the current line.
class _MiniLyrics extends StatefulWidget {
  const _MiniLyrics({
    super.key,
    required this.metadata,
    required this.position,
  });

  final MediaItem metadata;
  final Duration position;

  @override
  State<_MiniLyrics> createState() => _MiniLyricsState();
}

class _MiniLyricsState extends State<_MiniLyrics> {
  late final Future<SongLyrics?> _lyrics = fetchSongLyrics(
    artist: widget.metadata.artist ?? '',
    title: widget.metadata.title,
    album: widget.metadata.album,
    duration: widget.metadata.duration,
    videoId: widget.metadata.extras?['ytid']?.toString(),
  );

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<SongLyrics?>(
      future: _lyrics,
      builder: (context, snapshot) {
        // Only this song's lyrics: while a new song's load, the old ones
        // (which the builder keeps) don't show.
        final lyrics = snapshot.connectionState == ConnectionState.done
            ? snapshot.data
            : null;
        var line = snapshot.connectionState == ConnectionState.done
            ? 'Lyrics unavailable'
            : 'Loading lyrics…';
        if (lyrics?.isSynced == true) {
          line = '♪';
          final position = widget.position + const Duration(milliseconds: 250);
          for (final lyric in lyrics!.lines!) {
            if (lyric.time > position) break;
            line = lyric.text.trim().isEmpty ? '♪' : lyric.text;
          }
        } else if (lyrics?.plain?.trim().isNotEmpty == true) {
          line = lyrics!.plain!
              .split('\n')
              .firstWhere(
                (line) => line.trim().isNotEmpty,
                orElse: () => 'Lyrics unavailable',
              );
        }
        // A tap opens the player, like the rest of the bar.
        return SizedBox(
          width: double.infinity,
          child: Text(
            line,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: muzikaBody(
              12,
              weight: 500,
              color: Theme.of(context).colorScheme.onSurfaceVariant
                  .withValues(alpha: 0.72),
            ),
          ),
        );
      },
    );
  }
}

class _ControlsWidget extends StatelessWidget {
  const _ControlsWidget({
    required this.colorScheme,
    required this.playbackState,
    required this.hasNext,
    required this.progress,
    this.onPlay,
    this.onClose,
  });

  final ColorScheme colorScheme;
  final PlaybackState playbackState;
  final bool hasNext;
  final double progress;
  final VoidCallback? onPlay;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _CircularPlayButton(
          colorScheme: colorScheme,
          playbackState: playbackState,
          progress: progress,
          onPlay: onPlay,
        ),
        const SizedBox(width: 4),
        IconButton(
          tooltip: onClose != null ? 'Back to current song' : 'Queue',
          onPressed: onClose ?? () => showMuzikaQueueSheet(context),
          splashColor: Colors.transparent,
          highlightColor: Colors.transparent,
          icon: Icon(
            onClose != null ? Icons.close_rounded : Icons.queue_music_rounded,
            color: colorScheme.onSurface,
            size: 26,
          ),
          visualDensity: VisualDensity.compact,
        ),
      ],
    );
  }
}

class _CircularPlayButton extends StatelessWidget {
  const _CircularPlayButton({
    required this.colorScheme,
    required this.playbackState,
    required this.progress,
    this.onPlay,
  });

  final ColorScheme colorScheme;
  final PlaybackState playbackState;
  final double progress;
  final VoidCallback? onPlay;

  @override
  Widget build(BuildContext context) {
    final processingState = playbackState.processingState;
    final isPlaying = onPlay == null && playbackState.playing;
    final isLoading =
        onPlay == null &&
        (processingState == AudioProcessingState.loading ||
            processingState == AudioProcessingState.buffering);
    final isCompleted =
        onPlay == null && processingState == AudioProcessingState.completed;

    // Progress runs along the mini player's top edge; this stays a plain icon.
    return SizedBox(
      width: 48,
      height: 48,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (isLoading)
            MuzikaPulse(
              child: Icon(
                FluentIcons.play_24_filled,
                size: 26,
                color: colorScheme.onSurface,
              ),
            )
          else
            IconButton(
              onPressed:
                  onPlay ??
                  (isCompleted
                      ? () => audioHandler.playAgain()
                      : (isPlaying ? audioHandler.pause : audioHandler.play)),
              splashColor: Colors.transparent,
              highlightColor: Colors.transparent,
              icon: Icon(
                isCompleted
                    ? FluentIcons.arrow_counterclockwise_24_filled
                    : (isPlaying
                          ? FluentIcons.pause_16_filled
                          : FluentIcons.play_16_filled),
                color: colorScheme.primary,
                size: 22,
              ),
              visualDensity: VisualDensity.compact,
            ),
        ],
      ),
    );
  }
}
