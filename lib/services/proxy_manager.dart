/*
 *     Copyright (C) 2026 Valeri Gokadze
 *     Modified for Muzika, 2026.
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

import 'package:http/http.dart' as http;
import 'package:muzika/constants/clients.dart';
import 'package:muzika/services/tunnel_service.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

/// The original app scraped free public proxies here. Muzika instead routes every
/// HttpClient through [TunnelService] (see [MuzikaHttpOverrides]), so this
/// class only keeps the API the rest of the code base expects.
class ProxyManager {
  factory ProxyManager() => _instance;
  ProxyManager._internal();
  static final ProxyManager _instance = ProxyManager._internal();

  final YoutubeExplode _yt = YoutubeExplode();

  YoutubeExplode getClientSync() => _yt;

  Future<StreamManifest?> getSongManifest(String songId) async {
    await TunnelService.instance.ready();
    try {
      return await getManifestWithFallback(
        _yt,
        songId,
        timeout: const Duration(seconds: 15),
      );
    } catch (_) {
      return null;
    }
  }

  Future<http.Response> getProxiedResponse(
    Uri uri, {
    Map<String, String>? headers,
    int timeoutSeconds = 10,
  }) {
    return http
        .get(uri, headers: headers)
        .timeout(
          Duration(seconds: timeoutSeconds),
          onTimeout: () => http.Response('Timeout', 408),
        );
  }

  /// Kept for API compatibility; the shared client is already tunneled.
  Future<YoutubeExplode?> getYoutubeExplodeClient({
    int timeoutSeconds = 5,
  }) async => null;
}

final ytClient = ProxyManager().getClientSync();
