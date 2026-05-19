import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../i18n/locale_provider.dart';
import '../i18n/strings.dart';
import '../state/lan_scanner.dart';
import '../state/server_config.dart';
import '../theme.dart';
import 'qr_scan_screen.dart';

/// Shown when user taps an unpaired server in LAN scan results.
/// Three pairing paths: Auto (default), PIN, QR-claim.
class PairSheet extends ConsumerStatefulWidget {
  final LanScanResult server;

  const PairSheet({super.key, required this.server});

  @override
  ConsumerState<PairSheet> createState() => _PairSheetState();
}

class _PairSheetState extends ConsumerState<PairSheet>
    with SingleTickerProviderStateMixin {
  late final TabController _tabCtrl;
  final _pinCtrl = TextEditingController();
  bool _loading = false;
  String? _errorMsg; // PIN / QR error
  String? _autoErrorMsg; // Auto-pair error

  // Auto-pair state
  bool _autoPolling = false;
  http.Client? _pollClient;
  bool _cancelled = false;

  @override
  void initState() {
    super.initState();
    // 3 tabs: 0=Auto, 1=PIN, 2=QR
    _tabCtrl = TabController(length: 3, vsync: this);
    // Kick off auto-pair as soon as sheet is shown.
    WidgetsBinding.instance.addPostFrameCallback((_) => _startAutoPair());
  }

  @override
  void dispose() {
    _cancelled = true;
    _pollClient?.close();
    _tabCtrl.dispose();
    _pinCtrl.dispose();
    super.dispose();
  }

  // ─── Auto-pair ────────────────────────────────────────────────────────────

  Future<void> _startAutoPair() async {
    if (!mounted) return;
    setState(() {
      _autoPolling = true;
      _cancelled = false;
      _autoErrorMsg = null;
    });

    try {
      final deviceId = await PairedServersNotifier.getOrCreateDeviceId();
      final deviceName = PairedServersNotifier.deviceName;

      final resp = await http
          .post(
            Uri.parse(
                'http://${widget.server.host}:${widget.server.port}/pair/request'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'deviceId': deviceId,
              'deviceName': deviceName,
            }),
          )
          .timeout(const Duration(seconds: 10));

      if (!mounted || _cancelled) return;

      if (resp.statusCode == 404) {
        // Old server — gracefully fall back to PIN tab.
        final s = ref.read(stringsProvider);
        setState(() {
          _autoPolling = false;
          _autoErrorMsg = s.pairSheetAutoOldServer;
        });
        _tabCtrl.animateTo(1); // Switch to PIN tab
        return;
      }

      if (resp.statusCode != 200) {
        final s = ref.read(stringsProvider);
        setState(() {
          _autoPolling = false;
          _autoErrorMsg = s.pairSheetAutoNetError;
        });
        return;
      }

      final body = jsonDecode(resp.body) as Map<String, dynamic>;
      final pollUrl = body['pollUrl'] as String;

      await _pollLoop(pollUrl);
    } catch (e) {
      if (!mounted || _cancelled) return;
      final s = ref.read(stringsProvider);
      // 404 comes as ClientException on some platforms; treat unknown as net err
      setState(() {
        _autoPolling = false;
        _autoErrorMsg = s.pairSheetAutoNetError;
      });
    }
  }

  Future<void> _pollLoop(String pollUrl) async {
    while (mounted && !_cancelled) {
      _pollClient = http.Client();
      try {
        final req = http.Request('GET', Uri.parse(pollUrl));
        final streamedResp = await _pollClient!
            .send(req)
            .timeout(const Duration(seconds: 35));

        final bodyBytes = await streamedResp.stream.toBytes();
        if (!mounted || _cancelled) return;

        if (streamedResp.statusCode != 200) {
          final s = ref.read(stringsProvider);
          setState(() {
            _autoPolling = false;
            _autoErrorMsg = s.pairSheetAutoNetError;
          });
          return;
        }

        final body =
            jsonDecode(utf8.decode(bodyBytes)) as Map<String, dynamic>;
        final status = body['status'] as String?;

        switch (status) {
          case 'pending':
            // Continue polling immediately
            break;
          case 'approved':
            final deviceToken = body['deviceToken'] as String;
            final serverId =
                body['serverId'] as String? ?? widget.server.serverId;
            setState(() => _autoPolling = false);
            await _savePaired(serverId, deviceToken);
            return;
          case 'denied':
            final s = ref.read(stringsProvider);
            setState(() {
              _autoPolling = false;
              _autoErrorMsg = s.pairSheetAutoDenied;
            });
            return;
          case 'expired':
            final s = ref.read(stringsProvider);
            setState(() {
              _autoPolling = false;
              _autoErrorMsg = s.pairSheetAutoExpired;
            });
            return;
          default:
            // Unexpected status — treat as network issue
            final s = ref.read(stringsProvider);
            setState(() {
              _autoPolling = false;
              _autoErrorMsg = s.pairSheetAutoNetError;
            });
            return;
        }
      } on TimeoutException {
        // 35s timeout: server may have dropped the long-poll; just retry
        if (!mounted || _cancelled) return;
      } catch (e) {
        if (!mounted || _cancelled) return;
        final s = ref.read(stringsProvider);
        setState(() {
          _autoPolling = false;
          _autoErrorMsg = s.pairSheetAutoNetError;
        });
        return;
      } finally {
        _pollClient?.close();
        _pollClient = null;
      }
    }
  }

  void _cancelAutoPair() {
    _cancelled = true;
    _pollClient?.close();
    _pollClient = null;
    setState(() => _autoPolling = false);
    Navigator.of(context).pop();
  }

  // ─── PIN pair ─────────────────────────────────────────────────────────────

  Future<void> _pairWithPin() async {
    final pin = _pinCtrl.text.trim();
    if (pin.length != 6) {
      final s = ref.read(stringsProvider);
      setState(() => _errorMsg = s.pairSheetBadPin);
      return;
    }
    setState(() {
      _loading = true;
      _errorMsg = null;
    });
    try {
      final deviceId = await PairedServersNotifier.getOrCreateDeviceId();
      final deviceName = PairedServersNotifier.deviceName;
      final resp = await http
          .post(
            Uri.parse(
                'http://${widget.server.host}:${widget.server.port}/pair/start'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'deviceId': deviceId,
              'deviceName': deviceName,
              'pin': pin,
            }),
          )
          .timeout(const Duration(seconds: 10));

      if (!mounted) return;

      final body = jsonDecode(resp.body) as Map<String, dynamic>;
      if (resp.statusCode == 200 && body['ok'] == true) {
        final deviceToken = body['deviceToken'] as String;
        final serverId =
            body['serverId'] as String? ?? widget.server.serverId;
        await _savePaired(serverId, deviceToken);
      } else {
        final error = body['error'] as String? ?? 'unknown';
        setState(() {
          _loading = false;
          _errorMsg = _pinErrorMessage(error);
        });
      }
    } catch (e) {
      if (!mounted) return;
      final s = ref.read(stringsProvider);
      setState(() {
        _loading = false;
        _errorMsg = s.pairSheetConnFailed;
      });
    }
  }

  String _pinErrorMessage(String error) {
    final s = ref.read(stringsProvider);
    switch (error) {
      case 'bad_pin':
        return s.pairSheetBadPin;
      case 'pairing_closed':
        return s.pairSheetPairingClosed;
      case 'rate_limited':
        return s.pairSheetRateLimited;
      default:
        return s.pairSheetFailed.replaceAll('{error}', error);
    }
  }

  // ─── QR pair ──────────────────────────────────────────────────────────────

  Future<void> _pairWithQr() async {
    final result = await Navigator.of(context).push<PawTermQrResult>(
      MaterialPageRoute(builder: (_) => const QrScanScreen()),
    );
    if (result == null || !mounted) return;

    setState(() {
      _loading = true;
      _errorMsg = null;
    });

    try {
      final deviceId = await PairedServersNotifier.getOrCreateDeviceId();
      final deviceName = PairedServersNotifier.deviceName;
      final resp = await http
          .post(
            Uri.parse('${result.url}/pair/qr-claim'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer ${result.token}',
            },
            body: jsonEncode({
              'deviceId': deviceId,
              'deviceName': deviceName,
            }),
          )
          .timeout(const Duration(seconds: 10));

      if (!mounted) return;

      if (resp.statusCode == 200) {
        final body = jsonDecode(resp.body) as Map<String, dynamic>;
        final deviceToken = body['deviceToken'] as String;
        final serverId =
            body['serverId'] as String? ?? widget.server.serverId;
        await _savePaired(serverId, deviceToken);
      } else {
        final s = ref.read(stringsProvider);
        setState(() {
          _loading = false;
          _errorMsg =
              s.pairSheetFailed.replaceAll('{error}', '${resp.statusCode}');
        });
      }
    } catch (e) {
      if (!mounted) return;
      final s = ref.read(stringsProvider);
      setState(() {
        _loading = false;
        _errorMsg = s.pairSheetConnFailed;
      });
    }
  }

  // ─── Shared ───────────────────────────────────────────────────────────────

  Future<void> _savePaired(String serverId, String deviceToken) async {
    final server = PairedServer(
      serverId: serverId,
      deviceToken: deviceToken,
      name: widget.server.name,
      host: widget.server.host,
      port: widget.server.port,
      lastSeen: DateTime.now(),
    );
    await ref.read(pairedServersProvider.notifier).add(server);
    if (!mounted) return;
    Navigator.of(context).pop(server);
  }

  // ─── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final s = ref.watch(stringsProvider);

    return Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        constraints:
            BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.7),
        decoration: BoxDecoration(
          color: t.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          border: Border.all(color: t.border),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Handle
            Container(
              margin: const EdgeInsets.only(top: 12),
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                  color: t.border, borderRadius: BorderRadius.circular(2)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Pair ${widget.server.name}',
                    style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        color: t.text),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${widget.server.host}:${widget.server.port}  ·  ${widget.server.serverId.substring(widget.server.serverId.length - 6)}',
                    style: TextStyle(fontSize: 12, color: t.textMuted),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            TabBar(
              controller: _tabCtrl,
              labelColor: t.accent,
              unselectedLabelColor: t.textMuted,
              indicatorColor: t.accent,
              indicatorSize: TabBarIndicatorSize.label,
              tabs: [
                Tab(text: s.pairSheetAutoTab),
                Tab(text: s.pairSheetPinTab),
                Tab(text: s.pairSheetQrTab),
              ],
            ),
            const Divider(height: 1),
            Flexible(
              child: TabBarView(
                controller: _tabCtrl,
                children: [
                  _AutoTab(
                    polling: _autoPolling,
                    errorMsg: _autoErrorMsg,
                    onCancel: _cancelAutoPair,
                    onRetry: () {
                      setState(() => _autoErrorMsg = null);
                      _startAutoPair();
                    },
                    t: t,
                    s: s,
                  ),
                  _PinTab(
                    pinCtrl: _pinCtrl,
                    loading: _loading,
                    errorMsg: _errorMsg,
                    onSubmit: _pairWithPin,
                    t: t,
                    s: s,
                  ),
                  _QrTab(
                    loading: _loading,
                    errorMsg: _errorMsg,
                    onTap: _pairWithQr,
                    t: t,
                    s: s,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Auto tab ─────────────────────────────────────────────────────────────────

class _AutoTab extends StatelessWidget {
  final bool polling;
  final String? errorMsg;
  final VoidCallback onCancel;
  final VoidCallback onRetry;
  final AppTokens t;
  final Strings s;

  const _AutoTab({
    required this.polling,
    required this.errorMsg,
    required this.onCancel,
    required this.onRetry,
    required this.t,
    required this.s,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 32, 20, 40),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (polling) ...[
            SizedBox(
              width: 48,
              height: 48,
              child: CircularProgressIndicator(
                strokeWidth: 3,
                color: t.accent,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              s.pairSheetAutoWaiting,
              style: TextStyle(
                  fontSize: 16, fontWeight: FontWeight.w600, color: t.text),
            ),
            const SizedBox(height: 8),
            Text(
              s.pairSheetAutoHint,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: t.textMuted, height: 1.5),
            ),
            const SizedBox(height: 28),
            TextButton(
              onPressed: onCancel,
              child: Text(
                s.pairSheetAutoCancel,
                style: TextStyle(fontSize: 15, color: t.textMuted),
              ),
            ),
          ] else ...[
            if (errorMsg != null) ...[
              Icon(Icons.error_outline_rounded, size: 40, color: t.error),
              const SizedBox(height: 12),
              Text(
                errorMsg!,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, color: t.error, height: 1.5),
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: onRetry,
                style: FilledButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 32, vertical: 12),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
                child: Text(
                  s.genericRetry,
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

// ─── PIN tab ──────────────────────────────────────────────────────────────────

class _PinTab extends StatelessWidget {
  final TextEditingController pinCtrl;
  final bool loading;
  final String? errorMsg;
  final VoidCallback onSubmit;
  final AppTokens t;
  final Strings s;

  const _PinTab({
    required this.pinCtrl,
    required this.loading,
    required this.errorMsg,
    required this.onSubmit,
    required this.t,
    required this.s,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            s.pairSheetPinHint,
            style: TextStyle(fontSize: 13, color: t.textMuted, height: 1.5),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: pinCtrl,
            keyboardType: TextInputType.number,
            maxLength: 6,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            style: TextStyle(
              fontSize: 28,
              letterSpacing: 8,
              fontWeight: FontWeight.w700,
              color: t.text,
            ),
            textAlign: TextAlign.center,
            decoration: InputDecoration(
              hintText: '000000',
              hintStyle:
                  TextStyle(color: t.textDim, letterSpacing: 8, fontSize: 28),
              counterText: '',
            ),
            onSubmitted: (_) => onSubmit(),
          ),
          if (errorMsg != null) ...[
            const SizedBox(height: 12),
            Text(errorMsg!, style: TextStyle(fontSize: 12, color: t.error)),
          ],
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: loading ? null : onSubmit,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
              child: loading
                  ? SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: t.surface),
                    )
                  : Text(s.pairSheetPairBtn,
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w600)),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── QR tab ───────────────────────────────────────────────────────────────────

class _QrTab extends StatelessWidget {
  final bool loading;
  final String? errorMsg;
  final VoidCallback onTap;
  final AppTokens t;
  final Strings s;

  const _QrTab({
    required this.loading,
    required this.errorMsg,
    required this.onTap,
    required this.t,
    required this.s,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 40),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            s.pairSheetPinHint,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: t.textMuted, height: 1.5),
          ),
          const SizedBox(height: 24),
          if (errorMsg != null) ...[
            Text(errorMsg!, style: TextStyle(fontSize: 12, color: t.error)),
            const SizedBox(height: 16),
          ],
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: loading ? null : onTap,
              icon: loading
                  ? SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: t.surface),
                    )
                  : const Icon(Icons.qr_code_scanner_rounded, size: 20),
              label: Text(s.pairSheetQrBtn,
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w600)),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
