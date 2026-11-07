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
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:muzika/main.dart' show logger;
import 'package:muzika/services/listening_stats.dart';
import 'package:timezone/timezone.dart' as tz;

/// The daily story is "ready" at 9 pm: the ring on Home lights up and, if
/// something was played today, a notification says so.
class StoryReminder {
  StoryReminder._();

  static const readyHour = 21;
  static const _notificationId = 2100;
  static const _seenKey = 'storySeenDay';
  static const _bookedKey = 'storyReminderDay';

  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _initialized = false;
  static String? _bookedToday;

  /// Set when the app is opened from the reminder; Home then plays the story.
  static final openRequested = ValueNotifier<bool>(false);

  /// Bumped when today's story is watched, so the ring goes grey again.
  static final seen = ValueNotifier<String?>(
    Hive.box('settings').get(_seenKey) as String?,
  );

  static String get _today => ListeningStats.dayKey(DateTime.now());

  /// Lit from 9 pm until midnight, once something was played today and the
  /// story hasn't been watched yet.
  static bool get isReady {
    final now = DateTime.now();
    if (now.hour < readyHour) return false;
    if (seen.value == _today) return false;
    return (ListeningStats.instance.day(now)?.totalSeconds ?? 0) >= 60;
  }

  /// Today's story exists: from 9 pm until midnight, once something was
  /// played today (watched or not).
  static bool get isAvailable {
    final now = DateTime.now();
    if (now.hour < readyHour) return false;
    return (ListeningStats.instance.day(now)?.totalSeconds ?? 0) >= 60;
  }

  static void markSeen() {
    seen.value = _today;
    unawaited(Hive.box('settings').put(_seenKey, _today));
  }

  static Future<void> init() async {
    if (!Platform.isAndroid && !Platform.isWindows) return;
    try {
      await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('ic_launcher_foreground'),
          windows: WindowsInitializationSettings(
            appName: 'Muzika',
            appUserModelId: 'et.muzika.app',
            guid: 'e8d93ba7-8829-45d4-8c2b-41e90c05a773',
          ),
        ),
        onDidReceiveNotificationResponse: (r) {
          if (r.payload == 'story') openRequested.value = true;
        },
      );
      final launch = await _plugin.getNotificationAppLaunchDetails();
      if (launch?.didNotificationLaunchApp == true &&
          launch?.notificationResponse?.payload == 'story') {
        openRequested.value = true;
      }
      _initialized = true;
    } catch (e, st) {
      logger.log('Story reminder init failed', error: e, stackTrace: st);
    }
  }

  /// Books today's 9 pm reminder, once a day, the first time a minute of
  /// listening is recorded before then.
  static Future<void> bookForToday() async {
    final today = _today;
    if (!_initialized || _bookedToday == today) return;
    _bookedToday = today;
    final box = Hive.box('settings');
    if (box.get(_bookedKey) == today) return;
    final now = DateTime.now();
    final at = DateTime(now.year, now.month, now.day, readyHour);
    if (!now.isBefore(at)) return;
    await box.put(_bookedKey, today);
    try {
      await _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.requestNotificationsPermission();
      await _plugin.zonedSchedule(
        id: _notificationId,
        // An instant in time, so UTC works whatever the phone's zone is.
        scheduledDate: tz.TZDateTime.from(at, tz.UTC),
        notificationDetails: const NotificationDetails(
          windows: WindowsNotificationDetails(),
          android: AndroidNotificationDetails(
            'daily_story',
            'Your day in music',
            channelDescription:
                'A nudge at 9 pm when your daily story is ready',
          ),
        ),
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        title: 'Your day in music is ready',
        body: 'Tap to see what you played today',
        payload: 'story',
      );
    } catch (e, st) {
      logger.log('Story reminder failed', error: e, stackTrace: st);
    }
  }
}
