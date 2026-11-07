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

import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';
import 'package:muzika/services/settings_manager.dart';
import 'package:muzika/theme/muzika_tokens.dart';

/// Inter for display/headline/title, DM Sans for body and labels.
TextTheme _muzikaTextTheme(TextTheme base, ColorScheme scheme) {
  TextStyle h(TextStyle? s, int w) => (s ?? const TextStyle()).merge(
    muzikaHeading(s?.fontSize ?? 16, color: scheme.onSurface, weight: w),
  );
  TextStyle b(TextStyle? s, int w) => (s ?? const TextStyle()).merge(
    muzikaBody(s?.fontSize ?? 14, color: scheme.onSurface, weight: w),
  );
  return base.copyWith(
    displayLarge: h(base.displayLarge, 700),
    displayMedium: h(base.displayMedium, 700),
    displaySmall: h(base.displaySmall, 700),
    headlineLarge: h(base.headlineLarge, 700),
    headlineMedium: h(base.headlineMedium, 700),
    headlineSmall: h(base.headlineSmall, 700),
    titleLarge: h(base.titleLarge, 700),
    titleMedium: b(base.titleMedium, 500),
    titleSmall: b(base.titleSmall, 500),
    bodyLarge: b(base.bodyLarge, 400),
    bodyMedium: b(base.bodyMedium, 400),
    bodySmall: b(base.bodySmall, 400).copyWith(color: scheme.onSurfaceVariant),
    labelLarge: b(base.labelLarge, 500),
    labelMedium: b(base.labelMedium, 500),
    labelSmall: b(base.labelSmall, 500),
  );
}

ThemeMode themeMode = getThemeMode(themeModeSetting);
Brightness brightness = getBrightnessFromThemeMode(themeMode);

Brightness getBrightnessFromThemeMode(ThemeMode themeMode) {
  final themeBrightnessMapping = {
    ThemeMode.light: Brightness.light,
    ThemeMode.dark: Brightness.dark,
    ThemeMode.system:
        SchedulerBinding.instance.platformDispatcher.platformBrightness,
  };

  return themeBrightnessMapping[themeMode] ?? Brightness.dark;
}

ThemeMode getThemeMode(int themeModeIndex) {
  const themeModes = ThemeMode.values;
  if (themeModeIndex >= 0 && themeModeIndex < themeModes.length) {
    return themeModes[themeModeIndex];
  }
  return ThemeMode.system;
}

/// Muzika is monochrome: black on white, white on charcoal. Dynamic (Material
/// You) colors and the accent picker are intentionally ignored.
ColorScheme getAppColorScheme(
  ColorScheme? lightColorScheme,
  ColorScheme? darkColorScheme,
) {
  return brightness == Brightness.light ? _muzikaLight : _muzikaDark;
}

const _muzikaLight = ColorScheme(
  brightness: Brightness.light,
  primary: MuzikaColors.lightText,
  onPrimary: MuzikaColors.lightBg,
  primaryContainer: MuzikaColors.lightSurface,
  onPrimaryContainer: MuzikaColors.lightText,
  secondary: MuzikaColors.lightMuted,
  onSecondary: MuzikaColors.lightBg,
  secondaryContainer: MuzikaColors.lightSurface,
  onSecondaryContainer: MuzikaColors.lightText,
  tertiary: MuzikaColors.lightMuted,
  onTertiary: MuzikaColors.lightBg,
  error: MuzikaColors.danger,
  onError: MuzikaColors.lightBg,
  surface: MuzikaColors.lightBg,
  onSurface: MuzikaColors.lightText,
  onSurfaceVariant: MuzikaColors.lightMuted,
  surfaceContainerLowest: MuzikaColors.lightBg,
  surfaceContainerLow: Color(0xFFF8F8FA),
  surfaceContainer: MuzikaColors.lightSurface,
  surfaceContainerHigh: Color(0xFFECECF0),
  surfaceContainerHighest: Color(0xFFE6E6EA),
  outline: MuzikaColors.lightLine,
  outlineVariant: Color(0xFFE6E6EA),
  inverseSurface: Color(0xFF212124),
  onInverseSurface: MuzikaColors.lightBg,
  shadow: Color(0xFF000000),
);

