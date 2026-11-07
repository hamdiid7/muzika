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

import 'dart:async';
import 'dart:io';

import 'package:app_links/app_links.dart';
import 'package:audio_service/audio_service.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:muzika/services/analytics.dart';
import 'package:muzika/extensions/l10n.dart';
import 'package:muzika/localization/app_localizations.dart';
import 'package:muzika/services/audio_service.dart';
import 'package:muzika/services/common_services.dart'
    show dropOldSubstitutePlays;
import 'package:muzika/services/cover_tint.dart';
import 'package:muzika/services/data_manager.dart';
import 'package:muzika/services/data_saver.dart';
import 'package:muzika/services/io_service.dart';
import 'package:muzika/services/itunes_catalog.dart';
import 'package:muzika/services/listening_stats.dart';
import 'package:muzika/services/listening_stats_service.dart';
import 'package:muzika/services/logger_service.dart';
import 'package:muzika/services/playlist_sharing.dart';
import 'package:muzika/services/playlists_manager.dart';
import 'package:muzika/services/proxy_manager.dart' show ytClient;
import 'package:muzika/services/router_service.dart';
import 'package:muzika/services/settings_manager.dart';
import 'package:muzika/services/story_reminder.dart';
import 'package:muzika/services/synced_lyrics.dart' show untilSongStarted;
import 'package:muzika/services/tunnel_service.dart';
import 'package:muzika/services/update_manager.dart';
import 'package:muzika/services/windows_tray.dart';
import 'package:muzika/theme/app_themes.dart';
import 'package:muzika/utilities/flutter_toast.dart';
import 'package:muzika/utilities/language_utils.dart';
import 'package:muzika/utilities/playlist_utils.dart';
import 'package:muzika/utilities/sharing_intent.dart';
import 'package:path_provider/path_provider.dart';
import 'package:posthog_flutter/posthog_flutter.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

late MuzikaAudioHandler audioHandler;
StreamSubscription<String?>? sharingIntentSubscription;
StreamSubscription<Uri?>? appLinksSubscription;

final logger = Logger();
final appLinks = AppLinks();

bool isFdroidBuild = false;
const bool kMuzikaUpdateChecks = false;
bool isUpdateChecked = false;

class Muzika extends StatefulWidget {
  const Muzika({super.key});

  static Future<void> updateAppState(
    BuildContext context, {
    ThemeMode? newThemeMode,
    Locale? newLocale,
    Color? newAccentColor,
    bool? useSystemColor,
  }) async {
    context.findAncestorStateOfType<_MuzikaState>()!.changeSettings(
      newThemeMode: newThemeMode,
      newLocale: newLocale,
      newAccentColor: newAccentColor,
      systemColorStatus: useSystemColor,
    );
  }

  @override
  _MuzikaState createState() => _MuzikaState();
}

class _MuzikaState extends State<Muzika> with WidgetsBindingObserver {
  void changeSettings({
    ThemeMode? newThemeMode,
    Locale? newLocale,
    Color? newAccentColor,
    bool? systemColorStatus,
  }) {
    setState(() {
      if (newThemeMode != null) {
        themeMode = newThemeMode;
        brightness = getBrightnessFromThemeMode(newThemeMode);
      }
      if (newLocale != null) {
        languageSetting = newLocale;
      }
      if (newAccentColor != null) {
        if (systemColorStatus != null &&
            useSystemColor.value != systemColorStatus) {
          useSystemColor.value = systemColorStatus;
          addOrUpdateData<bool>(
            'settings',
            'useSystemColor',
            systemColorStatus,
          );
        }
        primaryColorSetting = newAccentColor;
      }
    });
  }

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addObserver(this);

    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

    final platformDispatcher = PlatformDispatcher.instance;

    // This callback is called every time the brightness changes.
    platformDispatcher.onPlatformBrightnessChanged = () {
      if (themeMode == ThemeMode.system) {
        setState(() {
          brightness = platformDispatcher.platformBrightness;
        });
      }
    };

    offlineMode.addListener(_onOfflineModeChanged);

    if (Platform.isAndroid || Platform.isIOS) {
      sharingIntentSubscription = ReceiveSharingIntent.getTextStream().listen(
        (String? value) async {
          await consumeYoutubeSharedTextIntent(
            value,
            audioHandler: audioHandler,
            onError: (error, stackTrace) {
              logger.log(
                'Error while playing shared song:',
                error: error,
                stackTrace: stackTrace,
              );
            },
          );
        },
        onError: (err) {
          logger.log('getTextStream error:', error: err);
        },
      );
    }

    try {
      LicenseRegistry.addLicense(() async* {
        final license = await rootBundle.loadString(
          'assets/licenses/paytone.txt',
        );
        yield LicenseEntryWithLineBreaks(['paytoneOne'], license);
      });
    } catch (e, stackTrace) {
      logger.log(
        'License Registration Error',
        error: e,
        stackTrace: stackTrace,
      );
    }

