/*
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

// The consonant of each row of the Ethiopic block, eight letters a row from
// U+1200: ሀ ለ ሐ መ ሠ ረ ሰ ሸ ቀ ቈ ቐ ቘ በ ቨ ተ ቸ ኀ ኈ ነ ኘ አ ከ ኰ ኸ ዀ ወ ዐ ዘ ዠ የ ደ ዸ ጀ ገ
// ጐ ጘ ጠ ጨ ጰ ጸ ፀ ፈ ፐ.
const _consonants = [
  'h', 'l', 'h', 'm', 's', 'r', 's', 'sh', 'k', 'kw', 'k', 'kw', 'b', 'v', //
  't', 'ch', 'h', 'hw', 'n', 'ny', '', 'k', 'kw', 'h', 'hw', 'w', '', 'z', //
  'zh', 'y', 'd', 'd', 'j', 'g', 'gw', 'ng', 't', 'ch', 'p', 'ts', 'ts', 'f',
  'p',
];

// The vowel of each of a row's eight letters: ለ ሉ ሊ ላ ሌ ል ሎ ሏ.
const _vowels = ['e', 'u', 'i', 'a', 'e', '', 'o', 'wa'];

// Rows whose first letter is said with an "a": ሀ ሐ ኀ and the vowels አ ዐ.
const _aFirst = {0, 2, 16, 20, 26};

/// [text] with its Ethiopic letters spelled in Latin ones, the way artists'
/// names are usually written in catalogs ("ቴዲ አፍሮ" → "tedi afro"), or null
/// when it has none. Rough on purpose: the catalog's own search forgives
/// the difference between "tedi" and "Teddy".
String? ethiopicToLatin(String text) {
  var found = false;
  final out = StringBuffer();
  for (final rune in text.runes) {
    if (rune < 0x1200 || rune > 0x137F) {
      out.writeCharCode(rune);
      continue;
    }
    found = true;
    final row = (rune - 0x1200) ~/ 8;
    final order = (rune - 0x1200) % 8;
    if (row >= _consonants.length) {
      // Ethiopic punctuation and numerals: a gap between words.
      out.write(' ');
      continue;
    }
    final vowel = order == 0 && _aFirst.contains(row)
        ? 'a'
        // እ and ዕ alone are a sound of their own.
        : order == 5 && _consonants[row].isEmpty
        ? 'e'
        : _vowels[order];
    out
      ..write(_consonants[row])
      ..write(vowel);
  }
  if (!found) return null;
  return out.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
}
