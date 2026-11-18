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
import 'package:muzika/utilities/undo.dart';
import 'package:muzika/theme/muzika_tokens.dart';
import 'package:muzika/constants/version.dart';
import 'package:muzika/services/analytics.dart';
import 'package:muzika/extensions/l10n.dart';
import 'package:muzika/main.dart';
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
import 'package:muzika/utilities/flutter_toast.dart';
import 'package:muzika/utilities/language_utils.dart';
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
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              // The same header as Library: the page's name, big.
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                child: Text(
                  context.l10n!.settings,
                  style: muzikaHeading(29, color: scheme.onSurface),
                ),
              ),
              _SettingsGroup(title: 'Playback', rows: _playbackRows(context)),
              _SettingsGroup(
                title: 'Data and offline',
                rows: _dataRows(context),
              ),
              _SettingsGroup(
                title: 'Appearance',
                rows: _appearanceRows(context),
              ),
              _SettingsGroup(title: 'Library', rows: _libraryRows(context)),
              _SettingsGroup(title: 'Storage', rows: _storageRows(context)),
              _SettingsGroup(title: 'Privacy', rows: _privacyRows(context)),
              _SettingsGroup(title: 'About', rows: _aboutRows(context)),
              const SizedBox(height: 20),
              const MiniPlayerBottomSpace(),
            ],
          ),
        ),
      ),
    );
  }

  /// Every "pick one" setting opens the same sheet: its name on top, the
  /// choices underneath, the current one marked.
  void _pick<T>(
    BuildContext context, {
    required String title,
    required List<(T, String)> options,
    required T current,
    required void Function(T value) onSelected,
  }) {
    final scheme = Theme.of(context).colorScheme;
    showMuzikaMenu<T>(
      context,
      title: title,
      items: [
        for (final (value, label) in options)
          buildPopupMenuItem<T>(
            value: value,
            icon: value == current
                ? Icons.radio_button_checked_rounded
                : Icons.radio_button_unchecked_rounded,
            label: label,
            colorScheme: scheme,
          ),
      ],
      onSelected: onSelected,
    );
  }

  List<Widget> _playbackRows(BuildContext context) {
    final l10n = context.l10n!;
    final qualityNames = {
      'low': l10n.audioQualityLow,
      'medium': l10n.audioQualityMedium,
      'high': l10n.audioQualityHigh,
    };
    return [
      ValueListenableBuilder<String>(
        valueListenable: audioQualitySetting,
        builder: (context, quality, _) => CustomBar(
          l10n.audioQuality,
          Icons.graphic_eq_rounded,
          value: qualityNames[quality],
          onTap: () => _pick<String>(
            context,
            title: l10n.audioQuality,
            options: [
              for (final entry in qualityNames.entries)
                (entry.key, entry.value),
            ],
            current: quality,
            onSelected: (picked) {
              addOrUpdateData<String>('settings', 'audioQuality', picked);
              audioQualitySetting.value = picked;
            },
          ),
        ),
      ),
      // Songs fade in and out.
      ValueListenableBuilder<int>(
        valueListenable: songFadeSeconds,
        builder: (context, fade, _) => CustomBar(
          'Fade songs',
          Icons.blur_linear_rounded,
          value: fade <= 0 ? 'Off' : '$fade seconds',
          onTap: () => _pick<int>(
            context,
            title: 'Fade songs in and out',
            options: [
              for (final n in const [0, 2, 4, 6, 8])
                (n, n == 0 ? 'Off' : '$n seconds'),
            ],
            current: fade,
            onSelected: (n) {
              songFadeSeconds.value = n;
              addOrUpdateData<int>('settings', 'songFadeSeconds', n);
            },
          ),
        ),
      ),
      if (Platform.isAndroid)
        CustomBar(
          l10n.equalizer,
          Icons.equalizer_rounded,
          chevron: true,
          onTap: () => context.push('/settings/equalizer'),
        ),
      ValueListenableBuilder<bool>(
        valueListenable: canvasEnabled,
        builder: (_, value, __) {
          return CustomBar(
            'Canvas video',
            Icons.movie_outlined,
            description: 'A looping video behind the player',
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
    ];
  }

  List<Widget> _dataRows(BuildContext context) {
    return [
      // Auto: on while the line measures slow.
      AnimatedBuilder(
        animation: Listenable.merge([dataSaverSetting, lineSpeed]),
        builder: (context, _) {
          final speed = lineSpeed.value;
          final mode = switch (dataSaverSetting.value) {
            'on' => 'On',
            'off' => 'Off',
            _ => 'Auto · ${dataSaverOn ? 'on' : 'off'} now',
          };
          return CustomBar(
            'Data saver',
            Icons.data_saver_on_outlined,
            description: speed == null
                ? null
                : 'Your line: ${speed.round()} KB/s',
            value: mode,
            onTap: () => _pick<String>(
              context,
              title: 'Data saver',
              options: const [
                ('auto', 'Auto: when the line is slow'),
                ('on', 'On: always save data'),
                ('off', 'Off: best quality'),
              ],
              current: switch (dataSaverSetting.value) {
                'on' => 'on',
                'off' => 'off',
                _ => 'auto',
              },
              onSelected: setDataSaver,
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
              ? 'Played songs are not saved'
              : 'Played songs kept for offline listening',
          value: limit <= 0 ? 'Off' : 'Last $limit',
          onTap: () => _pick<int>(
            context,
            title: 'Cached songs',
            options: [
              for (final n in const [0, 50, 100, 200, 500, 1000])
                (n, n == 0 ? 'Off' : '$n songs'),
            ],
            current: limit,
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
            trailing: Switch(value: value, onChanged: _toggleOfflineMode),
          );
        },
      ),
      const TunnelTile(),
    ];
  }

  List<Widget> _appearanceRows(BuildContext context) {
    final l10n = context.l10n!;
    final modeNames = {
      ThemeMode.system: l10n.themeModeSystem,
      ThemeMode.light: l10n.themeModeLight,
      ThemeMode.dark: l10n.themeModeDark,
    };
    final locale = Localizations.localeOf(context);
    final activeLanguage = locale.scriptCode != null
        ? '${locale.languageCode}-${locale.scriptCode}'
        : locale.languageCode;
    return [
      CustomBar(
        l10n.themeMode,
        Icons.contrast_rounded,
        value: modeNames[themeMode],
        onTap: () => _pick<ThemeMode>(
          context,
          title: l10n.themeMode,
          options: [
            for (final entry in modeNames.entries) (entry.key, entry.value),
          ],
          current: themeMode,
          onSelected: (mode) {
            addOrUpdateData<int>('settings', 'themeIndex', mode.index);
            Muzika.updateAppState(context, newThemeMode: mode);
          },
        ),
      ),
      if (themeMode == ThemeMode.dark)
        CustomBar(
          l10n.pureBlackTheme,
          Icons.dark_mode_outlined,
          trailing: Switch(
            value: usePureBlackColor.value,
            onChanged: (value) => _togglePureBlack(context, value),
          ),
        ),
      CustomBar(
        l10n.language,
        Icons.language_rounded,
        value: appLanguages.contains(activeLanguage)
            ? getLanguageDisplayName(context, activeLanguage)
            : null,
        onTap: () => _pick<String>(
          context,
          title: l10n.language,
          options: [
            for (final language in appLanguages)
              (language, getLanguageDisplayName(context, language)),
          ],
          current: activeLanguage,
          onSelected: (language) {
            final newLocale = getLocaleFromLanguageCode(language);
            addOrUpdateData<String>(
              'settings',
              'languageCode',
              newLocale.scriptCode != null
                  ? '${newLocale.languageCode}-${newLocale.scriptCode}'
                  : newLocale.languageCode,
            );
            Muzika.updateAppState(context, newLocale: newLocale);
          },
        ),
      ),
      ValueListenableBuilder<bool>(
        valueListenable: showAudioQualityBadge,
        builder: (_, value, __) {
          return CustomBar(
            l10n.audioQualityBadge,
            Icons.high_quality_outlined,
            trailing: Switch(value: value, onChanged: _toggleAudioQualityBadge),
          );
        },
      ),
    ];
  }

  List<Widget> _libraryRows(BuildContext context) {
    return [
      CustomBar(
        context.l10n!.importSpotifyPlaylist,
        Icons.upload_outlined,
        chevron: true,
        onTap: () => context.push('/settings/import-spotify-playlist'),
      ),
      CustomBar(
        context.l10n!.backupUserData,
        Icons.cloud_sync_outlined,
        onTap: () => _backupUserData(context),
      ),
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
    ];
  }

  List<Widget> _storageRows(BuildContext context) {
    return [
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

  List<Widget> _aboutRows(BuildContext context) {
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
                onChanged: _toggleAutomaticUpdateChecks,
              ),
            );
          },
        ),

      if (!isFdroidBuild)
        CustomBar(
          context.l10n!.downloadAppUpdate,
          Icons.download_outlined,
          onTap: () => checkAppUpdates(manual: true),
        ),

      CustomBar(
        context.l10n!.copyLogs,
        Icons.bug_report_outlined,
        value: '${logger.getLogCount()}',
        onTap: () async => showToast(context, await logger.copyLogs(context)),
      ),
      CustomBar(
        context.l10n!.about,
        Icons.info_outline_rounded,
        value: appVersion,
        chevron: true,
        onTap: () => NavigationManager.router.go('/settings/about'),
      ),
    ];
  }

  // A switch already shows what it is set to, so these say nothing more.
  void _togglePureBlack(BuildContext context, bool value) {
    addOrUpdateData<bool>('settings', 'usePureBlackColor', value);
    usePureBlackColor.value = value;
    Muzika.updateAppState(context);
  }

  void _toggleAudioQualityBadge(bool value) {
    addOrUpdateData<bool>('settings', 'showAudioQualityBadge', value);
    showAudioQualityBadge.value = value;
  }

  void _toggleOfflineMode(bool value) {
    addOrUpdateData<bool>('settings', 'offlineMode', value);
    offlineMode.value = value;

    // Trigger router refresh and notify about the change
    NavigationManager.refreshRouter();
  }

  void _toggleAutomaticUpdateChecks(bool value) {
    addOrUpdateData<bool>('settings', 'shouldWeCheckUpdates', value);
    shouldWeCheckUpdates.value = value;
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

/// A group of settings: a section title like Home's ("Made for you"),
/// then its rows, full width like song rows. Left out when none of its
/// rows show.
class _SettingsGroup extends StatelessWidget {
  const _SettingsGroup({required this.title, required this.rows});

  final String title;
  final List<Widget> rows;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 6),
          child: Text(
            title,
            style: muzikaHeading(
              24,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
        ),
        ...rows,
      ],
    );
  }
}
