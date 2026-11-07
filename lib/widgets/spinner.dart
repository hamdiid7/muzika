/*
 *     Copyright (C) 2026 Valeri Gokadze
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
import 'package:muzika/widgets/muzika_shimmer.dart';

/// Muzika: loading is a shimmer, never a spinning circle. Small slots (an
/// artwork placeholder) shimmer as one block; large ones as song rows.
class Spinner extends StatelessWidget {
  const Spinner({super.key});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final small =
            constraints.hasBoundedHeight && constraints.maxHeight <= 160;
        if (small) {
          return const MuzikaShimmer(
            child: MuzikaSkeletonBox(
              width: double.infinity,
              height: double.infinity,
              radius: 0,
            ),
          );
        }
        return const Align(
          alignment: Alignment.topCenter,
          child: MuzikaSkeletonRows(count: 5),
        );
      },
    );
  }
}
