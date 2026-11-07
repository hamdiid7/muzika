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
import 'package:muzika/theme/muzika_tokens.dart';

class CustomBar extends StatelessWidget {
  CustomBar(
    this.tileName,
    this.tileIcon, {
    this.description,
    this.onTap,
    this.onLongPress,
    this.trailing,
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
  final Color? backgroundColor;
  final Color? iconColor;
  final Color? textColor;
  final BorderRadius borderRadius;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    // Muzika: Material 3 settings rows — a plain outlined icon, a bold title
    // with its description underneath, and the control on the right.
    return Material(
      color: backgroundColor ?? Colors.transparent,
      borderRadius: borderRadius,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 16, 14),
          child: Row(
            children: [
              Icon(
                tileIcon,
                size: 26,
                color: iconColor ?? colorScheme.onSurface,
              ),
              const SizedBox(width: 22),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      tileName,
                      style: muzikaHeading(
                        17,
                        color: textColor ?? colorScheme.onSurface,
                      ),
                    ),
                    if (description != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        description!,
                        style: muzikaBody(
                          14.5,
                          color:
                              textColor?.withValues(alpha: 0.75) ??
                              colorScheme.onSurfaceVariant,
                        ).copyWith(height: 1.25),
                      ),
                    ],
                  ],
                ),
              ),
              if (trailing != null) ...[const SizedBox(width: 12), trailing!],
            ],
          ),
        ),
      ),
    );
  }
}
