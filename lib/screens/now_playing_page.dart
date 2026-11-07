/*
 *     Copyright (C) 2026 Valeri Gokadze
 *     Rewritten for Muzika (design: Player Page / Lyrics Page), 2026.
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
import 'package:muzika/main.dart' show audioHandler;
import 'package:muzika/models/position_data.dart';
import 'package:muzika/screens/lyrics_page.dart';
import 'package:muzika/services/cover_tint.dart';
import 'package:muzika/services/data_saver.dart';
import 'package:muzika/services/settings_manager.dart';
import 'package:muzika/services/smart_shuffle.dart';
import 'package:muzika/services/synced_lyrics.dart';
import 'package:muzika/theme/muzika_tokens.dart';
import 'package:muzika/utilities/song_credits.dart';
import 'package:muzika/widgets/hold_for_speed.dart';
import 'package:muzika/widgets/muzika_player_options.dart';
import 'package:muzika/widgets/muzika_queue_sheet.dart';
import 'package:muzika/widgets/muzika_shimmer.dart';
import 'package:muzika/widgets/muzika_song_actions.dart';
import 'package:muzika/widgets/muzika_song_row.dart';
import 'package:muzika/widgets/song_artwork.dart';
import 'package:muzika/widgets/song_canvas.dart';
import 'package:muzika/widgets/story_row.dart';

/// Full player: the cover as a rounded card lined up with the title, the
/// title with a live lyrics line under the artist, progress and controls.
/// The queue opens from the button beside the title; lyrics open full screen
/// from the lyrics line. Drag the cover down to close.
class NowPlayingPage extends StatefulWidget {
  const NowPlayingPage({super.key, this.embedded = false});

  /// Shown in the wide Windows layout's right side: no close button, and it
  /// doesn't drag away.
  final bool embedded;

  @override
  State<NowPlayingPage> createState() => _NowPlayingPageState();
}

class _NowPlayingPageState extends State<NowPlayingPage>
    with SingleTickerProviderStateMixin {
  /// 0 = resting, 1 = pushed down by the page height (closed).
  late final AnimationController _close = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 240),
  );
  double _pageHeight = 1;

  /// The song's Canvas (a looping slice of its video) fills the player.
  final _canvasOn = ValueNotifier<bool>(false);

  /// The song whose Canvas was put away by tapping the small cover.
  final _canvasHiddenFor = ValueNotifier<String?>(null);

  @override
  void dispose() {
    _close.dispose();
    _canvasOn.dispose();
    _canvasHiddenFor.dispose();
    super.dispose();
  }

  void _dragPage(double dy) {
    _close.value = (_close.value + dy / _pageHeight).clamp(0.0, 1.0);
  }

  Future<void> _releasePage(double velocity) async {
    if (velocity > 700 || _close.value > 0.25) {
      await _close.animateTo(1, curve: Curves.easeInCubic);
      if (mounted) Navigator.of(context).pop();
    } else {
      await _close.animateTo(0, curve: Curves.easeOutBack);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // The cover's colour at the top, fading into the page.
    return ValueListenableBuilder<Color?>(
      valueListenable: coverTint,
      builder: (context, cover, child) => AnimatedContainer(
        duration: const Duration(milliseconds: 400),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            stops: const [0, 0.8],
            colors: [
              coverTinted(
                cover,
                scheme,
                amount: scheme.brightness == Brightness.dark ? 0.45 : 0.32,
              ),
              scheme.surface,
            ],
          ),
        ),
        child: child,
      ),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: StreamBuilder<MediaItem?>(
          stream: audioHandler.mediaItem,
          initialData: audioHandler.mediaItem.valueOrNull,
          builder: (context, snapshot) {
            final item = snapshot.data;
            if (item == null) return const SizedBox.shrink();
            return LayoutBuilder(
              builder: (context, constraints) {
                _pageHeight = constraints.maxHeight;
                return AnimatedBuilder(
                  animation: _close,
                  builder: (context, child) => Transform.translate(
                    offset: Offset(0, _close.value * _pageHeight),
                    child: child,
                  ),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      ValueListenableBuilder<String?>(
                        valueListenable: _canvasHiddenFor,
                        builder: (context, hiddenFor, canvas) =>
                            AnimatedOpacity(
                              opacity: hiddenFor == item.id ? 0 : 1,
                              duration: const Duration(milliseconds: 450),
                              child: canvas,
                            ),
                        child: SongCanvas(
                          key: ValueKey(item.id),
                          song: _currentSongMap(item),
                          showing: _canvasOn,
                        ),
                      ),
                      SafeArea(
                        child: _PlayerBody(
                          metadata: item,
                          embedded: widget.embedded,
                          canvasOn: _canvasOn,
                          canvasHiddenFor: _canvasHiddenFor,
                          onDrag: widget.embedded ? (_) {} : _dragPage,
                          onRelease: widget.embedded ? (_) {} : _releasePage,
                        ),
                      ),
                    ],
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class _PlayerBody extends StatelessWidget {
  const _PlayerBody({
    required this.metadata,
    required this.onDrag,
    required this.onRelease,
    required this.canvasOn,
    required this.canvasHiddenFor,
    this.embedded = false,
  });

  final MediaItem metadata;
  final bool embedded;

  /// The song's Canvas is playing behind the player: the cover steps aside.
  final ValueNotifier<bool> canvasOn;

  /// The song whose Canvas was put away (tap the small cover; again to
  /// bring it back).
  final ValueNotifier<String?> canvasHiddenFor;

  /// Dragging the cover down moves the whole player with the finger.
  final ValueChanged<double> onDrag;
  final ValueChanged<double> onRelease;

  static const _side = 26.0;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final song = _currentSongMap(metadata);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
          child: Row(
            children: [
              if (!embedded)
                IconButton(
                  tooltip: 'Close',
                  icon: Icon(
                    FluentIcons.chevron_down_24_regular,
                    color: scheme.onSurface,
                  ),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              AnimatedBuilder(
                animation: Listenable.merge([canvasOn, canvasHiddenFor]),
                builder: (context, _) {
                  final small =
                      canvasOn.value && canvasHiddenFor.value != metadata.id;
                  if (!small) return const SizedBox.shrink();
                  return Tooltip(
                    message: 'Show the cover',
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => canvasHiddenFor.value = metadata.id,
                      child: const SizedBox(width: 48, height: 48),
                    ),
                  );
                },
              ),
              const Spacer(),
              IconButton(
                tooltip: 'More',
                icon: Icon(Icons.more_vert_rounded, color: scheme.onSurface),
                onPressed: () => showPlayerOptions(context, song),
              ),
            ],
          ),
        ),
        // The cover: a rounded card as wide as the text below it.
        Expanded(
          child: GestureDetector(
            // Swipe sideways for the next or previous song.
            onHorizontalDragEnd: (d) {
              final v = d.primaryVelocity ?? 0;
              if (v < -300) unawaited(audioHandler.skipToNext());
              if (v > 300) unawaited(audioHandler.skipToPrevious());
            },
            onVerticalDragUpdate: (d) => onDrag(d.delta.dy),
            onVerticalDragEnd: (d) {
              final v = d.primaryVelocity ?? 0;
              // A flick up opens the lyrics; down closes the player.
              if (v < -500) {
                onRelease(0);
                unawaited(openLyricsPage(context));
              } else {
                onRelease(v);
              }
            },
            child: LayoutBuilder(
              builder: (context, box) {
                final size = (box.maxWidth - _side * 2).clamp(
                  0.0,
                  box.maxHeight - 16,
                );
                // While the Canvas plays, the cover flies to the top left,
                // small; tapping it there puts the Canvas away (the cover
                // flies back), tapping the big cover brings it back.
                return AnimatedBuilder(
                  animation: Listenable.merge([canvasOn, canvasHiddenFor]),
                  builder: (context, _) {
                    final hidden = canvasHiddenFor.value == metadata.id;
                    final small = canvasOn.value && !hidden;
                    // In the top bar, the size of the ⋮ button and level
                    // with it: its left end on Windows, after the close
                    // arrow on a phone. The bar is 52 high (4 + 48) above
                    // this box, so the small cover sits above its top.
                    const thumb = 36.0;
                    final thumbLeft = embedded ? 14.0 : 8.0 + 48 + 6;
                    const thumbTop = 4 + (48 - thumb) / 2 - 52;
                    return Stack(
                      clipBehavior: Clip.none,
                      children: [
                        AnimatedPositioned(
                          duration: const Duration(milliseconds: 500),
                          curve: Curves.easeInOutCubic,
                          left: small ? thumbLeft : (box.maxWidth - size) / 2,
                          top: small ? thumbTop : (box.maxHeight - size) / 2,
                          width: small ? thumb : size,
                          height: small ? thumb : size,
                          child: GestureDetector(
                            onTap: canvasOn.value
                                ? () => canvasHiddenFor.value = small
                                      ? metadata.id
                                      : null
                                : null,
                            // Hold its right side for 2×.
                            child: HoldForSpeed(
                              child: AnimatedSwitcher(
                                duration: const Duration(milliseconds: 300),
                                child: DecoratedBox(
                                  key: ValueKey(metadata.id),
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(
                                      small ? 8 : 18,
                                    ),
                                    boxShadow: [
                                      BoxShadow(
                                        color: Colors.black.withValues(
                                          alpha: 0.18,
                                        ),
                                        blurRadius: small ? 12 : 28,
                                        offset: Offset(0, small ? 4 : 12),
                                      ),
                                    ],
                                  ),
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(
                                      small ? 8 : 18,
                                    ),
                                    child: FittedBox(
                                      child: SongArtworkWidget(
                                        metadata: metadata,
                                        size: size,
                                        borderRadius: 18,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                );
              },
            ),
          ),
        ),
        const SizedBox(height: 22),
        Padding(
          padding: const EdgeInsets.fromLTRB(_side, 0, _side, 0),
          child: Align(
            alignment: Alignment.centerLeft,
            child: GestureDetector(
              onLongPress: () => showSongOptions(context, song),
              // Right-click (Windows) does what a long press does.
              onSecondaryTap: () => showSongOptions(context, song),
              child: Text(
                songCredits(metadata.title, metadata.artist ?? '').title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: muzikaHeading(21, color: scheme.onSurface),
              ),
            ),
          ),
        ),
        const SizedBox(height: 4),
        // The artist (their round photo, ringed when they have a story: a
        // tap plays it, else opens the artist), and on the same line the
        // download, save to a playlist (a ✓ once it's in one) and like.
        Padding(
          padding: const EdgeInsets.fromLTRB(_side, 0, _side - 6, 0),
          child: Row(
            children: [
              // Everyone credited, as a collab post: "Rihanna, Drake" shows
              // both.
              CollabArtistAvatars(
                key: ValueKey(metadata.artist),
                // With whoever the title features ("Work (feat. Drake)"),
                // as the names beside them read.
                names: CollabArtistAvatars.split(
                  songCredits(metadata.title, metadata.artist ?? '').artist,
                ),
                onArtist: (name) =>
                    openArtistFor(context, {'artist': name}, fromPlayer: true),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: MuzikaArtistLink(
                  song: song,
                  text: metadata.artist ?? '',
                  fromPlayer: true,
                  style: muzikaBody(16, color: scheme.onSurfaceVariant),
                ),
              ),
              for (final button in [
                MuzikaDownloadButton(song: song, size: 24),
                MuzikaAddButton(song: song, size: 20),
                MuzikaLikeButton(song: song, size: 26),
              ])
                SizedBox(width: 44, height: 44, child: Center(child: button)),
            ],
          ),
        ),
        // While the song is on its way: says so (and why, on a slow line).
        const Padding(
          padding: EdgeInsets.fromLTRB(_side, 2, _side, 0),
          child: _LoadingNote(),
        ),
        // The lyrics strip across the whole width, under the buttons too.
        Padding(
          padding: const EdgeInsets.fromLTRB(_side, 8, _side, 0),
          child: _LyricsPeek(metadata: metadata),
        ),
        const SizedBox(height: 8),
        _ProgressBar(metadata: metadata),
        const SizedBox(height: 10),
        const _Controls(),
        const SizedBox(height: 26),
      ],
    );
  }
}

/// A "Lyrics" tag and the line being sung, under the artist; tap for the
/// full lyrics. Unsynced lyrics show their first line; none, nothing.
class _LyricsPeek extends StatefulWidget {
  const _LyricsPeek({required this.metadata});

  final MediaItem metadata;

  @override
  State<_LyricsPeek> createState() => _LyricsPeekState();
}

class _LyricsPeekState extends State<_LyricsPeek> {
  String? _key;
  late Future<SongLyrics?> _future;

  void _load() {
    final m = widget.metadata;
    final key = '${m.artist}|${m.title}';
    if (key == _key) return;
    _key = key;
    _future = fetchSongLyrics(
      artist: m.artist ?? '',
      title: m.title,
      album: m.album,
      duration: m.duration,
      videoId: m.extras?['ytid']?.toString(),
    );
  }

  @override
  Widget build(BuildContext context) {
    _load();
    final scheme = Theme.of(context).colorScheme;
    return FutureBuilder<SongLyrics?>(
      future: _future,
      builder: (context, snapshot) {
        // Only this song's lyrics: while a new song's load, the old ones
        // (which the builder keeps) don't show.
        final lyrics = snapshot.connectionState == ConnectionState.done
            ? snapshot.data
            : null;
        final credits = songCredits(
          widget.metadata.title,
          widget.metadata.artist ?? '',
        );
        final fallback = '${credits.title}  -  ${credits.artist}';
        // One row: a long lyrics line ends in "…".
        Widget line(String text) => Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: muzikaBody(
            14.5,
            weight: 500,
            color: scheme.onSurfaceVariant,
          ).copyWith(height: 1.25),
        );
        final Widget text;
        if (lyrics == null) {
          // Looked up and none: an invitation (the lyrics page has Add).
          text = line(
            snapshot.connectionState == ConnectionState.done
                ? 'No lyrics yet · add them'
                : fallback,
          );
        } else if (lyrics.isSynced) {
          final lines = lyrics.lines!;
          text = StreamBuilder<PositionData>(
            stream: audioHandler.positionDataStream,
            builder: (context, snap) {
              final t =
                  (snap.data?.position ?? Duration.zero) +
                  const Duration(milliseconds: 250);
              var current = '';
              for (final l in lines) {
                if (l.time > t) break;
                current = l.text;
              }
              if (current.isEmpty) current = fallback;
              return AnimatedSwitcher(
                duration: const Duration(milliseconds: 220),
                layoutBuilder: (cur, prev) => Stack(
                  alignment: Alignment.centerLeft,
                  children: [...prev, ?cur],
                ),
                child: KeyedSubtree(
                  key: ValueKey(current),
                  child: line(current),
                ),
              );
            },
          );
        } else {
          text = line(
            (lyrics.plain ?? '')
                .split('\n')
                .firstWhere((l) => l.trim().isNotEmpty, orElse: () => fallback),
          );
        }
        return InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () => openLyricsPage(context),
          child: SizedBox(
            height: 42,
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    'Lyrics',
                    style: muzikaBody(12, weight: 700, color: scheme.onSurface),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(child: text),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// "Getting the song…" under the artist while a song loads, so a wait
/// isn't silence; after four seconds on a slow line, why ("Slow connection ·
/// data saver on"). Gone once it plays.
class _LoadingNote extends StatefulWidget {
  const _LoadingNote();

  @override
  State<_LoadingNote> createState() => _LoadingNoteState();
}

class _LoadingNoteState extends State<_LoadingNote> {
  StreamSubscription<PlaybackState>? _sub;
  Timer? _slowTimer;
  bool _loading = false;
  bool _long = false;

  @override
  void initState() {
    super.initState();
    _sub = audioHandler.playbackState.listen(_onState);
  }

  void _onState(PlaybackState state) {
    final loading =
        state.processingState == AudioProcessingState.loading ||
        state.processingState == AudioProcessingState.buffering;
    if (loading == _loading) return;
    _slowTimer?.cancel();
    if (loading) {
      _slowTimer = Timer(const Duration(seconds: 4), () {
        if (mounted) setState(() => _long = true);
      });
    }
    if (mounted) {
      setState(() {
        _loading = loading;
        _long = false;
      });
    }
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    _slowTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final speed = lineSpeed.value;
    final text = !_long
        ? 'Getting the song…'
        : dataSaverOn
        ? 'Slow connection · data saver on'
              '${speed == null ? '' : ' (${speed.round()} KB/s)'}'
        : 'Still getting the song: the line is slow';
    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      alignment: Alignment.topLeft,
      child: !_loading
          ? const SizedBox(width: double.infinity)
          : Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                children: [
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      text,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: muzikaBody(13.5, color: scheme.onSurfaceVariant),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

/// Shrinks a little under the finger and springs back: every player button.
class _Pressable extends StatefulWidget {
  const _Pressable({required this.child, required this.onTap});

  final Widget child;
  final VoidCallback? onTap;

  @override
  State<_Pressable> createState() => _PressableState();
}

class _PressableState extends State<_Pressable> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _down = true),
      onTapCancel: () => setState(() => _down = false),
      onTapUp: (_) => setState(() => _down = false),
      onTap: widget.onTap == null
          ? null
          : () {
              unawaited(HapticFeedback.selectionClick());
              widget.onTap!();
            },
      child: AnimatedScale(
        scale: _down ? 0.88 : 1,
        duration: Duration(milliseconds: _down ? 90 : 260),
        curve: _down ? Curves.easeOut : Curves.elasticOut,
        child: widget.child,
      ),
    );
  }
}

/// The playing song as a song map (for the options sheet).
Map _currentSongMap(MediaItem metadata) {
  final index = audioHandler.playbackState.valueOrNull?.queueIndex;
  final queue = audioHandler.queueAsMapStreamValue;
  if (index != null && index >= 0 && index < queue.length) return queue[index];
  return {
    'ytid': metadata.extras?['ytid'] ?? metadata.id,
    'title': metadata.title,
    'artist': metadata.artist,
    'artistId': metadata.extras?['artistId'],
    'image': metadata.artUri?.toString(),
    'lowResImage': metadata.artUri?.toString(),
  };
}

class _ProgressBar extends StatefulWidget {
  const _ProgressBar({required this.metadata});

  final MediaItem metadata;

  @override
  State<_ProgressBar> createState() => _ProgressBarState();
}

class _ProgressBarState extends State<_ProgressBar> {
  double? _dragValue;

  String _fmt(Duration d) {
    final m = d.inMinutes;
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return StreamBuilder<PositionData>(
      stream: audioHandler.positionDataStream,
      builder: (context, snapshot) {
        final p = snapshot.data;
        final total = (p?.duration ?? Duration.zero) > Duration.zero
            ? p!.duration
            : (widget.metadata.duration ?? Duration.zero);
        final pos = p?.position ?? Duration.zero;
        final max = total.inMilliseconds.toDouble().clamp(1.0, double.infinity);
        final value = (_dragValue ?? pos.inMilliseconds.toDouble()).clamp(
          0.0,
          max,
        );
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 26),
          child: Column(
            children: [
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 5,
                  activeTrackColor: scheme.onSurface,
                  inactiveTrackColor: scheme.surfaceContainerHighest,
                  thumbColor: scheme.onSurface,
                  overlayShape: SliderComponentShape.noOverlay,
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 8,
                  ),
                  trackShape: const RoundedRectSliderTrackShape(),
                ),
                child: Slider(
                  // ignore: deprecated_member_use
                  year2023: true,
                  value: value,
                  max: max,
                  onChanged: (v) => setState(() => _dragValue = v),
                  onChangeEnd: (v) {
                    unawaited(
                      audioHandler.seek(Duration(milliseconds: v.round())),
                    );
                    setState(() => _dragValue = null);
                  },
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Text(
                    _fmt(Duration(milliseconds: value.round())),
                    style: muzikaBody(13, color: scheme.onSurface),
                  ),
                  const Spacer(),
                  Text(
                    _fmt(total),
                    style: muzikaBody(13, color: scheme.onSurface),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Controls extends StatelessWidget {
  const _Controls();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return StreamBuilder<PlaybackState>(
      stream: audioHandler.playbackState,
      builder: (context, snapshot) {
        final state = snapshot.data;
        final playing = state?.playing ?? false;
        final loading =
            state?.processingState == AudioProcessingState.loading ||
            state?.processingState == AudioProcessingState.buffering;

        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            // One button, three ways: in order, shuffled (the sparkle when
            // smart shuffle is on, switched in the queue), this song again.
            ListenableBuilder(
              listenable: Listenable.merge([
                shuffleNotifier,
                smartShuffleNotifier,
                repeatNotifier,
              ]),
              builder: (context, _) {
                watchSmartShuffle();
                final shuffle = shuffleNotifier.value;
                final smart = shuffle && smartShuffleNotifier.value;
                final repeat =
                    repeatNotifier.value != AudioServiceRepeatMode.none;
                return _ModeButton(
                  tooltip: repeat
                      ? 'Repeat this song'
                      : smart
                      ? 'Smart shuffle'
                      : (shuffle ? 'Shuffle' : 'In order'),
                  icon: repeat
                      ? FluentIcons.arrow_repeat_1_24_regular
                      : FluentIcons.arrow_shuffle_24_regular,
                  badge: smart && !repeat
                      ? FluentIcons.sparkle_16_filled
                      : null,
                  active: shuffle || repeat,
                  onPressed: () async {
                    if (repeat) {
                      await audioHandler.setRepeatMode(
                        AudioServiceRepeatMode.none,
                      );
                    } else if (shuffle) {
                      await toggleShuffle();
                      await audioHandler.setRepeatMode(
                        AudioServiceRepeatMode.one,
                      );
                    } else {
                      await toggleShuffle();
                    }
                  },
                );
              },
            ),
            _Pressable(
              onTap: audioHandler.skipToPrevious,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Icon(
                  FluentIcons.previous_24_filled,
                  size: 30,
                  color: scheme.onSurface,
                ),
              ),
            ),
            _Pressable(
              onTap: playing ? audioHandler.pause : audioHandler.play,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  color: playing
                      ? scheme.onSurface
                      : scheme.surfaceContainerHigh,
                  shape: BoxShape.circle,
                ),
                child: Center(
                  child: loading
                      ? MuzikaPulse(
                          child: Icon(
                            FluentIcons.play_24_filled,
                            size: 34,
                            color: playing ? scheme.surface : scheme.onSurface,
                          ),
                        )
                      : AnimatedSwitcher(
                          duration: const Duration(milliseconds: 180),
                          transitionBuilder: (child, a) =>
                              ScaleTransition(scale: a, child: child),
                          child: Icon(
                            playing
                                ? FluentIcons.pause_24_filled
                                : FluentIcons.play_24_filled,
                            key: ValueKey(playing),
                            size: 34,
                            color: playing ? scheme.surface : scheme.onSurface,
                          ),
                        ),
                ),
              ),
            ),
            _Pressable(
              onTap: audioHandler.skipToNext,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Icon(
                  FluentIcons.next_24_filled,
                  size: 30,
                  color: scheme.onSurface,
                ),
              ),
            ),
            // The queue, where repeat used to be.
            _ModeButton(
              tooltip: 'Queue',
              icon: Icons.queue_music_rounded,
              active: false,
              onPressed: () => showMuzikaQueueSheet(context),
            ),
          ],
        );
      },
    );
  }
}

/// Shuffle / repeat: a filled dark circle when on, a plain grey icon when
/// off. No toast: the circle itself shows the state.
class _ModeButton extends StatelessWidget {
  const _ModeButton({
    required this.tooltip,
    required this.icon,
    required this.active,
    required this.onPressed,
    this.badge,
  });

  final String tooltip;
  final IconData icon;

  /// A small mark on the icon (the sparkle of smart shuffle).
  final IconData? badge;
  final bool active;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: _Pressable(
        onTap: onPressed,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: active ? scheme.onSurface : Colors.transparent,
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              Icon(
                icon,
                size: 22,
                color: active ? scheme.surface : scheme.onSurfaceVariant,
              ),
              if (badge != null)
                Positioned(
                  top: 7,
                  right: 7,
                  child: Icon(
                    badge,
                    size: 11,
                    color: active ? scheme.surface : scheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
