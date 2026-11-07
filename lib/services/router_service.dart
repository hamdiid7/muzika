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

import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/foundation.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:muzika/constants/version.dart';
import 'package:muzika/screens/about_page.dart';
import 'package:muzika/screens/artist_page.dart';
import 'package:muzika/screens/artist_songs_page.dart';
import 'package:muzika/services/deezer_catalog.dart' show deezerArtistPrefix;
import 'package:muzika/screens/bottom_navigation_page.dart';
import 'package:muzika/screens/discover_page.dart';
import 'package:muzika/screens/equalizer_page.dart';
import 'package:muzika/screens/home_page.dart';
import 'package:muzika/screens/import_spotify_playlist_page.dart';
import 'package:muzika/screens/library_page.dart';
import 'package:muzika/screens/playlist_folder_page.dart';
import 'package:muzika/screens/playlist_page.dart';
import 'package:muzika/screens/radio_stations_page.dart';
import 'package:muzika/screens/search_page.dart';
import 'package:muzika/screens/settings_page.dart';
import 'package:muzika/screens/time_machine_page.dart';
import 'package:muzika/screens/user_songs_page.dart';
import 'package:muzika/services/playlist_download_service.dart';
import 'package:muzika/services/settings_manager.dart';
import 'package:muzika/widgets/offline_search_placeholder.dart';

class NavigationManager {
  factory NavigationManager() {
    return _instance;
  }

  NavigationManager._internal() {
    _setupRouter();
  }

  void _setupRouter() {
    final routes = [
      StatefulShellRoute(
        parentNavigatorKey: parentNavigatorKey,
        branches: _getRouteBranches(),
        navigatorContainerBuilder: (context, shell, children) =>
            _FadingBranchContainer(
              currentIndex: shell.currentIndex,
              children: children,
            ),
        pageBuilder: (context, state, navigationShell) {
          return getPage(
            child: BottomNavigationPage(child: navigationShell),
            state: state,
          );
        },
      ),
    ];

    router = GoRouter(
      navigatorKey: parentNavigatorKey,
      initialLocation: homePath,
      routes: routes,
      restorationScopeId: 'router',
      debugLogDiagnostics: kDebugMode,
      routerNeglect: true,
      redirect: (context, state) {
        // Handle offline mode redirects
        final isOffline = offlineMode.value;
        final currentPath = state.matchedLocation;

        if (isOffline &&
            (currentPath == searchPath || currentPath == timeMachinePath)) {
          // Redirect unavailable pages to home in offline mode
          return homePath;
        }

        if (isOffline && currentPath.contains('/album/')) {
          // Releases are only browsable through YouTube Music.
          return homePath;
        }

        if (isOffline && currentPath.contains('/artist/')) {
          final artistId = state.pathParameters['artistId'] ?? '';
          if (!offlinePlaylistService.isPlaylistDownloaded(artistId)) {
            return homePath;
          }
        }

        return null; // No redirect needed
      },
    );
  }

  static final NavigationManager _instance = NavigationManager._internal();

  static NavigationManager get instance => _instance;

  static late final GoRouter router;

  static final GlobalKey<NavigatorState> parentNavigatorKey =
      GlobalKey<NavigatorState>();
  static final GlobalKey<NavigatorState> homeTabNavigatorKey =
      GlobalKey<NavigatorState>();
  static final GlobalKey<NavigatorState> searchTabNavigatorKey =
      GlobalKey<NavigatorState>();
  static final GlobalKey<NavigatorState> discoverTabNavigatorKey =
      GlobalKey<NavigatorState>();
  static final GlobalKey<NavigatorState> libraryTabNavigatorKey =
      GlobalKey<NavigatorState>();
  static final GlobalKey<NavigatorState> offlineTabNavigatorKey =
      GlobalKey<NavigatorState>();
  static final GlobalKey<NavigatorState> settingsTabNavigatorKey =
      GlobalKey<NavigatorState>();

  BuildContext get context {
    final ctx = router.routerDelegate.navigatorKey.currentContext;
    if (ctx == null) {
      throw StateError(
        'NavigationManager.context was accessed before the navigator context was available.',
      );
    }
    return ctx;
  }

  GoRouterDelegate get routerDelegate => router.routerDelegate;

  GoRouteInformationParser get routeInformationParser =>
      router.routeInformationParser;

  static const String homePath = '/home';
  static const String timeMachinePath = '$homePath/timeMachine';
  static const String settingsPath = '/settings';
  static const String searchPath = '/search';
  static const String libraryPath = '/library';
  static const String discoverPath = '/discover';
  static const String offlinePath = '/offline';

  /// Refresh the router configuration when offline mode changes
  static void refreshRouter() {
    // Force router to re-evaluate redirect logic
    router.refresh();
  }

