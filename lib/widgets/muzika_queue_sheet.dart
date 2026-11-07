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
import 'package:muzika/services/muzika_queue.dart';
import 'package:muzika/services/smart_shuffle.dart';
import 'package:muzika/theme/muzika_tokens.dart';
import 'package:muzika/widgets/muzika_song_actions.dart';
import 'package:muzika/widgets/muzika_song_row.dart';

/// The queue, opened from the mini player and the full player: what is
/// playing, then what plays next. The queue keeps itself topped up with
/// songs related to the one playing, so it reads like a radio. Drag the
/// handle on the right to reorder, tap a song to jump to it.
Future<void> showMuzikaQueueSheet(BuildContext context) {
  final current = audioHandler.mediaItem.valueOrNull;
  final ytid = current?.extras?['ytid'] ?? current?.id;
  if (ytid != null) {
    unawaited(
      topUpQueueWithRelated({
        'ytid': ytid,
        'title': current?.title,
        'artist': current?.artist,
      }),
    );
  }
  return showModalBottomSheet<void>(
    context: context,
    // Wide Windows layout: the sheet opens in the part it came from.
    useRootNavigator: !desktopPanels.value,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => const _QueueSheet(),
  );
}

class _QueueSheet extends StatelessWidget {
  const _QueueSheet();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, controller) => DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            stops: const [0, 0.4],
            colors: dark
                ? [scheme.surfaceContainer, scheme.surfaceContainerLow]
                : [const Color(0xFFF3F3F5), scheme.surface],
          ),
        ),
        child: StreamBuilder<List<Map>>(
          stream: audioHandler.queueAsMapStream,
          initialData: audioHandler.queueAsMapStreamValue,
          builder: (context, queueSnap) => StreamBuilder<PlaybackState>(
            stream: audioHandler.playbackState,
            initialData: audioHandler.playbackState.valueOrNull,
            builder: (context, stateSnap) {
              final queue = queueSnap.data ?? const <Map>[];
              final current = stateSnap.data?.queueIndex ?? 0;
              final upcoming = [
                for (var i = current + 1; i < queue.length; i++) i,
              ];
              return CustomScrollView(
                controller: controller,
                slivers: [
                  SliverToBoxAdapter(
                    child: Center(
                      child: Container(
                        margin: const EdgeInsets.only(top: 12, bottom: 8),
                        width: 38,
                        height: 4,
                        decoration: BoxDecoration(
                          color: scheme.onSurfaceVariant.withValues(
                            alpha: 0.45,
                          ),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                  ),
                  if (current < queue.length) ...[
                    _title(context, 'Now playing'),
                    SliverToBoxAdapter(
                      child: Row(
                        children: [
                          Expanded(
                            child: MuzikaSongRow(
                              song: queue[current],
                              showAddButton: false,
                              showDownloadButton: false,
                            ),
                          ),
                          const _SmartShuffleButton(),
                          const SizedBox(width: 12),
                        ],
                      ),
                    ),
                  ],
                  _title(
                    context,
                    'Up next',
                    trailing: 'Songs like this keep coming',
                  ),
                  if (upcoming.isEmpty)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Text(
                          'Finding songs like this…',
                          textAlign: TextAlign.center,
                          style: muzikaBody(15, color: scheme.onSurfaceVariant),
                        ),
                      ),
                    )
                  else
                    SliverReorderableList(
                      itemCount: upcoming.length,
                      onReorderItem: (oldIndex, newIndex) {
                        unawaited(
                          audioHandler.reorderQueue(
                            upcoming[oldIndex],
                            upcoming[newIndex],
                          ),
                        );
                      },
                      itemBuilder: (context, i) {
                        final queueIndex = upcoming[i];
                        final song = queue[queueIndex];
                        return _QueueRow(
                          key: ValueKey('${song['ytid']}_$queueIndex'),
                          song: song,
                          index: i,
                          onTap: () => audioHandler.skipToSong(queueIndex),
                        );
                      },
                    ),
                  const SliverToBoxAdapter(child: SizedBox(height: 32)),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _title(BuildContext context, String text, {String? trailing}) {
    final scheme = Theme.of(context).colorScheme;
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(text, style: muzikaHeading(20, color: scheme.onSurface)),
            const Spacer(),
            if (trailing != null)
              Text(
                trailing,
                style: muzikaBody(12, color: scheme.onSurfaceVariant),
              ),
          ],
        ),
      ),
    );
  }
}

/// Smart shuffle, beside the song playing: every tap shuffles all that's
/// up next again and mixes in fresh songs like these (the player's own
/// button only shuffles). Filled while smart shuffle is on; spins while
/// it finds the picks.
class _SmartShuffleButton extends StatelessWidget {
  const _SmartShuffleButton();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: Listenable.merge([smartShuffleNotifier, smartShuffleBusy]),
      builder: (context, _) {
        final on = smartShuffleNotifier.value;
        final busy = smartShuffleBusy.value;
        return Tooltip(
          message: 'Smart shuffle',
          child: Material(
            color: on ? scheme.onSurface : scheme.surfaceContainerHigh,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: busy ? null : () => unawaited(smartReshuffle()),
              child: SizedBox(
                width: 44,
                height: 44,
                child: Center(
                  child: busy
                      ? SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: on ? scheme.surface : scheme.onSurface,
                          ),
                        )
                      : Icon(
                          FluentIcons.sparkle_24_filled,
                          size: 22,
                          color: on ? scheme.surface : scheme.onSurface,
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

class _QueueRow extends StatelessWidget {
  const _QueueRow({
    super.key,
    required this.song,
    required this.index,
    required this.onTap,
  });

  final Map song;
  final int index;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        onLongPress: () => showSongOptions(context, song),
        // Right-click (Windows) does what a long press does.
        onSecondaryTap: () => showSongOptions(context, song),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 8, 8),
          child: Row(
            children: [
              MuzikaCover(song: song, size: 48, radius: 6),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      (song['title'] ?? '').toString(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: muzikaBody(
                        15,
                        weight: 500,
                        color: scheme.onSurface,
                      ),
                    ),
                    MuzikaArtistLink(
                      song: song,
                      fromPlayer: true,
                      style: muzikaBody(12.5, color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              ReorderableDragStartListener(
                index: index,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Icon(
                    FluentIcons.line_horizontal_3_20_regular,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
