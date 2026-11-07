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

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;

/// Data saver (Muzika): `auto` (on while the line is slow), `on` or `off`.
/// On, songs stream at medium quality instead of high, the Canvas video at
/// 360p, covers one size smaller, and one song (not three) is got ready
/// ahead.
final dataSaverSetting = ValueNotifier<String>(
  Hive.box('settings').get('dataSaver', defaultValue: 'auto') as String,
);

/// The line's download speed in KB/s, last measured (null until then).
final lineSpeed = ValueNotifier<double?>(null);

/// Below this (2 Mbit/s) the line counts as slow: a 720p video alone needs
/// about that.
const _slowKBps = 250.0;

bool get dataSaverOn =>
    dataSaverSetting.value == 'on' ||
    (dataSaverSetting.value == 'auto' &&
        (lineSpeed.value ?? double.infinity) < _slowKBps);

void setDataSaver(String value) {
  dataSaverSetting.value = value;
  unawaited(Hive.box('settings').put('dataSaver', value));
}

Timer? _timer;
bool _measuring = false;

/// Measures the line now and every half hour after.
void startLineSpeedChecks() {
  if (_timer != null) return;
  unawaited(measureLineSpeed());
  _timer = Timer.periodic(
    const Duration(minutes: 30),
    (_) => unawaited(measureLineSpeed()),
  );
}

/// Times a 250 KB download from Cloudflare (close to everyone, so it's the
/// user's own line that's measured).
Future<void> measureLineSpeed() async {
  if (_measuring) return;
  _measuring = true;
  try {
    final watch = Stopwatch()..start();
    final r = await http
        .get(Uri.parse('https://speed.cloudflare.com/__down?bytes=250000'))
        .timeout(const Duration(seconds: 30));
    if (r.statusCode == 200 && r.bodyBytes.isNotEmpty) {
      final seconds = watch.elapsedMilliseconds / 1000;
      lineSpeed.value = r.bodyBytes.length / 1024 / seconds;
    }
  } catch (_) {
    // Too slow to finish in half a minute: slow indeed.
    lineSpeed.value = 0;
  } finally {
    _measuring = false;
  }
}
