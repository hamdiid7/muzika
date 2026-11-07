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

/// Muzika's mark, in one colour ([color], else the text colour): drawn
/// beside the name on Home and on every card that's shared.
class MuzikaLogo extends StatelessWidget {
  const MuzikaLogo({super.key, this.height = 18, this.color});

  final double height;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      'assets/icons/muzika_logo.png',
      height: height,
      color: color ?? Theme.of(context).colorScheme.onSurface,
      filterQuality: FilterQuality.medium,
    );
  }
}
