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

/// Single-page sequential pairing flow.
/// Returns a [Connection] when pairing succeeds, or null when cancelled.
class PairSheet extends ConsumerStatefulWidget {
  final LanScanResult server;

  /// 当配对成功时是否跳过自带的成功页面（名称编辑）直接 pop 返回。
  /// 调用方需要自己提供 post-pair 的成功页面时使用。
  final bool skipSuccess;

  const PairSheet({super.key, required this.server, this.skipSuccess = false});

  @override
  ConsumerState<PairSheet> createState() => _PairSheetState();
}

enum _PairPhase {
  autoWaiting, // spinner — waiting for auto-pair approval
  autoDenied, // denied — show "Use PIN instead" button
  pinInput, // 6-box OTP input
  pinLoading, // spinner while submitting PIN
  success, // green check + name edit + Done button
}

class _PairSheetState extends ConsumerState<PairSheet> {
  _PairPhase _phase = _PairPhase.autoWaiting;

  // Auto-pair
  bool _cancelled = false;
  http.Client? _pollClient;

  // PIN OTP
  final _pinFocusNode = FocusNode();
  final _pinCtrl = TextEditingController();
  String? _pinError;

  // Success state
  Connection? _savedConn;
  late final TextEditingController _nameCtrl;
  String _serverName = '';

  @override
  void initState() {
    super.initState();
    _serverName = widget.server.name;
    _nameCtrl = TextEditingController(text: _serverName);
    WidgetsBinding.instance.addPostFrameCallback((_) => _startAutoPair());
  }

  @override
  void dispose() {
    _cancelled = true;
    _pollClient?.close();
    _pinCtrl.dispose();
    _pinFocusNode.dispose();
    _nameCtrl.dispose();
    super.dispose();
  }

  // ─── Auto-pair ─────────────────────────────────────────────────────────────