const _muzikaDark = ColorScheme(
  brightness: Brightness.dark,
  primary: MuzikaColors.darkText,
  onPrimary: MuzikaColors.darkBg,
  primaryContainer: MuzikaColors.darkSurface,
  onPrimaryContainer: MuzikaColors.darkText,
  secondary: MuzikaColors.darkMuted,
  onSecondary: MuzikaColors.darkBg,
  secondaryContainer: MuzikaColors.darkSurface,
  onSecondaryContainer: MuzikaColors.darkText,
  tertiary: MuzikaColors.darkMuted,
  onTertiary: MuzikaColors.darkBg,
  error: Color(0xFFFF6B6B),
  onError: MuzikaColors.darkBg,
  surface: MuzikaColors.darkBg,
  onSurface: MuzikaColors.darkText,
  onSurfaceVariant: MuzikaColors.darkMuted,
  surfaceContainerLowest: Color(0xFF1B1B1B),
  surfaceContainerLow: Color(0xFF2A2A2A),
  surfaceContainer: MuzikaColors.darkSurface,
  surfaceContainerHigh: Color(0xFF3D3D3D),
  surfaceContainerHighest: Color(0xFF454545),
  outline: MuzikaColors.darkLine,
  outlineVariant: Color(0xFF3D3D3D),
  inverseSurface: Color(0xFFF3F3F6),
  onInverseSurface: MuzikaColors.darkBg,
  shadow: Color(0xFF000000),
);