    // The original updater and announcements pointed at the original
    // project's GitHub; Muzika
    // has no release channel yet, so both stay off.
    if (kMuzikaUpdateChecks && !isFdroidBuild) {
      if (shouldWeCheckUpdates.value == true) {
        if (!isUpdateChecked && kReleaseMode) {
          SchedulerBinding.instance.addPostFrameCallback((_) {
            if (!offlineMode.value) {
              checkAppUpdates();
            }
            isUpdateChecked = true;
          });
        }
      } else {
        if (shouldWeCheckUpdates.value == null) {
          // show dialog that asks user if they want to enable update checks
          SchedulerBinding.instance.addPostFrameCallback((_) {
            showUpdateCheckDialog(NavigationManager().context);
          });
        } else {
          SchedulerBinding.instance.addPostFrameCallback((_) async {
            if (!offlineMode.value) {
              await fetchAnnouncementOnly();
            }
          });
        }
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // Persist listening stats when the app leaves the foreground. This is the
    // reliable moment to snapshot and flush: unlike widget dispose, these
    // callbacks are delivered before the OS suspends or terminates the process.
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      listeningStatsService.recordListeningSessionProgress(
        wasPlaying: audioHandler.audioPlayer.playing,
      );
      unawaited(listeningStatsService.flush());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    offlineMode.removeListener(_onOfflineModeChanged);
    PlatformDispatcher.instance.onPlatformBrightnessChanged = null;

    Hive.close();
    unawaited(sharingIntentSubscription?.cancel());
    unawaited(appLinksSubscription?.cancel());
    super.dispose();
  }

  void _onOfflineModeChanged() {
    // Force rebuild when offline mode changes
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return DynamicColorBuilder(
      builder: (lightColorScheme, darkColorScheme) {
        final colorScheme = getAppColorScheme(
          lightColorScheme,
          darkColorScheme,
        );

        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            systemNavigationBarColor: Colors.transparent,
            systemNavigationBarContrastEnforced: true,
            statusBarBrightness: brightness == Brightness.dark
                ? Brightness.light
                : Brightness.dark,
            statusBarIconBrightness: brightness == Brightness.dark
                ? Brightness.light
                : Brightness.dark,
            systemNavigationBarIconBrightness: brightness == Brightness.dark
                ? Brightness.light
                : Brightness.dark,
          ),
          child: ValueListenableBuilder<Color?>(
            valueListenable: coverTint,
            builder: (context, tint, _) => PostHogWidget(
              child: MaterialApp.router(
                themeMode: themeMode,
                darkTheme: getAppTheme(colorScheme, tint: tint),
                theme: getAppTheme(colorScheme, tint: tint),
                localizationsDelegates: [
                  AppLocalizations.delegate,
                  ...GlobalMaterialLocalizations.delegates,
                ],
                supportedLocales: appSupportedLocales,
                locale: languageSetting,
                routerConfig: NavigationManager.router,
                scrollBehavior: const MuzikaScrollBehavior(),
                // Everything drawn a little smaller than Flutter's sizes.
                builder: (context, child) =>
                    _UiScale(child: child ?? const SizedBox.shrink()),
              ),
            ),
          ),
        );
      },
    );
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Clips' videos and, on Windows, the music itself play through media_kit
  // (mpv); Android keeps its own player.
  MediaKit.ensureInitialized();
  JustAudioMediaKit.ensureInitialized();
  await initialisation();
  await WindowsTray.init();
  untilSongStarted = audioHandler.untilSongStarted;
  startLineSpeedChecks();
  await startAnalytics();
  // Each page by its route ("/artist/:id"), not its ids.
  final routes = NavigationManager.router.routerDelegate;
  routes.addListener(() => trackScreen(routes.currentConfiguration.fullPath));
  // The page YouTube's song lookups need, fetched once now so the first
  // song played doesn't wait for it.
  unawaited(ytClient.videos.streams.warmUp().catchError((_) {}));

  runApp(const Muzika());
}

/// The cache only holds things the app can fetch again, so a cache file
/// damaged by a crash or a forced close is thrown away instead of stopping
/// the app from starting.
Future<void> _openCacheBox() async {
  try {
    await Hive.openBox('cache');
  } catch (e, stackTrace) {
    logger.log(
      'Cache box unreadable, starting a fresh one',
      error: e,
      stackTrace: stackTrace,
    );
    await Hive.deleteBoxFromDisk('cache');
    await Hive.openBox('cache');
  }
}

