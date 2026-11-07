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
import 'dart:io';
import 'dart:math';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:muzika/main.dart' show logger;
import 'package:muzika/services/cover_tint.dart';
import 'package:muzika/services/desktop_panels.dart';
import 'package:muzika/services/listening_stats.dart';
import 'package:muzika/theme/muzika_tokens.dart';
import 'package:muzika/utilities/flutter_toast.dart';
import 'package:muzika/widgets/muzika_share.dart';

/// Opens today's listening story (or yesterday's when today is empty).
Future<void> openDailyStory(BuildContext context) {
  final now = DateTime.now();
  final day =
      ListeningStats.instance.day(now) ??
      ListeningStats.instance.day(now.subtract(const Duration(days: 1)));
  if (day == null) {
    showToast(context, 'Play some music and your story appears here');
    return Future.value();
  }
  return Navigator.of(context, rootNavigator: !desktopPanels.value).push(
    PageRouteBuilder<void>(
      pageBuilder: (_, _, _) => DailyStoryPage(day: day),
      transitionDuration: const Duration(milliseconds: 380),
      transitionsBuilder: (_, a, _, child) => FadeTransition(
        opacity: a,
        child: ScaleTransition(
          scale: Tween<double>(
            begin: 1.08,
            end: 1,
          ).animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)),
          child: child,
        ),
      ),
    ),
  );
}

/// The entry card at the top of Settings.
class DailyStoryCard extends StatelessWidget {
  const DailyStoryCard({super.key});

