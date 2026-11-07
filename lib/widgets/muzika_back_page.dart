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

import 'package:material_ui/material_ui.dart';

/// A plain full page with a back arrow (Liked Songs, Recently played…). The
/// mini player comes from the app shell, below the page.
class MuzikaBackPage extends StatefulWidget {
  const MuzikaBackPage({
    super.key,
    required this.child,
    this.actions,
    this.barOverContent = false,
    this.center,
    this.onBack,
  });

  /// Usually a scroll view; its own header carries the title.
  final Widget child;
  final List<Widget>? actions;

  /// The page runs up under a see-through back bar (a playlist's colour
  /// shows behind it and scrolls away); the bar turns solid once scrolled.
  /// The page's header leaves [topSpace] free for it.
  final bool barOverContent;

  /// Shown in the bar between the back arrow and [actions] (a search
  /// field); the bar is solid while it is there.
  final Widget? center;

  /// Replaces what the back arrow does (closing a search first).
  final VoidCallback? onBack;

  /// Room the bar takes at the top, under the status bar.
  static double topSpace(BuildContext context) =>
      MediaQuery.paddingOf(context).top + 52;

  @override
  State<MuzikaBackPage> createState() => _MuzikaBackPageState();
}

class _MuzikaBackPageState extends State<MuzikaBackPage> {
  bool _scrolled = false;

  Widget _bar(ColorScheme scheme) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
    child: Row(
      children: [
        IconButton(
          tooltip: 'Back',
          icon: Icon(Icons.arrow_back_rounded, color: scheme.onSurface),
          onPressed: widget.onBack ?? () => Navigator.of(context).maybePop(),
        ),
        if (widget.center != null)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: widget.center,
            ),
          )
        else
          const Spacer(),
        ...?widget.actions,
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (!widget.barOverContent) {
      return Scaffold(
        backgroundColor: scheme.surface,
        body: SafeArea(
          bottom: false,
          child: Column(
            children: [
              _bar(scheme),
              Expanded(child: widget.child),
            ],
          ),
        ),
      );
    }
    return Scaffold(
      backgroundColor: scheme.surface,
      body: Stack(
        children: [
          Positioned.fill(
            child: NotificationListener<ScrollNotification>(
              onNotification: (n) {
                final scrolled =
                    n.metrics.axis == Axis.vertical && n.metrics.pixels > 8;
                if (scrolled != _scrolled) setState(() => _scrolled = scrolled);
                return false;
              },
              child: widget.child,
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            // Solid once scrolled or searching, with a hairline under it
            // so what scrolls beneath reads as beneath.
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              decoration: BoxDecoration(
                color: _scrolled || widget.center != null
                    ? scheme.surface
                    : scheme.surface.withValues(alpha: 0),
                border: Border(
                  bottom: BorderSide(
                    width: 0.5,
                    color: _scrolled || widget.center != null
                        ? scheme.outlineVariant
                        : Colors.transparent,
                  ),
                ),
              ),
              padding: const EdgeInsets.only(bottom: 6),
              child: SafeArea(bottom: false, child: _bar(scheme)),
            ),
          ),
        ],
      ),
    );
  }
}
