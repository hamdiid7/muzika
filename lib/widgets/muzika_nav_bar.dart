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
import 'package:material_ui/material_ui.dart';
import 'package:muzika/theme/muzika_tokens.dart';

enum MuzikaTab { home, search, discover, library, offline, settings }

/// Muzika's bottom bar: flat, a hairline on top, grey icons, and a black
/// pill with a white icon for the open tab.
class MuzikaNavBar extends StatelessWidget {
  const MuzikaNavBar({
    super.key,
    required this.current,
    required this.onSelect,
    this.showSearch = true,
  });

  /// Null when the open screen belongs to no tab (e.g. an artist page).
  final MuzikaTab? current;
  final ValueChanged<MuzikaTab> onSelect;

  /// Search needs the network, so offline mode hides it.
  final bool showSearch;

  static const double height = 64;

  static const _items = [
    (
      MuzikaTab.home,
      'Home',
      FluentIcons.home_24_regular,
      FluentIcons.home_24_filled,
    ),
    (
      MuzikaTab.search,
      'Search',
      FluentIcons.search_24_regular,
      FluentIcons.search_24_filled,
    ),
    (
      MuzikaTab.discover,
      'Clips',
      FluentIcons.video_clip_24_regular,
      FluentIcons.video_clip_24_filled,
    ),
    (
      MuzikaTab.library,
      'Library',
      FluentIcons.library_24_regular,
      FluentIcons.library_24_filled,
    ),
    (
      MuzikaTab.offline,
      'Offline',
      FluentIcons.arrow_download_24_regular,
      FluentIcons.arrow_download_24_filled,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final items = [
      for (final item in _items)
        if (item.$1 != MuzikaTab.search || showSearch) item,
    ];
    final activeIndex = items.indexWhere((item) => item.$1 == current);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(
          top: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.6)),
        ),
      ),
      child: Padding(
        padding: EdgeInsets.only(bottom: bottomInset),
        child: SizedBox(
          height: height,
          child: Stack(
            children: [
              // The black pill slides from the old tab to the new one.
              if (activeIndex >= 0)
                LayoutBuilder(
                  builder: (context, box) {
                    final slot = box.maxWidth / items.length;
                    return Stack(
                      children: [
                        AnimatedPositioned(
                          duration: const Duration(milliseconds: 180),
                          curve: Curves.easeOutCubic,
                          left: slot * activeIndex + (slot - 52) / 2,
                          top: _pillTop,
                          width: 52,
                          height: 30,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: scheme.onSurface,
                              borderRadius: BorderRadius.circular(15),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              Row(
                children: [
                  for (final (tab, label, icon, activeIcon) in items)
                    Expanded(
                      child: _NavItem(
                        label: label,
                        icon: icon,
                        activeIcon: activeIcon,
                        active: tab == current,
                        onTap: () {
                          HapticFeedback.selectionClick();
                          onSelect(tab);
                        },
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Top of the pill/icon box inside the bar.
  static const double _pillTop = 9;
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.label,
    required this.icon,
    required this.activeIcon,
    required this.active,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final IconData activeIcon;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      selected: active,
      button: true,
      label: label,
      excludeSemantics: true,
      child: InkResponse(
        onTap: onTap,
        radius: 36,
        highlightColor: Colors.transparent,
        child: Column(
          children: [
            const SizedBox(height: MuzikaNavBar._pillTop),
            SizedBox(
              width: 52,
              height: 30,
              child: TweenAnimationBuilder<Color?>(
                duration: const Duration(milliseconds: 140),
                tween: ColorTween(
                  end: active ? scheme.surface : scheme.onSurfaceVariant,
                ),
                builder: (context, color, _) =>
                    Icon(active ? activeIcon : icon, size: 21, color: color),
              ),
            ),
            const SizedBox(height: 4),
            AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 220),
              style: muzikaBody(
                11,
                weight: active ? 600 : 400,
                color: active ? scheme.onSurface : scheme.onSurfaceVariant,
              ),
              child: Text(label, maxLines: 1),
            ),
          ],
        ),
      ),
    );
  }
}
