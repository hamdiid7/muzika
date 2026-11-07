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
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:material_ui/material_ui.dart';
import 'package:muzika/main.dart';
import 'package:muzika/services/common_services.dart';
import 'package:muzika/services/desktop_panels.dart';
import 'package:muzika/theme/muzika_tokens.dart';
import 'package:muzika/utilities/flutter_toast.dart';
import 'package:muzika/utilities/image_size.dart';
import 'package:muzika/utilities/playlist_dialogs.dart';
import 'package:muzika/utilities/song_credits.dart';
import 'package:muzika/widgets/muzika_share.dart';
import 'package:muzika/widgets/muzika_sheet_scaffold.dart';
import 'package:muzika/widgets/muzika_song_actions.dart';

/// A song row from the Muzika design: 56px cover, title + artist (tap the
/// artist to open it), the download button and the round "+" (tap: save to
/// your top playlist, hold: add to queue). Long-press the row for all song
/// options, including Like.
class MuzikaSongRow extends StatelessWidget {
  const MuzikaSongRow({
    super.key,
    required this.song,
    this.queue,
    this.index,
    this.subtitle,
    this.leading,
    this.showAddButton = true,
    this.showDownloadButton = true,
    this.onAdd,
    this.onSelect,
  });

  final Map song;

  /// When set, tapping plays [queue] from [index] instead of the single song.
  final List<Map>? queue;
  final int? index;

  /// Overrides the artist line (e.g. a duration on album pages).
  final String? subtitle;

  /// Replaces the cover (e.g. a track number on album pages).
  final Widget? leading;
  final bool showAddButton;
  final bool showDownloadButton;

  /// Replaces what "+" does (saving to the top playlist by default).
  final VoidCallback? onAdd;

  /// Observes a song selection without replacing its normal playback action.
  final VoidCallback? onSelect;

  String get _title => songCredits(
    (song['title'] ?? '').toString(),
    (song['artist'] ?? '').toString(),
  ).title;