Future<void> initialisation() async {
  try {
    await Hive.initFlutter();

    await Future.wait([
      Hive.openBox('settings'),
      Hive.openBox('user'),
      Hive.openBox('userNoBackup'),
      _openCacheBox(),
    ]);

    // Must run before any HttpClient is created so all traffic is tunneled.
    await TunnelService.instance.init();

    audioHandler = await AudioService.init(
      builder: MuzikaAudioHandler.new,
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'et.muzika.app',
        androidNotificationChannelName: 'Muzika',
        androidNotificationIcon: 'drawable/ic_launcher_foreground',
        androidShowNotificationBadge: true,
        androidStopForegroundOnPause: false,
        // Handed to Android Auto on the browsable root. Without the search
        // flag the car never offers a search box, and without the content
        // style keys it falls back to an undifferentiated list of everything.
        androidBrowsableRootExtras: {
          AndroidContentStyle.supportedKey: true,
          AndroidContentStyle.browsableHintKey:
              AndroidContentStyle.gridItemHintValue,
          AndroidContentStyle.playableHintKey:
              AndroidContentStyle.listItemHintValue,
          'android.media.browse.SEARCH_SUPPORTED': true,
        },
      ),
    );
    ListeningStats.instance.start();
    startCoverTint();
    unawaited(StoryReminder.init());
    unawaited(dropOldSubstitutePlays());
    initItunesCatalog();

    // Init router
    NavigationManager.instance;

    try {
      // Listen to incoming links while app is running
      appLinksSubscription = appLinks.uriLinkStream.listen(
        handleIncomingLink,
        onError: (err) {
          logger.log('URI link error:', error: err);
        },
      );
    } on PlatformException {
      logger.log('Failed to get initial uri');
    }

    if (isFdroidBuild && !offlineMode.value) {
      await fetchAnnouncementOnly();
    }
  } catch (e, stackTrace) {
    logger.log('Initialization Error', error: e, stackTrace: stackTrace);
  }

  applicationDirPath = (await getApplicationDocumentsDirectory()).path;
  await FilePaths.ensureDirectoriesExist();
}

void handleIncomingLink(Uri? uri) async {
  if (uri == null || uri.scheme != 'muzika' || uri.host != 'playlist') return;

  if (uri.pathSegments.length < 2 || uri.pathSegments[0] != 'custom') return;

  try {
    final encodedPlaylist = uri.pathSegments[1];
    final playlist = await PlaylistSharingService.decodeAndExpandPlaylist(
      encodedPlaylist,
    );

    if (playlist == null) {
      _showPlaylistError();
      return;
    }

    // Ensure the incoming playlist has a unique id so it can be removed later
    if (playlist['ytid'] == null || playlist['ytid'].toString().isEmpty) {
      playlist['ytid'] = PlaylistUtils.generateCustomPlaylistId();
    }

    // Check for duplicate by title and song ytids
    final incomingYtids = (playlist['list'] as List<dynamic>)
        .map((s) => s['ytid'].toString())
        .toList();

    final isDuplicate = PlaylistUtils.playlistExists(
      playlist,
      incomingYtids,
      userCustomPlaylists.value,
    );

    if (isDuplicate) {
      showToast(
        NavigationManager().context,
        NavigationManager().context.l10n!.playlistAlreadyExists,
      );
    } else {
      userCustomPlaylists.value = [...userCustomPlaylists.value, playlist];
      unawaited(
        addOrUpdateData<List>(
          'user',
          'customPlaylists',
          userCustomPlaylists.value,
        ),
      );
      showToast(
        NavigationManager().context,
        '${NavigationManager().context.l10n!.addedSuccess}!',
      );
    }
  } catch (e) {
    _showPlaylistError();
  }
}

void _showPlaylistError() {
  showToast(
    NavigationManager().context,
    NavigationManager().context.l10n!.failedToLoadPlaylist,
  );
}

/// iOS-style bouncing on every list, instead of Android's stretch/glow.
class MuzikaScrollBehavior extends MaterialScrollBehavior {
  const MuzikaScrollBehavior();

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) =>
      const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics());

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) => child;
}

/// Muzika's whole interface a touch smaller (94 %): laid out on a screen
/// that much bigger, then scaled down to fit, so cards, text and buttons
/// all shrink alike and taps still land where they're drawn.
class _UiScale extends StatelessWidget {
  const _UiScale({required this.child});

  static const _factor = 0.94;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    return LayoutBuilder(
      builder: (context, box) {
        final size = Size(box.maxWidth / _factor, box.maxHeight / _factor);
        return Transform.scale(
          scale: _factor,
          alignment: Alignment.topLeft,
          child: OverflowBox(
            alignment: Alignment.topLeft,
            minWidth: size.width,
            maxWidth: size.width,
            minHeight: size.height,
            maxHeight: size.height,
            child: MediaQuery(
              data: mq.copyWith(
                size: size,
                padding: mq.padding / _factor,
                viewPadding: mq.viewPadding / _factor,
                viewInsets: mq.viewInsets / _factor,
                systemGestureInsets: mq.systemGestureInsets / _factor,
              ),
              child: child,
            ),
          ),
        );
      },
    );
  }
}
