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
import 'dart:ui' show ImageFilter;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:muzika/services/clip_framing.dart';
import 'package:muzika/services/clip_requests.dart';
import 'package:muzika/services/common_services.dart';
import 'package:muzika/theme/muzika_tokens.dart';
import 'package:muzika/utilities/song_credits.dart';
import 'package:muzika/widgets/lyric_video.dart';
import 'package:muzika/widgets/muzika_playlist_picker.dart';
import 'package:muzika/widgets/muzika_share.dart';
import 'package:muzika/widgets/muzika_song_actions.dart';

/// A full-screen Clips card: the clip fills the screen (the song's cover
/// until it plays), its window following the face where the framing has
/// been worked out ([CropPath]), centred otherwise. At the bottom, over a
/// dark fade: the song (cover, title, "Artist · Album"; tap to play it in
/// full) and its buttons. Tap the clip to pause.
class ClipCard extends StatelessWidget {
  const ClipCard({
    super.key,
    required this.song,
    this.clipUrl,
    required this.playing,
    required this.player,
    required this.controller,
    required this.framing,
    required this.paused,
    required this.onTogglePause,
    required this.onOpenPlayer,
    this.lyrics,
    this.lyricPosition,
  });

  final Map song;

  /// The clip's video, so a liked clip is kept with Liked songs.
  final String? clipUrl;

  /// The clip is loaded and plays through [player] / [controller].
  final bool playing;
  final Player? player;
  final VideoController? controller;
  final CropPath? framing;
  final bool paused;
  final VoidCallback onTogglePause;
  final VoidCallback onOpenPlayer;

  /// A song with no music video: shown as a lyric video instead (nature
  /// picture, one line at a time), its audio playing in the player.
  final LyricClip? lyrics;

  /// Where a lyric video's song is, from Clips' own player.
  final Stream<Duration>? lyricPosition;

  String? _first(List<String> keys) =>
      [for (final k in keys) song[k]?.toString() ?? '']
          .where((e) => e.startsWith('http'))
          .firstOrNull;

  /// The cover behind the clip (600 px, quick to come), and a small one
  /// (226 px, at once) for the song's line and until the big one is in.
  String? get _cover => _first(['image', 'highResImage', 'lowResImage']);
  String? get _smallCover => _first(['lowResImage', 'image']);

