import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// Only LAN addresses are valid destinations for this device-to-device protocol.
bool isPrivateTransferAddress(String host) {
  final address = InternetAddress.tryParse(host);
  if (address == null || address.type != InternetAddressType.IPv4) return false;
  final b = address.rawAddress;
  return b[0] == 10 ||
      (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
      (b[0] == 192 && b[1] == 168) ||
      b[0] == 127;
}

class LikedSongsPairing {
  const LikedSongsPairing(this.host, this.port, this.token);

  factory LikedSongsPairing.parse(String value) {
    final uri = Uri.parse(value.trim());
    final host = uri.queryParameters['host'] ?? '';
    final port = int.tryParse(uri.queryParameters['port'] ?? '') ?? 0;
    final token = uri.queryParameters['token'] ?? '';
    if (uri.scheme != 'muzika' ||
        uri.host != 'transfer' ||
        uri.path != '/liked' ||
        !isPrivateTransferAddress(host) ||
        port < 1 ||
        port > 65535 ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(token)) {
      throw const FormatException('Scan a Muzika liked songs pairing code.');
    }
    return LikedSongsPairing(host, port, token);
  }

  final String host;
  final int port;
  final String token;

  String get code => Uri(
    scheme: 'muzika',
    host: 'transfer',
    path: '/liked',
    queryParameters: {'host': host, 'port': '$port', 'token': token},
  ).toString();

  Uri get endpoint =>
      Uri(scheme: 'http', host: host, port: port, path: '/liked');
}

/// Keep portable catalog metadata only. Never import phone-local file paths or
/// cached playback URLs, which are invalid on the receiving device.
List<Map<String, dynamic>> portableLikedSongs(Iterable songs) {
  final result = <Map<String, dynamic>>[];
  final seen = <String>{};
  for (final song in songs) {
    if (song is! Map) continue;
    final id = song['ytid']?.toString() ?? '';
    if (!RegExp(r'^[a-zA-Z0-9_-]{11}$').hasMatch(id) || !seen.add(id)) continue;
    final item = <String, dynamic>{'ytid': id};
    for (final key in ['title', 'artist', 'album', 'artistId', 'albumId']) {
      final value = song[key];
      if (value is String)
        item[key] = value.substring(0, min(512, value.length));
    }
    item['title'] ??= 'Unknown song';
    item['artist'] ??= '';
    for (final key in ['image', 'lowResImage', 'highResImage']) {
      final value = song[key];
      if (value is String && value.length <= 2048) {
        final uri = Uri.tryParse(value);
        if (uri?.scheme == 'https' && uri!.host.isNotEmpty) item[key] = value;
      }
    }
    final duration = song['duration'];
    if (duration is String && duration.length <= 32 ||
        duration is num && duration.isFinite && duration >= 0) {
      item['duration'] = duration;
    }
    if (song['isLive'] is bool) item['isLive'] = song['isLive'];
    result.add(item);
    if (result.length > 10000) throw const FormatException('Too many songs.');
  }
  return result;
}

List<dynamic> mergeTransferredLikes(Iterable existing, Iterable incoming) {
  final merged = List<dynamic>.of(existing);
  final ids = existing.whereType<Map>().map((s) => s['ytid']).toSet();
  for (final song in portableLikedSongs(incoming)) {
    if (ids.add(song['ytid'])) merged.add(song);
  }
  return merged;
}

class LikedSongsReceiver {
  LikedSongsReceiver._(
    this._server,
    this.token,
    this._onReceive,
    Duration lifetime,
  ) {
    _expiry = Timer(lifetime, () {
      expired = true;
      unawaited(close());
    });
    _server.listen(_handle);
  }

  static Future<LikedSongsReceiver> start({
    required Future<int> Function(List<Map<String, dynamic>>) onReceive,
    Duration lifetime = const Duration(minutes: 5),
    InternetAddress? bindAddress,
  }) async {
    final random = Random.secure();
    final token = List.generate(
      32,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final server = await HttpServer.bind(
      bindAddress ?? InternetAddress.anyIPv4,
      0,
    );
    return LikedSongsReceiver._(server, token, onReceive, lifetime);
  }

  final HttpServer _server;
  final String token;
  final Future<int> Function(List<Map<String, dynamic>>) _onReceive;
  late final Timer _expiry;
  bool expired = false;
  bool _busy = false;
  bool _closed = false;
  bool completed = false;
  int get port => _server.port;
  LikedSongsPairing pairing(String host) =>
      LikedSongsPairing(host, port, token);

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    response.headers.contentType = ContentType.json;
    try {
      if (_closed || expired || completed || _busy) {
        response.statusCode = HttpStatus.gone;
      } else if (request.method != 'POST' || request.uri.path != '/liked') {
        response.statusCode = HttpStatus.notFound;
      } else if (request.headers.value(HttpHeaders.authorizationHeader) !=
          'Bearer $token') {
        response.statusCode = HttpStatus.forbidden;
      } else {
        _busy = true;
        try {
          final bytes = <int>[];
          await for (final chunk in request.timeout(
            const Duration(seconds: 20),
          )) {
            if (bytes.length + chunk.length > 8 * 1024 * 1024) {
              throw const FormatException('Playlist is too large.');
            }
            bytes.addAll(chunk);
          }
          final data = jsonDecode(utf8.decode(bytes));
          if (data is! Map ||
              data['version'] != 1 ||
              data['songs'] is! List ||
              (data['songs'] as List).length > 10000) {
            throw const FormatException('Invalid playlist.');
          }
          final songs = portableLikedSongs(data['songs'] as List);
          if (songs.isEmpty) throw const FormatException('No playable songs.');
          // A disposed or expired pairing must never write library data.
          if (_closed || expired)
            throw const FormatException('Pairing expired.');
          final added = await _onReceive(songs);
          completed = true;
          response.write(
            jsonEncode({'added': added, 'received': songs.length}),
          );
        } finally {
          _busy = false;
        }
      }
    } on Object {
      response
        ..statusCode = HttpStatus.badRequest
        ..write(
          jsonEncode({
            'error': 'Unable to receive playlist. Generate a new code and try again.',
          }),
        );
    } finally {
      await response.close();
      if (completed) unawaited(close());
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _expiry.cancel();
    await _server.close(force: true);
  }
}

Future<({int added, int received})> sendLikedSongs(
  LikedSongsPairing pairing,
  Iterable songs,
) async {
  // Do not send local library data through the app's optional playback proxy.
  LikedSongsPairing.parse(pairing.code);
  final portable = portableLikedSongs(songs);
  if (portable.isEmpty)
    throw const FormatException('Like some songs before sending.');
  final body = utf8.encode(jsonEncode({'version': 1, 'songs': portable}));
  if (body.length > 8 * 1024 * 1024)
    throw const FormatException('Playlist is too large.');
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10)
    ..findProxy = (_) => 'DIRECT';
  try {
    final request = await client
        .postUrl(pairing.endpoint)
        .timeout(const Duration(seconds: 10));
    request.followRedirects = false;
    request.headers.contentType = ContentType.json;
    request.headers.set(
      HttpHeaders.authorizationHeader,
      'Bearer ${pairing.token}',
    );
    request.add(body);
    final response = await request.close().timeout(const Duration(seconds: 25));
    final text = await utf8.decoder
        .bind(response)
        .join()
        .timeout(const Duration(seconds: 10));
    if (response.statusCode != HttpStatus.ok)
      throw const FormatException(
        'Code expired or transfer failed. Generate a new code on Windows.',
      );
    final data = jsonDecode(text) as Map;
    return (added: data['added'] as int, received: data['received'] as int);
  } finally {
    client.close(force: true);
  }
}
