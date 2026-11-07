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

/// How an artist's name sounds, word by word: "Efrem Tamiru", "Ephrem
/// Tamiru" and "Ephrem Tamru" are all "frm tmr". Amharic names reach the
/// catalogs spelt many ways in Latin letters (each label picks one), so one
/// singer can be two or three artists there; this tells them apart from
/// different people. Letters only; sounds written two ways (ph/f, tz/ts,
/// q/k) count as one; vowels and doubled letters dropped.
String artistSoundKey(String name) => name
    .toLowerCase()
    .replaceAll('ph', 'f')
    .replaceAll('tz', 'ts')
    .replaceAll('q', 'k')
    .split(RegExp(r'\s+'))
    .map(
      (w) => w
          .replaceAll(RegExp('[^a-zሀ-፿]'), '')
          .replaceAll(RegExp('[aeiouy]'), '')
          .replaceAllMapped(RegExp(r'(.)\1+'), (m) => m[1]!),
    )
    .where((w) => w.isNotEmpty)
    .join(' ');

/// Whether two names are one artist spelt two ways: the same sound, and a
/// full name (two words or more), so "Teddy" and "Tedy" stay apart.
bool sameArtistName(String a, String b) {
  final ka = artistSoundKey(a);
  return ka.contains(' ') && ka == artistSoundKey(b);
}
