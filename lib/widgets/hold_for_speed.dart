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

import 'dart:async';

import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:muzika/main.dart' show audioHandler;
import 'package:muzika/theme/muzika_tokens.dart';

/// Hold the right side of [child] to play at 2× (Muzika), back to the old
/// speed on letting go; a "2×" pill shows meanwhile. Taps, scrolls and
/// swipes still reach [child].
class HoldForSpeed extends StatefulWidget {
  const HoldForSpeed({
    super.key,
    required this.child,
    this.side = 0.35,
    this.expand = false,
  });

  final Widget child;

  /// How much of the width, from the right, takes the hold.
  final double side;

  /// Fill the space given (a scrolling list) rather than wrap [child].
  final bool expand;

  @override
  State<HoldForSpeed> createState() => _HoldForSpeedState();
}

class _HoldForSpeedState extends State<HoldForSpeed> {
  double? _before;

  void _start() {
    final player = audioHandler.audioPlayer;
    _before = player.speed;
    unawaited(HapticFeedback.mediumImpact());
    unawaited(player.setSpeed(2));
    setState(() {});
  }

  void _stop() {
    final before = _before;
    if (before == null) return;
    _before = null;
    unawaited(audioHandler.audioPlayer.setSpeed(before));
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: widget.expand ? StackFit.expand : StackFit.loose,
      children: [
        widget.child,
        Positioned.fill(
          child: Align(
            alignment: Alignment.centerRight,
            child: FractionallySizedBox(
              widthFactor: widget.side,
              heightFactor: 1,
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onLongPressStart: (_) => _start(),
                onLongPressEnd: (_) => _stop(),
                onLongPressCancel: _stop,
              ),
            ),
          ),
        ),
        Positioned(
          top: 12,
          left: 0,
          right: 0,
          child: IgnorePointer(
            child: AnimatedOpacity(
              opacity: _before == null ? 0 : 1,
              duration: const Duration(milliseconds: 150),
              child: Center(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '2×',
                          style: muzikaBody(
                            14,
                            weight: 700,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(width: 4),
                        const Icon(
                          FluentIcons.fast_forward_20_filled,
                          size: 18,
                          color: Colors.white,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
