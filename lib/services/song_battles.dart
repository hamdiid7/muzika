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

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

/// Results of album matches: every song that played in one, with how many
/// rounds it won. Library's "Song ranks" lists them.
class SongBattles {
  SongBattles._();

  static const _key = 'songBattles';

  /// Bumped on every result, so Library can redraw.
  static final changes = ValueNotifier<int>(0);

  static Map<String, Map<String, dynamic>> _read() {
    final raw = Hive.box('user').get(_key);
    if (raw is! Map) return {};
    return {
      for (final e in raw.entries)
        if (e.value is Map)
          '${e.key}': Map<String, dynamic>.from(e.value as Map),
    };
  }

  /// The song map kept with a result: just what a row and playback need.
  static Map<String, dynamic> _slim(Map song) => {
    for (final k in [
      'ytid',
      'title',
      'artist',
      'artistId',
      'album',
      'albumId',
      'image',
      'lowResImage',
      'highResImage',
      'duration',
    ])
      if (song[k] != null) k: song[k],
  };

  /// One round: [winner] beat [loser].
  static void record({required Map winner, required Map loser}) {
    final all = _read();
    for (final (song, won) in [(winner, true), (loser, false)]) {
      final id = '${song['ytid'] ?? ''}';
      if (id.isEmpty) continue;
      final entry = all[id] ?? {'wins': 0, 'rounds': 0};
      all[id] = {
        'song': _slim(song),
        'wins': ((entry['wins'] as num?) ?? 0).toInt() + (won ? 1 : 0),
        'rounds': ((entry['rounds'] as num?) ?? 0).toInt() + 1,
      };
    }
    unawaited(Hive.box('user').put(_key, all));
    changes.value++;
  }

  static bool get isEmpty => _read().isEmpty;

  /// Every song that played in a match, most wins first. Songs with the
  /// same number of wins share a rank (1, 2, 2, 3…).
  static List<({int rank, Map song, int wins, int rounds})> ranked() {
    final entries = _read().values.toList()
      ..sort((a, b) {
        final byWins = ((b['wins'] as num?) ?? 0).compareTo(
          (a['wins'] as num?) ?? 0,
        );
        if (byWins != 0) return byWins;
        return ((a['rounds'] as num?) ?? 0).compareTo(
          (b['rounds'] as num?) ?? 0,
        );
      });
    final out = <({int rank, Map song, int wins, int rounds})>[];
    var rank = 0;
    int? lastWins;
    for (final e in entries) {
      final wins = ((e['wins'] as num?) ?? 0).toInt();
      if (wins != lastWins) {
        rank++;
        lastWins = wins;
      }
      out.add((
        rank: rank,
        song: Map<String, dynamic>.from(e['song'] as Map),
        wins: wins,
        rounds: ((e['rounds'] as num?) ?? 0).toInt(),
      ));
    }
    return out;
  }
}