  List<StatefulShellBranch> _getRouteBranches() {
    // Always return all branches, but handle visibility in the UI
    return [
      // Branch 0: Home
      StatefulShellBranch(
        navigatorKey: homeTabNavigatorKey,
        routes: [
          GoRoute(
            path: homePath,
            pageBuilder: (context, GoRouterState state) {
              return getPage(
                child: ValueListenableBuilder<bool>(
                  valueListenable: offlineMode,
                  builder: (context, isOffline, _) {
                    return isOffline
                        ? const UserSongsPage(page: 'offline')
                        : const HomePage();
                  },
                ),
                state: state,
              );
            },
            routes: [
              GoRoute(
                path: 'timeMachine',
                pageBuilder: (context, state) =>
                    _pushPage(child: const TimeMachinePage(), state: state),
              ),
              GoRoute(
                path: 'library',
                pageBuilder: (context, state) =>
                    _pushPage(child: const LibraryPage(), state: state),
              ),
              GoRoute(
                path: 'userSongs/:page',
                pageBuilder: (context, state) => _pushPage(
                  child: UserSongsPage(
                    page: state.pathParameters['page'] ?? 'liked',
                  ),
                  state: state,
                ),
              ),
              GoRoute(
                path: 'playlist/:playlistId',
                pageBuilder: (context, state) => _pushPage(
                  child: PlaylistPage(
                    playlistId: state.pathParameters['playlistId'],
                  ),
                  state: state,
                ),
              ),
              _artistRoute(),
              _albumRoute(),
              GoRoute(
                path: 'folder/:folderId/:folderName',
                pageBuilder: (context, state) => _pushPage(
                  child: PlaylistFolderPage(
                    folderId: state.pathParameters['folderId'] ?? '',
                    folderName: state.pathParameters['folderName'] ?? '',
                  ),
                  state: state,
                ),
              ),
            ],
          ),
        ],
      ),
      // Branch 1: Search
      StatefulShellBranch(
        navigatorKey: searchTabNavigatorKey,
        routes: [
          GoRoute(
            path: searchPath,
            pageBuilder: (context, GoRouterState state) {
              return getPage(
                child: ValueListenableBuilder<bool>(
                  valueListenable: offlineMode,
                  builder: (context, isOffline, _) {
                    return isOffline
                        ? const OfflineSearchPlaceholder()
                        : const SearchPage();
                  },
                ),
                state: state,
              );
            },
            routes: [_artistRoute(), _albumRoute()],
          ),
        ],
      ),
      // Branch 2: Library
      StatefulShellBranch(
        navigatorKey: discoverTabNavigatorKey,
        routes: [
          GoRoute(
            path: discoverPath,
            pageBuilder: (context, state) =>
                getPage(child: const DiscoverPage(), state: state),
            routes: [_artistRoute(), _albumRoute()],
          ),
        ],
      ),
      StatefulShellBranch(
        navigatorKey: libraryTabNavigatorKey,
        routes: [
          GoRoute(
            path: libraryPath,
            pageBuilder: (context, GoRouterState state) {
              return getPage(child: const LibraryPage(), state: state);
            },
            routes: [
              GoRoute(
                path: 'userSongs/:page',
                pageBuilder: (context, state) => _pushPage(
                  child: UserSongsPage(
                    page: state.pathParameters['page'] ?? 'liked',
                  ),
                  state: state,
                ),
              ),
              _artistRoute(),
              _albumRoute(),
              GoRoute(
                path: 'radioStations',
                pageBuilder: (context, state) =>
                    _pushPage(child: const RadioStationsPage(), state: state),
              ),
            ],
          ),
        ],
      ),
      // Branch 3: Settings
      // Muzika: Offline is a tab of its own, so the Library tab never
      // remembers it as its last page.
      StatefulShellBranch(
        navigatorKey: offlineTabNavigatorKey,
        routes: [
          GoRoute(
            path: offlinePath,
            pageBuilder: (context, state) => getPage(
              child: const UserSongsPage(page: 'offline'),
              state: state,
            ),
            routes: [
              _artistRoute(),
              _albumRoute(),
              GoRoute(
                path: 'playlist/:playlistId',
                pageBuilder: (context, state) => _pushPage(
                  child: PlaylistPage(
                    playlistId: state.pathParameters['playlistId'],
                  ),
                  state: state,
                ),
              ),
            ],
          ),
        ],
      ),
      StatefulShellBranch(
        navigatorKey: settingsTabNavigatorKey,
        routes: [
          GoRoute(
            path: settingsPath,
            pageBuilder: (context, state) {
              return getPage(child: const SettingsPage(), state: state);
            },
            routes: [
              GoRoute(
                path: 'license',
                pageBuilder: (context, state) => _pushPage(
                  child: const LicensePage(
                    applicationName: 'Muzika',
                    applicationVersion: appVersion,
                  ),
                  state: state,
                ),
              ),
              GoRoute(
                path: 'about',
                pageBuilder: (context, state) =>
                    _pushPage(child: const AboutPage(), state: state),
              ),
              GoRoute(
                path: 'equalizer',
                pageBuilder: (context, state) =>
                    _pushPage(child: const EqualizerPage(), state: state),
              ),
              GoRoute(
                path: 'import-spotify-playlist',
                pageBuilder: (context, state) => _pushPage(
                  child: const ImportSpotifyPlaylistPage(),
                  state: state,
                ),
              ),
            ],
          ),
        ],
      ),
    ];
  }

