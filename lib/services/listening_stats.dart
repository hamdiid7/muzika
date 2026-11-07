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

import 'package:hive_flutter/hive_flutter.dart';
import 'package:muzika/main.dart' show audioHandler;
import 'package:muzika/services/common_services.dart';
import 'package:muzika/services/muzika_queue.dart' show discoverPreviewId;
import 'package:muzika/services/playlists_manager.dart';
import 'package:muzika/services/story_reminder.dart';

/// Seconds listened per song, so "+" can save to the playlist you actually
/// listen to the most.
class ListeningStats {
  ListeningStats._();

  static final instance = ListeningStats._();

  static const _key = 'listenSeconds';
  static const _tick = Duration(seconds: 10);
  static const _maxSongs = 2000;

  late final Map<String, int> _seconds = _load();
  Timer? _timer;
  int _ticksSinceSave = 0;

  Map<String, int> _load() {
    final raw = Hive.box('user').get(_key);
    if (raw is! Map) return {};
    return {
      for (final e in raw.entries)
        if (e.value is int) e.key.toString(): e.value as int,
    };
  }

  void start() {
    _timer ??= Timer.periodic(_tick, (_) => _onTick());
  }

  void _onTick() {
    final state = audioHandler.playbackState.valueOrNull;
    final item = audioHandler.mediaItem.valueOrNull;
    if (state == null || item == null || !state.playing) return;
    final ytid = (item.extras?['ytid'] ?? item.id).toString();
    // Discover previews don't count.
    if (ytid == discoverPreviewId) return;
    _seconds[ytid] = (_seconds[ytid] ?? 0) + _tick.inSeconds;
    _recordDay(
      ytid,
      item.title,
      item.artist,
      (item.extras?['highResImage'] ??
              item.extras?['lowResImage'] ??
              item.artUri)
          ?.toString(),
    );
    if (++_ticksSinceSave >= 6) _save();
  }

  // -------------------------------------------------------------------------
  // Per-day listening (Muzika "Your day in music")
  // -------------------------------------------------------------------------

  static const _dailyKey = 'dailyListen';
  static const _keepDays = 30;

  late final Map<String, Map<String, dynamic>> _days = _loadDays();

  Map<String, Map<String, dynamic>> _loadDays() {
    final raw = Hive.box('user').get(_dailyKey);
    if (raw is! Map) return {};
    return {
      for (final e in raw.entries)
        if (e.value is Map)
          e.key.toString(): Map<String, dynamic>.from(e.value as Map),
    };
  }