  @override
  Widget build(BuildContext context) {
    final day = ListeningStats.instance.day(DateTime.now());
    final minutes = (day?.totalSeconds ?? 0) ~/ 60;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: GestureDetector(
        onTap: () => openDailyStory(context),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(22),
          child: SizedBox(
            height: 132,
            child: Stack(
              fit: StackFit.expand,
              children: [
                const _Aurora(seed: 3),
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              'Your day in music',
                              style: muzikaHeading(22, color: Colors.white),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              minutes > 0
                                  ? '$minutes min today · Tap to watch'
                                  : 'Play some music to unlock today',
                              style: muzikaBody(14, color: Colors.white70),
                            ),
                          ],
                        ),
                      ),
                      const Icon(
                        Icons.play_circle_fill_rounded,
                        color: Colors.white,
                        size: 44,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class DailyStoryPage extends StatefulWidget {
  const DailyStoryPage({super.key, required this.day});

  final DayListening day;

  @override
  State<DailyStoryPage> createState() => _DailyStoryPageState();
}

class _DailyStoryPageState extends State<DailyStoryPage>
    with TickerProviderStateMixin {
  static const _slideTime = Duration(seconds: 6);

  late final List<Widget Function(Animation<double>)> _slides = _buildSlides();
  late final AnimationController _progress = AnimationController(
    vsync: this,
    duration: _slideTime,
  )..addStatusListener(_onStatus);
  final _shareKey = GlobalKey();
  int _index = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_progress.forward());
  }

  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) _go(1);
  }

  void _go(int delta) {
    final next = _index + delta;
    if (next < 0) {
      unawaited(_progress.forward(from: 0));
      return;
    }
    if (next >= _slides.length) {
      if (delta > 0 && _index == _slides.length - 1) {
        _progress.stop();
        return; // stay on the summary
      }
      return;
    }
    unawaited(HapticFeedback.selectionClick());
    setState(() => _index = next);
    unawaited(_progress.forward(from: 0));
  }

  Future<void> _share() async {
    _progress.stop();
    try {
      await shareWidgetImage(
        _shareKey,
        fileName: 'muzika_day',
        text: 'My day in music · muzika.pages.dev',
      );
    } catch (e, st) {
      logger.log('Story share failed', error: e, stackTrace: st);
    }
    if (mounted) unawaited(_progress.forward());
  }

  // -------------------------------------------------------------------------

  List<Widget Function(Animation<double>)> _buildSlides() {
    final d = widget.day;
    final top = d.songs.first;
    final artists = d.artists;
    return [
      (t) => _IntroSlide(t: t, date: d.date),
      (t) =>
          _MinutesSlide(t: t, minutes: d.totalSeconds ~/ 60, image: top.image),
      (t) => _TopSongSlide(
        t: t,
        title: top.title,
        artist: top.artist,
        image: top.image,
        minutes: top.seconds ~/ 60,
      ),
      if (artists.isNotEmpty)
        (t) => _TopArtistSlide(
          t: t,
          name: artists.first.name,
          image: artists.first.image,
          minutes: artists.first.seconds ~/ 60,
        ),
      if (d.songs.length >= 3) (t) => _TopFiveSlide(t: t, day: d),
      (t) => _ClockSlide(t: t, day: d),
      (t) => _SummarySlide(t: t, day: d),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.paddingOf(context);
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTapUp: (d) {
          final w = MediaQuery.sizeOf(context).width;
          _go(d.localPosition.dx < w / 3 ? -1 : 1);
        },
        onLongPressStart: (_) => _progress.stop(),
        onLongPressEnd: (_) => unawaited(_progress.forward()),
        onVerticalDragEnd: (d) {
          if ((d.primaryVelocity ?? 0) > 400) Navigator.of(context).pop();
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Everything inside the boundary ends up in the shared image.
            RepaintBoundary(
              key: _shareKey,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _Aurora(seed: _index),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 450),
                    switchInCurve: Curves.easeOutCubic,
                    transitionBuilder: (child, a) => FadeTransition(
                      opacity: a,
                      child: ScaleTransition(
                        scale: Tween<double>(begin: 0.94, end: 1).animate(a),
                        child: child,
                      ),
                    ),
                    child: KeyedSubtree(
                      key: ValueKey(_index),
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(
                          28,
                          padding.top + 56,
                          28,
                          padding.bottom + 56,
                        ),
                        child: _slides[_index](_progress),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: padding.bottom + 20,
                    child: Center(
                      child: Text(
                        'muzika.pages.dev',
                        style: muzikaHeading(14, color: Colors.white70),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // Story bars, close and share sit outside the shared image.
            Positioned(
              left: 12,
              right: 12,
              top: padding.top + 8,
              child: Row(
                children: [
                  for (var i = 0; i < _slides.length; i++)
                    Expanded(
                      child: Container(
                        height: 3,
                        margin: const EdgeInsets.symmetric(horizontal: 2),
                        decoration: BoxDecoration(
                          color: Colors.white24,
                          borderRadius: BorderRadius.circular(2),
                        ),
                        child: AnimatedBuilder(
                          animation: _progress,
                          builder: (context, _) => FractionallySizedBox(
                            alignment: Alignment.centerLeft,
                            widthFactor: i < _index
                                ? 1
                                : i == _index
                                ? _progress.value
                                : 0,
                            child: Container(
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Positioned(
              top: padding.top + 18,
              right: 8,
              child: Row(
                children: [
                  IconButton(
                    tooltip: 'Share',
                    onPressed: _share,
                    icon: const Icon(
                      Icons.ios_share_rounded,
                      color: Colors.white,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded, color: Colors.white),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Background: soft blobs of colour drifting like an aurora, in the playing
// cover's hue.
// ---------------------------------------------------------------------------

class _Aurora extends StatefulWidget {
  const _Aurora({required this.seed});

  final int seed;

  @override
  State<_Aurora> createState() => _AuroraState();
}

class _AuroraState extends State<_Aurora> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 14),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final base = coverTint.value ?? const Color(0xFF6C4BD8);
    final hsl = HSLColor.fromColor(base);
    final shift = widget.seed * 47.0;
    final colors = [
      hsl.withHue((hsl.hue + shift) % 360).withLightness(0.45).toColor(),
      hsl.withHue((hsl.hue + shift + 60) % 360).withLightness(0.5).toColor(),
      hsl.withHue((hsl.hue + shift + 180) % 360).withLightness(0.35).toColor(),
    ];
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) =>
          CustomPaint(painter: _AuroraPainter(_c.value, colors)),
    );
  }
}

class _AuroraPainter extends CustomPainter {
  _AuroraPainter(this.t, this.colors);

  final double t;
  final List<Color> colors;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFF0B0B10),
    );
    final a = t * 2 * pi;
    final blobs = [
      (Offset(0.3 + 0.2 * sin(a), 0.25 + 0.1 * cos(a * 2)), 0.75, colors[0]),
      (Offset(0.75 + 0.15 * cos(a), 0.6 + 0.15 * sin(a)), 0.7, colors[1]),
      (Offset(0.4 + 0.2 * cos(a * 1.5), 0.9 + 0.08 * sin(a)), 0.6, colors[2]),
    ];
    for (final (c, r, color) in blobs) {
      final center = Offset(c.dx * size.width, c.dy * size.height);
      final radius = r * size.width;
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..shader = RadialGradient(
            colors: [color.withValues(alpha: 0.85), color.withValues(alpha: 0)],
          ).createShader(Rect.fromCircle(center: center, radius: radius)),
      );
    }
    // Tiny twinkling specks.
    final rnd = Random(7);
    for (var i = 0; i < 40; i++) {
      final p = Offset(
        rnd.nextDouble() * size.width,
        rnd.nextDouble() * size.height,
      );
      final o = (sin(a * 3 + i) + 1) / 2;
      canvas.drawCircle(
        p,
        1 + rnd.nextDouble() * 1.4,
        Paint()..color = Colors.white.withValues(alpha: 0.08 + 0.3 * o),
      );
    }
  }

  @override
  bool shouldRepaint(_AuroraPainter old) => old.t != t || old.colors != colors;
}

// ---------------------------------------------------------------------------
// Slides. Each gets the slide's 0→1 progress and stages its own entrance.
// ---------------------------------------------------------------------------

double _seg(
  double t,
  double from,
  double to, [
  Curve curve = Curves.easeOutCubic,
]) => curve.transform(((t - from) / (to - from)).clamp(0.0, 1.0));

TextStyle _big(double size) => muzikaHeading(
  size,
  weight: 800,
  color: Colors.white,
).copyWith(height: 1.05);

ImageProvider? _img(String? url) {
  if (url == null || url.isEmpty || url == 'null') return null;
  if (url.startsWith('http')) return CachedNetworkImageProvider(url);
  return FileImage(
    File(url.startsWith('file://') ? Uri.parse(url).toFilePath() : url),
  );
}

class _IntroSlide extends StatelessWidget {
  const _IntroSlide({required this.t, required this.date});

  final Animation<double> t;
  final DateTime date;

  @override
  Widget build(BuildContext context) {
    const words = ['Your', 'day', 'in', 'music'];
    const months = [
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ];
    return AnimatedBuilder(
      animation: t,
      builder: (context, _) => Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Words drop in one by one with a little spin.
          for (final (i, w) in words.indexed)
            Builder(
              builder: (context) {
                final p = _seg(
                  t.value,
                  i * 0.08,
                  i * 0.08 + 0.18,
                  Curves.elasticOut,
                );
                return Opacity(
                  opacity: p.clamp(0.0, 1.0),
                  child: Transform.translate(
                    offset: Offset(0, (1 - p) * -60),
                    child: Transform.rotate(
                      angle: (1 - p) * (i.isEven ? -0.3 : 0.3),
                      alignment: Alignment.centerLeft,
                      child: Text(w, style: _big(64)),
                    ),
                  ),
                );
              },
            ),
          const SizedBox(height: 24),
          Opacity(
            opacity: _seg(t.value, 0.45, 0.6),
            child: Text(
              '${date.day} ${months[date.month - 1]}',
              style: muzikaBody(20, weight: 500, color: Colors.white70),
            ),
          ),
        ],
      ),
    );
  }
}

class _MinutesSlide extends StatelessWidget {
  const _MinutesSlide({required this.t, required this.minutes, this.image});

  final Animation<double> t;
  final int minutes;
  final String? image;

  @override
  Widget build(BuildContext context) {
    final cover = _img(image);
    return AnimatedBuilder(
      animation: t,
      builder: (context, _) {
        final count = (minutes * _seg(t.value, 0.05, 0.5)).round();
        final pop = _seg(t.value, 0.45, 0.6, Curves.elasticOut);
        return Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // A record spinning with today's top cover as its label.
            Transform.rotate(
              angle: t.value * 2 * pi * 1.5,
              child: Container(
                width: 190,
                height: 190,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [Color(0xFF222222), Color(0xFF050505)],
                    stops: [0.6, 1],
                  ),
                ),
                child: Center(
                  child: CircleAvatar(
                    radius: 46,
                    backgroundColor: Colors.white24,
                    backgroundImage: cover,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 36),
            Transform.scale(
              scale: 1 + 0.12 * pop * (1 - pop + 0.2),
              child: Text('$count', style: _big(96)),
            ),
            Text(
              minutes == 1 ? 'minute of music' : 'minutes of music',
              style: muzikaBody(20, weight: 600, color: Colors.white),
            ),
            const SizedBox(height: 10),
            Opacity(
              opacity: _seg(t.value, 0.55, 0.7),
              child: Text(
                minutes >= 60
                    ? 'That’s ${(minutes / 60).toStringAsFixed(1)} hours of sound.'
                    : 'Every one of them yours.',
                style: muzikaBody(16, color: Colors.white70),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _TopSongSlide extends StatelessWidget {
  const _TopSongSlide({
    required this.t,
    required this.title,
    required this.artist,
    required this.image,
    required this.minutes,
  });

  final Animation<double> t;
  final String title;
  final String artist;
  final String? image;
  final int minutes;

  @override
  Widget build(BuildContext context) {
    final cover = _img(image);
    return AnimatedBuilder(
      animation: t,
      builder: (context, _) {
        final flip = _seg(t.value, 0.05, 0.35, Curves.easeOutBack);
        final side = min<double>(MediaQuery.sizeOf(context).width - 56, 280);
        return Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Opacity(
              opacity: _seg(t.value, 0, 0.1),
              child: Text(
                'Song of the day',
                textAlign: TextAlign.center,
                style: _big(30),
              ),
            ),
            const SizedBox(height: 28),
            // The cover turns over like a card being revealed.
            Center(
              child: Transform(
                alignment: Alignment.center,
                transform: Matrix4.identity()
                  ..setEntry(3, 2, 0.0012)
                  ..rotateY((1 - flip) * pi / 2)
                  ..rotateZ((1 - flip) * -0.15),
                child: Container(
                  width: side,
                  height: side,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(18),
                    color: Colors.white12,
                    image: cover == null
                        ? null
                        : DecorationImage(image: cover, fit: BoxFit.cover),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.white.withValues(alpha: 0.18 * flip),
                        blurRadius: 60,
                        spreadRadius: 4,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 28),
            Opacity(
              opacity: _seg(t.value, 0.3, 0.45),
              child: Transform.translate(
                offset: Offset(0, 20 * (1 - _seg(t.value, 0.3, 0.45))),
                child: Column(
                  children: [
                    Text(
                      title,
                      maxLines: 2,
                      textAlign: TextAlign.center,
                      overflow: TextOverflow.ellipsis,
                      style: _big(32),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '$artist · $minutes min',
                      textAlign: TextAlign.center,
                      style: muzikaBody(17, color: Colors.white70),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _TopArtistSlide extends StatelessWidget {
  const _TopArtistSlide({
    required this.t,
    required this.name,
    required this.image,
    required this.minutes,
  });

  final Animation<double> t;
  final String name;
  final String? image;
  final int minutes;

  @override
  Widget build(BuildContext context) {
    final cover = _img(image);
    return AnimatedBuilder(
      animation: t,
      builder: (context, _) {
        final shown = (name.length * _seg(t.value, 0.25, 0.55)).round();
        return Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              'You couldn’t get enough of',
              style: muzikaBody(18, weight: 600, color: Colors.white70),
            ),
            const SizedBox(height: 30),
            // Rings ripple out from the artist like sound.
            SizedBox(
              width: 280,
              height: 280,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  for (var i = 0; i < 3; i++)
                    Builder(
                      builder: (context) {
                        final p = (t.value * 2 + i / 3) % 1;
                        return Container(
                          width: 150 + 130 * p,
                          height: 150 + 130 * p,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: Colors.white.withValues(
                                alpha: 0.5 * (1 - p),
                              ),
                              width: 2,
                            ),
                          ),
                        );
                      },
                    ),
                  Transform.scale(
                    scale: _seg(t.value, 0, 0.25, Curves.elasticOut),
                    child: CircleAvatar(
                      radius: 75,
                      backgroundColor: Colors.white24,
                      backgroundImage: cover,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 30),
            // The name types itself out.
            Text(
              name.substring(0, shown),
              textAlign: TextAlign.center,
              style: _big(40),
            ),
            const SizedBox(height: 8),
            Opacity(
              opacity: _seg(t.value, 0.55, 0.7),
              child: Text(
                '$minutes minutes together today',
                style: muzikaBody(17, color: Colors.white70),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _TopFiveSlide extends StatelessWidget {
  const _TopFiveSlide({required this.t, required this.day});

  final Animation<double> t;
  final DayListening day;

  @override
  Widget build(BuildContext context) {
    final songs = day.songs.take(5).toList();
    return AnimatedBuilder(
      animation: t,
      builder: (context, _) => Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Today on repeat', style: _big(34)),
          const SizedBox(height: 26),
          for (final (i, s) in songs.indexed)
            Builder(
              builder: (context) {
                final p = _seg(t.value, 0.08 + i * 0.07, 0.3 + i * 0.07);
                return Opacity(
                  opacity: p,
                  child: Transform.translate(
                    offset: Offset(120 * (1 - p), 0),
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 40,
                            child: Text('${i + 1}', style: _big(30)),
                          ),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Container(
                              width: 56,
                              height: 56,
                              color: Colors.white12,
                              child: _img(s.image) == null
                                  ? null
                                  : Image(
                                      image: _img(s.image)!,
                                      fit: BoxFit.cover,
                                    ),
                            ),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  s.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: muzikaBody(
                                    17,
                                    weight: 700,
                                    color: Colors.white,
                                  ),
                                ),
                                Text(
                                  s.artist,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: muzikaBody(14, color: Colors.white70),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}

class _ClockSlide extends StatelessWidget {
  const _ClockSlide({required this.t, required this.day});

  final Animation<double> t;
  final DayListening day;

  String get _persona {
    final h = day.peakHour ?? 12;
    if (h < 5) return 'Night owl';
    if (h < 11) return 'Early bird';
    if (h < 17) return 'Daytime groover';
    if (h < 21) return 'Sunset listener';
    return 'Night owl';
  }

  @override
  Widget build(BuildContext context) {
    final peak = day.peakHour;
    return AnimatedBuilder(
      animation: t,
      builder: (context, _) => Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            'Your listening clock',
            style: muzikaBody(18, weight: 600, color: Colors.white70),
          ),
          const SizedBox(height: 24),
          SizedBox(
            width: 280,
            height: 280,
            child: CustomPaint(
              painter: _ClockPainter(day.hours, _seg(t.value, 0.05, 0.55)),
            ),
          ),
          const SizedBox(height: 28),
          Opacity(
            opacity: _seg(t.value, 0.5, 0.65),
            child: Column(
              children: [
                Text(_persona, style: _big(40)),
                if (peak != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Most of it around ${peak.toString().padLeft(2, '0')}:00',
                    style: muzikaBody(17, color: Colors.white70),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 24 bars around a dial, growing in clockwise.
class _ClockPainter extends CustomPainter {
  _ClockPainter(this.hours, this.progress);

  final Map<int, int> hours;
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final inner = size.width * 0.22;
    final maxLen = size.width * 0.26;
    final most = hours.values.fold<int>(1, max);
    canvas.drawCircle(
      c,
      inner - 6,
      Paint()
        ..color = Colors.white24
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    for (var h = 0; h < 24; h++) {
      final reveal = ((progress * 24) - h).clamp(0.0, 1.0);
      final value = (hours[h] ?? 0) / most;
      final len = 6 + maxLen * value * reveal;
      final angle = -pi / 2 + h / 24 * 2 * pi;
      final dir = Offset(cos(angle), sin(angle));
      canvas.drawLine(
        c + dir * inner,
        c + dir * (inner + len),
        Paint()
          ..color = Colors.white.withValues(alpha: 0.35 + 0.65 * value)
          ..strokeWidth = 7
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  @override
  bool shouldRepaint(_ClockPainter old) => old.progress != progress;
}

class _SummarySlide extends StatelessWidget {
  const _SummarySlide({required this.t, required this.day});

  final Animation<double> t;
  final DayListening day;

  @override
  Widget build(BuildContext context) {
    final top = day.songs.first;
    final artist = day.artists.isEmpty ? '' : day.artists.first.name;
    final cover = _img(top.image);
    return AnimatedBuilder(
      animation: t,
      builder: (context, _) {
        final p = _seg(t.value, 0, 0.25, Curves.easeOutBack);
        return Center(
          child: Transform.scale(
            scale: 0.85 + 0.15 * p,
            child: Opacity(
              opacity: p.clamp(0.0, 1.0),
              child: Container(
                padding: const EdgeInsets.all(22),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: Colors.white24),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Container(
                            width: 96,
                            height: 96,
                            color: Colors.white12,
                            child: cover == null
                                ? null
                                : Image(image: cover, fit: BoxFit.cover),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${day.totalSeconds ~/ 60}',
                                style: _big(44),
                              ),
                              Text(
                                'minutes today',
                                style: muzikaBody(15, color: Colors.white70),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    _label('Top song'),
                    Text(
                      '${top.title} · ${top.artist}',
                      maxLines: 2,
                      style: muzikaBody(17, weight: 700, color: Colors.white),
                    ),
                    if (artist.isNotEmpty) ...[
                      const SizedBox(height: 14),
                      _label('Top artist'),
                      Text(
                        artist,
                        style: muzikaBody(17, weight: 700, color: Colors.white),
                      ),
                    ],
                    const SizedBox(height: 14),
                    _label('On repeat'),
                    for (final s in day.songs.skip(1).take(3))
                      Text(
                        s.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: muzikaBody(15, color: Colors.white),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _label(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 2),
    child: Text(
      text.toUpperCase(),
      style: muzikaBody(
        11.5,
        weight: 700,
        color: Colors.white54,
      ).copyWith(letterSpacing: 1.2),
    ),
  );
}