  Future<void> _play() async {
    final q = queue;
    if (q != null && index != null) {
      await audioHandler.addPlaylistToQueue(
        q,
        replace: true,
        startIndex: index,
      );
    } else {
      await audioHandler.addPlaylistToQueue([song], replace: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ytid = (song['ytid'] ?? '').toString();
    return StreamBuilder<MediaItem?>(
      stream: audioHandler.mediaItem,
      initialData: audioHandler.mediaItem.valueOrNull,
      builder: (context, snapshot) {
        final item = snapshot.data;
        final playing =
            ytid.isNotEmpty &&
            item != null &&
            (item.extras?['ytid'] ?? item.id).toString() == ytid;
        return _row(context, playing);
      },
    );
  }

  Widget _row(BuildContext context, bool playing) {
    final scheme = Theme.of(context).colorScheme;
    // The playing song is marked and opens the full player when tapped.
    return Material(
      color: playing ? scheme.surfaceContainer : Colors.transparent,
      child: InkWell(
        onTap: () {
          onSelect?.call();
          if (playing) {
            MuzikaTopPlayer.openNowPlaying(context);
          } else {
            unawaited(_play());
          }
        },
        onLongPress: () => showSongOptions(context, song),
        // Right-click (Windows) does what a long press does.
        onSecondaryTap: () => showSongOptions(context, song),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          child: Row(
            children: [
              leading ?? MuzikaCover(song: song),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (playing) ...[
                          Icon(
                            FluentIcons.data_bar_vertical_24_filled,
                            size: 15,
                            color: scheme.onSurface,
                          ),
                          const SizedBox(width: 5),
                        ],
                        Expanded(
                          child: Text(
                            _title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: muzikaBody(
                              16,
                              weight: playing ? 700 : 500,
                              color: scheme.onSurface,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    if (subtitle == null)
                      MuzikaArtistLink(
                        song: song,
                        style: muzikaBody(12.5, color: scheme.onSurfaceVariant),
                      )
                    else
                      Text(
                        subtitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: muzikaBody(12.5, color: scheme.onSurfaceVariant),
                      ),
                  ],
                ),
              ),
              if (showDownloadButton) MuzikaDownloadButton(song: song),
              if (showAddButton) ...[
                const SizedBox(width: 2),
                if (onAdd != null)
                  MuzikaRoundButton(
                    icon: FluentIcons.add_24_regular,
                    tooltip: 'Add',
                    onPressed: onAdd!,
                  )
                else
                  MuzikaAddButton(song: song),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 40px grey circle button used for "+" and other row actions.
class MuzikaRoundButton extends StatelessWidget {
  const MuzikaRoundButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.tooltip,
    this.filled = false,
    this.size = 40,
  });

  final IconData icon;
  final VoidCallback onPressed;
  final String? tooltip;
  final bool filled;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip ?? '',
      child: Material(
        color: filled ? scheme.onSurface : scheme.surfaceContainerHigh,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: SizedBox(
            width: size,
            height: size,
            child: Icon(
              icon,
              size: size * 0.5,
              color: filled ? scheme.surface : scheme.onSurface,
            ),
          ),
        ),
      ),
    );
  }
}

/// Square song/album artwork with rounded corners; uses the offline file
/// when the song was downloaded.
class MuzikaCover extends StatelessWidget {
  const MuzikaCover({
    super.key,
    required this.song,
    this.size = 56,
    this.radius = 8,
    this.highRes = false,
  });

  final Map song;
  final double size;
  final double radius;
  final bool highRes;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final artworkPath = song['artworkPath']?.toString();
    final url =
        (highRes
                ? (song['highResImage'] ?? song['image'] ?? song['lowResImage'])
                // Queue songs may carry only the big one: it's sized down.
                : (song['lowResImage'] ??
                      song['image'] ??
                      song['highResImage']))
            ?.toString()
            // 4:3 video thumbnails carry black letterbox bars; the 16:9 one
            // doesn't, and BoxFit.cover crops it square.
            .replaceFirst(RegExp(r'/(hq|sd|)default\.jpg'), '/mqdefault.jpg');

    Widget placeholder() => Container(
      width: size,
      height: size,
      color: scheme.surfaceContainer,
      child: Icon(
        FluentIcons.music_note_2_24_regular,
        color: scheme.onSurfaceVariant,
        size: size * 0.4,
      ),
    );

    final Widget image;
    if (artworkPath != null &&
        artworkPath.isNotEmpty &&
        File(artworkPath).existsSync()) {
      image = Image.file(
        File(artworkPath),
        width: size,
        height: size,
        fit: BoxFit.cover,
      );
    } else if (url != null && url.isNotEmpty) {
      image = CachedNetworkImage(
        // No bigger than it's drawn (a 56 px row cover needn't be 1000 px).
        imageUrl: sizedImageUrl(
          url,
          size * MediaQuery.devicePixelRatioOf(context),
        ),
        width: size,
        height: size,
        fit: BoxFit.cover,
        placeholder: (_, _) => placeholder(),
        errorWidget: (_, _, _) => placeholder(),
      );
    } else {
      image = placeholder();
    }
    return ClipRRect(borderRadius: BorderRadius.circular(radius), child: image);
  }
}

/// The long-press sheet from the design (Play next, Add to queue, …).
Future<void> showSongOptions(BuildContext context, Map song) {
  final title = (song['title'] ?? '').toString();
  final artist = (song['artist'] ?? '').toString();
  final ytid = (song['ytid'] ?? '').toString();

  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    // Wide Windows layout: the sheet opens in the part it came from.
    useRootNavigator: !desktopPanels.value,
    builder: (sheetContext) {
      final scheme = Theme.of(sheetContext).colorScheme;
      void close() => Navigator.of(sheetContext).pop();

      Widget option(IconData icon, String label, FutureOr<void> Function() on) {
        return ListTile(
          leading: Icon(icon, color: scheme.onSurface),
          title: Text(label, style: muzikaBody(16, weight: 500)),
          onTap: () async {
            close();
            await on();
          },
        );
      }

      final liked = isSongAlreadyLiked(ytid);
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Row(
                children: [
                  MuzikaCover(song: song, size: 48),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: muzikaBody(16, weight: 500),
                        ),
                        Text(
                          artist,
                          maxLines: 1,
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
            const Divider(height: 1),
            option(FluentIcons.next_24_regular, 'Play next', () async {
              await audioHandler.playNext(song);
              if (context.mounted) showToast(context, 'Playing “$title” next');
            }),
            option(
              FluentIcons.text_bullet_list_add_24_regular,
              'Add to queue',
              () async {
                await audioHandler.addToQueue(song);
                if (context.mounted) {
                  showToast(context, 'Added “$title” to queue');
                }
              },
            ),
            option(
              FluentIcons.album_add_24_regular,
              'Add to playlist',
              () => showAddToPlaylistDialog(context, song: song),
            ),
            option(
              liked
                  ? FluentIcons.heart_24_filled
                  : FluentIcons.heart_24_regular,
              liked ? 'Remove from liked songs' : 'Like',
              () => updateSongLikeStatus(ytid, !liked, songData: song),
            ),
            if (artist.isNotEmpty)
              option(
                FluentIcons.person_24_regular,
                'Go to artist',
                () => openArtistFor(context, song),
              ),
            option(
              FluentIcons.share_24_regular,
              'Share',
              () => showSongShare(context, song),
            ),
            const SizedBox(height: 8),
          ],
        ),
      );
    },
  );
}