  @override
  Widget build(BuildContext context) {
    final cover = _cover;
    final scheme = Theme.of(context).colorScheme;
    return Stack(
      fit: StackFit.expand,
      children: [
        // Until the clip plays: the cover blurred and darkened, so the switch
        // to the video isn't a jump from a sharp, full-screen picture.
        ColoredBox(
          color: Colors.black,
          child: cover == null
              ? null
              : ImageFiltered(
                  imageFilter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
                  child: ColorFiltered(
                    colorFilter: const ColorFilter.mode(
                      Color(0x8C000000),
                      BlendMode.srcOver,
                    ),
                    child: CachedNetworkImage(
                      imageUrl: cover,
                      fit: BoxFit.cover,
                      fadeInDuration: Duration.zero,
                      placeholder: (_, _) => _smallCover == null
                          ? const SizedBox.shrink()
                          : CachedNetworkImage(
                              imageUrl: _smallCover!,
                              fit: BoxFit.cover,
                              fadeInDuration: Duration.zero,
                            ),
                      errorWidget: (_, _, _) => const SizedBox.shrink(),
                    ),
                  ),
                ),
        ),
        if (lyrics != null)
          LyricVideo(
            songId: '${song['ytid']}',
            clip: lyrics!,
            active: playing,
            position: lyricPosition,
          )
        else if (playing && player != null && controller != null)
          LayoutBuilder(
            builder: (context, box) => _FramedVideo(
              player: player!,
              controller: controller!,
              framing: framing ?? CropPath.centre,
              aspect: box.maxWidth / box.maxHeight,
            ),
          )
        else
          const Center(
            child: SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                color: Colors.white70,
              ),
            ),
          ),
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTogglePause,
          child: AnimatedOpacity(
            opacity: paused ? 1 : 0,
            duration: const Duration(milliseconds: 150),
            child: const Center(
              child: Icon(
                FluentIcons.play_48_filled,
                size: 72,
                color: Colors.white70,
              ),
            ),
          ),
        ),
        Align(
          alignment: Alignment.bottomCenter,
          // Fades into the bottom bar's colour, so the card runs on into it.
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                stops: const [0, 0.45, 1],
                colors: [
                  scheme.surface,
                  scheme.surface.withValues(alpha: 0.85),
                  scheme.surface.withValues(alpha: 0),
                ],
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 72, 12, 18),
              // The song and its buttons on one line, centred on each other.
              child: Row(
                children: [
                  Expanded(child: _songRow(scheme)),
                  ClipActions(song: song, clipUrl: clipUrl),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _songRow(ColorScheme scheme) {
    final cover = _smallCover;
    final album = '${song['album'] ?? ''}'.trim();
    final credits = songCredits(
      '${song['title'] ?? ''}',
      '${song['artist'] ?? ''}'.replaceAll(RegExp(r'\s*-\s*Topic$'), '').trim(),
    );
    final artist = credits.artist;
    return GestureDetector(
      onTap: onOpenPlayer,
      behavior: HitTestBehavior.opaque,
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(
              width: 42,
              height: 42,
              child: cover == null
                  ? ColoredBox(color: scheme.surfaceContainerHigh)
                  : CachedNetworkImage(
                      imageUrl: cover,
                      fit: BoxFit.cover,
                      fadeInDuration: Duration.zero,
                    ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  credits.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: muzikaBody(15, weight: 700, color: scheme.onSurface),
                ),
                Text(
                  album.isEmpty ? artist : '$artist · $album',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: muzikaBody(13, color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The clip filling the screen, its window moved along [framing] as it
/// plays.
class _FramedVideo extends StatefulWidget {
  const _FramedVideo({
    required this.player,
    required this.controller,
    required this.framing,
    required this.aspect,
  });

  final Player player;
  final VideoController controller;
  final CropPath framing;
  final double aspect;

  @override
  State<_FramedVideo> createState() => _FramedVideoState();
}

class _FramedVideoState extends State<_FramedVideo> {
  final _alignment = ValueNotifier(Alignment.center);
  StreamSubscription<Duration>? _watch;

  @override
  void initState() {
    super.initState();
    _watch = widget.player.stream.position.listen(_follow);
  }

  @override
  void didUpdateWidget(covariant _FramedVideo old) {
    super.didUpdateWidget(old);
    if (!identical(old.player, widget.player)) {
      unawaited(_watch?.cancel());
      _watch = widget.player.stream.position.listen(_follow);
    }
    _follow(widget.player.state.position);
  }

  /// The window's centre (0..1 of the frame) as BoxFit.cover's alignment.
  void _follow(Duration position) {
    final f = widget.framing;
    final visible = (f.height * widget.aspect / f.width).clamp(0.0, 1.0);
    if (visible >= 0.999) return;
    final half = visible / 2;
    final x = f.at(position).clamp(half, 1 - half);
    _alignment.value = Alignment(((x - half) / (1 - visible)) * 2 - 1, 0);
  }

  @override
  void dispose() {
    unawaited(_watch?.cancel());
    _alignment.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Alignment>(
      valueListenable: _alignment,
      builder: (context, alignment, _) => Video(
        controller: widget.controller,
        fit: BoxFit.cover,
        alignment: alignment,
        controls: NoVideoControls,
        fill: Colors.transparent,
      ),
    );
  }
}

/// Buttons on the right: save (hold: choose a playlist), like,
/// download and share.
/// A clip's buttons: save (long press: pick a playlist), like, download,
/// share. Also under the stories, in [color].
class ClipActions extends StatelessWidget {
  const ClipActions({super.key, required this.song, this.clipUrl, this.color});

  final Map song;
  final String? clipUrl;

  /// The icons' colour (the theme's text colour when null).
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final iconColor = color ?? scheme.onSurface;
    Widget action(
      IconData icon,
      String tooltip,
      VoidCallback onTap, {
      VoidCallback? onLongPress,
    }) {
      return GestureDetector(
        onLongPress: onLongPress,
        // Right-click (Windows) does what a long press does.
        onSecondaryTap: onLongPress,
        child: IconButton(
          tooltip: tooltip,
          visualDensity: VisualDensity.compact,
          iconSize: 22,
          color: iconColor,
          icon: Icon(icon),
          onPressed: () {
            unawaited(HapticFeedback.lightImpact());
            onTap();
          },
        ),
      );
    }

    final ytid = '${song['ytid']}';
    return ValueListenableBuilder<List>(
      valueListenable: userLikedSongsList,
      builder: (context, _, _) {
        final liked = isSongAlreadyLiked(ytid);
        return IconTheme(
          data: IconThemeData(color: iconColor),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              action(
                FluentIcons.add_circle_24_regular,
                'Save',
                () => saveToFavorite(context, song),
                onLongPress: () =>
                    showMuzikaPlaylistPicker(context, song: song),
              ),
              action(
                liked
                    ? FluentIcons.heart_24_filled
                    : FluentIcons.heart_24_regular,
                liked ? 'Liked' : 'Like',
                () {
                  unawaited(updateSongLikeStatus(ytid, !liked, songData: song));
                  // The clip too, for the Clips row of Liked songs.
                  final url = clipUrl;
                  if (url != null) {
                    setClipLiked((
                      song: Map<String, dynamic>.from(song),
                      url: url,
                    ), !liked);
                  }
                },
              ),
              MuzikaDownloadButton(song: song),
              action(
                FluentIcons.share_24_regular,
                'Share',
                () => showSongShare(context, song),
              ),
            ],
          ),
        );
      },
    );
  }
}
