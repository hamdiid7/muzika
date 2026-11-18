/*
 *     Copyright (C) 2026 Valeri Gokadze
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

import 'dart:convert';
import 'dart:io';

import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';
import 'package:muzika/constants/version.dart';
import 'package:muzika/extensions/l10n.dart';
import 'package:muzika/main.dart';
import 'package:muzika/services/data_manager.dart';
import 'package:muzika/services/router_service.dart';
import 'package:muzika/services/settings_manager.dart';
import 'package:muzika/theme/muzika_tokens.dart';
import 'package:muzika/utilities/flutter_toast.dart';
import 'package:muzika/utilities/url_launcher.dart';
import 'package:muzika/widgets/auto_format_text.dart';

/// Muzika's releases on GitHub: the newest one's version (its tag, "v1.0.6"),
/// what's new (its notes) and its APK (the file attached to it).
const String checkUrl =
    'https://api.github.com/repos/hamdiid7/muzika/releases/latest';
const String downloadUrlKey = 'url';
const String downloadUrlArm64Key = 'arm64url';
const String downloadFilename = 'Muzika.apk';
const String downloadUrlWindowsKey = 'windowsurl';

/// The oldest version that may keep running, read from a hidden line in
/// the release's notes: `<!-- min: 1.0.7 -->` (GitHub doesn't show it).
/// Older apps get a screen that only offers the update.
final RegExp _minVersionLine = RegExp(
  r'<!--\s*min:\s*v?([0-9]+(?:\.[0-9]+)*)\s*-->',
  caseSensitive: false,
);

/// The newest GitHub release as the update dialog wants it: `version`,
/// `notes`, and the APK's link under `url` and `arm64url` (the release page
/// when no APK is attached). Null when GitHub can't be reached.
Future<Map<String, dynamic>?> _latestRelease() async {
  final response = await http
      .get(
        Uri.parse(checkUrl),
        headers: const {'Accept': 'application/vnd.github+json'},
      )
      .timeout(const Duration(seconds: 15));
  if (response.statusCode != 200) {
    logger.log(
      'Fetch update API (checkUrl) call returned status code ${response.statusCode}',
    );
    return null;
  }
  final release = json.decode(response.body) as Map<String, dynamic>;
  final apks = [
    for (final a in (release['assets'] as List? ?? const []).whereType<Map>())
      if ('${a['name']}'.toLowerCase().endsWith('.apk'))
        '${a['browser_download_url']}',
  ];
  final page = '${release['html_url'] ?? 'https://github.com/hamdiid7/muzika'}';
  final apk = apks.isNotEmpty ? apks.first : page;
  final assets = (release['assets'] as List? ?? const []).whereType<Map>();
  final exe = assets
      .map((a) => '${a['browser_download_url']}')
      .where((u) => u.toLowerCase().endsWith('.exe'))
      .firstOrNull;
  final body = '${release['body'] ?? ''}';
  return {
    'version': '${release['tag_name'] ?? ''}'.replaceFirst(RegExp('^v'), ''),
    'notes': body.replaceAll(_minVersionLine, '').trim(),
    'min': _minVersionLine.firstMatch(body)?.group(1),
    downloadUrlWindowsKey: exe ?? page,
    downloadUrlKey: apk,
    downloadUrlArm64Key: apks.firstWhere(
      (u) => u.toLowerCase().contains('arm64'),
      orElse: () => apk,
    ),
  };
}

/// Looks for a newer Muzika and offers it. [manual] (Settings' "Download
/// app update"): also says so when this one is the newest. [forcedOnly]:
/// only an update this version must take (for people who turned update
/// checks off); nothing else is offered.
Future<void> checkAppUpdates({
  bool manual = false,
  bool forcedOnly = false,
}) async {
  if (!Platform.isAndroid && !Platform.isWindows) return;
  try {
    final map = await _latestRelease();
    // Too old to keep running: the update screen, on every platform.
    final min = map?['min'] as String?;
    if (map != null &&
        min != null &&
        isLatestVersionHigher(appVersion, min) &&
        isLatestVersionHigher(appVersion, '${map['version']}')) {
      await showForcedUpdate(map);
      return;
    }
    if (forcedOnly) return;
    // Otherwise only Android offers updates; on Windows Settings' button
    // opens the releases page.
    if (!Platform.isAndroid) {
      if (manual) {
        await launchURL(
          Uri.parse('https://github.com/hamdiid7/muzika/releases'),
        );
      }
      return;
    }
    if (map == null) {
      if (manual) {
        showToast(
          NavigationManager().context,
          "Couldn't check for updates right now",
        );
      }
      return;
    }
    final latestVersion = map['version'].toString();

    if (!isLatestVersionHigher(appVersion, latestVersion)) {
      if (manual) {
        showToast(
          NavigationManager().context,
          'Muzika is up to date ($appVersion)',
        );
      }
      return;
    }

    await showDialog(
      context: NavigationManager().context,
      builder: (BuildContext context) {
        final colorScheme = Theme.of(context).colorScheme;

        return AlertDialog(
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: colorScheme.primaryContainer,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  FluentIcons.arrow_download_24_regular,
                  color: colorScheme.onPrimaryContainer,
                  size: 32,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                context.l10n!.appUpdateIsAvailable,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w600,
                  color: colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  'V$latestVersion',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: colorScheme.onPrimaryContainer,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Container(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(context).height / 2.5,
                ),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: SingleChildScrollView(
                  child: AutoFormatText(text: '${map['notes'] ?? ''}'),
                ),
              ),
            ],
          ),
          actionsAlignment: MainAxisAlignment.center,
          actions: <Widget>[
            OutlinedButton(
              onPressed: () => Navigator.pop(context),
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: colorScheme.outline),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: Text(context.l10n!.cancel),
            ),
            FilledButton.icon(
              onPressed: () {
                getDownloadUrl(map).then(
                  (url) => {launchURL(Uri.parse(url)), Navigator.pop(context)},
                );
              },
              icon: const Icon(FluentIcons.arrow_download_20_regular),
              label: Text(context.l10n!.download),
            ),
          ],
        );
      },
    );
  } catch (e, stackTrace) {
    logger.log('Error in checkAppUpdates', error: e, stackTrace: stackTrace);
  }
}

void showUpdateCheckDialog(BuildContext context) {
  final colorScheme = Theme.of(context).colorScheme;

  showDialog(
    context: context,
    builder: (context) {
      return AlertDialog(
        icon: Icon(
          FluentIcons.arrow_sync_circle_24_regular,
          color: colorScheme.primary,
          size: 40,
        ),
        title: Text(
          context.l10n!.checkForUpdates,
          style: TextStyle(
            color: colorScheme.onSurface,
            fontWeight: FontWeight.w600,
          ),
          textAlign: TextAlign.center,
        ),
        content: Text(
          context.l10n!.enableUpdateChecksDescription,
          style: TextStyle(color: colorScheme.onSurfaceVariant),
          textAlign: TextAlign.center,
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          OutlinedButton(
            onPressed: () {
              shouldWeCheckUpdates.value = false;
              addOrUpdateData<bool>('settings', 'shouldWeCheckUpdates', false);
              Navigator.of(context).pop();
            },
            style: OutlinedButton.styleFrom(
              side: BorderSide(color: colorScheme.outline),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: Text(context.l10n!.no),
          ),
          FilledButton(
            onPressed: () {
              shouldWeCheckUpdates.value = true;
              addOrUpdateData<bool>('settings', 'shouldWeCheckUpdates', true);
              if (!isFdroidBuild && kReleaseMode && !offlineMode.value) {
                checkAppUpdates();
                isUpdateChecked = true;
              }
              Navigator.of(context).pop();
            },
            child: Text(context.l10n!.yes),
          ),
        ],
      );
    },
  );
}

bool isLatestVersionHigher(String appVersion, String latestVersion) {
  final parsedAppVersion = appVersion.split('.');
  final parsedAppLatestVersion = latestVersion.split('.');
  final length = parsedAppVersion.length > parsedAppLatestVersion.length
      ? parsedAppVersion.length
      : parsedAppLatestVersion.length;
  for (var i = 0; i < length; i++) {
    final value1 = i < parsedAppVersion.length
        ? int.parse(parsedAppVersion[i])
        : 0;
    final value2 = i < parsedAppLatestVersion.length
        ? int.parse(parsedAppLatestVersion[i])
        : 0;
    if (value2 > value1) {
      return true;
    } else if (value2 < value1) {
      return false;
    }
  }

  return false;
}

Future<String> getCPUArchitecture() async {
  final info = await Process.run('uname', ['-m']);
  final cpu = info.stdout.toString().replaceAll('\n', '');

  return cpu;
}

Future<String> getDownloadUrl(Map<String, dynamic> map) async {
  if (Platform.isWindows) return map[downloadUrlWindowsKey].toString();
  final cpuArchitecture = await getCPUArchitecture();
  final url = cpuArchitecture == 'aarch64'
      ? map[downloadUrlArm64Key].toString()
      : map[downloadUrlKey].toString();

  return url;
}

/// Announcements came with the old update file; GitHub releases have
/// none, so there is nothing to fetch.
Future<void> fetchAnnouncementOnly() async {}

bool _forcedOnScreen = false;

/// The update this version must take: a full screen with what's new and a
/// Download button, no way back to the app. It only shows when GitHub could
/// be reached, so without internet the app still opens.
Future<void> showForcedUpdate(Map<String, dynamic> release) async {
  if (_forcedOnScreen) return;
  _forcedOnScreen = true;
  final latest = '${release['version']}';
  await showGeneralDialog<void>(
    context: NavigationManager().context,
    barrierDismissible: false,
    useRootNavigator: true,
    pageBuilder: (context, _, _) {
      final scheme = Theme.of(context).colorScheme;
      final notes = '${release['notes'] ?? ''}';
      return PopScope(
        canPop: false,
        child: Scaffold(
          backgroundColor: Theme.of(context).scaffoldBackgroundColor,
          body: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Container(
                        width: 64,
                        height: 64,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: scheme.surfaceContainerHigh,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Icon(
                          FluentIcons.arrow_download_24_regular,
                          size: 32,
                          color: scheme.onSurface,
                        ),
                      ),
                      ),
                      const SizedBox(height: 20),
                      Text(
                        'Update Muzika to keep listening',
                        style: muzikaHeading(28, color: scheme.onSurface),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'This version ($appVersion) no longer works well. '
                        'Get Muzika $latest, it only takes a minute.',
                        style: muzikaBody(
                          15,
                          color: scheme.onSurfaceVariant,
                        ).copyWith(height: 1.4),
                      ),
                      const SizedBox(height: 20),
                      if (notes.isNotEmpty)
                        Flexible(
                          child: Container(
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: scheme.surfaceContainerLow,
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: SingleChildScrollView(
                              child: AutoFormatText(
                                text: notes,
                                textAlign: TextAlign.start,
                              ),
                            ),
                          ),
                        ),
                      const SizedBox(height: 20),
                      FilledButton.icon(
                        style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(52),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        onPressed: () async =>
                            launchURL(Uri.parse(await getDownloadUrl(release))),
                        icon: const Icon(FluentIcons.arrow_download_20_regular),
                        label: Text(
                          'Download Muzika $latest',
                          style: muzikaBody(16, weight: 600),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        Platform.isAndroid
                            ? 'Open the downloaded file and tap Install.'
                            : 'Open the downloaded file to install it.',
                        textAlign: TextAlign.center,
                        style: muzikaBody(12.5, color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}
