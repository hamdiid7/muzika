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
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:muzika/services/data_manager.dart';

/// A song NetEase lists as new: its title, first artist and release day.
typedef NeteaseNewSong = ({String title, String artist, DateTime released});

/// NetEase's regions for new songs: Western, Korean, Japanese, Chinese.
const _areas = [96, 16, 8, 7];

/// The songs NetEase lists as new (about 100 per region, the last few
/// weeks), from its public web API; kept six hours. Empty when NetEase
/// doesn't answer.
Future<List<NeteaseNewSong>> neteaseNewSongs() async {
  final lists = await Future.wait([
    for (final area in _areas) _newSongs(area).catchError((_) => <Map>[]),
  ]);
  return [
    for (final list in lists)
      for (final s in list)
        if (s['released'] is int)
          (
            title: '${s['title']}',
            artist: '${s['artist']}',
            released: DateTime.fromMillisecondsSinceEpoch(s['released'] as int),
          ),
  ];
}

Future<List<Map>> _newSongs(int area) async {
  final key = 'netease_new_v1_$area';
  final cached = await getData(
    'cache',
    key,
    cachingDuration: const Duration(hours: 6),
  );
  if (cached is String) {
    return (jsonDecode(cached) as List).whereType<Map>().toList();
  }
  final r = await http
      .get(
        Uri.parse(
          'https://music.163.com/api/v1/discovery/new/songs'
          '?areaId=$area&total=true',
        ),
        headers: const {
          'User-Agent': 'Mozilla/5.0',
          'Referer': 'https://music.163.com',
        },
      )
      .timeout(const Duration(seconds: 10));
  if (r.statusCode != 200) return const [];
  final songs = [
    for (final s
        in ((jsonDecode(r.body) as Map)['data'] as List? ?? const [])
            .whereType<Map>())
      {
        'title': s['name'],
        'artist': ((s['artists'] as List?)?.firstOrNull as Map?)?['name'],
        'released': (s['album'] as Map?)?['publishTime'],
      },
  ];
  unawaited(addOrUpdateData<String>('cache', key, jsonEncode(songs)));
  return songs;
}
