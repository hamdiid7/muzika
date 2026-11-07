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

import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:muzika/services/desktop_panels.dart';
import 'package:muzika/services/router_service.dart';

/// The gear left of every tab's title: opens Settings. Phone layout only:
/// the wide Windows layout has it in the sidebar already.
class SettingsIconButton extends StatelessWidget {
  const SettingsIconButton({super.key, this.color});

  /// The icon's colour (the theme's text colour when null; white over
  /// Clips' videos).
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: desktopPanels,
      builder: (context, wide, _) => wide
          ? const SizedBox.shrink()
          // With its gap to the title.
          : Padding(
              padding: const EdgeInsets.only(right: 6),
              child: _button(context),
            ),
    );
  }

  Widget _button(BuildContext context) {
    return IconButton(
      tooltip: 'Settings',
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 36, height: 36),
      icon: Icon(
        FluentIcons.settings_24_regular,
        size: 24,
        color: color ?? Theme.of(context).colorScheme.onSurface,
      ),
      onPressed: () {
        HapticFeedback.selectionClick();
        context.go(NavigationManager.settingsPath);
      },
    );
  }
}