  static String dayKey(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  void _recordDay(String ytid, String title, String? artist, String? image) {
    final now = DateTime.now();
    final day = _days.putIfAbsent(dayKey(now), () => {});
    final songs = Map<String, dynamic>.from(day['songs'] as Map? ?? {});
    songs[ytid] = ((songs[ytid] as num?) ?? 0) + _tick.inSeconds;
    if (songs.values.fold<num>(0, (a, b) => a + (b as num)) >= 60) {
      unawaited(StoryReminder.bookForToday());
    }
    final meta = Map<String, dynamic>.from(day['meta'] as Map? ?? {});
    meta[ytid] = {'title': title, 'artist': artist ?? '', 'image': image};
    final hours = Map<String, dynamic>.from(day['hours'] as Map? ?? {});
    hours['${now.hour}'] =
        ((hours['${now.hour}'] as num?) ?? 0) + _tick.inSeconds;
    day
      ..['songs'] = songs
      ..['meta'] = meta
      ..['hours'] = hours;
  }

  void _saveDays() {
    if (_days.length > _keepDays) {
      final keys = _days.keys.toList()..sort();
      for (final k in keys.take(_days.length - _keepDays)) {
        _days.remove(k);
      }
    }
    unawaited(Hive.box('user').put(_dailyKey, _days));
  }

  /// A cover that will actually load: the recorded one when it is a web
  /// image or a file that still exists, else the song's cover from the
  /// offline, liked or recent lists.
  static String? _cover(String ytid, String? recorded) {
    bool usable(String? u) {
      if (u == null || u.isEmpty || u == 'null') return false;
      if (u.startsWith('http')) return true;
      final path = u.startsWith('file://') ? Uri.parse(u).toFilePath() : u;
      return File(path).existsSync();
    }

    if (usable(recorded)) return recorded;
    for (final list in [
      userOfflineSongs.value,
      userLikedSongsList.value,
      userRecentlyPlayed.value,
    ]) {
      for (final s in list.whereType<Map>()) {
        if ('${s['ytid']}' != ytid) continue;
        for (final k in [
          'highResImage',
          'lowResImage',
          'image',
          'artworkPath',
        ]) {
          final v = s[k]?.toString();
          if (usable(v)) return v;
        }
      }
    }
    return null;
  }

  /// What was played on [date]: seconds per song (with title, artist and
  /// cover) and seconds per hour of the day. Null when nothing was played.
  DayListening? day(DateTime date) {
    final raw = _days[dayKey(date)];
    if (raw == null) return null;
    final songs = Map<String, dynamic>.from(raw['songs'] as Map? ?? {});
    if (songs.isEmpty) return null;
    final meta = Map<String, dynamic>.from(raw['meta'] as Map? ?? {});
    final hours = Map<String, dynamic>.from(raw['hours'] as Map? ?? {});
    final ranked = songs.entries.toList()
      ..sort((a, b) => (b.value as num).compareTo(a.value as num));
    return DayListening(
      date: date,
      songs: [
        for (final e in ranked)
          (
            ytid: e.key,
            seconds: (e.value as num).toInt(),
            title: '${(meta[e.key] as Map?)?['title'] ?? ''}',
            artist: '${(meta[e.key] as Map?)?['artist'] ?? ''}',
            image: _cover(e.key, (meta[e.key] as Map?)?['image']?.toString()),
          ),
      ],
      hours: {
        for (final e in hours.entries)
          int.parse(e.key): (e.value as num).toInt(),
      },
    );
  }

  void _save() {
    _ticksSinceSave = 0;
    if (_seconds.length > _maxSongs) {
      final keep =
          (_seconds.entries.toList()
                ..sort((a, b) => b.value.compareTo(a.value)))
              .take(_maxSongs);
      _seconds
        ..clear()
        ..addEntries(keep);
    }
    unawaited(Hive.box('user').put(_key, Map<String, int>.from(_seconds)));
    _saveDays();
  }

  int secondsFor(String ytid) => _seconds[ytid] ?? 0;

  /// The user-created playlist with the most listening time, or null when
  /// there is none. Ties go to the bigger playlist.
  Map? favoritePlaylist() {
    final playlists = getUserCustomPlaylists();
    if (playlists.isEmpty) return null;
    Map? best;
    var bestScore = -1;
    var bestSize = -1;
    for (final playlist in playlists) {
      final songs = playlist['list'] as List? ?? const [];
      var score = 0;
      for (final song in songs) {
        if (song is Map) score += secondsFor('${song['ytid']}');
      }
      if (score > bestScore ||
          (score == bestScore && songs.length > bestSize)) {
        best = playlist;
        bestScore = score;
        bestSize = songs.length;
      }
    }
    return best;
  }
}

/// One day of listening, for the daily story.
class DayListening {
  const DayListening({
    required this.date,
    required this.songs,
    required this.hours,
  });

  final DateTime date;

  /// Most played first.
  final List<
    ({String ytid, int seconds, String title, String artist, String? image})
  >
  songs;

  /// Seconds listened in each hour (0–23).
  final Map<int, int> hours;

  int get totalSeconds => songs.fold(0, (sum, s) => sum + s.seconds);

  /// Artists by seconds listened, most first.
  List<({String name, int seconds, String? image})> get artists {
    final by = <String, ({int seconds, String? image})>{};
    for (final s in songs) {
      final name = s.artist.split(RegExp(r',|&| x | feat\.?')).first.trim();
      if (name.isEmpty) continue;
      final prev = by[name];
      by[name] = (
        seconds: (prev?.seconds ?? 0) + s.seconds,
        image: prev?.image ?? s.image,
      );
    }
    final list = [
      for (final e in by.entries)
        (name: e.key, seconds: e.value.seconds, image: e.value.image),
    ]..sort((a, b) => b.seconds.compareTo(a.seconds));
    return list;
  }

  /// The hour with the most listening.
  int? get peakHour {
    if (hours.isEmpty) return null;
    return hours.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
  }
}
