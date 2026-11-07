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
import 'package:muzika/services/desktop_panels.dart';
import 'package:muzika/services/muzika_downloads.dart';
import 'package:muzika/services/router_service.dart';
import 'package:muzika/theme/muzika_tokens.dart';
import 'package:muzika/utilities/playlist_dialogs.dart';
import 'package:muzika/widgets/muzika_queue_sheet.dart';
import 'package:muzika/widgets/muzika_share.dart';
import 'package:muzika/widgets/muzika_song_actions.dart';
import 'package:muzika/widgets/muzika_song_row.dart';

/// The playing song as a song map.
Map currentSongMap([MediaItem? metadata]) {
  final item = metadata ?? audioHandler.mediaItem.valueOrNull;
  final index = audioHandler.playbackState.valueOrNull?.queueIndex;
  final queue = audioHandler.queueAsMapStreamValue;
  if (index != null && index >= 0 && index < queue.length) return queue[index];
  return {
    'ytid': item?.extras?['ytid'] ?? item?.id,
    'title': item?.title,
    'artist': item?.artist,
    'artistId': item?.extras?['artistId'],
    'image': item?.artUri?.toString(),
    'lowResImage': item?.artUri?.toString(),
  };
}

/// Options for the song that is already playing (from the player's ⋮ and a
/// long press on the mini player): no "Play next" — it is playing.
Future<void> showPlayerOptions(BuildContext context, [Map? song]) {
  final s = song ?? currentSongMap();
  final ytid = '${s['ytid'] ?? ''}';
  final albumId = '${s['albumId'] ?? ''}';
  return showModalBottomSheet<void>(
    context: context,
    // Wide Windows layout: the sheet opens in the part it came from.
    useRootNavigator: !desktopPanels.value,
    useSafeArea: true,
    showDragHandle: true,
    builder: (sheetContext) {
      final scheme = Theme.of(sheetContext).colorScheme;
      // The gesture/nav bar of the phone: never cover the last option.
      final bottom = MediaQueryData.fromView(View.of(sheetContext))
          .viewPadding
          .bottom;
      void close() => Navigator.of(sheetContext).pop();

      Widget option(IconData icon, String label, FutureOr<void> Function() on) {
        return ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 24),
          leading: Icon(icon, color: scheme.onSurface),
          title: Text(label, style: muzikaBody(16, weight: 500)),
          onTap: () async {
            close();
            await on();
          },
        );
      }

      return Padding(
        padding: EdgeInsets.only(bottom: bottom + 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
              child: Row(
                children: [
                  MuzikaCover(song: s, size: 48),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${s['title'] ?? ''}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: muzikaBody(16, weight: 700),
                        ),
                        Text(
                          '${s['artist'] ?? ''}',
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
            const Divider(height: 1),
            if ('${s['artist'] ?? ''}'.isNotEmpty)
              option(
                FluentIcons.person_24_regular,
                'Go to artist',
                () => openArtistFor(context, s, fromPlayer: true),
              ),
            if (albumId.startsWith('MPRE'))
              option(FluentIcons.album_24_regular, 'Go to album', () {
                final nav = Navigator.of(context);
                if (nav.canPop()) nav.pop();
                NavigationManager.router.push(
                  '${NavigationManager.currentBasePath}/album/$albumId',
                );
              }),
            if (!isSongDownloaded(ytid))
              option(
                FluentIcons.arrow_download_24_regular,
                'Download',
                () => downloadSong(s),
              ),
            option(
              FluentIcons.album_add_24_regular,
              'Add to playlist',
              () => showAddToPlaylistDialog(context, song: s),
            ),
            option(
              Icons.queue_music_rounded,
              'Queue',
              () => showMuzikaQueueSheet(context),
            ),
            option(
              FluentIcons.share_24_regular,
              'Share',
              () => showSongShare(context, s),
            ),
          ],
        ),
      );
    },
  );
}