ThemeData getAppTheme(ColorScheme colorScheme, {Color? tint}) {
  // The playing cover's colour in every surface: the whole app takes on
  // the song (Muzika), still light or dark enough for the text on it.
  if (tint != null) {
    final amount = colorScheme.brightness == Brightness.light ? 0.10 : 0.14;
    Color mix(Color c) => Color.lerp(c, tint, amount)!;
    colorScheme = colorScheme.copyWith(
      surface: mix(colorScheme.surface),
      surfaceContainerLowest: mix(colorScheme.surfaceContainerLowest),
      surfaceContainerLow: mix(colorScheme.surfaceContainerLow),
      surfaceContainer: mix(colorScheme.surfaceContainer),
      surfaceContainerHigh: mix(colorScheme.surfaceContainerHigh),
      surfaceContainerHighest: mix(colorScheme.surfaceContainerHighest),
    );
  }
  final base = colorScheme.brightness == Brightness.light
      ? ThemeData.light()
      : ThemeData.dark();

  final isLight = colorScheme.brightness == Brightness.light;
  final isPureBlack =
      colorScheme.brightness == Brightness.dark && usePureBlackColor.value;

  // Pure black theme colors
  const pureBlack = Color(0xFF000000);
  const pureBlackElevated = Color(0xFF0A0A0A);
  const pureBlackContainer = Color(0xFF121212);
  const pureBlackContainerHigh = Color(0xFF1A1A1A);

  final bgColor = isLight
      ? colorScheme.surface
      : (isPureBlack ? pureBlack : null);

  final cardBgColor = isLight
      ? colorScheme.surfaceContainerLow
      : (isPureBlack ? pureBlackElevated : null);

  // modified color scheme for pure black theme
  final effectiveColorScheme = isPureBlack
      ? colorScheme.copyWith(
          surface: pureBlack,
          surfaceContainerLowest: pureBlack,
          surfaceContainerLow: pureBlackElevated,
          surfaceContainer: pureBlackContainer,
          surfaceContainerHigh: pureBlackContainerHigh,
          surfaceContainerHighest: pureBlackContainerHigh,
        )
      : colorScheme;

  return ThemeData(
    fontFamily: MuzikaFonts.body,
    fontFamilyFallback: MuzikaFonts.fallback,
    textTheme: _muzikaTextTheme(base.textTheme, effectiveColorScheme),
    scaffoldBackgroundColor: bgColor,
    colorScheme: effectiveColorScheme,
    cardColor: cardBgColor,
    cardTheme: base.cardTheme.copyWith(
      elevation: 0,
      color: cardBgColor,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    appBarTheme: base.appBarTheme.copyWith(
      backgroundColor: bgColor,
      foregroundColor: effectiveColorScheme.primary,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: muzikaHeading(24, color: effectiveColorScheme.primary),
      toolbarHeight: 64,
      iconTheme: IconThemeData(
        color: effectiveColorScheme.onSurfaceVariant,
        size: 24,
      ),
      actionsIconTheme: IconThemeData(
        color: effectiveColorScheme.onSurfaceVariant,
        size: 24,
      ),
    ),
    listTileTheme: base.listTileTheme.copyWith(
      textColor: effectiveColorScheme.primary,
      iconColor: effectiveColorScheme.primary,
    ),
    sliderTheme: base.sliderTheme.copyWith(
      year2023: false,
      trackHeight: 12,
      thumbSize: WidgetStateProperty.all(const Size(6, 30)),
    ),
    bottomSheetTheme: base.bottomSheetTheme.copyWith(
      backgroundColor: isLight
          ? colorScheme.surfaceContainerLow
          : (isPureBlack ? pureBlackElevated : null),
    ),
    inputDecorationTheme: base.inputDecorationTheme.copyWith(
      filled: true,
      isDense: true,
      fillColor: isLight
          ? colorScheme.surfaceContainerHighest
          : (isPureBlack
                ? pureBlackContainerHigh
                : colorScheme.surfaceContainerHigh),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      contentPadding: const EdgeInsets.fromLTRB(18, 14, 20, 14),
    ),
    dialogTheme: base.dialogTheme.copyWith(
      backgroundColor: isLight
          ? colorScheme.surfaceContainerLow
          : (isPureBlack ? pureBlackContainer : null),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
    ),
    navigationBarTheme: base.navigationBarTheme.copyWith(
      backgroundColor: bgColor,
      elevation: 0,
      height: 70,
      indicatorColor: effectiveColorScheme.primaryContainer,
      iconTheme: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return IconThemeData(
            color: effectiveColorScheme.onPrimaryContainer,
            size: 24,
          );
        }
        return IconThemeData(
          color: effectiveColorScheme.onSurfaceVariant,
          size: 24,
        );
      }),
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return TextStyle(
            color: effectiveColorScheme.onSurface,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          );
        }
        return TextStyle(
          color: effectiveColorScheme.onSurfaceVariant,
          fontSize: 12,
          fontWeight: FontWeight.w500,
        );
      }),
    ),
    navigationRailTheme: base.navigationRailTheme.copyWith(
      backgroundColor: bgColor,
      elevation: 0,
      indicatorColor: effectiveColorScheme.primaryContainer,
      selectedIconTheme: IconThemeData(
        color: effectiveColorScheme.onPrimaryContainer,
        size: 24,
      ),
      unselectedIconTheme: IconThemeData(
        color: effectiveColorScheme.onSurfaceVariant,
        size: 24,
      ),
      selectedLabelTextStyle: TextStyle(
        color: effectiveColorScheme.onSurface,
        fontSize: 12,
        fontWeight: FontWeight.w600,
      ),
      unselectedLabelTextStyle: TextStyle(
        color: effectiveColorScheme.onSurfaceVariant,
        fontSize: 12,
        fontWeight: FontWeight.w500,
      ),
    ),
    popupMenuTheme: base.popupMenuTheme.copyWith(
      color: isLight
          ? colorScheme.surfaceContainerLow
          : (isPureBlack ? pureBlackContainer : null),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    dividerTheme: base.dividerTheme.copyWith(
      color: effectiveColorScheme.outlineVariant,
      thickness: 1,
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: effectiveColorScheme.secondaryContainer,
      closeIconColor: effectiveColorScheme.onSecondaryContainer,
      contentTextStyle: TextStyle(
        color: effectiveColorScheme.onSecondaryContainer,
        fontWeight: FontWeight.w500,
      ),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: effectiveColorScheme.outlineVariant,
          width: 0.2,
        ),
      ),
      elevation: 0,
      actionTextColor: effectiveColorScheme.secondary,
    ),
    // Material 3 switch: a check inside the thumb when on, monochrome.
    switchTheme: SwitchThemeData(
      thumbIcon: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? Icon(Icons.check_rounded, color: effectiveColorScheme.onSurface)
            : null,
      ),
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? effectiveColorScheme.surface
            : effectiveColorScheme.outline,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? effectiveColorScheme.onSurface
            : effectiveColorScheme.surfaceContainerHighest,
      ),
      trackOutlineColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? Colors.transparent
            : effectiveColorScheme.outline,
      ),
    ),
    visualDensity: VisualDensity.adaptivePlatformDensity,
    useMaterial3: true,
  );
}
