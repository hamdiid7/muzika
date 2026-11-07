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
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:muzika/services/socks_bridge.dart';

/// How the app reaches the internet.
enum TunnelMode {
  /// Built-in Psiphon tunnel (needs `psiphon_config.json` in Android assets).
  psiphon,

  /// A user-supplied HTTP proxy (`host:port`).
  manual,

  /// Direct connection, no tunnel.
  off,
}

enum TunnelStatus { off, connecting, connected, unavailable, error }

@immutable
class TunnelState {
  const TunnelState(this.status, {this.proxy, this.message});

  final TunnelStatus status;

  /// `host:port` of the HTTP proxy all traffic is sent through, if any.
  final String? proxy;
  final String? message;

  @override
  String toString() => 'TunnelState($status, proxy: $proxy, message: $message)';
}

/// Routes every Dart HTTP connection of the app through one exit:
/// YouTube API calls, the googlevideo audio bytes (via just_audio's local
/// header proxy), artwork and lyrics. YouTube stream URLs are bound to the
/// IP that requested them, so resolving and streaming must share the exit.
class TunnelService {
  TunnelService._();
  static final TunnelService instance = TunnelService._();

  /// Whether this build includes the Psiphon tunnel. It is left out by
  /// default to keep the APK small; build with
  /// `--dart-define=MUZIKA_TUNNEL=true --android-project-arg muzikaPsiphon=true`
  /// to include it.
  static const bool hasBuiltInTunnel = bool.fromEnvironment('MUZIKA_TUNNEL');

  static const TunnelMode _defaultMode = hasBuiltInTunnel
      ? TunnelMode.psiphon
      : TunnelMode.off;

  static const _methods = MethodChannel('muzika/tunnel');
  static const _events = EventChannel('muzika/tunnel/events');

  final state = ValueNotifier<TunnelState>(const TunnelState(TunnelStatus.off));
  final mode = ValueNotifier<TunnelMode>(_defaultMode);
  final manualProxy = ValueNotifier<String>('');

  StreamSubscription<dynamic>? _eventSub;
  SocksBridge? _socksBridge;
  Completer<void>? _ready;

  /// The proxy currently in use, read by [MuzikaHttpOverrides] per request.
  String? get activeProxy =>
      state.value.status == TunnelStatus.connected ? state.value.proxy : null;

  bool get _isAndroid => !kIsWeb && Platform.isAndroid;

  Future<void> init() async {
    HttpOverrides.global = MuzikaHttpOverrides(this);

    final settings = Hive.box('settings');
    final saved = TunnelMode.values.firstWhere(
      (m) => m.name == settings.get('tunnelMode'),
      orElse: () => _defaultMode,
    );
    mode.value = saved == TunnelMode.psiphon && !hasBuiltInTunnel
        ? TunnelMode.off
        : saved;
    manualProxy.value = settings.get('manualProxy', defaultValue: '') as String;

    if (_isAndroid) {
      _eventSub = _events.receiveBroadcastStream().listen(
        _onNativeEvent,
        onError: (Object e) =>
            _set(TunnelState(TunnelStatus.error, message: '$e')),
      );
    }
    await _apply();
  }

  Future<void> setMode(TunnelMode newMode, {String? proxy}) async {
    final settings = Hive.box('settings');
    mode.value = newMode;
    await settings.put('tunnelMode', newMode.name);
    if (proxy != null) {
      manualProxy.value = proxy.trim();
      await settings.put('manualProxy', manualProxy.value);
    }
    await _apply();
  }

  /// Completes once the tunnel is usable (or definitely unavailable), so the
  /// first YouTube request does not race the tunnel and go out direct.
  Future<void> ready({Duration timeout = const Duration(seconds: 25)}) {
    final ready = _ready;
    if (ready == null || ready.isCompleted) return Future.value();
    return ready.future.timeout(timeout, onTimeout: () {});
  }

