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

import 'package:flutter/services.dart';
import 'package:muzika/main.dart' show logger;
import 'package:muzika/services/data_manager.dart';

/// Auto framing for the full-screen Clips (Muzika): where the tall screen's
/// window sits over a wide clip as it plays, so the face stays in the
/// picture. Worked out once per clip in the background from the downloaded
/// file (faces from ML Kit, see SmartCrop.kt) and kept a month; until then,
/// and on Windows, the clip is centred.
///
/// The same rules as the prototype (muzika-mix-proto/smartcrop.py): per
/// shot, one person (where faces are seen most and biggest, then the face
/// nearest to where they were); held still while they stay in the window,
/// else followed with a centred moving average (no lag); and a face that
/// was seen is always kept in the window's middle 60%.
class CropPath {
  CropPath(this.times, this.xs, this.width, this.height);

  /// No analysis: the middle of the frame.
  static final centre = CropPath(const [0], const [0.5], 16, 9);

  /// Moments of the clip (ms) and the window's centre then (0..1 of the
  /// frame's width).
  final List<int> times;
  final List<double> xs;
  final int width;
  final int height;

  double at(Duration t) {
    if (xs.length == 1) return xs.first;
    final ms = t.inMilliseconds;
    var lo = 0;
    var hi = times.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) ~/ 2;
      if (times[mid] <= ms) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return xs[lo];
  }
}

const _channel = MethodChannel('muzika/smart_crop');
final _paths = <String, Future<CropPath>>{};

/// The framing of the clip at [file] for a screen [aspect] wide/tall.
Future<CropPath> clipFraming(String key, File file, double aspect) {
  return _paths['$key@${aspect.toStringAsFixed(2)}'] ??= () async {
    if (!Platform.isAndroid) return CropPath.centre;
    final cacheKey = 'clip_framing_v1_$key';
    final cached = await getData(
      'cache',
      cacheKey,
      cachingDuration: const Duration(days: 30),
    );
    var analysis = cached is Map ? cached : null;
    if (analysis == null) {
      try {
        analysis = await _channel
            .invokeMapMethod<String, dynamic>('analyze', {
              'path': file.path,
              'perSecond': 2,
            })
            .timeout(const Duration(seconds: 90));
        if (analysis != null) {
          unawaited(addOrUpdateData<Map>('cache', cacheKey, analysis));
        }
      } catch (e) {
        logger.log('Auto framing failed for $key', error: e);
      }
    }
    return analysis == null ? CropPath.centre : _path(analysis, aspect);
  }();
}

CropPath _path(Map analysis, double aspect) {
  final w = (analysis['width'] as num?)?.toInt() ?? 1920;
  final h = (analysis['height'] as num?)?.toInt() ?? 1080;
  final length = (analysis['length'] as num?)?.toInt() ?? 30000;
  final crop = min(1, h * aspect / w).toDouble();
  if (crop >= 0.999) return CropPath(const [0], const [0.5], w, h);
  final half = crop / 2;

  final samples = [
    for (final s in (analysis['samples'] as List? ?? const []))
      (
        t: (s['t'] as num).toInt(),
        faces: [
          for (final f in (s['faces'] as List? ?? const []))
            (x: (f[0] as num).toDouble(), area: (f[1] as num).toDouble()),
        ],
      ),
  ];
  if (samples.isEmpty) return CropPath(const [0], const [0.5], w, h);
  final cuts = [
    0,
    for (final c in (analysis['cuts'] as List? ?? const [])) (c as num).toInt(),
    length + 1,
  ]..sort();

  final times = <int>[];
  final xs = <double>[];
  for (var k = 0; k + 1 < cuts.length; k++) {
    final a = cuts[k];
    final b = cuts[k + 1];
    final shot = samples.where((s) => s.t >= a && s.t < b).toList();
    // The person the shot is about, then that person from frame to frame.
    final all = [for (final s in shot) ...s.faces];
    final followed = <({int t, double x})>[];
    if (all.isNotEmpty) {
      final anchor = all
          .reduce(
            (p, q) =>
                _weight(all, p.x, half) >= _weight(all, q.x, half) ? p : q,
          )
          .x;
      var prev = anchor;
      for (final s in shot) {
        final near = s.faces
            .where((f) => (f.x - prev).abs() < crop * 0.6)
            .toList();
        if (near.isEmpty) continue;
        prev = near
            .reduce((p, q) => (p.x - prev).abs() <= (q.x - prev).abs() ? p : q)
            .x;
        followed.add((t: s.t, x: prev));
      }
    }
    if (followed.isEmpty) {
      times.add(a);
      xs.add(0.5);
      continue;
    }
    // Ten steps a second through the shot.
    final steps = [for (var t = a; t < min(b, length); t += 100) t];
    double faceAt(int t) {
      if (t <= followed.first.t) return followed.first.x;
      if (t >= followed.last.t) return followed.last.x;
      for (var i = 0; i + 1 < followed.length; i++) {
        final p = followed[i];
        final q = followed[i + 1];
        if (t >= p.t && t <= q.t) {
          final f = q.t == p.t ? 0.0 : (t - p.t) / (q.t - p.t);
          return p.x + (q.x - p.x) * f;
        }
      }
      return followed.last.x;
    }

    final target = [for (final t in steps) faceAt(t)];
    final sorted = [...target]..sort();
    List<double> path;
    if (sorted.last - sorted.first < crop * 0.35) {
      path = List.filled(target.length, sorted[sorted.length ~/ 2]);
    } else {
      // A centred moving average over about a second.
      path = [
        for (var i = 0; i < target.length; i++)
          target
                  .sublist(max(0, i - 5), min(target.length, i + 6))
                  .reduce((p, q) => p + q) /
              (min(target.length, i + 6) - max(0, i - 5)),
      ];
    }
    for (var i = 0; i < steps.length; i++) {
      final reach = half * 0.6;
      final x = path[i].clamp(target[i] - reach, target[i] + reach);
      times.add(steps[i]);
      xs.add(x.clamp(half, 1 - half));
    }
  }
  return CropPath(times, xs, w, h);
}

/// How much of the shot is about the person at [x]: the faces seen near
/// there, bigger ones counting more.
double _weight(List<({double x, double area})> all, double x, double half) {
  var sum = 0.0;
  for (final f in all) {
    if ((f.x - x).abs() < half) sum += f.area;
  }
  return sum;
}