  Future<void> _startAutoPair() async {
    if (!mounted) return;
    setState(() {
      _phase = _PairPhase.autoWaiting;
      _cancelled = false;
    });

    try {
      final deviceId = await ConnectionsNotifier.getOrCreateDeviceId();
      final deviceName = await ConnectionsNotifier.getDeviceName();

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
        // Old server — silently fall to PIN input
        setState(() => _phase = _PairPhase.pinInput);
        return;
      }

      if (resp.statusCode != 200) {
        // Any other error — silently fall to PIN input
        setState(() => _phase = _PairPhase.pinInput);
        return;
      }

      final body = jsonDecode(resp.body) as Map<String, dynamic>;
      final pollUrl = body['pollUrl'] as String;

      await _pollLoop(pollUrl);
    } catch (e) {
      if (!mounted || _cancelled) return;
      // Network error — fall to PIN input silently
      setState(() => _phase = _PairPhase.pinInput);
    }
  }

  Future<void> _pollLoop(String pollUrl) async {
    while (mounted && !_cancelled) {
      _pollClient = http.Client();
      try {
        final req = http.Request('GET', Uri.parse(pollUrl));
        final streamedResp =
            await _pollClient!.send(req).timeout(const Duration(seconds: 35));

        final bodyBytes = await streamedResp.stream.toBytes();
        if (!mounted || _cancelled) return;

        if (streamedResp.statusCode != 200) {
          if (mounted) setState(() => _phase = _PairPhase.pinInput);
          return;
        }

        final body = jsonDecode(utf8.decode(bodyBytes)) as Map<String, dynamic>;
        final status = body['status'] as String?;

        switch (status) {
          case 'pending':
            break; // continue polling
          case 'approved':
            final deviceToken = body['deviceToken'] as String;
            final serverId =
                body['serverId'] as String? ?? widget.server.serverId;
            await _saveImmediately(serverId, deviceToken);
            return;
          case 'denied':
            if (mounted) setState(() => _phase = _PairPhase.autoDenied);
            return;
          case 'expired':
            // Fall to PIN input silently
            if (mounted) setState(() => _phase = _PairPhase.pinInput);
            return;
          default:
            if (mounted) setState(() => _phase = _PairPhase.pinInput);
            return;
        }
      } on TimeoutException {
        // 35s timeout: long-poll dropped; retry
        if (!mounted || _cancelled) return;
      } catch (e) {
        if (!mounted || _cancelled) return;
        setState(() => _phase = _PairPhase.pinInput);
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
    if (mounted) Navigator.of(context).pop();
  }

  // ─── Save on approval ──────────────────────────────────────────────────────

  Future<void> _saveImmediately(String serverId, String deviceToken) async {
    final url = 'http://${widget.server.host}:${widget.server.port}';

    // Check for existing Connection with same serverId (re-pair case)
    final existing = ref
        .read(connectionsProvider)
        .where((c) => c.serverId == serverId)
        .firstOrNull;

    late final Connection conn;
    if (existing != null) {
      final notifier = ref.read(connectionsProvider.notifier);
      final updated = await notifier.updateUrl(existing.id, url) ?? existing;
      conn = updated.copyWith(
        token: deviceToken,
        lastSeen: DateTime.now(),
      );
      await notifier.update(conn);
    } else {
      conn = Connection(
        id: ConnectionsNotifier.newId(),
        name: widget.server.name,
        emoji: '🖥️',
        url: url,
        token: deviceToken,
        serverId: serverId,
        lastSeen: DateTime.now(),
      );
      await ref.read(connectionsProvider.notifier).add(conn);
    }

    if (!mounted) return;
    if (widget.skipSuccess) {
      Navigator.of(context).pop(conn);
      return;
    }
    setState(() {
      _savedConn = conn;
      _serverName = widget.server.name;
      _nameCtrl.text = _serverName;
      _phase = _PairPhase.success;
    });
  }

  // ─── PIN pair ──────────────────────────────────────────────────────────────

  Future<void> _pairWithPin() async {
    final pin = _pinCtrl.text.trim();
    if (pin.length != 6) {
      final s = ref.read(stringsProvider);
      setState(() => _pinError = s.pairSheetBadPin);
      return;
    }
    setState(() {
      _phase = _PairPhase.pinLoading;
      _pinError = null;
    });
    try {
      final deviceId = await ConnectionsNotifier.getOrCreateDeviceId();
      final deviceName = await ConnectionsNotifier.getDeviceName();
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
        final serverId = body['serverId'] as String? ?? widget.server.serverId;
        await _saveImmediately(serverId, deviceToken);
      } else {
        final error = body['error'] as String? ?? 'unknown';
        setState(() {
          _phase = _PairPhase.pinInput;
          _pinError = _pinErrorMessage(error);
        });
      }
    } catch (e) {
      if (!mounted) return;
      final s = ref.read(stringsProvider);
      setState(() {
        _phase = _PairPhase.pinInput;
        _pinError = s.pairSheetConnFailed;
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

  // ─── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final s = ref.watch(stringsProvider);

    return Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.75),
        decoration: BoxDecoration(
          color: t.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          border: Border.all(color: t.border),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Handle bar
            Container(
              margin: const EdgeInsets.only(top: 12),
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                  color: t.border, borderRadius: BorderRadius.circular(2)),
            ),
            // Header
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
                    '${widget.server.host}:${widget.server.port}'
                    '${widget.server.serverId.isNotEmpty ? '  ·  ${widget.server.serverId.length >= 6 ? widget.server.serverId.substring(widget.server.serverId.length - 6) : widget.server.serverId}' : ''}',
                    style: TextStyle(fontSize: 12, color: t.textMuted),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            const Divider(height: 1),
            // Body
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 24, 20, 40),
                child: _buildPhaseBody(t, s),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPhaseBody(AppTokens t, Strings s) {
    switch (_phase) {
      case _PairPhase.autoWaiting:
        return _buildAutoWaiting(t, s);
      case _PairPhase.autoDenied:
        return _buildAutoDenied(t, s);
      case _PairPhase.pinInput:
        return _buildPinInput(t, s);
      case _PairPhase.pinLoading:
        return _buildSpinner(t, s.pairSheetPairBtn);
      case _PairPhase.success:
        return _buildSuccess(t, s);
    }
  }

  // ─── Auto waiting ──────────────────────────────────────────────────────────

  Widget _buildAutoWaiting(AppTokens t, Strings s) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const SizedBox(height: 8),
        SizedBox(
          width: 48,
          height: 48,
          child: CircularProgressIndicator(strokeWidth: 3, color: t.accent),
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
        const SizedBox(height: 32),
        TextButton(
          onPressed: _cancelAutoPair,
          child: Text(
            s.pairSheetAutoCancel,
            style: TextStyle(fontSize: 15, color: t.textMuted),
          ),
        ),
      ],
    );
  }

  // ─── Auto denied ───────────────────────────────────────────────────────────

  Widget _buildAutoDenied(AppTokens t, Strings s) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const SizedBox(height: 8),
        Icon(Icons.block_rounded, size: 44, color: t.error),
        const SizedBox(height: 16),
        Text(
          s.pairSheetAutoDenied,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 15, color: t.text, height: 1.5),
        ),
        const SizedBox(height: 32),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: () {
              _pinCtrl.clear();
              setState(() {
                _pinError = null;
                _phase = _PairPhase.pinInput;
              });
            },
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            child: Text(
              s.pairSheetUsePinInstead,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
          ),
        ),
        const SizedBox(height: 12),
        TextButton(
          onPressed: _cancelAutoPair,
          child: Text(
            s.pairSheetAutoCancel,
            style: TextStyle(fontSize: 14, color: t.textMuted),
          ),
        ),
      ],
    );
  }

  // ─── PIN input (6-box OTP) ─────────────────────────────────────────────────

  Widget _buildPinInput(AppTokens t, Strings s) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          s.pairSheetPinHint,
          style: TextStyle(fontSize: 13, color: t.textMuted, height: 1.5),
        ),
        const SizedBox(height: 20),
        // 6-box OTP widget
        _OtpBoxes(
          controller: _pinCtrl,
          focusNode: _pinFocusNode,
          t: t,
          onCompleted: (_) => _pairWithPin(),
        ),
        if (_pinError != null) ...[
          const SizedBox(height: 10),
          Text(_pinError!, style: TextStyle(fontSize: 12, color: t.error)),
        ],
        const SizedBox(height: 24),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: _pairWithPin,
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            child: Text(
              s.pairSheetPairBtn,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
          ),
        ),
      ],
    );
  }

  // ─── Generic spinner ───────────────────────────────────────────────────────

  Widget _buildSpinner(AppTokens t, String label) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const SizedBox(height: 16),
        SizedBox(
          width: 44,
          height: 44,
          child: CircularProgressIndicator(strokeWidth: 3, color: t.accent),
        ),
        const SizedBox(height: 16),
        Text(
          label,
          style: TextStyle(fontSize: 14, color: t.textMuted),
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  // ─── Success ───────────────────────────────────────────────────────────────

  Widget _buildSuccess(AppTokens t, Strings s) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Center(
          child: Column(
            children: [
              const SizedBox(height: 8),
              Icon(Icons.check_circle_rounded, size: 56, color: t.success),
              const SizedBox(height: 14),
              Text(
                s.pairSheetSuccess,
                style: TextStyle(
                    fontSize: 20, fontWeight: FontWeight.w700, color: t.text),
              ),
              const SizedBox(height: 4),
              Text(
                '${widget.server.host}:${widget.server.port}',
                style: TextStyle(fontSize: 13, color: t.textMuted),
              ),
            ],
          ),
        ),
        const SizedBox(height: 28),
        // Name label + text field
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text(
            s.pairSheetNameLabel,
            style: TextStyle(
                fontSize: 12, fontWeight: FontWeight.w500, color: t.textMuted),
          ),
        ),
        TextField(
          controller: _nameCtrl,
          style: TextStyle(fontSize: 14, color: t.text),
          decoration: InputDecoration(hintText: widget.server.name),
          onChanged: (v) => setState(() => _serverName = v),
        ),
        const SizedBox(height: 24),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: _onDone,
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            child: Text(
              s.pairSheetDone,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _onDone() async {
    final saved = _savedConn;
    if (saved == null) {
      Navigator.of(context).pop();
      return;
    }
    Connection result = saved;
    final newName = _nameCtrl.text.trim();
    if (newName.isNotEmpty && newName != saved.name) {
      result = saved.copyWith(name: newName);
      await ref.read(connectionsProvider.notifier).update(result);
    }
    if (mounted) Navigator.of(context).pop(result);
  }
}

