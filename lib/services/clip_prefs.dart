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

import 'package:hive_flutter/hive_flutter.dart';

/// What the Clips feed learns from you (Muzika): a clip you have seen
/// stays away for 7 days, and an artist you swipe away from twice within 3
/// seconds is held back for 30 days (and their related artists are not
/// followed).
class ClipPrefs {
  ClipPrefs._();

  static const _seenKey = 'clipsSeen';
  static const _skipKey = 'clipsQuickSkips';
  static const _seenFor = Duration(days: 7);
  static const _skipsFor = Duration(days: 30);

  static Box get _box => Hive.box('user');

  static Map<String, int> _map(String key) {
    final raw = _box.get(key);
    return raw is Map
        ? {
            for (final e in raw.entries)
              if (e.value is int) '${e.key}': e.value as int,
          }
        : <String, int>{};
  }

  static int get _now => DateTime.now().millisecondsSinceEpoch;

  /// Seen in the last 7 days.
  static bool seenRecently(String songId) {
    final at = _map(_seenKey)[songId];
    return at != null && _now - at < _seenFor.inMilliseconds;
  }

  static void markSeen(String songId) {
    final seen = _map(_seenKey)
      ..removeWhere((_, at) => _now - at > _seenFor.inMilliseconds)
      ..[songId] = _now;
    unawaited(_box.put(_seenKey, seen));
  }

  static String _artistKey(String artist) => artist.trim().toLowerCase();

  /// The clip on screen was swiped away within 3 seconds.
  static void quickSkip(String artist) {
    if (artist.trim().isEmpty) return;
    // "count * 1e13 + time of the last one", so one int holds both.
    final skips = _map(_skipKey);
    final key = _artistKey(artist);
    final old = skips[key];
    var count = old == null ? 0 : old ~/ 10000000000000;
    final last = old == null ? 0 : old % 10000000000000;
    if (_now - last > _skipsFor.inMilliseconds) count = 0;
    skips[key] = (count + 1) * 10000000000000 + _now;
    unawaited(_box.put(_skipKey, skips));
  }

  /// Swiped away quickly twice or more in the last 30 days.
  static bool heldBack(String artist) {
    final value = _map(_skipKey)[_artistKey(artist)];
    if (value == null) return false;
    final count = value ~/ 10000000000000;
    final last = value % 10000000000000;
    return count >= 2 && _now - last < _skipsFor.inMilliseconds;
  }
}
