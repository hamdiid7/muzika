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
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// A loopback HTTP proxy that forwards every connection through a SOCKS5
/// server. Dart's HttpClient only speaks HTTP proxies, so the app points
/// `findProxy` at this bridge and the bridge does the SOCKS5 handshake.
class SocksBridge {
  SocksBridge(this.socksHost, this.socksPort);

  final String socksHost;
  final int socksPort;

  ServerSocket? _server;

  int? get port => _server?.port;

  Future<int> start() async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.listen(_handleClient, onError: (_) {});
    return server.port;
  }

  Future<void> stop() async {
    await _server?.close();
    _server = null;
  }

  /// Checks that the SOCKS5 server accepts a CONNECT to [host]:[port].
  Future<void> probe({String host = 'www.youtube.com', int port = 443}) async {
    final socket = await _SocksConnection.open(
      socksHost,
      socksPort,
      host,
      port,
    );
    socket.destroy();
  }

  void _handleClient(Socket client) {
    final header = BytesBuilder(copy: false);
    late final StreamSubscription<Uint8List> sub;
    var upgraded = false;

    sub = client.listen(
      (data) async {
        if (upgraded) return;
        header.add(data);
        final bytes = header.toBytes();
        final end = _indexOfHeaderEnd(bytes);
        if (end < 0) {
          if (bytes.length > 64 * 1024) client.destroy();
          return;
        }
        upgraded = true;
        sub.pause();

        final head = latin1.decode(bytes.sublist(0, end));
        final rest = bytes.sublist(end + 4);
        final requestLine = head.split('\r\n').first.split(' ');
        if (requestLine.length < 2) {
          client.destroy();
          return;
        }

        final isConnect = requestLine[0].toUpperCase() == 'CONNECT';
        String host;
        int port;
        if (isConnect) {
          final hp = requestLine[1].split(':');
          host = hp[0];
          port = hp.length > 1 ? int.tryParse(hp[1]) ?? 443 : 443;
        } else {
          final uri = Uri.tryParse(requestLine[1]);
          if (uri == null || uri.host.isEmpty) {
            client.destroy();
            return;
          }
          host = uri.host;
          port = uri.hasPort ? uri.port : 80;
        }

        try {
          final upstream = await _SocksConnection.open(
            socksHost,
            socksPort,
            host,
            port,
          );
          if (isConnect) {
            client.add(
              ascii.encode('HTTP/1.1 200 Connection Established\r\n\r\n'),
            );
            if (rest.isNotEmpty) upstream.add(rest);
          } else {
            upstream.add(bytes); // forward the original request as-is
          }
          _pipe(client, sub, upstream);
        } catch (_) {
          client
            ..add(ascii.encode('HTTP/1.1 502 Bad Gateway\r\n\r\n'))
            ..destroy();
        }
      },
      onError: (_) => client.destroy(),
      cancelOnError: true,
    );
  }

  void _pipe(
    Socket client,
    StreamSubscription<Uint8List> clientSub,
    _SocksConnection upstream,
  ) {
    clientSub
      ..onData(upstream.add)
      ..onDone(upstream.destroy)
      ..onError((_) => upstream.destroy())
      ..resume();
    upstream.onData(client.add, onDone: client.destroy);
  }

  static int _indexOfHeaderEnd(Uint8List b) {
    for (var i = 0; i + 3 < b.length; i++) {
      if (b[i] == 13 && b[i + 1] == 10 && b[i + 2] == 13 && b[i + 3] == 10) {
        return i;
      }
    }
    return -1;
  }
}

/// A TCP connection tunneled through SOCKS5 (no auth, CONNECT, domain name
/// resolved by the proxy so DNS doesn't leak to the local network).
class _SocksConnection {
  _SocksConnection._(this._socket);

  final Socket _socket;
  late final StreamSubscription<Uint8List> _sub;
  final _buffer = BytesBuilder(copy: false);
  final _ready = Completer<void>();
  var _stage = 0; // 0: method reply, 1: connect reply, 2: streaming
  void Function(Uint8List)? _onData;
  void Function()? _onDone;
  final _early = <Uint8List>[];

  static Future<_SocksConnection> open(
    String proxyHost,
    int proxyPort,
    String host,
    int port,
  ) async {
    final socket = await Socket.connect(
      proxyHost,
      proxyPort,
      timeout: const Duration(seconds: 15),
    );
    socket.setOption(SocketOption.tcpNoDelay, true);
    final c = _SocksConnection._(socket);
    c._sub = socket.listen(
      (d) => c._onBytes(d, host, port),
      onError: (Object e) {
        if (!c._ready.isCompleted) c._ready.completeError(e);
        c._onDone?.call();
      },
      onDone: () {
        if (!c._ready.isCompleted) {
          c._ready.completeError(const SocketException('SOCKS closed'));
        }
        c._onDone?.call();
      },
    );
    socket.add([5, 1, 0]); // version 5, one method: no authentication
    await c._ready.future.timeout(const Duration(seconds: 20));
    return c;
  }

  void _onBytes(Uint8List data, String host, int port) {
    if (_stage == 2) {
      final cb = _onData;
      cb == null ? _early.add(data) : cb(data);
      return;
    }
    _buffer.add(data);
    final b = _buffer.toBytes();

    if (_stage == 0) {
      if (b.length < 2) return;
      if (b[0] != 5 || b[1] != 0) {
        _ready.completeError(const SocketException('SOCKS auth rejected'));
        return;
      }
      _buffer.clear();
      if (b.length > 2) _buffer.add(b.sublist(2));
      _stage = 1;
      final name = ascii.encode(host);
      _socket.add([
        5,
        1,
        0,
        3,
        name.length,
        ...name,
        (port >> 8) & 0xff,
        port & 0xff,
      ]);
      return;
    }

    // Stage 1: VER REP RSV ATYP BND.ADDR BND.PORT
    if (b.length < 5) return;
    if (b[1] != 0) {
      _ready.completeError(SocketException('SOCKS connect failed (${b[1]})'));
      return;
    }
    final addrLen = switch (b[3]) {
      1 => 4,
      4 => 16,
      3 => 1 + b[4],
      _ => -1,
    };
    if (addrLen < 0) {
      _ready.completeError(const SocketException('SOCKS bad reply'));
      return;
    }
    final total = 4 + addrLen + 2;
    if (b.length < total) return;
    _stage = 2;
    _buffer.clear();
    if (b.length > total) _early.add(b.sublist(total));
    _ready.complete();
  }

  void add(List<int> data) {
    try {
      _socket.add(data);
    } catch (_) {}
  }

  void onData(void Function(Uint8List) cb, {required void Function() onDone}) {
    _onData = cb;
    _onDone = onDone;
    for (final d in _early) {
      cb(d);
    }
    _early.clear();
  }

  void destroy() {
    unawaited(_sub.cancel());
    _socket.destroy();
  }
}
