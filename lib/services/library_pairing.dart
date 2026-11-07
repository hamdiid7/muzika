import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:muzika/services/library_merge.dart';
import 'package:muzika/services/liked_songs_transfer.dart'
    show isPrivateTransferAddress;

const _maxBytes = 32 * 1024 * 1024;
String _nonce() {
  final random = Random.secure();
  return List.generate(
    32,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

class LibraryPairing {
  const LibraryPairing(this.host, this.port, this.token);
  factory LibraryPairing.parse(String text) {
    final uri = Uri.parse(text.trim());
    final host = uri.queryParameters['host'] ?? '';
    final port = int.tryParse(uri.queryParameters['port'] ?? '') ?? 0;
    final token = uri.queryParameters['token'] ?? '';
    if (uri.scheme != 'muzika' ||
        uri.host != 'transfer' ||
        uri.path != '/library' ||
        !isPrivateTransferAddress(host) ||
        port < 1 ||
        port > 65535 ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(token)) {
      throw const FormatException(
        'Scan a Sync library code from the updated Muzika app.',
      );
    }
    return LibraryPairing(host, port, token);
  }
  final String host;
  final int port;
  final String token;
  String get code => Uri(
    scheme: 'muzika',
    host: 'transfer',
    path: '/library',
    queryParameters: {'host': host, 'port': '$port', 'token': token},
  ).toString();
  Uri endpoint(String path) =>
      Uri(scheme: 'http', host: host, port: port, path: path);
}

Future<Map<String, dynamic>> _readJson(Stream<List<int>> stream) async {
  final bytes = <int>[];
  await for (final chunk in stream.timeout(const Duration(seconds: 30))) {
    if (bytes.length + chunk.length > _maxBytes)
      throw const FormatException('Library too large.');
    bytes.addAll(chunk);
  }
  final decoded = jsonDecode(utf8.decode(bytes));
  if (decoded is! Map<String, dynamic>)
    throw const FormatException('Invalid library data.');
  return decoded;
}

/// Two-phase, retryable exchange. Desktop adds the phone data and sends back
/// the union. Completion is displayed only after the phone persists that union
/// and acknowledges it. Retries reuse the same exchange ID and cannot duplicate
/// songs or inflate play counts.
class LibraryPairingServer {
  LibraryPairingServer._(this._server, this._onExchange, this._onConfirmed) {
    _expiry = Timer(const Duration(minutes: 5), () {
      expired = true;
      unawaited(close());
    });
    _server.listen(_handle);
  }
  static Future<LibraryPairingServer> start({
    required Future<Map<String, dynamic>> Function(Map) onExchange,
    required void Function() onConfirmed,
  }) async => LibraryPairingServer._(
    await HttpServer.bind(InternetAddress.anyIPv4, 0),
    onExchange,
    onConfirmed,
  );
  final HttpServer _server;
  final Future<Map<String, dynamic>> Function(Map) _onExchange;
  final void Function() _onConfirmed;
  final String token = _nonce();
  late Timer _expiry;
  bool expired = false;
  bool completed = false;
  bool _closed = false;
  bool _busy = false;
  String? _exchangeId;
  String? _reply;
  LibraryPairing pairing(String host) =>
      LibraryPairing(host, _server.port, token);

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    response.headers.contentType = ContentType.json;
    try {
      if (_closed || expired) {
        response.statusCode = HttpStatus.gone;
        return;
      }
      if (request.method != 'POST' ||
          !['/library', '/confirm'].contains(request.uri.path)) {
        response.statusCode = HttpStatus.notFound;
        return;
      }
      if (request.headers.value(HttpHeaders.authorizationHeader) !=
          'Bearer $token') {
        response.statusCode = HttpStatus.forbidden;
        return;
      }
      if (_busy) {
        response.statusCode = HttpStatus.conflict;
        return;
      }
      _busy = true;
      try {
        final data = await _readJson(request);
        final id = data['exchangeId'];
        if (data['version'] != 2 ||
            id is! String ||
            !RegExp(r'^[a-f0-9]{64}$').hasMatch(id))
          throw const FormatException('Invalid exchange.');
        if (_exchangeId != null && _exchangeId != id) {
          response.statusCode = HttpStatus.conflict;
          return;
        }
        if (_closed || expired) {
          response.statusCode = HttpStatus.gone;
          return;
        }
        if (request.uri.path == '/confirm') {
          if (_reply == null || _exchangeId != id)
            throw const FormatException('No exchange to confirm.');
          response.write(
            jsonEncode({'version': 2, 'confirmed': true, 'exchangeId': id}),
          );
          if (!completed) {
            completed = true;
            // Leave a short window to retry an acknowledgement lost in transit.
            _expiry.cancel();
            _expiry = Timer(
              const Duration(seconds: 30),
              () => unawaited(close()),
            );
            _onConfirmed();
          }
        } else {
          if (_reply == null) {
            if (data['library'] is! Map)
              throw const FormatException('Missing library.');
            final incoming = portableLibrary(data['library'] as Map);
            final union = await _onExchange(incoming);
            final reply = jsonEncode({
              'version': 2,
              'exchangeId': id,
              'library': portableLibrary(union),
            });
            if (utf8.encode(reply).length > _maxBytes)
              throw const FormatException('Library too large.');
            _exchangeId = id;
            _reply = reply;
          }
          response.write(_reply);
        }
      } finally {
        _busy = false;
      }
    } on Object {
      response
        ..statusCode = HttpStatus.badRequest
        ..write(
          jsonEncode({
            'error': 'Could not sync. Update both apps, then generate a new pairing code.',
          }),
        );
    } finally {
      try {
        await response.close();
      } on Object {
        /* Client can retry. */
      }
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _expiry.cancel();
    await _server.close(force: true);
  }
}

class LibraryExchange {
  LibraryExchange(this.pairing);
  final LibraryPairing pairing;
  final String id = _nonce();

  Future<void> sync({
    required Map library,
    required Future<void> Function(Map) save,
  }) async {
    LibraryPairing.parse(pairing.code);
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10)
      ..findProxy = (_) => 'DIRECT';
    Future<Map<String, dynamic>> post(String path, Map data) async {
      final body = utf8.encode(
        jsonEncode({'version': 2, 'exchangeId': id, ...data}),
      );
      if (body.length > _maxBytes)
        throw const FormatException('Library too large for one transfer.');
      final request = await client
          .postUrl(pairing.endpoint(path))
          .timeout(const Duration(seconds: 10));
      request
        ..followRedirects = false
        ..headers.contentType = ContentType.json;
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer ${pairing.token}',
      );
      request.add(body);
      final response = await request.close().timeout(
        const Duration(seconds: 45),
      );
      final reply = await _readJson(response);
      if (response.statusCode != HttpStatus.ok ||
          reply['version'] != 2 ||
          reply['exchangeId'] != id) {
        throw const FormatException(
          'Pairing expired or unavailable. Generate a new code and scan again.',
        );
      }
      return reply;
    }

    try {
      final reply = await post('/library', {
        'library': portableLibrary(library),
      });
      if (reply['library'] is! Map)
        throw const FormatException('Invalid library reply.');
      await save(portableLibrary(reply['library'] as Map));
      final confirmation = await post('/confirm', const {});
      if (confirmation['confirmed'] != true)
        throw const FormatException('Please retry to confirm the sync.');
    } finally {
      client.close(force: true);
    }
  }
}
