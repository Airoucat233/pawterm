import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../i18n/locale_provider.dart';
import '../state/server_config.dart';
import '../theme.dart';
import 'lan_scan_sheet.dart'; // also re-exports LanScanResult
import 'pair_sheet.dart';
import 'qr_scan_screen.dart';

const _emojis = ['🖥️', '💻', '☁️', '🌐', '🏢', '🚀', '⚡', '🔧'];

enum _SheetState { input, detecting, detected, error }

class AddConnectionSheet extends ConsumerStatefulWidget {
  final ServerEntry? editing;
  const AddConnectionSheet({super.key, this.editing});

  @override
  ConsumerState<AddConnectionSheet> createState() => _AddConnectionSheetState();
}

class _AddConnectionSheetState extends ConsumerState<AddConnectionSheet> {
  late final TextEditingController _ipCtrl;
  late final TextEditingController _portCtrl;
  late final TextEditingController _nameCtrl;
  late String _emoji;

  _SheetState _phase = _SheetState.input;
  String? _detectedName;
  String? _detectedVersion;
  String? _errorMsg;

  @override
  void initState() {
    super.initState();
    final e = widget.editing;
    if (e != null) {
      // Reconstruct IP and port from the stored URL
      final uri = Uri.tryParse(e.url);
      _ipCtrl = TextEditingController(text: uri?.host ?? e.url.replaceFirst(RegExp(r'^https?://'), '').split(':').first);
      _portCtrl = TextEditingController(text: uri?.port != null && uri!.port != 0 ? '${uri.port}' : '8765');
      _phase = _SheetState.detected;
    } else {
      _ipCtrl = TextEditingController();
      _portCtrl = TextEditingController(text: '8765');
    }
    _nameCtrl = TextEditingController(text: e?.name ?? '');
    _emoji = e?.emoji ?? '🖥️';
  }

  @override
  void dispose() {
    _ipCtrl.dispose();
    _portCtrl.dispose();
    _nameCtrl.dispose();
    super.dispose();
  }

  String get _normalizedUrl {
    var ip = _ipCtrl.text.trim();
    final port = int.tryParse(_portCtrl.text.trim()) ?? 8765;
    if (ip.isEmpty) return '';
    if (!kIsWeb && Platform.isAndroid) {
      ip = ip.replaceFirst(RegExp(r'^localhost$'), '10.0.2.2');
    }
    return 'http://$ip:$port';
  }

