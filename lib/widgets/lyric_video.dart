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

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:muzika/main.dart' show audioHandler;
import 'package:muzika/services/synced_lyrics.dart';
import 'package:muzika/theme/muzika_tokens.dart';

/// A song with synced lyrics and no music video, as a lyric video for
/// Clips: where it starts (its chorus) and its lines.
typedef LyricClip = ({SongLyrics lyrics, Duration start});

/// How long a lyric video plays before going round again, like a clip.
const lyricClipLength = Duration(seconds: 30);

/// Where a lyric video starts: the first time its most repeated line (the
/// chorus) comes, else a quarter of the way in.
Duration lyricClipStart(SongLyrics lyrics) {
  final lines = lyrics.lines ?? const <LyricLine>[];
  if (lines.isEmpty) return Duration.zero;
  String norm(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N} ]', unicode: true), '');
  final counts = <String, int>{};
  for (final l in lines) {
    final k = norm(l.text);
    if (k.length > 3) counts[k] = (counts[k] ?? 0) + 1;
  }
  final best = counts.entries
      .where((e) => e.value > 1)
      .fold<MapEntry<String, int>?>(
        null,
        (a, b) => a == null || b.value > a.value ? b : a,
      );
  final line = best == null
      ? lines[lines.length ~/ 4]
      : lines.firstWhere((l) => norm(l.text) == best.key);
  final t = line.time - const Duration(milliseconds: 600);
  return t.isNegative ? Duration.zero : t;
}

/// The nature pictures in assets/lyric_backgrounds/, read once.
Future<List<String>> _backgrounds() => _pictures ??= () async {
  final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
  return [
    for (final a in manifest.listAssets())
      if (a.startsWith('assets/lyric_backgrounds/') &&
          RegExp(r'\.(jpe?g|png|webp)$', caseSensitive: false).hasMatch(a))
        a,
  ]..sort();
}();
Future<List<String>>? _pictures;

/// The lyric video: a nature picture that slowly drifts closer, and the
/// line being sung in the middle, in big white italics, one at a time.
class LyricVideo extends StatefulWidget {
  const LyricVideo({
    super.key,
    required this.songId,
    required this.clip,
    required this.active,
    this.position,
  });

  /// Picks the picture, the same one each time for a song.
  final String songId;
  final LyricClip clip;

  /// Only the card on screen follows the song.
  final bool active;

  /// Where the song is (Clips plays it in its own player); the app's
  /// player when null.
  final Stream<Duration>? position;

  @override
  State<LyricVideo> createState() => _LyricVideoState();
}

class _LyricVideoState extends State<LyricVideo>
    with SingleTickerProviderStateMixin {
  late final AnimationController _drift = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 24),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _drift.dispose();
    super.dispose();
  }

  String _lineAt(Duration position) {
    var current = '';
    for (final l in widget.clip.lyrics.lines ?? const <LyricLine>[]) {
      if (l.time > position) break;
      current = l.text.trim();
    }
    return current;
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(
          color: const Color(0xFF6E8FB5),
          child: FutureBuilder<List<String>>(
            future: _backgrounds(),
            builder: (context, snapshot) {
              final all = snapshot.data ?? const <String>[];
              if (all.isEmpty) return const SizedBox.shrink();
              final picture = all[widget.songId.hashCode.abs() % all.length];
              return AnimatedBuilder(
                animation: _drift,
                builder: (context, child) => Transform.scale(
                  scale: 1 + 0.12 * Curves.easeInOut.transform(_drift.value),
                  child: child,
                ),
                child: Image.asset(picture, fit: BoxFit.cover),
              );
            },
          ),
        ),
        // A little shade so white words read on a light sky.
        const ColoredBox(color: Color(0x33000000)),
        if (widget.active)
          StreamBuilder<Duration>(
            stream:
                widget.position ??
                audioHandler.positionDataStream.map((d) => d.position),
            builder: (context, snapshot) {
              final line = _lineAt(
                (snapshot.data ?? Duration.zero) +
                    const Duration(milliseconds: 200),
              );
              return Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 28),
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 420),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeInCubic,
                    transitionBuilder: (child, animation) => FadeTransition(
                      opacity: animation,
                      child: SlideTransition(
                        position: Tween(
                          begin: const Offset(0, 0.25),
                          end: Offset.zero,
                        ).animate(animation),
                        child: ScaleTransition(
                          scale: Tween<double>(
                            begin: 0.92,
                            end: 1,
                          ).animate(animation),
                          child: child,
                        ),
                      ),
                    ),
                    child: Text(
                      line.isEmpty ? '♪' : line,
                      key: ValueKey(line),
                      textAlign: TextAlign.center,
                      style: muzikaHeading(34, weight: 800, color: Colors.white)
                          .copyWith(
                            fontStyle: FontStyle.italic,
                            height: 1.15,
                            shadows: const [
                              Shadow(color: Color(0x99000000), blurRadius: 14),
                              Shadow(
                                color: Color(0x66000000),
                                offset: Offset(0, 2),
                                blurRadius: 3,
                              ),
                            ],
                          ),
                    ),
                  ),
                ),
              );
            },
          ),
      ],
    );
  }
}
