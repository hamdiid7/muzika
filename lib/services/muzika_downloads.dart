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
import 'package:material_ui/material_ui.dart';
import 'package:muzika/main.dart' show logger;
import 'package:muzika/services/common_services.dart';
import 'package:muzika/services/data_manager.dart';

/// Download progress (0–1) of the songs being saved right now, by ytid.
final downloadProgress = ValueNotifier<Map<String, double>>({});

/// Songs saved automatically because they were played. The oldest are
/// removed again past this many (Settings → Cached songs, 0 = none); songs
/// the user downloads with the button are never removed.
final autoCacheLimit = ValueNotifier<int>(
  Hive.box('settings').get('autoCacheLimit', defaultValue: 200) as int,
);

void setAutoCacheLimit(int limit) {
  autoCacheLimit.value = limit;
  unawaited(Hive.box('settings').put('autoCacheLimit', limit));
  _trimAutoCache();
}

/// Downloads run one at a time so they don't fight playback for bandwidth.
Future<void> _chain = Future.value();

bool isSongDownloading(String ytid) => downloadProgress.value.containsKey(ytid);

/// Saved because it was played, not because the user downloaded it.
bool isAutoCachedSong(Map song) => song['autoCached'] == true;

/// Downloaded on purpose with the download button (cached songs don't count).
bool isSongDownloaded(String ytid) => userOfflineSongs.value
    .whereType<Map>()
    .any((s) => s['ytid'] == ytid && !isAutoCachedSong(s));

/// Removes every song that was only cached from playing; downloads stay.
/// Returns how many were removed.
Future<int> clearCachedSongs() async {
  final cached = userOfflineSongs.value
      .whereType<Map>()
      .where(isAutoCachedSong)
      .map((s) => s['ytid'])
      .toList();
  for (final ytid in cached) {
    await removeSongFromOffline(ytid);
  }
  return cached.length;
}

/// The download button: saves [song] for offline listening and marks it as
/// the user's own download (never cleaned up automatically).
Future<bool> downloadSong(Map song) async {
  final ytid = song['ytid']?.toString() ?? '';
  if (ytid.isEmpty) return false;
  if (isSongAlreadyOffline(ytid)) {
    _keep(ytid);
    return true;
  }
  return _enqueue(song, auto: false);
}

/// Saves a song that just started playing, so everything played ends up in
/// Offline.
void autoCachePlayedSong(Map? song) {
  final ytid = song?['ytid']?.toString() ?? '';
  if (song == null || ytid.isEmpty || song['isLive'] == true) return;
  if (autoCacheLimit.value <= 0) return;
  if (isSongAlreadyOffline(ytid) || isSongDownloading(ytid)) return;
  unawaited(_enqueue(song, auto: true));
}

Future<bool> _enqueue(Map song, {required bool auto}) {
  final ytid = song['ytid'].toString();
  _setProgress(ytid, 0);
  final completer = Completer<bool>();
  _chain = _chain.then((_) async {
    var ok = false;
    try {
      ok = await makeSongOffline({
        ...song,
        'autoCached': auto,
      }, onProgress: (p) => _setProgress(ytid, p));
      if (ok && auto) _trimAutoCache();
      if (ok && !auto) _keep(ytid);
    } catch (e, st) {
      logger.log('Download failed for $ytid', error: e, stackTrace: st);
    } finally {
      _clearProgress(ytid);
      completer.complete(ok);
    }
  });
  return completer.future;
}

/// Turns an automatic save into a kept download.
void _keep(String ytid) {
  final songs = List.from(userOfflineSongs.value);
  final i = songs.indexWhere((s) => s['ytid'] == ytid);
  if (i == -1 || songs[i]['autoCached'] != true) return;
  songs[i] = {...songs[i] as Map, 'autoCached': false};
  userOfflineSongs.value = songs;
  unawaited(addOrUpdateData<List>('userNoBackup', 'offlineSongs', songs));
}

void _trimAutoCache() {
  final auto =
      userOfflineSongs.value
          .whereType<Map>()
          .where((s) => s['autoCached'] == true)
          .toList()
        ..sort(
          (a, b) => ((a['dateAdded'] ?? 0) as int).compareTo(
            (b['dateAdded'] ?? 0) as int,
          ),
        );
  final limit = autoCacheLimit.value;
  if (auto.length <= limit) return;
  for (final song in auto.take(auto.length - limit)) {
    unawaited(removeSongFromOffline(song['ytid']));
  }
}

DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);

void _setProgress(String ytid, double value) {
  final now = DateTime.now();
  // Rebuild listeners at most ~8 times a second while bytes stream in.
  if (value > 0 &&
      value < 1 &&
      now.difference(_lastNotify) < const Duration(milliseconds: 120)) {
    downloadProgress.value[ytid] = value;
    return;
  }
  _lastNotify = now;
  downloadProgress.value = {...downloadProgress.value, ytid: value};
}

void _clearProgress(String ytid) {
  downloadProgress.value = {...downloadProgress.value}..remove(ytid);
}
