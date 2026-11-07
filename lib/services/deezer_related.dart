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
import 'package:muzika/main.dart' show logger;
import 'package:muzika/services/data_manager.dart';

/// An artist like another (Muzika), from Deezer's open API (no key, reached
/// directly): Apple's free catalog has no "related artists".
typedef RelatedArtist = ({String name, String? photo});

final _inFlight = <String, Future<List<RelatedArtist>>>{};

String _key(String s) =>
    s.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');

/// Artists like [name], most alike first; kept a week. Empty when Deezer
/// doesn't know the artist by that exact name.
Future<List<RelatedArtist>> relatedArtists(String name) {
  final wanted = _key(name);
  if (wanted.isEmpty) return Future.value(const []);
  return _inFlight[wanted] ??= _read(name, wanted).whenComplete(() {
    _inFlight.remove(wanted);
  });
}

Future<List<RelatedArtist>> _read(String name, String wanted) async {
  final cacheKey = 'deezer_related_v1_$wanted';
  final cached = await getData(
    'cache',
    cacheKey,
    cachingDuration: const Duration(days: 7),
  );
  if (cached is List) {
    return [
      for (final e in cached)
        if (e is Map) (name: '${e['name']}', photo: e['photo'] as String?),
    ];
  }
  try {
    final found = await _get(
      'search/artist?q=${Uri.encodeQueryComponent(name)}&limit=25',
    );
    // The artist by its exact name ("Teddy Afro", not "Teddy Karo"), the
    // one with most fans when several share it.
    final matches =
        [
          for (final a in (found['data'] as List? ?? const []))
            if (a is Map && _key('${a['name']}') == wanted) a,
        ]..sort(
          (a, b) => ((b['nb_fan'] as num?) ?? 0).compareTo(
            (a['nb_fan'] as num?) ?? 0,
          ),
        );
    var result = const <RelatedArtist>[];
    if (matches.isNotEmpty) {
      final related = await _get(
        'artist/${matches.first['id']}/related?limit=20',
      );
      result = [
        for (final a in (related['data'] as List? ?? const []))
          if (a is Map && '${a['name'] ?? ''}'.isNotEmpty)
            (
              name: '${a['name']}',
              photo: (a['picture_xl'] ?? a['picture_big'])?.toString(),
            ),
      ];
    }
    unawaited(
      addOrUpdateData<List>('cache', cacheKey, [
        for (final r in result) {'name': r.name, 'photo': r.photo},
      ]),
    );
    return result;
  } catch (e) {
    logger.log('Deezer related artists failed for $name', error: e);
    return const [];
  }
}

Future<Map<String, dynamic>> _get(String path) async {
  final response = await http
      .get(Uri.parse('https://api.deezer.com/$path'))
      .timeout(const Duration(seconds: 12));
  if (response.statusCode != 200) {
    throw Exception('Deezer ${response.statusCode}');
  }
  return json.decode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
}
