import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../config/build_defaults.dart';
import '../i18n/locale_provider.dart';

class PawTermQrResult {
  final String url;
  final String claim;
  const PawTermQrResult({required this.url, required this.claim});
}

class QrScanScreen extends ConsumerStatefulWidget {
  const QrScanScreen({super.key});

  @override
  ConsumerState<QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends ConsumerState<QrScanScreen> {
  final _controller = MobileScannerController();
  bool _handled = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw == null) continue;
      final result = _parse(raw);
      if (result != null) {
        _handled = true;
        Navigator.of(context).pop(result);
        return;
      }
    }
  }

  PawTermQrResult? _parse(String raw) {
    final uri = Uri.tryParse(raw);
    if (uri == null) return null;
    if (uri.scheme != 'pawterm') return null;
    final claim = uri.queryParameters['claim'];
    if (claim == null || claim.isEmpty) return null;
    final host = uri.host;
    final port = uri.hasPort ? uri.port : BuildDefaults.defaultServerPort;
    if (host.isEmpty) return null;
    return PawTermQrResult(url: 'http://$host:$port', claim: claim);
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(stringsProvider);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(s.qrScanTitle),
      ),
      body: Stack(
        children: [
          MobileScanner(controller: _controller, onDetect: _onDetect),
          Positioned(
            bottom: 60,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  s.qrScanHint,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
