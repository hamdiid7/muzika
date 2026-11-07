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

import 'dart:async';

import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:material_ui/material_ui.dart';
import 'package:muzika/services/desktop_panels.dart';
import 'package:muzika/theme/muzika_tokens.dart';
import 'package:muzika/widgets/popup_menu_item.dart';

/// The "⋮" button. Its options open in the Muzika bottom sheet, the same as
/// a song's options (a name on top, then a row per option).
class OverflowMenuButton<T> extends StatelessWidget {
  const OverflowMenuButton({
    super.key,
    required this.onSelected,
    required this.itemBuilder,
    this.icon,
    this.borderRadius,
    this.iconSize = 24,
    this.color,
    this.title,
  });

  final void Function(T value) onSelected;
  final List<PopupMenuEntry<T>> Function(BuildContext context) itemBuilder;

  final IconData? icon;
  final double iconSize;
  final Color? color;
  final BorderRadius? borderRadius;

  /// Shown at the top of the sheet (the playlist's name).
  final String? title;

  /// Opens this button's menu (also from a right-click on its row).
  Future<void> open(BuildContext context) => showMuzikaMenu<T>(
    context,
    items: itemBuilder(context),
    onSelected: onSelected,
    title: title,
  );

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return IconButton(
      padding: EdgeInsets.zero,
      onPressed: () => unawaited(
        showMuzikaMenu<T>(
          context,
          items: itemBuilder(context),
          onSelected: onSelected,
          title: title,
        ),
      ),
      icon: Icon(
        icon ?? FluentIcons.more_vertical_24_regular,
        size: iconSize,
        color: color ?? colorScheme.onSurfaceVariant,
      ),
    );
  }
}

/// Shows [items] as rows of the Muzika bottom sheet; the chosen value goes
/// to [onSelected] once the sheet has closed.
Future<void> showMuzikaMenu<T>(
  BuildContext context, {
  required List<PopupMenuEntry<T>> items,
  required void Function(T value) onSelected,
  String? title,
}) async {
  final picked = await showModalBottomSheet<T>(
    context: context,
    showDragHandle: true,
    // Wide Windows layout: the sheet opens in the part it came from.
    useRootNavigator: !desktopPanels.value,
    builder: (sheetContext) {
      final scheme = Theme.of(sheetContext).colorScheme;
      return SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (title != null && title.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: muzikaBody(16, weight: 700),
                  ),
                ),
              for (final item in items)
                if (item is MuzikaMenuItem<T>)
                  ListTile(
                    leading: Icon(
                      item.icon,
                      color: item.danger ? scheme.error : scheme.onSurface,
                    ),
                    title: Text(
                      item.label,
                      style: muzikaBody(
                        16,
                        weight: 500,
                        color: item.danger ? scheme.error : null,
                      ),
                    ),
                    onTap: () => Navigator.of(sheetContext).pop(item.value),
                  )
                else if (item is PopupMenuItem<T>)
                  ListTile(
                    title: item.child,
                    onTap: () => Navigator.of(sheetContext).pop(item.value),
                  ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      );
    },
  );
  if (picked != null) onSelected(picked);
}

/// Opens the first "⋮" menu inside [context] (a right-click on a playlist or
/// song row, Windows). Nothing happens when there's none.
void openOverflowMenuIn(BuildContext context) {
  Element? found;
  void visit(Element e) {
    if (found != null) return;
    if (e.widget is OverflowMenuButton) {
      found = e;
      return;
    }
    e.visitChildElements(visit);
  }

  (context as Element).visitChildElements(visit);
  final element = found;
  if (element == null) return;
  (element.widget as OverflowMenuButton).open(element);
}