  Future<void> _detect() async {
    final url = _normalizedUrl;
    if (url.isEmpty) return;

    setState(() {
      _phase = _SheetState.detecting;
      _errorMsg = null;
    });

    try {
      final res = await http
          .get(Uri.parse('$url/health'))
          .timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        final body = jsonDecode(res.body) as Map<String, dynamic>;
        final hostname = body['hostname'] as String? ?? _ipCtrl.text.trim();
        final version = body['version'] as String? ?? '';
        setState(() {
          _detectedName = hostname;
          _detectedVersion = version;
          _nameCtrl.text = hostname;
          _phase = _SheetState.detected;
        });
      } else {
        final s = ref.read(stringsProvider);
        setState(() {
          _errorMsg = s.addConnectionServerReturnedTpl
              .replaceAll('{code}', '${res.statusCode}');
          _phase = _SheetState.error;
        });
      }
    } catch (e) {
      final s = ref.read(stringsProvider);
      setState(() {
        _errorMsg = s.addConnectionUnreachable;
        _phase = _SheetState.error;
      });
    }
  }

  Future<void> _save() async {
    // Used only when editing an existing connection (no pairing).
    final url = _normalizedUrl;
    final name = _nameCtrl.text.trim().isNotEmpty
        ? _nameCtrl.text.trim()
        : (_detectedName ?? _ipCtrl.text.trim());
    final notifier = ref.read(connectionsProvider.notifier);
    if (widget.editing != null) {
      await notifier.update(widget.editing!.copyWith(
        name: name,
        emoji: _emoji,
        url: url,
      ));
    }
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _openPairSheet() async {
    final host = _ipCtrl.text.trim();
    final port = int.tryParse(_portCtrl.text.trim()) ?? 8765;
    final scanResult = LanScanResult(
      serverId: '',
      name: _detectedName ?? host,
      host: host,
      port: port,
      version: _detectedVersion ?? '',
      pairingOpen: true,
    );
    final result = await showModalBottomSheet<PairedServer>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => PairSheet(server: scanResult),
    );
    if (result == null || !mounted) return;
    // PairSheet already saved to pairedServersProvider; create ServerEntry here
    final notifier = ref.read(connectionsProvider.notifier);
    await notifier.add(
      name: result.name,
      emoji: '🖥️',
      url: result.httpBase,
      token: result.deviceToken,
    );
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _openQrScan() async {
    final result = await Navigator.of(context).push<PawTermQrResult>(
      MaterialPageRoute(builder: (_) => const QrScanScreen()),
    );
    if (result == null || !mounted) return;

    // QR gives adminToken — call qr-claim directly, no PairSheet needed
    setState(() { _phase = _SheetState.detecting; _errorMsg = null; });
    try {
      final deviceId = await PairedServersNotifier.getOrCreateDeviceId();
      final deviceName = PairedServersNotifier.deviceName;
      final claimResp = await http.post(
        Uri.parse('${result.url}/pair/qr-claim'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${result.token}',
        },
        body: jsonEncode({'deviceId': deviceId, 'deviceName': deviceName}),
      ).timeout(const Duration(seconds: 10));
      if (!mounted) return;
      if (claimResp.statusCode == 200) {
        final body = jsonDecode(claimResp.body) as Map<String, dynamic>;
        final deviceToken = body['deviceToken'] as String;
        final serverId = body['serverId'] as String? ?? '';
        // Get hostname from /health
        String name = result.url.replaceFirst(RegExp(r'^https?://'), '').split(':').first;
        try {
          final healthResp = await http.get(Uri.parse('${result.url}/health'))
              .timeout(const Duration(seconds: 5));
          if (healthResp.statusCode == 200) {
            final h = jsonDecode(healthResp.body) as Map<String, dynamic>;
            name = h['hostname'] as String? ?? name;
          }
        } catch (_) {}
        final uri = Uri.tryParse(result.url);
        final server = PairedServer(
          serverId: serverId,
          deviceToken: deviceToken,
          name: name,
          host: uri?.host ?? name,
          port: uri?.port ?? 8765,
          lastSeen: DateTime.now(),
        );
        await ref.read(pairedServersProvider.notifier).add(server);
        await ref.read(connectionsProvider.notifier).add(
          name: name, emoji: '🖥️', url: result.url, token: deviceToken,
        );
        if (mounted) Navigator.of(context).pop();
      } else {
        final s = ref.read(stringsProvider);
        setState(() {
          _errorMsg = s.addConnectionServerReturnedTpl.replaceAll('{code}', '${claimResp.statusCode}');
          _phase = _SheetState.error;
        });
      }
    } catch (e) {
      if (!mounted) return;
      final s = ref.read(stringsProvider);
      setState(() { _errorMsg = s.addConnectionUnreachable; _phase = _SheetState.error; });
    }
  }

  Future<void> _openLanScan() async {
    final result = await showModalBottomSheet<Object>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const LanScanSheet(),
    );
    if (result == null || !mounted) return;

    if (result is PairedServer) {
      final notifier = ref.read(connectionsProvider.notifier);
      await notifier.add(
        name: result.name,
        emoji: '🖥️',
        url: result.httpBase,
        token: result.deviceToken,
      );
      if (mounted) Navigator.of(context).pop();
      return;
    }

    if (result is LanScanResult) {
      final paired = ref
          .read(pairedServersProvider)
          .where((s) => s.serverId == result.serverId)
          .firstOrNull;
      if (paired != null) {
        final notifier = ref.read(connectionsProvider.notifier);
        await notifier.add(
          name: paired.name,
          emoji: '🖥️',
          url: paired.httpBase,
          token: paired.deviceToken,
        );
        if (mounted) Navigator.of(context).pop();
      } else {
        _ipCtrl.text = result.host;
        _portCtrl.text = '${result.port}';
        _detectedName = result.name;
        _detectedVersion = result.version;
        _nameCtrl.text = result.name;
        setState(() => _phase = _SheetState.input);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final s = ref.watch(stringsProvider);
    final isEditing = widget.editing != null;

    return Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: BoxDecoration(
          color: t.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          border: Border.all(color: t.border),
        ),
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 40),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                      color: t.border,
                      borderRadius: BorderRadius.circular(2)),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                isEditing
                    ? s.addConnectionEditTitle
                    : s.addConnectionTitle,
                style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: t.text),
              ),
              const SizedBox(height: 20),

              // Quick-connect buttons (only when adding new)
              if (!isEditing) ...[
                Row(children: [
                  Expanded(
                    child: _ActionButton(
                      icon: Icons.wifi_find_rounded,
                      label: s.addConnectionFindLan,
                      onTap: _openLanScan,
                      t: t,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _ActionButton(
                      icon: Icons.qr_code_scanner_rounded,
                      label: s.addConnectionScanQr,
                      onTap: _openQrScan,
                      t: t,
                    ),
                  ),
                ]),
                const SizedBox(height: 20),
                Row(children: [
                  Expanded(child: Divider(color: t.border)),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Text(s.addConnectionOrManual,
                        style: TextStyle(fontSize: 12, color: t.textDim)),
                  ),
                  Expanded(child: Divider(color: t.border)),
                ]),
                const SizedBox(height: 16),
              ],

              // IP + Port side-by-side
              _Label(s.addConnectionUrl),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _ipCtrl,
                      enabled: _phase == _SheetState.input ||
                          _phase == _SheetState.error ||
                          isEditing,
                      keyboardType: TextInputType.url,
                      style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 13,
                          color: t.text),
                      decoration: InputDecoration(
                        hintText: s.addConnectionUrlHintLan,
                      ),
                      onChanged: (_) {
                        if (_phase == _SheetState.error) {
                          setState(() => _phase = _SheetState.input);
                        }
                      },
                      onSubmitted: (_) {
                        if (_phase == _SheetState.input ||
                            _phase == _SheetState.error) {
                          _detect();
                        }
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 72,
                    child: TextField(
                      controller: _portCtrl,
                      enabled: _phase == _SheetState.input ||
                          _phase == _SheetState.error ||
                          isEditing,
                      keyboardType: TextInputType.number,
                      style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 13,
                          color: t.text),
                      decoration: InputDecoration(
                        hintText: s.addConnectionPort,
                      ),
                      onChanged: (_) {
                        if (_phase == _SheetState.error) {
                          setState(() => _phase = _SheetState.input);
                        }
                      },
                      onSubmitted: (_) {
                        if (_phase == _SheetState.input ||
                            _phase == _SheetState.error) {
                          _detect();
                        }
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(s.addConnectionPortNote,
                  style: TextStyle(fontSize: 11, color: t.textDim)),
              const SizedBox(height: 14),

              // Detecting indicator
              if (_phase == _SheetState.detecting) ...[
                Row(children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: t.accent),
                  ),
                  const SizedBox(width: 10),
                  Text(s.addConnectionDetecting,
                      style: TextStyle(fontSize: 13, color: t.textMuted)),
                ]),
                const SizedBox(height: 20),
              ],

              // Error
              if (_phase == _SheetState.error && _errorMsg != null) ...[
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: t.error.withValues(alpha: 0.08),
                    border: Border.all(
                        color: t.error.withValues(alpha: 0.25)),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(children: [
                    Icon(Icons.error_outline, size: 14, color: t.error),
                    const SizedBox(width: 8),
                    Expanded(
                        child: Text(_errorMsg!,
                            style: TextStyle(
                                fontSize: 12, color: t.error))),
                  ]),
                ),
                const SizedBox(height: 16),
              ],

              // Detected result + name + emoji
              if (_phase == _SheetState.detected) ...[
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: t.accent.withValues(alpha: 0.07),
                    border: Border.all(
                        color: t.accent.withValues(alpha: 0.2)),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(children: [
                    Icon(Icons.check_circle_outline,
                        size: 14, color: t.accent),
                    const SizedBox(width: 8),
                    Text(
                      s.addConnectionDetectedTpl.replaceAll(
                          '{ver}',
                          _detectedVersion != null
                              ? ' · v$_detectedVersion'
                              : ''),
                      style:
                          TextStyle(fontSize: 12, color: t.accent),
                    ),
                  ]),
                ),
                const SizedBox(height: 16),

                _Label(s.addConnectionName),
                TextField(
                  controller: _nameCtrl,
                  style: TextStyle(fontSize: 14, color: t.text),
                  decoration: InputDecoration(
                      hintText: s.addConnectionNameNicknameHint),
                ),
                const SizedBox(height: 16),

                _Label(s.addConnectionEmoji),
                _EmojiPicker(
                  selected: _emoji,
                  onSelect: (e) => setState(() => _emoji = e),
                ),
                const SizedBox(height: 20),
              ],

              // Actions
              Row(children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    style: OutlinedButton.styleFrom(
                      padding:
                          const EdgeInsets.symmetric(vertical: 13),
                      side: BorderSide(color: t.border),
                      foregroundColor: t.textMuted,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                    child: Text(s.addConnectionCancel,
                        style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600)),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 2,
                  child: FilledButton(
                    onPressed: _phase == _SheetState.detecting
                        ? null
                        : () {
                            FocusScope.of(context).unfocus();
                            if (_phase == _SheetState.detected) {
                              if (isEditing) {
                                _save();
                              } else {
                                _openPairSheet();
                              }
                            } else {
                              _detect();
                            }
                          },
                    style: FilledButton.styleFrom(
                      padding:
                          const EdgeInsets.symmetric(vertical: 13),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                    child: Text(
                      _phase == _SheetState.detected
                          ? (isEditing
                              ? s.addConnectionSave
                              : s.addConnectionPairConnect)
                          : s.addConnectionConnectBtn,
                      style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final AppTokens t;

  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
    required this.t,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: t.surfaceHi,
          border: Border.all(color: t.border),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          children: [
            Icon(icon, size: 24, color: t.accent),
            const SizedBox(height: 6),
            Text(
              label,
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: t.textMuted),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _Label extends StatelessWidget {
  final String text;
  const _Label(this.text);

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(text,
          style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: t.textMuted)),
    );
  }
}

class _EmojiPicker extends StatelessWidget {
  final String selected;
  final ValueChanged<String> onSelect;
  const _EmojiPicker({required this.selected, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: _emojis.map((e) {
        final isSelected = e == selected;
        return GestureDetector(
          onTap: () => onSelect(e),
          child: Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: isSelected ? t.accentSubt : t.surfaceHi,
              border: Border.all(
                color: isSelected
                    ? t.accent.withValues(alpha: 0.5)
                    : t.border,
                width: isSelected ? 1.5 : 1,
              ),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Center(
                child: Text(e, style: const TextStyle(fontSize: 20))),
          ),
        );
      }).toList(),
    );
  }
}
