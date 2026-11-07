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

import 'dart:io';

import 'package:hive/hive.dart';
import 'package:material_ui/material_ui.dart';

/// True while the wide Windows layout shows the player and lyrics on the
/// right (Muzika): opening either one then does nothing, it's already there.
final desktopPanels = ValueNotifier<bool>(false);

/// The right side shows the lyrics, full height, instead of the player
/// (tapping the lyrics opens them; the back arrow returns to the player).
final desktopLyricsOpen = ValueNotifier<bool>(false);

/// The sidebar's and the player's widths, set by dragging the lines between
/// them and the page; kept for next time.
final desktopSidebarWidth = ValueNotifier<double>(
  (Hive.box('settings').get('desktopSidebarWidth', defaultValue: 240.0) as num)
      .toDouble(),
);
final desktopPanelWidth = ValueNotifier<double>(
  (Hive.box('settings').get('desktopPanelWidth', defaultValue: 400.0) as num)
      .toDouble(),
);

const desktopSidebarMin = 76.0;
const desktopSidebarMax = 360.0;
const desktopPanelMin = 320.0;
const desktopPanelMax = 640.0;

/// Below this the sidebar shows only the tabs' icons.
const desktopSidebarCompact = 160.0;

void saveDesktopWidths() {
  Hive.box('settings')
    ..put('desktopSidebarWidth', desktopSidebarWidth.value)
    ..put('desktopPanelWidth', desktopPanelWidth.value);
}

/// The wide layout is for Windows windows of at least this width.
bool useDesktopLayout(double width) => Platform.isWindows && width >= 1000;