// ─── 6-box OTP widget ──────────────────────────────────────────────────────────

class _OtpBoxes extends StatefulWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final AppTokens t;
  final ValueChanged<String> onCompleted;

  const _OtpBoxes({
    required this.controller,
    required this.focusNode,
    required this.t,
    required this.onCompleted,
  });

  @override
  State<_OtpBoxes> createState() => _OtpBoxesState();
}

class _OtpBoxesState extends State<_OtpBoxes> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    setState(() {});
    if (widget.controller.text.length == 6) {
      widget.onCompleted(widget.controller.text);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.t;
    final value = widget.controller.text;
    const boxW = 44.0;
    const boxH = 54.0;

    return GestureDetector(
      onTap: () => widget.focusNode.requestFocus(),
      child: Stack(
        children: [
          // Visible boxes
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: List.generate(6, (i) {
              final hasChar = i < value.length;
              final isCursor = i == value.length && value.length < 6;
              return Container(
                width: boxW,
                height: boxH,
                decoration: BoxDecoration(
                  color: t.surfaceHi,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: isCursor
                        ? t.accent
                        : hasChar
                            ? t.border
                            : t.border,
                    width: isCursor ? 1.8 : 1.0,
                  ),
                ),
                alignment: Alignment.center,
                child: hasChar
                    ? Text(
                        value[i],
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                          color: t.text,
                        ),
                      )
                    : null,
              );
            }),
          ),
          // Hidden full-width TextField capturing actual input
          Opacity(
            opacity: 0,
            child: TextField(
              controller: widget.controller,
              focusNode: widget.focusNode,
              keyboardType: TextInputType.number,
              maxLength: 6,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(counterText: ''),
              autofocus: true,
            ),
          ),
        ],
      ),
    );
  }
}
