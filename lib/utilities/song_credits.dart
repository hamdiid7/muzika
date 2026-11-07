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

/// "Taki Taki feat. Selena Gomez, Ozuna & Cardi B" by "DJ Snake" shows as
/// "Taki Taki" by "DJ Snake, Selena Gomez, Ozuna & Cardi B" (Muzika): the
/// featured artists go on the artist line, not in the title.
final _feat = RegExp(
  r'\s*[(\[]?\s*\b(?:feat\.?|ft\.?|featuring)\s+([^)\]]+)[)\]]?',
  caseSensitive: false,
);

({String title, String artist}) songCredits(String title, String artist) {
  final m = _feat.firstMatch(title);
  if (m == null) return (title: title, artist: artist);
  final cleanTitle = title.replaceRange(m.start, m.end, '').trim();
  final featured = m.group(1)!.trim();
  final names = artistNames(artist).map((e) => e.toLowerCase()).toSet();
  final extra = artistNames(featured)
      .where((n) => !names.contains(n.toLowerCase()))
      .toList();
  if (extra.isEmpty) {
    return (title: cleanTitle.isEmpty ? title : cleanTitle, artist: artist);
  }
  final all = artist.trim().isEmpty ? featured : '$artist, $featured';
  return (title: cleanTitle.isEmpty ? title : cleanTitle, artist: all);
}

/// The single artists in an artist line ("A, B & C" -> A, B, C).
List<String> artistNames(String artist) => artist
    .replaceAll(RegExp(r'\s*-\s*Topic$'), '')
    .split(RegExp(r',|\s&\s|\sx\s|\s(?:feat|ft)\.?\s', caseSensitive: false))
    .map((e) => e.trim())
    .where((e) => e.isNotEmpty)
    .toList();