  /// The artist landing page, plus the full song catalog of the artist.
  GoRoute _artistRoute() {
    return GoRoute(
      path: 'artist/:artistId',
      pageBuilder: (context, state) => _pushPage(
        child: ArtistPage(
          artistId: state.pathParameters['artistId'] ?? '',
          artistData: _extraAsMap(state.extra),
        ),
        state: state,
      ),
      routes: [
        GoRoute(
          path: 'songs',
          pageBuilder: (context, state) {
            final artistId = state.pathParameters['artistId'] ?? '';
            final data = _extraAsMap(state.extra);
            // A Deezer artist's songs come ten at a time, most played
            // first, instead of after every album has been read.
            if (artistId.startsWith(deezerArtistPrefix) &&
                state.uri.queryParameters['search'] != '1') {
              return _pushPage(
                child: ArtistSongsPage(
                  artistId: artistId,
                  name: '${data?['title'] ?? ''}',
                ),
                state: state,
              );
            }
            return _pushPage(
              child: PlaylistPage(
                playlistId: artistId,
                playlistData: data,
                cubeIcon: FluentIcons.person_24_filled,
                isArtist: true,
                startSearching: state.uri.queryParameters['search'] == '1',
              ),
              state: state,
            );
          },
        ),
      ],
    );
  }

  /// A release opened from an artist page. YouTube Music browses a release the
  /// way it browses a playlist, so the playlist page shows it as it is.
  GoRoute _albumRoute() {
    return GoRoute(
      path: 'album/:albumId',
      pageBuilder: (context, state) => _pushPage(
        child: PlaylistPage(
          playlistId: state.pathParameters['albumId'] ?? '',
          playlistData: _extraAsMap(state.extra),
          cubeIcon: FluentIcons.cd_16_regular,
        ),
        state: state,
      ),
    );
  }

  /// Path of the page of an artist, inside the tab [context] belongs to.
  static String artistPath(BuildContext context, String artistId) =>
      '${basePathFor(context)}/artist/${Uri.encodeComponent(artistId)}';

  /// Path of the songs of an artist, i.e. of its "All songs" playlist.
  static String artistSongsPath(BuildContext context, String artistId) =>
      '${artistPath(context, artistId)}/songs';

  /// Path of the page of a YouTube Music release.
  static String albumPath(BuildContext context, String albumId) =>
      '${basePathFor(context)}/album/${Uri.encodeComponent(albumId)}';

  /// The tab a sub page pushed from [context] belongs to, so that artists,
  /// albums and playlists stay inside the tab they were opened from.
  static String basePathOf(String currentPath) {
    for (final tab in [searchPath, discoverPath, libraryPath, offlinePath]) {
      if (currentPath.startsWith(tab)) return tab;
    }
    return homePath;
  }

  /// The tab the app is showing now, for pages opened from the full player.
  static String get currentBasePath => basePathOf(topLocation);

  /// Where the screen on top is, pushed pages included.
  static String get topLocation {
    try {
      return router.state.matchedLocation;
    } catch (_) {
      return router.routerDelegate.currentConfiguration.uri.path;
    }
  }

  static String basePathFor(BuildContext context) {
    try {
      return basePathOf(GoRouterState.of(context).uri.path);
    } catch (_) {}

    return homePath;
  }

  static Map? _extraAsMap(Object? extra) {
    if (extra is Map) return Map<String, dynamic>.from(extra);
    return null;
  }

  static Page<void> getPage({
    required Widget child,
    required GoRouterState state,
  }) {
    return CustomTransitionPage<void>(
      key: state.pageKey,
      child: child,
      transitionDuration: const Duration(milliseconds: 180),
      reverseTransitionDuration: const Duration(milliseconds: 150),
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        return FadeTransition(
          opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
          child: child,
        );
      },
    );
  }

  static Page<void> _pushPage({
    required Widget child,
    required GoRouterState state,
  }) {
    return CustomTransitionPage<void>(
      key: state.pageKey,
      child: child,
      transitionDuration: const Duration(milliseconds: 220),
      reverseTransitionDuration: const Duration(milliseconds: 180),
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        final curvedAnimation = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        return FadeTransition(
          opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0.06, 0),
              end: Offset.zero,
            ).animate(curvedAnimation),
            child: child,
          ),
        );
      },
    );
  }
}

/// Tab screens stay alive (like an IndexedStack) but cross-fade when the
/// bottom bar switches between them.
class _FadingBranchContainer extends StatelessWidget {
  const _FadingBranchContainer({
    required this.currentIndex,
    required this.children,
  });

  final int currentIndex;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        for (final (i, child) in children.indexed)
          IgnorePointer(
            ignoring: i != currentIndex,
            child: ExcludeSemantics(
              excluding: i != currentIndex,
              // The fade sits outside TickerMode: muting the outgoing tab
              // first froze its fade-out, leaving it drawn over the new tab.
              child: AnimatedOpacity(
                opacity: i == currentIndex ? 1 : 0,
                duration: const Duration(milliseconds: 120),
                curve: Curves.easeOut,
                child: TickerMode(enabled: i == currentIndex, child: child),
              ),
            ),
          ),
      ],
    );
  }
}
