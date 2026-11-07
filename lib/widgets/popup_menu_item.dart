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

/// A menu entry that also remembers its icon and label, so the "⋮" menus
/// can show it as a row of the Muzika bottom sheet (see OverflowMenuButton).
class MuzikaMenuItem<T> extends PopupMenuItem<T> {
  const MuzikaMenuItem({
    super.key,
    required T super.value,
    required this.icon,
    required this.label,
    this.danger = false,
    required super.child,
  });

  final IconData icon;
  final String label;

  /// Shown in the error colour (deleting).
  final bool danger;
}

/// Creates a PopupMenuItem with consistent icon + label styling
PopupMenuItem<T> buildPopupMenuItem<T>({
  required T value,
  required IconData icon,
  required String label,
  required ColorScheme colorScheme,
  Color? iconColor,
  TextStyle? labelStyle,
  double iconSize = 24,
  double spacing = 8,
}) {
  return MuzikaMenuItem<T>(
    value: value,
    icon: icon,
    label: label,
    danger: iconColor == colorScheme.error,
    child: Row(
      children: [
        Icon(icon, color: iconColor ?? colorScheme.primary, size: iconSize),
        SizedBox(width: spacing),
        Text(
          label,
          style: labelStyle ?? TextStyle(color: colorScheme.onSurface),
        ),
      ],
    ),
  );
}
