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

import 'package:hive_flutter/hive_flutter.dart';
import 'package:material_ui/material_ui.dart';
import 'package:muzika/services/analytics.dart';
import 'package:muzika/services/router_service.dart';
import 'package:muzika/theme/muzika_tokens.dart';

const _onboardedKey = 'muzikaOnboarded';

bool get needsOnboarding =>
    !(Hive.box('settings').get(_onboardedKey, defaultValue: false) as bool);

/// Opens the onboarding once, over everything, on first launch.
void maybeShowOnboarding(BuildContext context) {
  if (!needsOnboarding) return;
  Navigator.of(context, rootNavigator: true).push(
    PageRouteBuilder<void>(
      pageBuilder: (_, _, _) => const OnboardingPage(),
      transitionsBuilder: (_, animation, _, child) =>
          FadeTransition(opacity: animation, child: child),
    ),
  );
}

/// Three plain-text steps, played like a story: progress bars on top, tap the
/// right side for next and the left side for back, auto-advance every 5s.
/// Going past the last step (tap or timeout) opens the app.
class OnboardingPage extends StatefulWidget {
  const OnboardingPage({super.key});

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage>
    with SingleTickerProviderStateMixin {
  static const _steps = [
    ('Music, without\nthe wait.', 'Muzika plays YouTube Music in Ethiopia.'),
    (
      'Built-in\nconnection.',
      'A tunnel is included, so songs load without a VPN.',
    ),
    (
      'Lyrics that\nfollow along.',
      'Synced lyrics, queue and radio — all free.',
    ),
    // The last: bring your music over (it waits for an answer).
    (
      'Coming from\nSpotify?',
      'Paste a playlist link and your songs come with you.',
    ),
  ];

  bool get _onLast => _step == _steps.length - 1;

  late final AnimationController _progress = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 5),
  )..addStatusListener(_onTick);

  int _step = 0;

  @override
  void initState() {
    super.initState();
    _progress.forward();
  }

  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }

  void _onTick(AnimationStatus status) {
    if (status == AnimationStatus.completed && !_onLast) _go(_step + 1);
  }

  void _go(int step) {
    if (step >= _steps.length) {
      unawaited(_finish()); // tapping past the last story starts the app
      return;
    }
    if (step < 0) return;
    setState(() => _step = step);
    _progress.forward(from: 0);
  }

  bool _finished = false;

  Future<void> _finish({bool import = false}) async {
    if (_finished) return; // Skip, a tap and the timer can all end it
    _finished = true;
    _progress.stop();
    track('onboarding_done', {'import': import});
    await Hive.box('settings').put(_onboardedKey, true);
    if (mounted) Navigator.of(context).pop();
    // "Import my playlists": straight to the import, link box first.
    if (import) {
      unawaited(
        NavigationManager.router.push('/settings/import-spotify-playlist'),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (title, body) = _steps[_step];
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: scheme.surface,
        body: SafeArea(
          child: Stack(
            children: [
              Row(
                children: [
                  Expanded(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => _go(_step - 1),
                    ),
                  ),
                  Expanded(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => _onLast ? null : _go(_step + 1),
                    ),
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: AnimatedBuilder(
                  animation: _progress,
                  builder: (context, _) => Row(
                    spacing: 6,
                    children: [
                      for (var i = 0; i < _steps.length; i++)
                        Expanded(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(2),
                            child: LinearProgressIndicator(
                              minHeight: 3,
                              value: i < _step
                                  ? 1
                                  : i == _step
                                  ? _progress.value
                                  : 0,
                              color: scheme.onSurface,
                              backgroundColor: scheme.surfaceContainerHighest,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              Positioned(
                top: 28,
                right: 8,
                child: TextButton(
                  onPressed: _finish,
                  child: Text(
                    'Skip',
                    style: muzikaBody(14, color: scheme.onSurfaceVariant),
                  ),
                ),
              ),
              IgnorePointer(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 28),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 250),
                        switchOutCurve: const Interval(0, 0.4),
                        // Old and new text share the same left edge.
                        layoutBuilder: (current, previous) => Stack(
                          alignment: Alignment.centerLeft,
                          children: [...previous, ?current],
                        ),
                        child: Column(
                          key: ValueKey(_step),
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              style: muzikaHeading(
                                40,
                                color: scheme.onSurface,
                              ).copyWith(height: 1.1),
                            ),
                            const SizedBox(height: 16),
                            Text(
                              body,
                              style: muzikaBody(
                                17,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              // The last step's answer.
              if (_onLast)
                Positioned(
                  left: 28,
                  right: 28,
                  bottom: 36,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      FilledButton.icon(
                        style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(52),
                        ),
                        onPressed: () => _finish(import: true),
                        icon: const Icon(Icons.playlist_add_rounded),
                        label: const Text('Import my playlists'),
                      ),
                      const SizedBox(height: 8),
                      TextButton(
                        onPressed: _finish,
                        child: const Text('Not now'),
                      ),
                      if (analyticsAvailable)
                        Text(
                          'Muzika shares anonymous usage stats to get '
                          'better. Turn it off any time in Settings.',
                          textAlign: TextAlign.center,
                          style: muzikaBody(12, color: scheme.onSurfaceVariant),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
