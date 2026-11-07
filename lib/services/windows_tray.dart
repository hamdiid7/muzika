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

import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

/// Windows: closing the window hides it to the tray ("hidden icons") and
/// the music keeps playing. Click the tray icon to bring it back; Quit in
/// its menu closes Muzika.
class WindowsTray with TrayListener, WindowListener {
  WindowsTray._();

  static final _instance = WindowsTray._();

  static Future<void> init() async {
    if (!Platform.isWindows) return;
    await windowManager.ensureInitialized();
    await windowManager.setPreventClose(true);
    windowManager.addListener(_instance);
    await trayManager.setIcon('assets/icons/tray.ico');
    await trayManager.setToolTip('Muzika');
    await trayManager.setContextMenu(
      Menu(
        items: [
          MenuItem(key: 'show', label: 'Open Muzika'),
          MenuItem.separator(),
          MenuItem(key: 'quit', label: 'Quit'),
        ],
      ),
    );
    trayManager.addListener(_instance);
  }

  Future<void> _show() async {
    await windowManager.show();
    await windowManager.focus();
  }

  @override
  void onWindowClose() => windowManager.hide();

  @override
  void onTrayIconMouseDown() => _show();

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  Future<void> onTrayMenuItemClick(MenuItem menuItem) async {
    switch (menuItem.key) {
      case 'show':
        await _show();
      case 'quit':
        await trayManager.destroy();
        await windowManager.setPreventClose(false);
        await windowManager.destroy();
    }
  }
}
