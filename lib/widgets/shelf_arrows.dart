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

/// A row that scrolls sideways, with small round arrows on its ends (a
/// mouse can't swipe): the right one while there is more to the right, the
/// left one once it has moved. [builder] gets the controller for the list.
class ShelfArrows extends StatefulWidget {
  const ShelfArrows({super.key, required this.builder, this.pictureHeight});

  final Widget Function(ScrollController controller) builder;

  /// The height of the row's pictures, to centre the arrows on them rather
  /// than on pictures and titles together; the whole row when null.
  final double? pictureHeight;

  @override
  State<ShelfArrows> createState() => _ShelfArrowsState();
}

class _ShelfArrowsState extends State<ShelfArrows> {
  final _controller = ScrollController();
  bool _left = false;
  bool _right = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_update);
    WidgetsBinding.instance.addPostFrameCallback((_) => _update());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _update() {
    if (!mounted || !_controller.hasClients) return;
    final p = _controller.position;
    final left = p.pixels > 4;
    final right = p.pixels < p.maxScrollExtent - 4;
    if (left != _left || right != _right) {
      setState(() {
        _left = left;
        _right = right;
      });
    }
  }

  void _move(int direction) {
    if (!_controller.hasClients) return;
    final p = _controller.position;
    final to = (p.pixels + direction * p.viewportDimension * 0.8).clamp(
      0.0,
      p.maxScrollExtent,
    );
    _controller.animateTo(
      to,
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOutCubic,
    );
  }

  Widget _arrow(IconData icon, int direction, bool shown) {
    final scheme = Theme.of(context).colorScheme;
    return IgnorePointer(
      ignoring: !shown,
      child: AnimatedOpacity(
        opacity: shown ? 1 : 0,
        duration: const Duration(milliseconds: 150),
        child: Material(
          color: scheme.surface.withValues(alpha: 0.88),
          shape: const CircleBorder(),
          elevation: 2,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: () => _move(direction),
            child: SizedBox(
              width: 32,
              height: 32,
              child: Icon(icon, size: 18, color: scheme.onSurface),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (_) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _update());
        return false;
      },
      child: Stack(
        children: [
          widget.builder(_controller),
          Positioned(
            left: 6,
            top: 0,
            bottom: widget.pictureHeight == null ? 0 : null,
            height: widget.pictureHeight,
            child: Center(
              child: _arrow(FluentIcons.chevron_left_20_regular, -1, _left),
            ),
          ),
          Positioned(
            right: 6,
            top: 0,
            bottom: widget.pictureHeight == null ? 0 : null,
            height: widget.pictureHeight,
            child: Center(
              child: _arrow(FluentIcons.chevron_right_20_regular, 1, _right),
            ),
          ),
        ],
      ),
    );
  }
}
