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

import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:muzika/utilities/undo.dart';
import 'package:muzika/widgets/muzika_logo.dart';
import 'package:muzika/theme/muzika_tokens.dart';
import 'package:muzika/constants/version.dart';
import 'package:muzika/services/analytics.dart';
import 'package:muzika/constants/app_constants.dart';
import 'package:muzika/extensions/l10n.dart';
import 'package:muzika/main.dart';
import 'package:muzika/screens/bottom_navigation_page.dart';
import 'package:muzika/screens/search_page.dart';
import 'package:muzika/services/common_services.dart';
import 'package:muzika/services/data_manager.dart';
import 'package:muzika/services/data_saver.dart';
import 'package:muzika/services/listening_stats_service.dart';
import 'package:muzika/services/muzika_downloads.dart';
import 'package:muzika/services/playlist_download_service.dart';
import 'package:muzika/services/playlists_manager.dart';
import 'package:muzika/services/router_service.dart';
import 'package:muzika/services/settings_manager.dart';
import 'package:muzika/services/update_manager.dart';
import 'package:muzika/theme/app_themes.dart';
import 'package:muzika/utilities/flutter_bottom_sheet.dart';
import 'package:muzika/utilities/flutter_toast.dart';
import 'package:muzika/utilities/language_utils.dart';
import 'package:muzika/widgets/bottom_sheet_bar.dart';
import 'package:muzika/widgets/custom_bar.dart';
import 'package:muzika/widgets/mini_player_bottom_space.dart';
import 'package:muzika/widgets/overflow_menu_button.dart';
import 'package:muzika/widgets/popup_menu_item.dart';
import 'package:muzika/widgets/tunnel_tile.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: [
                  const IconButton(
                    tooltip: 'Back',
                    icon: Icon(FluentIcons.arrow_left_24_regular),
                    onPressed: BottomNavigationPage.back,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    context.l10n!.settings,
                    style: muzikaHeading(29, color: scheme.onSurface),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              const _MuzikaHeader(),
              _SettingsGroup(title: 'Listening', rows: _listeningRows(context)),
              _SettingsGroup(title: 'Look', rows: _lookRows(context)),
              _SettingsGroup(
                title: 'Your music',
                rows: _yourmusicRows(context),
              ),
              _SettingsGroup(title: 'Privacy', rows: _privacyRows(context)),
              _SettingsGroup(title: 'App', rows: _appRows(context)),
              const SizedBox(height: 20),
              const MiniPlayerBottomSpace(),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _listeningRows(BuildContext context) {
    return [
      CustomBar(
        context.l10n!.audioQuality,
        Icons.graphic_eq_rounded,
        onTap: () => _showAudioQualityPicker(context),
      ),
      // Auto: on while the line measures slow.
      AnimatedBuilder(
        animation: Listenable.merge([dataSaverSetting, lineSpeed]),
        builder: (context, _) {
          final speed = lineSpeed.value;
          final mode = switch (dataSaverSetting.value) {
            'on' => 'On',
            'off' => 'Off',
            _ => 'Auto (${dataSaverOn ? 'on' : 'off'} now)',
          };
          return CustomBar(
            'Data saver',
            Icons.data_saver_on_outlined,
            description: speed == null
                ? mode
                : '$mode · your line: ${speed.round()} KB/s',
            onTap: () => _showDataSaverPicker(context),
          );
        },
      ),
      // Songs fade in and out.
      ValueListenableBuilder<int>(
        valueListenable: songFadeSeconds,
        builder: (context, fade, _) => CustomBar(
          'Fade songs',
          Icons.graphic_eq_rounded,
          description: fade <= 0 ? 'Off' : 'Fade in and out over $fade seconds',
          onTap: () => showMuzikaMenu<int>(
            context,
            title: 'Fade songs in and out',
            items: [
              for (final n in const [0, 2, 4, 6, 8])
                buildPopupMenuItem<int>(
                  value: n,
                  icon: n == fade
                      ? Icons.check_rounded
                      : Icons.graphic_eq_rounded,
                  label: n == 0 ? 'Off' : '$n seconds',
                  colorScheme: Theme.of(context).colorScheme,
                ),
            ],
            onSelected: (n) {
              songFadeSeconds.value = n;
              addOrUpdateData<int>('settings', 'songFadeSeconds', n);
            },
          ),
        ),
      ),
      ValueListenableBuilder<bool>(
        valueListenable: canvasEnabled,
        builder: (_, value, __) {
          return CustomBar(
            'Canvas (looping video on the player)',
            Icons.movie_outlined,
            trailing: Switch(
              value: value,
              onChanged: (value) {
                canvasEnabled.value = value;
                addOrUpdateData<bool>('settings', 'canvasEnabled', value);
              },
            ),
          );
        },
      ),
      if (Platform.isAndroid)
        CustomBar(
          context.l10n!.equalizer,
          Icons.equalizer_rounded,
          onTap: () => context.push('/settings/equalizer'),
        ),
      ValueListenableBuilder<bool>(
        valueListenable: showAudioQualityBadge,
        builder: (_, value, __) {
          return CustomBar(
            context.l10n!.audioQualityBadge,
            Icons.high_quality_outlined,
            trailing: Switch(
              value: value,
              onChanged: (value) => _toggleAudioQualityBadge(context, value),
            ),
          );
        },
      ),
      // How many played songs are kept for offline listening.
      ValueListenableBuilder<int>(
        valueListenable: autoCacheLimit,
        builder: (context, limit, _) => CustomBar(
          'Cached songs',
          Icons.sd_storage_outlined,
          description: limit <= 0
              ? 'Off: played songs are not saved'
              : 'Keep the last $limit played songs offline',
          onTap: () => showMuzikaMenu<int>(
            context,
            title: 'Cached songs',
            items: [
              for (final n in const [0, 50, 100, 200, 500, 1000])
                buildPopupMenuItem<int>(
                  value: n,
                  icon: n == limit
                      ? Icons.check_rounded
                      : Icons.music_note_outlined,
                  label: n == 0 ? 'Off' : '$n songs',
                  colorScheme: Theme.of(context).colorScheme,
                ),
            ],
            onSelected: setAutoCacheLimit,
          ),
        ),
      ),
      ValueListenableBuilder<bool>(
        valueListenable: offlineMode,
        builder: (_, value, __) {
          return CustomBar(
            context.l10n!.offlineMode,
            Icons.cloud_off_outlined,
            trailing: Switch(
              value: value,
              onChanged: (value) => _toggleOfflineMode(context, value),
            ),
          );
        },
      ),
      const TunnelTile(),
    ];
  }

  List<Widget> _lookRows(BuildContext context) {
    return [
      CustomBar(
        context.l10n!.themeMode,
        Icons.contrast_rounded,
        onTap: () => _showThemeModePicker(context),
      ),
      if (themeMode == ThemeMode.dark)
        CustomBar(
          context.l10n!.pureBlackTheme,
          Icons.contrast_rounded,
          trailing: Switch(
            value: usePureBlackColor.value,
            onChanged: (value) => _togglePureBlack(context, value),
          ),
        ),
      CustomBar(
        context.l10n!.language,
        Icons.language_rounded,
        onTap: () => _showLanguagePicker(context),
      ),
    ];
  }

  List<Widget> _yourmusicRows(BuildContext context) {
    return [
      if (!offlineMode.value)
        CustomBar(
          context.l10n!.importSpotifyPlaylist,
          Icons.upload_outlined,
          onTap: () => context.push('/settings/import-spotify-playlist'),
        ),
      if (!offlineMode.value)
        CustomBar(
          context.l10n!.backupUserData,
          Icons.cloud_sync_outlined,
          onTap: () => _backupUserData(context),
        ),
      if (!offlineMode.value)
        CustomBar(
          context.l10n!.restoreUserData,
          Icons.cloud_upload_outlined,
          onTap: () async {
            try {
              final result = await restoreData(context);
              if (result.success) {
                reloadSettingsFromStorage();
                reloadSongLibraryStateFromStorage();
                reloadPlaylistLibraryStateFromStorage();
                reloadSearchHistoryFromStorage();
                listeningStatsService.reload();
                await audioHandler.setShuffleMode(
                  shuffleNotifier.value
                      ? AudioServiceShuffleMode.all
                      : AudioServiceShuffleMode.none,
                );
                await audioHandler.setRepeatMode(repeatNotifier.value);
                themeMode = getThemeMode(themeModeSetting);
                brightness = getBrightnessFromThemeMode(themeMode);
                if (context.mounted) {
                  await Muzika.updateAppState(
                    context,
                    newThemeMode: themeMode,
                    newLocale: languageSetting,
                    newAccentColor: primaryColorSetting,
                    useSystemColor: useSystemColor.value,
                  );
                  NavigationManager.refreshRouter();
                }
              }
              if (context.mounted) {
                showToast(
                  context,
                  result.message,
                  icon: result.success ? null : Icons.error_outline_rounded,
                );
              }
            } catch (e, str) {
              logger.log('Error restoring data', error: e, stackTrace: str);
              if (context.mounted) {
                showToast(
                  context,
                  context.l10n!.error,
                  icon: Icons.error_outline_rounded,
                );
              }
            }
          },
        ),
      ValueListenableBuilder<bool>(
        valueListenable: gameMode,
        builder: (_, value, __) {
          return CustomBar(
            'Game mode',
            Icons.sports_esports_outlined,
            trailing: Switch(
              value: value,
              onChanged: (value) => gameMode.value = value,
            ),
          );
        },
      ),
      if (!offlineMode.value)
        CustomBar(
          context.l10n!.clearCache,
          Icons.cleaning_services_outlined,
          // Songs saved from playing go too; downloads stay. Erased once
          // the Undo bar has gone.
          onTap: () => doWithUndo(
            context,
            'Cache cleared',
            commit: () async {
              await clearCache();
              await clearCachedSongs();
            },
          ),
        ),
      if (!offlineMode.value)
        CustomBar(
          context.l10n!.deleteDownloads,
          Icons.delete_outline_rounded,
          iconColor: Theme.of(context).colorScheme.error,
          textColor: Theme.of(context).colorScheme.error,
          // The files go once the Undo bar has gone.
          onTap: () => doWithUndo(
            context,
            context.l10n!.downloadsDeleted,
            commit: () =>
                offlinePlaylistService.deleteAllDownloads().catchError((_) {}),
          ),
        ),
    ];
  }

  List<Widget> _privacyRows(BuildContext context) {
    return [
      if (analyticsAvailable)
        ValueListenableBuilder<bool>(
          valueListenable: usageStatsOn,
          builder: (_, value, __) => CustomBar(
            'Share anonymous usage stats',
            Icons.insights_outlined,
            description:
                'What gets played and used, to make Muzika better. '
                'No name, no account.',
            trailing: Switch(value: value, onChanged: setUsageStats),
          ),
        ),
      if (!offlineMode.value)
        CustomBar(
          context.l10n!.clearSearchHistory,
          Icons.history_rounded,
          onTap: () {
            final before = searchHistoryNotifier.value;
            searchHistoryNotifier.value = [];
            doWithUndo(
              context,
              'Search history cleared',
              undo: () => searchHistoryNotifier.value = before,
              commit: () async => deleteData('user', 'searchHistory'),
            );
          },
        ),
      if (!offlineMode.value)
        CustomBar(
          context.l10n!.clearRecentlyPlayed,
          Icons.receipt_long_outlined,
          onTap: () {
            final before = userRecentlyPlayed.value;
            userRecentlyPlayed.value = [];
            doWithUndo(
              context,
              'Recently played cleared',
              undo: () => userRecentlyPlayed.value = before,
              commit: () async => deleteData('user', 'recentlyPlayedSongs'),
            );
          },
        ),
      if (!offlineMode.value)
        CustomBar(
          context.l10n!.clearListeningStats,
          Icons.schedule_rounded,
          iconColor: Theme.of(context).colorScheme.error,
          textColor: Theme.of(context).colorScheme.error,
          // Wiped once the Undo bar has gone.
          onTap: () => doWithUndo(
            context,
            'Listening stats cleared',
            commit: () async {
              audioHandler.resetListeningStatsSession(flushStats: false);
              await listeningStatsService.clearStats();
              audioHandler.startListeningStatsSessionIfNeeded();
            },
          ),
        ),
    ];
  }

  List<Widget> _appRows(BuildContext context) {
    return [
      if (!isFdroidBuild)
        ValueListenableBuilder<bool?>(
          valueListenable: shouldWeCheckUpdates,
          builder: (_, value, __) {
            return CustomBar(
              context.l10n!.automaticUpdateChecks,
              Icons.sync_rounded,
              trailing: Switch(
                value: value ?? false,
                onChanged: (value) =>
                    _toggleAutomaticUpdateChecks(context, value),
              ),
            );
          },
        ),

      if (!offlineMode.value && !isFdroidBuild)
        CustomBar(
          context.l10n!.downloadAppUpdate,
          Icons.download_outlined,
          onTap: () => checkAppUpdates(manual: true),
        ),

      CustomBar(
        '${context.l10n!.copyLogs} (${logger.getLogCount()})',
        Icons.error_outline_rounded,
        onTap: () async => showToast(context, await logger.copyLogs(context)),
      ),
      CustomBar(
        context.l10n!.about,
        Icons.info_outline_rounded,
        onTap: () => NavigationManager.router.go('/settings/about'),
      ),
    ];
  }

  void _showThemeModePicker(BuildContext context) {
    final availableModes = [ThemeMode.system, ThemeMode.light, ThemeMode.dark];
    const modeIcons = [
      Icons.smartphone_outlined,
      Icons.light_mode_outlined,
      Icons.dark_mode_outlined,
    ];

    showCustomBottomSheet(
      context,
      ListView.builder(
        shrinkWrap: true,
        physics: const BouncingScrollPhysics(),
        padding: commonListViewBottomPadding,
        itemCount: availableModes.length,
        itemBuilder: (context, index) {
          final mode = availableModes[index];
          final modeNames = [
            context.l10n!.themeModeSystem,
            context.l10n!.themeModeLight,
            context.l10n!.themeModeDark,
          ];

          return BottomSheetBar(
            modeNames[mode.index],
            () {
              addOrUpdateData<int>('settings', 'themeIndex', mode.index);
              Muzika.updateAppState(context, newThemeMode: mode);
              Navigator.pop(context);
            },
            themeMode == mode,
            icon: modeIcons[mode.index],
          );
        },
      ),
    );
  }

  void _showLanguagePicker(BuildContext context) {
    final availableLanguages = appLanguages.toList();
    final activeLanguageCode = Localizations.localeOf(context).languageCode;
    final activeScriptCode = Localizations.localeOf(context).scriptCode;
    final activeLanguageFullCode = activeScriptCode != null
        ? '$activeLanguageCode-$activeScriptCode'
        : activeLanguageCode;

    showCustomBottomSheet(
      context,
      ListView.builder(
        shrinkWrap: true,
        physics: const BouncingScrollPhysics(),
        padding: commonListViewBottomPadding,
        itemCount: availableLanguages.length,
        itemBuilder: (context, index) {
          final language = availableLanguages[index];
          final newLocale = getLocaleFromLanguageCode(language);
          final newLocaleFullCode = newLocale.scriptCode != null
              ? '${newLocale.languageCode}-${newLocale.scriptCode}'
              : newLocale.languageCode;

          return BottomSheetBar(getLanguageDisplayName(context, language), () {
            addOrUpdateData<String>(
              'settings',
              'languageCode',
              newLocaleFullCode,
            );
            Muzika.updateAppState(context, newLocale: newLocale);
            showToast(context, context.l10n!.languageMsg);
            Navigator.pop(context);
          }, activeLanguageFullCode == newLocaleFullCode);
        },
      ),
    );
  }

  /// Auto, On or Off: on, songs stream at medium quality, the Canvas at
  /// 360p, covers smaller, and only the next song is got ready.
  void _showDataSaverPicker(BuildContext context) {
    const modes = [
      ('auto', 'Auto: when the line is slow', Icons.network_check),
      ('on', 'On: always save data', Icons.data_saver_on_outlined),
      ('off', 'Off: best quality', Icons.high_quality_outlined),
    ];
    showCustomBottomSheet(
      context,
      ListView(
        shrinkWrap: true,
        physics: const BouncingScrollPhysics(),
        padding: commonListViewBottomPadding,
        children: [
          for (final (value, name, icon) in modes)
            BottomSheetBar(
              name,
              () {
                setDataSaver(value);
                Navigator.pop(context);
              },
              dataSaverSetting.value == value,
              icon: icon,
            ),
        ],
      ),
    );
  }

  void _showAudioQualityPicker(BuildContext context) {
    final availableQualities = ['low', 'medium', 'high'];
    final qualityNames = [
      context.l10n!.audioQualityLow,
      context.l10n!.audioQualityMedium,
      context.l10n!.audioQualityHigh,
    ];
    const qualityIcons = [
      Icons.volume_down_outlined,
      Icons.volume_up_outlined,
      Icons.volume_up_rounded,
    ];

    showCustomBottomSheet(
      context,
      ListView.builder(
        shrinkWrap: true,
        physics: const BouncingScrollPhysics(),
        padding: commonListViewBottomPadding,
        itemCount: availableQualities.length,
        itemBuilder: (context, index) {
          final quality = availableQualities[index];

          return BottomSheetBar(
            qualityNames[index],
            () {
              addOrUpdateData<String>('settings', 'audioQuality', quality);
              audioQualitySetting.value = quality;
              showToast(context, context.l10n!.audioQualityMsg);
              Navigator.pop(context);
            },
            audioQualitySetting.value == quality,
            icon: qualityIcons[index],
          );
        },
      ),
    );
  }

  void _togglePureBlack(BuildContext context, bool value) {
    addOrUpdateData<bool>('settings', 'usePureBlackColor', value);
    usePureBlackColor.value = value;
    Muzika.updateAppState(context);
    showToast(context, context.l10n!.settingChangedMsg);
  }

  void _toggleAudioQualityBadge(BuildContext context, bool value) {
    addOrUpdateData<bool>('settings', 'showAudioQualityBadge', value);
    showAudioQualityBadge.value = value;
    showToast(context, context.l10n!.settingChangedMsg);
  }

  void _toggleOfflineMode(BuildContext context, bool value) {
    addOrUpdateData<bool>('settings', 'offlineMode', value);
    offlineMode.value = value;

    // Trigger router refresh and notify about the change
    NavigationManager.refreshRouter();

    showToast(context, context.l10n!.settingChangedMsg);
  }

  void _toggleAutomaticUpdateChecks(BuildContext context, bool value) {
    addOrUpdateData<bool>('settings', 'shouldWeCheckUpdates', value);
    shouldWeCheckUpdates.value = value;
    showToast(context, context.l10n!.settingChangedMsg);
  }

  Future<void> _backupUserData(BuildContext context) async {
    try {
      final result = await backupData(context);
      if (context.mounted) {
        showToast(
          context,
          result.message,
          icon: result.success ? null : Icons.error_outline_rounded,
        );
      }
    } catch (e, stackTrace) {
      logger.log('Error backing up data', error: e, stackTrace: stackTrace);
      if (context.mounted) {
        showToast(
          context,
          context.l10n!.error,
          icon: Icons.error_outline_rounded,
        );
      }
    }
  }
}

