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

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:posthog_flutter/posthog_flutter.dart';

/// Anonymous usage stats (PostHog). The project key comes in at build time
/// (`--dart-define-from-file=posthog.json`), so it isn't in the public code
/// and builds without it (forks, F-Droid) send nothing.
const _postHogKey = String.fromEnvironment('POSTHOG_KEY');
const _postHogHost = String.fromEnvironment(
  'POSTHOG_HOST',
  defaultValue: 'https://us.i.posthog.com',
);

/// The user's "Share anonymous usage stats" switch (Settings).
final usageStatsOn = ValueNotifier<bool>(
  Hive.box('settings').get('usageStats', defaultValue: true) as bool,
);

bool _ready = false;

/// Whether this build sends stats at all (it has a key).
bool get analyticsAvailable => _postHogKey.isNotEmpty;

/// Starts PostHog: events, screens, errors and, on phones, session
/// recordings. Nothing without a key, nor in debug runs.
Future<void> startAnalytics() async {
  if (!analyticsAvailable || kDebugMode) return;
  try {
    final config = PostHogConfig(_postHogKey)
      ..host = _postHogHost
      ..captureApplicationLifecycleEvents = true
      ..optOut = !usageStatsOn.value
      // An anonymous profile per install, so each user has their own page
      // (events, recordings) in PostHog. No name or account.
      ..personProfiles = PostHogPersonProfiles.always
      ..sessionReplay = Platform.isAndroid || Platform.isIOS;
    // Song titles and covers show in recordings: what was played is the
    // point of them. Text typed in fields stays hidden.
    config.sessionReplayConfig
      ..maskAllTexts = false
      ..maskAllImages = false;
    config.errorTrackingConfig
      ..captureFlutterErrors = true
      ..capturePlatformDispatcherErrors = true
      ..captureNativeExceptions = true;
    await Posthog().setup(config);
    _ready = true;
  } catch (_) {
    // Stats never get in the way of the app.
  }
}

/// Turns stats on or off (Settings), remembered.
Future<void> setUsageStats(bool on) async {
  usageStatsOn.value = on;
  await Hive.box('settings').put('usageStats', on);
  if (!_ready) return;
  try {
    await (on ? Posthog().optIn() : Posthog().optOut());
  } catch (_) {}
}

/// Records [event] with its [properties] (text and numbers only).
void track(String event, [Map<String, Object>? properties]) {
  if (!_ready || !usageStatsOn.value) return;
  unawaited(
    Posthog()
        .capture(eventName: event, properties: properties)
        .catchError((_) {}),
  );
}

/// Records the screen now showing, by its route ("/artist/:id").
void trackScreen(String name) {
  if (!_ready || !usageStatsOn.value || name.isEmpty) return;
  unawaited(Posthog().screen(screenName: name).catchError((_) {}));
}
