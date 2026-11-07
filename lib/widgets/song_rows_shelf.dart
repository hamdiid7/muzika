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

import 'dart:math';

import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:material_ui/material_ui.dart';
import 'package:muzika/main.dart' show audioHandler;
import 'package:muzika/theme/muzika_tokens.dart';
import 'package:muzika/widgets/muzika_song_row.dart';
import 'package:muzika/widgets/shelf_arrows.dart';

/// Songs in two rows sliding sideways (Home's New releases, an artist's
/// popular songs): each with its cover, title, a line under it ([subtitle])
/// and ⋮ for its options. A tap plays the shelf from that song.
class SongRowsShelf extends StatelessWidget {
  const SongRowsShelf({super.key, required this.songs, required this.subtitle});

  final List<Map> songs;

  /// The line under a song's title ("Rihanna · 2 weeks ago").
  final String Function(Map song, int index) subtitle;

  static const rowHeight = 64.0;

  @override
  Widget build(BuildContext context) {
    final columns = (songs.length / 2).ceil();
    return LayoutBuilder(
      builder: (context, box) {
        // The next column peeks in, so it's clear the rows slide.
        final width = min<double>(box.maxWidth - 64, 340);
        return SizedBox(
          height: rowHeight * 2,
          child: ShelfArrows(
            pictureHeight: rowHeight * 2,
            builder: (controller) => ListView.separated(
              controller: controller,
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemCount: columns,
              separatorBuilder: (_, _) => const SizedBox(width: 4),
              itemBuilder: (context, column) => SizedBox(
                width: width,
                child: Column(
                  children: [
                    for (
                      var i = column * 2;
                      i < column * 2 + 2 && i < songs.length;
                      i++
                    )
                      _SongRow(
                        songs: songs,
                        index: i,
                        subtitle: subtitle(songs[i], i),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _SongRow extends StatelessWidget {
  const _SongRow({
    required this.songs,
    required this.index,
    required this.subtitle,
  });

  final List<Map> songs;
  final int index;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final song = songs[index];
    return SizedBox(
      height: SongRowsShelf.rowHeight,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => audioHandler.addPlaylistToQueue(
          songs,
          replace: true,
          startIndex: index,
        ),
        onLongPress: () => showSongOptions(context, song),
        // Right-click (Windows) does what a long press does.
        onSecondaryTap: () => showSongOptions(context, song),
        child: Padding(
          padding: const EdgeInsets.only(left: 8),
          child: Row(
            children: [
              MuzikaCover(song: song, size: 48, radius: 6),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${song['title'] ?? ''}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: muzikaBody(
                        15,
                        weight: 600,
                        color: scheme.onSurface,
                      ),
                    ),
                    if (subtitle.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: muzikaBody(12.5, color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ],
                ),
              ),
              IconButton(
                tooltip: 'More',
                icon: Icon(
                  FluentIcons.more_vertical_24_regular,
                  size: 20,
                  color: scheme.onSurfaceVariant,
                ),
                onPressed: () => showSongOptions(context, song),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
