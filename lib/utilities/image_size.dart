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

import 'package:muzika/services/data_saver.dart';

/// Sizes the servers make: asking for one of these keeps their caches warm.
const _sizes = [120, 250, 500, 1000];

/// [url] asked at about [pixels] wide, where its server can scale it
/// (Deezer, Apple, Google's image hosts): a cover drawn 56 px wide needn't
/// download as 1000 px (11 KB instead of 67). Other addresses are left as
/// they are. With the data saver on, one size smaller.
String sizedImageUrl(String url, double pixels) {
  var i = _sizes.indexWhere((s) => s >= pixels);
  if (i < 0) i = _sizes.length - 1;
  if (dataSaverOn && i > 0) i--;
  final px = _sizes[i];
  // Deezer: …/cover/<hash>/1000x1000-000000-80-0-0.jpg
  if (url.contains('dzcdn.net')) {
    return url.replaceFirstMapped(
      RegExp(r'/(\d+)x(\d+)-'),
      (m) => int.parse(m[1]!) > px ? '/${px}x$px-' : m[0]!,
    );
  }
  // Apple: …/600x600bb.jpg
  if (url.contains('mzstatic.com')) {
    return url.replaceFirstMapped(
      RegExp(r'/(\d+)x(\d+)(bb|cc)'),
      (m) => int.parse(m[1]!) > px ? '/${px}x$px${m[3]}' : m[0]!,
    );
  }
  // Google (YouTube Music covers, channel photos): …=w544-h544-l90-rj
  if (url.contains('googleusercontent.com') || url.contains('ggpht.com')) {
    return url.replaceFirstMapped(
      RegExp(r'=w(\d+)-h(\d+)'),
      (m) => int.parse(m[1]!) > px ? '=w$px-h$px' : m[0]!,
    );
  }
  return url;
}
