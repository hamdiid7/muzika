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

import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:muzika/screens/search_page.dart'
    show catchEarlySearchKeys, pendingSearchQuery;
import 'package:muzika/main.dart';
import 'package:muzika/services/desktop_panels.dart';
import 'package:muzika/services/router_service.dart';
import 'package:muzika/services/settings_manager.dart';
import 'package:muzika/widgets/desktop_layout.dart';
import 'package:muzika/widgets/mini_player.dart';
import 'package:muzika/widgets/muzika_nav_bar.dart';
import 'package:muzika/widgets/muzika_sheet_scaffold.dart';

class BottomNavigationPage extends StatefulWidget {
  const BottomNavigationPage({required this.child, super.key});

  final StatefulNavigationShell child;

  /// Snack bars from tab screens show right above the mini player.
  static final shellMessengerKey = GlobalKey<ScaffoldMessengerState>();

  static _BottomNavigationPageState? _current;

  /// What the system back button does on a tab: the tab you came from.
  static void back() => _current?._back();

  @override
  State<BottomNavigationPage> createState() => _BottomNavigationPageState();
}

class _BottomNavigationPageState extends State<BottomNavigationPage> {
  late final _miniPlayerVisibilityStream = audioHandler.mediaItem
      .map((mediaItem) => mediaItem != null)
      .distinct();

  bool? _previousOfflineMode;

  /// Tabs visited before the current one, most recent last, so back walks
  /// Library → Search → Home the way you came.
  final _history = <int>[];
  bool _goingBack = false;

  @override
  void initState() {
    super.initState();
    BottomNavigationPage._current = this;
  }

  @override
  void dispose() {
    if (BottomNavigationPage._current == this) {
      BottomNavigationPage._current = null;
    }
    super.dispose();
  }

  @override
  void didUpdateWidget(BottomNavigationPage old) {
    super.didUpdateWidget(old);
    final from = old.child.currentIndex;
    final to = widget.child.currentIndex;
    if (from != to) {
      if (!_goingBack) {
        _history
          ..remove(from)
          ..add(from);
        if (_history.length > 8) _history.removeAt(0);
      }
      _history.remove(to);
    }
    _goingBack = false;
  }

  void _back() {
    // Sheet screens slide away first.
    if (MuzikaSheetScaffold.dismissVisible()) return;
    final current = widget.child.currentIndex;
    if (_history.isNotEmpty) {
      _goingBack = true;
      widget.child.goBranch(_history.removeLast());
    } else if (current != 0) {
      _goingBack = true;
      widget.child.goBranch(0);
    } else {
      unawaited(SystemNavigator.pop());
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: ValueListenableBuilder<bool>(
        valueListenable: offlineMode,
        builder: (context, isOfflineMode, _) {
          if (_previousOfflineMode != null &&
              _previousOfflineMode != isOfflineMode) {
            SchedulerBinding.instance.addPostFrameCallback((_) {
              _handleOfflineModeChange(isOfflineMode);
            });
          }
          _previousOfflineMode = isOfflineMode;

          // Muzika: the bar shows on the five tab screens only; inner
          // screens (artist, album, playlist) keep the whole height and show
          // the playing song at the top instead of the mini player.
          // Muzika: the mini player and the tab bar sit in the scaffold's
          // bottom bar, so every snack bar shows just above them.
          return StreamBuilder<bool>(
            initialData: audioHandler.mediaItem.value != null,
            stream: _miniPlayerVisibilityStream,
            builder: (context, snapshot) {
              return ListenableBuilder(
                listenable: NavigationManager.router.routerDelegate,
                builder: (context, _) {
                  // The top route's own location: after a push the URI still
                  // names the tab underneath.
                  final path = NavigationManager.topLocation;
                  final root = _tabRootAt(path);
                  // The bar shows everywhere, lighting the section the page
                  // belongs to (none for Settings, which left the bar).
                  final tab = _tabOfBranch(widget.child.currentIndex);
                  // Discover plays its own cards full screen.
                  final showMini =
                      (snapshot.data ?? false) && root != MuzikaTab.discover;
                  // A wide Windows window: tabs on the left, the player and
                  // lyrics on the right, no bottom bar or mini player.
                  final wide = useDesktopLayout(
                    MediaQuery.sizeOf(context).width,
                  );
                  if (wide != desktopPanels.value) {
                    SchedulerBinding.instance.addPostFrameCallback((_) {
                      desktopPanels.value = wide;
                    });
                  }
                  if (wide) {
                    return ScaffoldMessenger(
                      key: BottomNavigationPage.shellMessengerKey,
                      child: Scaffold(
                        body: DesktopShell(
                          current: tab,
                          showSearch: !isOfflineMode,
                          onSelect: (t) => _select(t, tab),
                          child: widget.child,
                        ),
                      ),
                    );
                  }
                  return ScaffoldMessenger(
                    key: BottomNavigationPage.shellMessengerKey,
                    child: Scaffold(
                      body: widget.child,
                      bottomNavigationBar: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (showMini) ...[
                            const MiniPlayer(),
                            const SizedBox(height: 6),
                          ],
                          MuzikaNavBar(
                            current: tab,
                            showSearch: !isOfflineMode,
                            // Its own tab from an inner page goes back to the
                            // section's first screen.
                            onSelect: (t) => _select(t, tab),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              );
            },
          );
        },
      ),
    );
  }

  /// The tab whose root screen [path] is, or null on an inner screen.
  MuzikaTab? _tabRootAt(String path) => switch (path) {
    NavigationManager.homePath => MuzikaTab.home,
    NavigationManager.searchPath => MuzikaTab.search,
    NavigationManager.discoverPath => MuzikaTab.discover,
    NavigationManager.libraryPath => MuzikaTab.library,
    NavigationManager.offlinePath => MuzikaTab.offline,
    _ => null,
  };

  MuzikaTab? _tabOfBranch(int index) => switch (index) {
    0 => MuzikaTab.home,
    1 => MuzikaTab.search,
    2 => MuzikaTab.discover,
    3 => MuzikaTab.library,
    4 => MuzikaTab.offline,
    _ => null,
  };

  void _select(MuzikaTab tab, MuzikaTab? current) {
    final shell = widget.child;
    switch (tab) {
      case MuzikaTab.home:
        shell.goBranch(0, initialLocation: current == MuzikaTab.home);
      case MuzikaTab.search:
        shell.goBranch(1, initialLocation: current == MuzikaTab.search);
        // Straight to typing, every time; keys typed meanwhile kept.
        catchEarlySearchKeys();
        pendingSearchQuery.value = '';
      case MuzikaTab.discover:
        shell.goBranch(2, initialLocation: current == MuzikaTab.discover);
      case MuzikaTab.library:
        shell.goBranch(3, initialLocation: current == MuzikaTab.library);
      case MuzikaTab.offline:
        shell.goBranch(4, initialLocation: current == MuzikaTab.offline);
      case MuzikaTab.settings:
        shell.goBranch(5, initialLocation: current == MuzikaTab.settings);
    }
  }

  void _handleOfflineModeChange(bool isOfflineMode) {
    if (!mounted) return;

    final currentRoute = GoRouterState.of(context).matchedLocation;

    // If we're switching to offline mode and currently on search tab
    if (isOfflineMode && currentRoute.startsWith('/search')) {
      // Navigate to home
      widget.child.goBranch(0);
    }
  }
}
