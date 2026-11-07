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

import 'package:muzika/main.dart' show audioHandler, logger;
import 'package:muzika/services/common_services.dart';

/// Songs left after the current one before the queue is topped up.
const _minUpcoming = 3;

String? _toppingUpFor;

/// The song Discover is previewing. A preview isn't a play: it isn't added
/// to Recently played, counted in stats or the daily story, auto-downloaded
/// or used to grow the queue, until the user opens it in the player.
String? discoverPreviewId;

bool isDiscoverPreview(Map? song) =>
    song != null &&
    discoverPreviewId != null &&
    '${song['ytid']}' == discoverPreviewId;

/// Keeps the queue going like a radio: when fewer than three songs are left
/// after [song], songs related to it (YouTube Music radio) are appended, so
/// the queue is always "more of this".
Future<void> topUpQueueWithRelated(Map song) async {
  final ytid = song['ytid']?.toString() ?? '';
  if (ytid.isEmpty || _toppingUpFor == ytid) return;
  final queue = audioHandler.queueAsMapStreamValue;
  final index = audioHandler.playbackState.valueOrNull?.queueIndex ?? 0;
  if (queue.length - index - 1 >= _minUpcoming) return;

  _toppingUpFor = ytid;
  try {
    final related = await getRelatedSongs(ytid);
    final queued = {
      for (final s in audioHandler.queueAsMapStreamValue) '${s['ytid']}',
    };
    final fresh = [
      for (final s in related)
        if (queued.add('${s['ytid']}')) s,
    ].take(10).toList();
    if (fresh.isNotEmpty) await audioHandler.addPlaylistToQueue(fresh);
  } catch (e, st) {
    logger.log('Queue top-up failed for $ytid', error: e, stackTrace: st);
  } finally {
    _toppingUpFor = null;
  }
}
