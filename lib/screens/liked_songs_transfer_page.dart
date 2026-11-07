import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:muzika/services/desktop_panels.dart';
import 'package:muzika/services/library_pairing.dart';
import 'package:muzika/services/library_sync_service.dart';
import 'package:qr_flutter/qr_flutter.dart';

void openLikedSongsTransfer(BuildContext context) {
  Navigator.of(context, rootNavigator: !desktopPanels.value).push(
    MaterialPageRoute<void>(
      builder: (_) =>
          InheritedTheme.captureAll(context, const LikedSongsTransferPage()),
    ),
  );
}

class LikedSongsTransferPage extends StatefulWidget {
  const LikedSongsTransferPage({super.key});
  @override
  State<LikedSongsTransferPage> createState() => _LikedSongsTransferPageState();
}

class _LikedSongsTransferPageState extends State<LikedSongsTransferPage> {
  LibraryPairingServer? _receiver;
  LibraryPairing? _pairing;
  LibraryExchange? _exchange;
  List<String> _addresses = [];
  String? _host;
  String? _error;
  String? _working;
  bool _success = false;
  bool _busy = false;
  bool _expired = false;
  Timer? _expiry;
  int _generation = 0;
  bool get _receiving => Platform.isWindows;

  @override
  void initState() {
    super.initState();
    if (_receiving) unawaited(_startReceiver());
  }

  @override
  void dispose() {
    _generation++;
    _expiry?.cancel();
    unawaited(_receiver?.close());
    super.dispose();
  }