  Future<void> _apply() async {
    if (_isAndroid) {
      try {
        await _methods.invokeMethod<void>('stop');
      } catch (_) {}
    }

    switch (mode.value) {
      case TunnelMode.off:
        _set(const TunnelState(TunnelStatus.off));
      case TunnelMode.manual:
        await _applyManualProxy(manualProxy.value);
      case TunnelMode.psiphon:
        if (!_isAndroid) {
          _set(
            const TunnelState(
              TunnelStatus.unavailable,
              message: 'The built-in tunnel is Android only',
            ),
          );
          return;
        }
        _ready = Completer<void>();
        _set(const TunnelState(TunnelStatus.connecting));
        try {
          final result = await _methods.invokeMethod<String>('start');
          if (result == 'not_included') {
            _set(
              const TunnelState(
                TunnelStatus.unavailable,
                message: 'This build has no built-in tunnel',
              ),
            );
          } else if (result == 'no_config') {
            _set(
              const TunnelState(
                TunnelStatus.unavailable,
                message: 'No Psiphon config bundled — connecting directly',
              ),
            );
          }
        } on PlatformException catch (e) {
          _set(TunnelState(TunnelStatus.error, message: e.message));
        }
    }
  }

  /// Accepts `host:port` / `http://host:port` (HTTP proxy) or
  /// `socks5://host:port`. SOCKS5 goes through a loopback [SocksBridge]
  /// because Dart's HttpClient only speaks HTTP proxies.
  Future<void> _applyManualProxy(String raw) async {
    await _socksBridge?.stop();
    _socksBridge = null;

    final value = raw.trim();
    final uri = Uri.tryParse(value.contains('://') ? value : 'http://$value');
    if (uri == null || uri.host.isEmpty || !uri.hasPort) {
      _set(
        const TunnelState(
          TunnelStatus.error,
          message: 'Enter a proxy as host:port or socks5://host:port',
        ),
      );
      return;
    }

    if (uri.scheme.startsWith('socks')) {
      _ready = Completer<void>();
      _set(const TunnelState(TunnelStatus.connecting));
      final bridge = SocksBridge(uri.host, uri.port);
      try {
        await bridge.probe();
        final port = await bridge.start();
        _socksBridge = bridge;
        _set(TunnelState(TunnelStatus.connected, proxy: '127.0.0.1:$port'));
      } catch (e) {
        await bridge.stop();
        _set(
          TunnelState(TunnelStatus.error, message: 'SOCKS5 proxy failed: $e'),
        );
      }
      return;
    }

    _set(TunnelState(TunnelStatus.connected, proxy: '${uri.host}:${uri.port}'));
  }

  void _onNativeEvent(dynamic event) {
    if (event is! Map) return;
    switch (event['type']) {
      case 'connecting':
        _set(const TunnelState(TunnelStatus.connecting));
      case 'connected':
        final port = event['httpPort'];
        _set(
          port is int && port > 0
              ? TunnelState(TunnelStatus.connected, proxy: '127.0.0.1:$port')
              : const TunnelState(
                  TunnelStatus.error,
                  message: 'Tunnel connected without a local proxy port',
                ),
        );
      case 'error':
        _set(TunnelState(TunnelStatus.error, message: '${event['message']}'));
      case 'stopped':
        if (mode.value == TunnelMode.psiphon) {
          _set(const TunnelState(TunnelStatus.connecting));
        }
    }
  }

  void _set(TunnelState s) {
    state.value = s;
    if (s.status != TunnelStatus.connecting) {
      final ready = _ready;
      if (ready != null && !ready.isCompleted) ready.complete();
    }
  }

  void dispose() {
    unawaited(_eventSub?.cancel());
  }
}

/// Points every [HttpClient] the app creates at the active tunnel proxy.
/// Loopback stays direct: just_audio's header proxy and Psiphon's own
/// local proxy both listen on 127.0.0.1.
class MuzikaHttpOverrides extends HttpOverrides {
  MuzikaHttpOverrides(this._tunnel);

  final TunnelService _tunnel;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context)
      ..findProxy = (uri) {
        final host = uri.host;
        if (host == 'localhost' || host == '127.0.0.1' || host == '::1') {
          return 'DIRECT';
        }
        final proxy = _tunnel.activeProxy;
        return proxy == null ? 'DIRECT' : 'PROXY $proxy';
      };
  }
}
