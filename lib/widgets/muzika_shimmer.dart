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

/// Muzika never shows a spinning loader: placeholders shimmer instead.
///
/// Everything under [child] is painted as a light sweep moving left to right,
/// so the child only needs to lay out grey shapes (see [MuzikaSkeletonBox]).
class MuzikaShimmer extends StatefulWidget {
  const MuzikaShimmer({super.key, required this.child});

  final Widget child;

  @override
  State<MuzikaShimmer> createState() => _MuzikaShimmerState();
}

class _MuzikaShimmerState extends State<MuzikaShimmer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1300),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    final base = dark ? const Color(0xFF363636) : const Color(0xFFE9E9EC);
    final highlight = dark ? const Color(0xFF4A4A4A) : const Color(0xFFF7F7F9);
    return AnimatedBuilder(
      animation: _controller,
      child: widget.child,
      builder: (context, child) {
        final x = _controller.value * 3 - 1; // sweep from -1 to 2
        return ShaderMask(
          blendMode: BlendMode.srcATop,
          shaderCallback: (rect) => LinearGradient(
            begin: Alignment(x - 1, -0.3),
            end: Alignment(x + 1, 0.3),
            colors: [base, highlight, base],
            stops: const [0.35, 0.5, 0.65],
          ).createShader(rect),
          child: child,
        );
      },
    );
  }
}

/// A grey placeholder shape, meant to sit inside a [MuzikaShimmer].
class MuzikaSkeletonBox extends StatelessWidget {
  const MuzikaSkeletonBox({
    super.key,
    this.width,
    required this.height,
    this.radius = 6,
  });

  final double? width;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) => Container(
    width: width,
    height: height,
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(radius),
    ),
  );
}

/// Placeholder song rows: cover, two lines of text and the round button.
class MuzikaSkeletonRows extends StatelessWidget {
  const MuzikaSkeletonRows({
    super.key,
    this.count = 6,
    this.showButton = true,
    this.circular = false,
  });

  final int count;
  final bool showButton;
  final bool circular;

  @override
  Widget build(BuildContext context) {
    return MuzikaShimmer(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < count; i++)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: Row(
                children: [
                  MuzikaSkeletonBox(
                    width: 56,
                    height: 56,
                    radius: circular ? 28 : 8,
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        FractionallySizedBox(
                          widthFactor: 0.45 + (i * 37 % 30) / 100,
                          child: const MuzikaSkeletonBox(height: 14),
                        ),
                        const SizedBox(height: 8),
                        FractionallySizedBox(
                          widthFactor: 0.25 + (i * 23 % 20) / 100,
                          child: const MuzikaSkeletonBox(height: 11),
                        ),
                      ],
                    ),
                  ),
                  if (showButton) ...[
                    const SizedBox(width: 12),
                    const MuzikaSkeletonBox(width: 40, height: 40, radius: 20),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Full-page placeholder used while a sheet page (artist, album, playlist)
/// loads: a header card, a divider and some rows.
class MuzikaSkeletonPage extends StatelessWidget {
  const MuzikaSkeletonPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const SingleChildScrollView(
      physics: NeverScrollableScrollPhysics(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MuzikaShimmer(
            child: Padding(
              padding: EdgeInsets.fromLTRB(20, 4, 20, 20),
              child: Row(
                children: [
                  MuzikaSkeletonBox(width: 96, height: 96, radius: 12),
                  SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        FractionallySizedBox(
                          widthFactor: 0.8,
                          child: MuzikaSkeletonBox(height: 24),
                        ),
                        SizedBox(height: 10),
                        FractionallySizedBox(
                          widthFactor: 0.5,
                          child: MuzikaSkeletonBox(height: 12),
                        ),
                        SizedBox(height: 14),
                        Row(
                          spacing: 8,
                          children: [
                            MuzikaSkeletonBox(
                              width: 40,
                              height: 40,
                              radius: 20,
                            ),
                            MuzikaSkeletonBox(
                              width: 40,
                              height: 40,
                              radius: 20,
                            ),
                            MuzikaSkeletonBox(
                              width: 40,
                              height: 40,
                              radius: 20,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          MuzikaSkeletonRows(count: 8),
        ],
      ),
    );
  }
}

/// A gently breathing icon, used where a button is waiting (play while the
/// song buffers, download while it prepares) instead of a spinner.
class MuzikaPulse extends StatefulWidget {
  const MuzikaPulse({super.key, required this.child});

  final Widget child;

  @override
  State<MuzikaPulse> createState() => _MuzikaPulseState();
}

class _MuzikaPulseState extends State<MuzikaPulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 750),
    lowerBound: 0.3,
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      FadeTransition(opacity: _controller, child: widget.child);
}
