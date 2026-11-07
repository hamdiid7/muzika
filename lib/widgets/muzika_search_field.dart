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
import 'package:material_ui/material_ui.dart';
import 'package:muzika/theme/muzika_tokens.dart';

/// The search box that floats in a page's top bar while searching its songs
/// (playlists, albums, Liked songs, Recently played): built like the Search
/// tab's field so the icon and text line up, only shorter; the keyboard
/// opens at once.
class MuzikaSearchField extends StatelessWidget {
  const MuzikaSearchField({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.onChanged,
    this.hint = 'Search songs here',
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;

  /// What the empty box says it searches.
  final String hint;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: BorderSide.none,
    );
    return TextField(
      controller: controller,
      focusNode: focusNode,
      autofocus: true,
      style: muzikaBody(15, color: scheme.onSurface),
      cursorColor: scheme.onSurface,
      decoration: InputDecoration(
        isDense: true,
        hintText: hint,
        hintStyle: muzikaBody(15, color: scheme.onSurfaceVariant),
        // A ✕ once something's typed: empties it.
        suffixIcon: ValueListenableBuilder<TextEditingValue>(
          valueListenable: controller,
          builder: (context, value, _) => value.text.isEmpty
              ? const SizedBox.shrink()
              : IconButton(
                  tooltip: 'Clear',
                  visualDensity: VisualDensity.compact,
                  icon: Icon(
                    FluentIcons.dismiss_circle_20_filled,
                    color: scheme.onSurfaceVariant,
                  ),
                  onPressed: () {
                    controller.clear();
                    onChanged('');
                  },
                ),
        ),
        suffixIconConstraints: const BoxConstraints(
          minWidth: 40,
          minHeight: 40,
        ),
        prefixIcon: Icon(
          FluentIcons.search_24_regular,
          size: 24,
          color: scheme.onSurfaceVariant,
        ),
        prefixIconConstraints: const BoxConstraints(
          minWidth: 44,
          minHeight: 40,
        ),
        filled: true,
        fillColor: scheme.brightness == Brightness.dark
            ? scheme.surfaceContainerHigh
            : const Color(0xFFE6E6EA),
        contentPadding: const EdgeInsets.fromLTRB(0, 11, 12, 11),
        border: border,
        enabledBorder: border,
        focusedBorder: border,
      ),
      onChanged: onChanged,
    );
  }
}