  Future<void> _startReceiver() async {
    final generation = ++_generation;
    _expiry?.cancel();
    setState(() {
      _busy = true;
      _error = null;
      _success = false;
      _expired = false;
      _working = null;
    });
    await _receiver?.close();
    _receiver = null;
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      );
      bool isWifi(NetworkInterface i) => RegExp(
        'wi[ -]?fi|wlan|wireless',
        caseSensitive: false,
      ).hasMatch(i.name);
      interfaces.sort(
        (a, b) => (isWifi(a) ? 0 : 1).compareTo(isWifi(b) ? 0 : 1),
      );
      final addresses = interfaces
          .expand((i) => i.addresses)
          .where((a) => !a.isLoopback && _isLan(a.address))
          .map((a) => a.address)
          .toSet()
          .toList();
      if (addresses.isEmpty)
        throw const SocketException('No Wi-Fi connection.');
      final receiver = await LibraryPairingServer.start(
        onExchange: (library) async {
          if (!mounted || generation != _generation)
            throw StateError('Pairing closed');
          setState(() => _working = 'Adding missing library items…');
          try {
            final merged = await mergeAndSaveSyncLibrary(library);
            if (mounted && generation == _generation)
              setState(
                () => _working = 'Waiting for your phone to save its library…',
              );
            return merged;
          } on Object {
            if (mounted && generation == _generation)
              setState(() {
                _working = null;
                _error =
                    'Could not save the library. Please try pairing again.';
              });
            rethrow;
          }
        },
        onConfirmed: () {
          if (!mounted || generation != _generation) return;
          _expiry?.cancel();
          setState(() {
            _success = true;
            _working = null;
            _error = null;
          });
        },
      );
      if (!mounted || generation != _generation) {
        await receiver.close();
        return;
      }
      _receiver = receiver;
      _expiry = Timer(const Duration(minutes: 5), () {
        if (mounted)
          setState(() {
            _expired = true;
            _working = null;
          });
      });
      setState(() {
        _addresses = addresses;
        _host = addresses.first;
        _busy = false;
      });
    } on Object {
      if (mounted && generation == _generation)
        setState(() {
          _busy = false;
          _error = 'Could not start pairing. Connect this PC to Wi-Fi and try again.';
        });
    }
  }

  bool _isLan(String host) {
    final b = InternetAddress(host).rawAddress;
    return b[0] == 10 ||
        (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
        (b[0] == 192 && b[1] == 168);
  }

  Future<void> _scan() async {
    final code = await Navigator.of(
      context,
    ).push<String>(MaterialPageRoute(builder: (_) => const _PairingScanner()));
    if (!mounted || code == null) return;
    try {
      final pairing = LibraryPairing.parse(code);
      setState(() {
        _pairing = pairing;
        _exchange = LibraryExchange(pairing);
        _error = null;
        _success = false;
      });
    } on Object {
      setState(
        () =>
            _error = 'Scan the Sync library code from the updated Windows app.',
      );
    }
  }

  Future<void> _sync() async {
    final exchange = _exchange;
    if (exchange == null) return;
    setState(() {
      _busy = true;
      _error = null;
      _working = 'Syncing both libraries…';
    });
    try {
      await exchange.sync(
        library: readSyncLibrary(),
        save: (library) async {
          await mergeAndSaveSyncLibrary(library);
        },
      );
      if (mounted)
        setState(() {
          _success = true;
          _pairing = null;
          _exchange = null;
        });
    } on Object {
      if (mounted)
        setState(
          () => _error = 'Sync could not finish. Keep Muzika open on both devices on the same Wi-Fi, then retry. Any items already added are kept. If the code expired, scan a new one.',
        );
    } finally {
      if (mounted)
        setState(() {
          _busy = false;
          _working = null;
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Sync library')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(Icons.sync_rounded, size: 44, color: scheme.primary),
                const SizedBox(height: 16),
                Text(
                  'Phone ↔ Windows',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 12),
                Text(
                  _receiving
                      ? 'On your phone, open Muzika → Library → Sync library. Scan this code, then tap Sync both libraries.'
                      : 'On Windows, open Muzika → Library → Sync library. Scan the code shown there.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                Text(
                  'Add what either device is missing. Nothing is removed. Same-name playlists combine their songs.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Use the same Wi-Fi on both devices.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),
                if (_busy) const Center(child: CircularProgressIndicator()),
                if (_working != null) ...[
                  const SizedBox(height: 12),
                  Text(_working!, textAlign: TextAlign.center),
                ],
                if (_success) ...[
                  const Icon(
                    Icons.check_circle_rounded,
                    size: 60,
                    color: Colors.green,
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Both libraries updated',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Songs, playlists, albums, artists, folders, favourites and recently played are merged. Your downloaded audio stays on its original device.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: _receiving
                        ? _startReceiver
                        : () => setState(() => _success = false),
                    child: const Text('Pair another device'),
                  ),
                ] else if (_receiving &&
                    !_busy &&
                    _receiver != null &&
                    !_expired) ...[
                  Center(
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      padding: const EdgeInsets.all(16),
                      child: QrImageView(
                        data: _receiver!.pairing(_host!).code,
                        size: 236,
                        backgroundColor: Colors.white,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'One-time pairing · expires in 5 minutes',
                    textAlign: TextAlign.center,
                  ),
                  if (_addresses.length > 1 && _working == null)
                    DropdownButton<String>(
                      value: _host,
                      isExpanded: true,
                      items: [
                        for (var i = 0; i < _addresses.length; i++)
                          DropdownMenuItem(
                            value: _addresses[i],
                            child: Text(
                              i == 0
                                  ? 'Primary network'
                                  : 'Alternate network ${i + 1}',
                            ),
                          ),
                      ],
                      onChanged: (host) => setState(() => _host = host),
                    ),
                ] else if (_receiving && !_busy) ...[
                  if (_expired)
                    const Text(
                      'This code has expired.',
                      textAlign: TextAlign.center,
                    ),
                  FilledButton(
                    onPressed: _startReceiver,
                    child: const Text('Generate new code'),
                  ),
                ],
                if (!_receiving && !_busy && !_success) ...[
                  if (_pairing != null) ...[
                    const Text(
                      'Ready to update both libraries',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: _sync,
                      icon: const Icon(Icons.sync_rounded),
                      label: const Text('Sync both libraries'),
                    ),
                  ],
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: _scan,
                    icon: const Icon(Icons.qr_code_scanner_rounded),
                    label: Text(
                      _pairing == null ? 'Scan QR code' : 'Scan a new code',
                    ),
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    _error!,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: scheme.error),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PairingScanner extends StatefulWidget {
  const _PairingScanner();
  @override
  State<_PairingScanner> createState() => _PairingScannerState();
}

class _PairingScannerState extends State<_PairingScanner>
    with WidgetsBindingObserver {
  final _controller = MobileScannerController(
    formats: [BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  bool _done = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_controller.value.hasCameraPermission || _done) return;
    if (state == AppLifecycleState.resumed) {
      unawaited(_controller.start());
    } else {
      unawaited(_controller.stop());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_controller.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    appBar: AppBar(title: const Text('Scan library QR code')),
    body: Stack(
      children: [
        MobileScanner(
          controller: _controller,
          onDetect: (capture) {
            if (_done) return;
            for (final barcode in capture.barcodes) {
              final value = barcode.rawValue;
              if (value == null) continue;
              try {
                LibraryPairing.parse(value);
              } on Object {
                setState(() => _error = 'Scan the code in Muzika on Windows.');
                continue;
              }
              _done = true;
              unawaited(_controller.stop());
              Navigator.pop(context, value);
              break;
            }
          },
          errorBuilder: (_, _) => const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'Camera unavailable. Allow camera access for Muzika in your phone settings, or go back and try scanning again.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white),
              ),
            ),
          ),
        ),
        Positioned(
          left: 24,
          right: 24,
          bottom: 40,
          child: Container(
            padding: const EdgeInsets.all(16),
            color: Colors.black87,
            child: Text(
              _error ?? 'Point your camera at the QR code on Windows.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white),
            ),
          ),
        ),
      ],
    ),
  );
}
