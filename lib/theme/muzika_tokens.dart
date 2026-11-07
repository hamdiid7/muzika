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

/// Design tokens from the Muzika Figma file (White Theme + "– Dark" frames).
abstract final class MuzikaColors {
  // Light
  static const lightBg = Color(0xFFFFFFFF);
  static const lightSurface = Color(0xFFF3F3F6); // chips, fields, sheets
  static const lightLine = Color(0xFFD1D1D6);
  static const lightText = Color(0xFF000000);
  static const lightMuted = Color(0xFF6B6B70);

  // Dark (charcoal, after the "too dark" pass)
  static const darkBg = Color(0xFF212121);
  static const darkSurface = Color(0xFF363636);
  static const darkLine = Color(0xFF4A4A4A);
  static const darkText = Color(0xFFFFFFFF);
  static const darkMuted = Color(0xFFA9A9AF);

  static const danger = Color(0xFFD92E2E);
  static const link = Color(0xFF9ECCFF);
}

abstract final class MuzikaFonts {
  static const heading = 'Metropolis';
  static const body = 'Metropolis';

  /// Ge'ez script (Amharic, Tigrinya…) for titles and lyrics.
  static const fallback = <String>['NotoSansEthiopic'];
}

/// Every Muzika text style goes through these helpers. Metropolis ships as
/// static weights (400–800); the `wght` variation only matters for the
/// variable Ethiopic fallback.
TextStyle muzikaHeading(double size, {Color? color, int weight = 700}) =>
    TextStyle(
      fontFamily: MuzikaFonts.heading,
      fontFamilyFallback: MuzikaFonts.fallback,
      fontSize: size,
      fontWeight: FontWeight.values[(weight ~/ 100) - 1],
      fontVariations: [FontVariation.weight(weight.toDouble())],
      letterSpacing: -0.2,
      color: color,
    );

TextStyle muzikaBody(double size, {Color? color, int weight = 400}) =>
    TextStyle(
      fontFamily: MuzikaFonts.body,
      fontFamilyFallback: MuzikaFonts.fallback,
      fontSize: size,
      fontWeight: FontWeight.values[(weight ~/ 100) - 1],
      fontVariations: [FontVariation.weight(weight.toDouble())],
      color: color,
    );

/// The one colour accent: section labels in settings-style lists.
Color muzikaAccent(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
    ? MuzikaColors.link
    : const Color(0xFF2F5FD0);
