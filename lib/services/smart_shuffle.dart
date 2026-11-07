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
import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:material_ui/material_ui.dart';
import 'package:muzika/services/analytics.dart';
import 'package:muzika/main.dart' show audioHandler, logger;
import 'package:muzika/services/common_services.dart';
import 'package:muzika/services/settings_manager.dart';

/// Smart shuffle (Muzika): shuffle plus songs like the ones in the queue,
/// one after every few. The player's shuffle button turns shuffle on and
/// off; the queue's ✨ button reshuffles with fresh smart picks.
final smartShuffleNotifier = ValueNotifier<bool>(
  Hive.box('settings').get('smartShuffle', defaultValue: false) == true,
);

StreamSubscription<List<MediaItem>>? _watch;
String? _mixedFor;
bool _mixing = false;

/// The player's shuffle button: shuffle on or off (off ends smart shuffle
/// too).
Future<void> toggleShuffle() async {
  watchSmartShuffle();
  if (!shuffleNotifier.value) {
    await audioHandler.setShuffleMode(AudioServiceShuffleMode.all);
  } else {
    if (smartShuffleNotifier.value) {
      _setSmart(false);
      audioHandler.removeSmartShuffle();
    }
    await audioHandler.setShuffleMode(AudioServiceShuffleMode.none);
  }
}

/// While smart picks are being found (the queue's ✨ button spins).
final smartShuffleBusy = ValueNotifier<bool>(false);

/// The queue's ✨ button: every tap shuffles all that's up next again and
/// mixes in fresh songs like the queue's (the last picks go).
Future<void> smartReshuffle() async {
  if (_mixing) return;
  track('smart_shuffle');
  watchSmartShuffle();
  _setSmart(true);
  audioHandler.removeSmartShuffle();
  if (shuffleNotifier.value) {
    await audioHandler.shuffleQueue();
  } else {
    await audioHandler.setShuffleMode(AudioServiceShuffleMode.all);
  }
  await _mix();
}

/// Shuffle with smart picks, for what was just put in the queue (an
/// artist's radio).
Future<void> startSmartShuffle() async {
  watchSmartShuffle();
  _setSmart(true);
  await audioHandler.setShuffleMode(AudioServiceShuffleMode.all);
  await _mix();
}

void _setSmart(bool on) {
  smartShuffleNotifier.value = on;
  unawaited(Hive.box('settings').put('smartShuffle', on));
}

/// A new queue (another playlist) gets its own picks.
void watchSmartShuffle() {
  _watch ??= audioHandler.queue.listen((_) {
    if (!smartShuffleNotifier.value || _mixing) return;
    final queue = audioHandler.queueAsMapStreamValue;
    if (queue.isEmpty || queue.any((s) => s['isSmartShuffle'] == true)) return;
    final key = '${queue.first['ytid']}|${queue.length}';
    if (key == _mixedFor) return;
    unawaited(_mix());
  });
}

Future<void> _mix() async {
  final queue = audioHandler.queueAsMapStreamValue;
  if (queue.isEmpty || _mixing) return;
  _mixing = true;
  smartShuffleBusy.value = true;
  _mixedFor = '${queue.first['ytid']}|${queue.length}';
  try {
    final index = audioHandler.currentQueueIndex.clamp(0, queue.length - 1);
    final random = Random();
    // The playing song and a few others from the queue lead the picks.
    final seeds = <Map>{
      queue[index],
      for (var i = 0; i < 3; i++) queue[random.nextInt(queue.length)],
    };
    final have = queue.map((s) => s['ytid']).toSet();
    final picks = <Map>[];
    for (final seed in seeds) {
      final related = await getRelatedSongs('${seed['ytid']}', seed: seed);
      for (final song in related) {
        final seconds = (song['duration'] as num?)?.toInt() ?? 0;
        if (have.contains(song['ytid']) || seconds > 600) continue;
        have.add(song['ytid']);
        picks.add(song);
      }
    }
    picks.shuffle(random);
    final count = (queue.length ~/ 3).clamp(5, 15);
    if (smartShuffleNotifier.value && picks.isNotEmpty) {
      audioHandler.mixInSmartShuffle(picks.take(count).toList());
    }
  } catch (e) {
    logger.log('Smart shuffle failed', error: e);
  } finally {
    _mixing = false;
    smartShuffleBusy.value = false;
  }
}
