/*
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

import 'package:material_ui/material_ui.dart';
import 'package:muzika/services/data_manager.dart';
import 'package:muzika/services/router_service.dart';
import 'package:muzika/services/settings_manager.dart';

/// True while the internet can't be reached: two checks in a row failed.
final connectionLost = ValueNotifier<bool>(false);

/// Offline mode was switched on by the "No connection" pop-up, so it
/// switches itself off again once the connection is back.
bool _offlineByWatch = false;

Timer? _timer;
int _failures = 0;

/// Starts watching the connection: a tiny request (a couple of hundred
/// bytes) every half minute, every 15 seconds while it's down.
void startConnectionWatch() {
  if (_timer != null) return;
  unawaited(_check());
  _schedule();
}

void _schedule() {
  _timer?.cancel();
  _timer = Timer.periodic(
    Duration(seconds: connectionLost.value ? 15 : 30),
    (_) => unawaited(_check()),
  );
}

Future<void> _check() async {
  final ok = await _reachable();
  final wasLost = connectionLost.value;
  if (ok) {
    _failures = 0;
    connectionLost.value = false;
  } else if (++_failures >= 2) {
    connectionLost.value = true;
  }
  if (wasLost != connectionLost.value) _schedule();
}

Future<bool> _reachable() async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
  try {
    final request = await client
        .getUrl(Uri.parse('https://www.cloudflare.com/cdn-cgi/trace'))
        .timeout(const Duration(seconds: 8));
    final response = await request.close().timeout(const Duration(seconds: 8));
    await response.drain<void>();
    return response.statusCode < 500;
  } catch (_) {
    return false;
  } finally {
    client.close(force: true);
  }
}

/// Switches offline mode on or off, as the Settings switch does. [byWatch]:
/// the pop-up did it, so coming back online undoes it.
void setOfflineMode(bool on, {bool byWatch = false}) {
  _offlineByWatch = on && byWatch;
  if (offlineMode.value == on) return;
  unawaited(addOrUpdateData<bool>('settings', 'offlineMode', on));
  offlineMode.value = on;
  NavigationManager.refreshRouter();
}

/// The connection is back: offline mode the pop-up switched on goes off.
/// True when it did.
bool leaveWatchOffline() {
  if (!_offlineByWatch || !offlineMode.value) return false;
  setOfflineMode(false);
  return true;
}