/// Muzika's own card at the top: the logo, the version, the site. A tap
/// opens About.
class _MuzikaHeader extends StatelessWidget {
  const _MuzikaHeader();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(22),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => NavigationManager.router.go('/settings/about'),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 60,
                height: 60,
                decoration: BoxDecoration(
                  color: const Color(0xFF191919),
                  borderRadius: BorderRadius.circular(16),
                ),
                padding: const EdgeInsets.all(13),
                child: const MuzikaLogo(height: 26, color: Colors.white),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Muzika',
                      style: muzikaHeading(22, color: scheme.onSurface),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Version $appVersion · muzika.pages.dev',
                      style: muzikaBody(13.5, color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              Icon(
                FluentIcons.chevron_right_24_regular,
                color: scheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A group of settings: its name, then its rows together in one rounded
/// card. Left out when none of its rows show.
class _SettingsGroup extends StatelessWidget {
  const _SettingsGroup({required this.title, required this.rows});

  final String title;
  final List<Widget> rows;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(6, 26, 6, 10),
          child: Text(title, style: muzikaHeading(20, color: scheme.onSurface)),
        ),
        Material(
          color: scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(22),
          clipBehavior: Clip.antiAlias,
          child: Column(children: rows),
        ),
      ],
    );
  }
}
