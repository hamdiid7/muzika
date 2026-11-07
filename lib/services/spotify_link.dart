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

import 'dart:convert';

import 'package:http/http.dart' as http;

/// A Spotify playlist or album read from its link: its name and songs.
typedef SpotifyList = ({
  String name,
  List<({String title, String artist})> songs,
});

/// The most songs Spotify's player shows of a list (longer ones are cut).
const spotifyLinkLimit = 100;

/// "open.spotify.com/playlist/…", "spotify:album:…": the kind and id.
({String kind, String id})? parseSpotifyLink(String text) {
  final m = RegExp(r'(playlist|album)[/:]([A-Za-z0-9]{22})')
      .firstMatch(text.trim());
  return m == null ? null : (kind: m[1]!, id: m[2]!);
}

/// The playlist or album behind a Spotify [link], read from the player
/// Spotify gives websites to show it (no account needed, so public lists
/// only): its name and first [spotifyLinkLimit] songs. Null when the link
/// isn't one, or Spotify doesn't show it.
Future<SpotifyList?> spotifyListFromLink(String link) async {
  final found = parseSpotifyLink(link);
  if (found == null) return null;
  final r = await http
      .get(
        Uri.parse('https://open.spotify.com/embed/${found.kind}/${found.id}'),
        headers: const {'User-Agent': 'Mozilla/5.0'},
      )
      .timeout(const Duration(seconds: 20));
  if (r.statusCode != 200) return null;
  final m = RegExp(
    r'<script id="__NEXT_DATA__" type="application/json">(.*?)</script>',
    dotAll: true,
  ).firstMatch(utf8.decode(r.bodyBytes));
  if (m == null) return null;
  final entity =
      (((((jsonDecode(m[1]!) as Map)['props'] as Map?)?['pageProps']
                      as Map?)?['state']
                  as Map?)?['data']
              as Map?)?['entity']
          as Map?;
  if (entity == null) return null;
  // Artists come as "KAROL G, Judeline" with no-break spaces.
  String clean(Object? s) =>
      '${s ?? ''}'.replaceAll(String.fromCharCode(0xA0), " ").trim();
  final songs = [
    for (final t
        in ((entity['trackList'] as List?) ?? const []).whereType<Map>())
      if (clean(t['title']).isNotEmpty)
        (title: clean(t['title']), artist: clean(t['subtitle'])),
  ];
  if (songs.isEmpty) return null;
  return (name: clean(entity['name']), songs: songs);
}
