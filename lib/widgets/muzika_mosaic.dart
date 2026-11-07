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

import 'package:material_ui/material_ui.dart';
import 'package:muzika/widgets/muzika_song_row.dart';

/// A square cover made of four song covers in a 2×2 grid (radio mixes,
/// playlists without their own image). With fewer than four, the first one
/// fills the square.
class MuzikaMosaic extends StatelessWidget {
  const MuzikaMosaic({
    super.key,
    required this.images,
    required this.size,
    this.radius = 8,
  });

  final List<String> images;
  final double size;
  final double radius;

  @override
  Widget build(BuildContext context) {
    Widget cover(String? url, double side) => MuzikaCover(
      song: {'image': url, 'lowResImage': url},
      size: side,
      radius: 0,
    );

    final Widget child;
    if (images.length < 4) {
      child = cover(images.firstOrNull, size);
    } else {
      final half = size / 2;
      child = Column(
        children: [
          Row(children: [cover(images[0], half), cover(images[1], half)]),
          Row(children: [cover(images[2], half), cover(images[3], half)]),
        ],
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(width: size, height: size, child: child),
    );
  }
}
