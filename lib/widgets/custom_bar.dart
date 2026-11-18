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

import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:material_ui/material_ui.dart';
import 'package:muzika/theme/muzika_tokens.dart';

class CustomBar extends StatelessWidget {
  CustomBar(
    this.tileName,
    this.tileIcon, {
    this.description,
    this.onTap,
    this.onLongPress,
    this.trailing,
    this.value,
    this.chevron = false,
    this.backgroundColor,
    this.iconColor,
    this.textColor,
    this.borderRadius = BorderRadius.zero,
    super.key,
  });

  final String tileName;
  final IconData tileIcon;
  final String? description;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final Widget? trailing;

  /// What the setting is set to now, shown quietly on the right.
  final String? value;

  /// An arrow on the right, for rows that open another page.
  final bool chevron;
  final Color? backgroundColor;
  final Color? iconColor;
  final Color? textColor;
  final BorderRadius borderRadius;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    // Muzika: a settings row looks like every other row in the app (a song,
    // a playlist): a rounded square on the left (here holding the icon),
    // the name in medium weight with a small muted line under it, and on
    // the right what it's set to, its switch, or an arrow.
    return Material(
      color: backgroundColor ?? Colors.transparent,
      borderRadius: borderRadius,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  tileIcon,
                  size: 22,
                  color: iconColor ?? textColor ?? colorScheme.onSurface,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      tileName,
                      style: muzikaBody(
                        16,
                        weight: 500,
                        color: textColor ?? colorScheme.onSurface,
                      ),
                    ),
                    if (description != null) ...[
                      const SizedBox(height: 3),
                      Text(
                        description!,
                        style: muzikaBody(
                          12.5,
                          color:
                              textColor?.withValues(alpha: 0.75) ??
                              colorScheme.onSurfaceVariant,
                        ).copyWith(height: 1.3),
                      ),
                    ],
                  ],
                ),
              ),
              if (value != null) ...[
                const SizedBox(width: 12),
                Text(
                  value!,
                  style: muzikaBody(13.5, color: colorScheme.onSurfaceVariant),
                ),
              ],
              if (trailing != null) ...[const SizedBox(width: 12), trailing!],
              if (chevron) ...[
                const SizedBox(width: 6),
                Icon(
                  FluentIcons.chevron_right_20_regular,
                  size: 20,
                  color: colorScheme.onSurfaceVariant,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
