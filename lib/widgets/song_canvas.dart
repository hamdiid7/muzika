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

import 'package:audio_service/audio_service.dart' show AudioProcessingState;
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:muzika/main.dart' show audioHandler;
import 'package:muzika/services/settings_manager.dart';
import 'package:muzika/services/youtube_canvas.dart';

/// Behind the whole player: a few seconds from the middle of the song's
/// music video looping silently, as Spotify's Canvas (Muzika), shaded
/// towards the bottom so the song's name and buttons stay readable. It
/// fades in once the video plays and pauses with the song; [showing] is
/// true meanwhile (the cover steps aside). A song with no video shows
/// nothing. Settings › Canvas turns it off.
class SongCanvas extends StatefulWidget {
  const SongCanvas({super.key, required this.song, required this.showing});

  final Map song;
  final ValueNotifier<bool> showing;

  @override
  State<SongCanvas> createState() => _SongCanvasState();
}

class _SongCanvasState extends State<SongCanvas> {
  /// How long the looped slice is.
  static const _loop = Duration(seconds: 6);

  /// From the player's foot up to the line under the song's name: the
  /// name, artist, lyrics line, progress bar and buttons (the same height
  /// in any window). The video fades out down to there; below, solid.
  static const _controlsHeight = 235.0;

  /// How far above that line the fade begins.
  static const _fadeLength = 220.0;

  Player? _player;
  VideoController? _controller;
  StreamSubscription<Duration>? _watch;
  StreamSubscription<bool>? _playing;
  Duration _start = Duration.zero;
  bool _visible = false;
  String? _songId;

  @override
  void initState() {
    super.initState();
    canvasEnabled.addListener(_reload);
    _reload();
  }

  @override
  void didUpdateWidget(covariant SongCanvas old) {
    super.didUpdateWidget(old);
    if ('${old.song['ytid']}' != '${widget.song['ytid']}') _reload();
  }

  void _show(bool on) {
    _visible = on;
    widget.showing.value = on;
    if (mounted) setState(() {});
  }

  Future<void> _reload() async {
    final id = '${widget.song['ytid']}';
    _songId = id;
    await _stop();
    if (!canvasEnabled.value) return;
    // The song first: its video is looked up once it plays, so the two
    // don't share a slow line (a paused song waits up to half a minute).
    for (var i = 0; i < 100 && !_songPlaying(id); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      if (!mounted || _songId != id) return;
    }
    // The song's music video on YouTube.
    final video = await youtubeCanvasFor(widget.song).catchError((_) => null);
    if (video == null || !mounted || _songId != id || !canvasEnabled.value) {
      return;
    }
    // Only the loop is needed: mpv's usual 32 MB read-ahead downloads the
    // whole video, more than a slow line has for the song itself.
    final player = Player(
      configuration: const PlayerConfiguration(bufferSize: 4 * 1024 * 1024),
    );
    final controller = VideoController(player);
    _player = player;
    _controller = controller;
    await player.setVolume(0);
    // Opened straight at the loop's start (media_kit sets mpv's start as
    // it loads), so nothing waits for the video's length or a seek.
    _start = video.start;
    await player.open(
      Media(video.url, httpHeaders: video.headers, start: _start),
      play: false,
    );
    if (!mounted || _player != player) return;
    await player.setPlaylistMode(PlaylistMode.single);
    _watch = player.stream.position.listen((p) {
      if (p >= _start + _loop) unawaited(player.seek(_start));
    });
    // Moves only while the song plays.
    _playing = audioHandler.playbackState
        .map((s) => s.playing)
        .distinct()
        .listen((on) => unawaited(on ? player.play() : player.pause()));
    // A paused song still shows its first frame.
    await player.play();
    // Shown once frames come, so the page doesn't flash black.
    // (A player closed meanwhile ends the stream with no frame: orElse.)
    await player.stream.width
        .firstWhere((w) => (w ?? 0) > 0, orElse: () => 0)
        .timeout(const Duration(seconds: 15), onTimeout: () => 0);
    if (!mounted || _player != player) return;
    if (!audioHandler.playbackState.value.playing) await player.pause();
    _show(true);
  }

  /// Whether the song [id] is the one playing (not still loading).
  static bool _songPlaying(String id) {
    final item = audioHandler.mediaItem.valueOrNull;
    final state = audioHandler.playbackState.valueOrNull;
    return item != null &&
        '${item.extras?['ytid'] ?? item.id}' == id &&
        state != null &&
        state.playing &&
        state.processingState == AudioProcessingState.ready;
  }

  Future<void> _stop() async {
    final player = _player;
    unawaited(_watch?.cancel());
    unawaited(_playing?.cancel());
    _watch = null;
    _playing = null;
    _player = null;
    _controller = null;
    if (_visible) _show(false);
    await player?.dispose();
  }

  @override
  void dispose() {
    canvasEnabled.removeListener(_reload);
    _songId = null;
    final player = _player;
    unawaited(_watch?.cancel());
    unawaited(_playing?.cancel());
    _player = null;
    // Not while the screen is being taken down (that throws): just after.
    if (_visible) {
      final showing = widget.showing;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        try {
          showing.value = false;
        } catch (_) {} // the player went with it
      });
    }
    unawaited(player?.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null) return const SizedBox.shrink();
    final surface = Theme.of(context).colorScheme.surface;
    return AnimatedOpacity(
      opacity: _visible ? 1 : 0,
      duration: const Duration(milliseconds: 600),
      // The video fills the player down to the line under the song's name,
      // not all of it: a less tall box crops less off its sides, so more of
      // the (wide) video shows. Below that line the player is solid.
      child: LayoutBuilder(
        builder: (context, box) {
          final height = box.maxHeight;
          final solidFrom = (height - _controlsHeight).clamp(
            height * 0.5,
            height,
          );
          final videoHeight = solidFrom + 4;
          final fadeFrom = (solidFrom - _fadeLength).clamp(0.0, solidFrom);
          return Stack(
            fit: StackFit.expand,
            children: [
              ColoredBox(color: surface),
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: videoHeight,
                // Zoomed in a little: many music videos come with black
                // bars above and below, which this pushes off the edge.
                child: ClipRect(
                  child: Transform.scale(
                    // Enough for a cinema-wide video's bars (2.35:1 in a
                    // 16:9 frame) to fall outside the box.
                    scale: 1.3,
                    child: Video(
                      controller: controller,
                      fit: BoxFit.cover,
                      controls: NoVideoControls,
                      fill: Colors.transparent,
                    ),
                  ),
                ),
              ),
              // A light shade at the top for the buttons; the video fades out
              // over the song's name, solid from the line under it (the
              // video's last rows, a black bar perhaps, never show).
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    stops: [
                      0,
                      0.14 * fadeFrom / height,
                      fadeFrom / height,
                      (fadeFrom + _fadeLength * 0.6) / height,
                      solidFrom / height,
                      1,
                    ],
                    colors: [
                      surface.withValues(alpha: 0.3),
                      surface.withValues(alpha: 0),
                      surface.withValues(alpha: 0),
                      surface.withValues(alpha: 0.55),
                      surface,
                      surface,
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
}
