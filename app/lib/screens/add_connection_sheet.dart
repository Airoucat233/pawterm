import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../config/build_defaults.dart';
import '../i18n/locale_provider.dart';
import '../state/connection_url.dart';
import '../state/server_config.dart';
import '../theme.dart';
import 'lan_scan_sheet.dart'; // also re-exports LanScanResult
import 'pair_sheet.dart';
import 'qr_scan_screen.dart';

const _emojis = ['🖥️', '💻', '☁️', '🌐', '🏢', '🚀', '⚡', '🔧'];

enum _SheetState { input, detecting, detected, error }

class AddConnectionSheet extends ConsumerStatefulWidget {
  final Connection? editing;
  const AddConnectionSheet({super.key, this.editing});

  @override
  ConsumerState<AddConnectionSheet> createState() => _AddConnectionSheetState();
}

class _AddConnectionSheetState extends ConsumerState<AddConnectionSheet> {
  late final TextEditingController _ipCtrl;
  late final TextEditingController _portCtrl;
  late final TextEditingController _nameCtrl;
  late String _emoji;
  String _scheme = defaultConnectionScheme;

  _SheetState _phase = _SheetState.input;
  String? _detectedName;
  String? _detectedVersion;
  String? _errorMsg;
  // 配对成功后保存下来的设备凭据；新建连接路径下 detected 状态依赖它判定来源。
  Connection? _pairedConn;

  @override
  void initState() {
    super.initState();
    final e = widget.editing;
    if (e != null) {
      final parts = parseConnectionUrlInput(input: e.url);
      _scheme = parts?.scheme ?? defaultConnectionScheme;
      _ipCtrl = TextEditingController(text: parts?.host ?? e.url);
      _portCtrl = TextEditingController(
          text: '${parts?.port ?? BuildDefaults.defaultServerPort}');
      _phase = _SheetState.detected;
    } else {
      _ipCtrl = TextEditingController();
      _portCtrl =
          TextEditingController(text: '${BuildDefaults.defaultServerPort}');
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
    return _currentUrlParts?.baseUrl ?? '';
  }

  ConnectionUrlParts? get _currentUrlParts {
    return parseConnectionFields(
      scheme: _scheme,
      hostInput: _ipCtrl.text,
      portInput: _portCtrl.text,
    );
  }

  void _maybeApplyPastedUrl(String value) {
    final raw = value.trim();
    if (!raw.startsWith('http://') && !raw.startsWith('https://')) return;
    final parts = parseConnectionUrlInput(input: raw);
    if (parts == null) return;
    _ipCtrl.value = TextEditingValue(
      text: parts.host,
      selection: TextSelection.collapsed(offset: parts.host.length),
    );
    _portCtrl.text = '${parts.port}';
    setState(() {
      _scheme = parts.scheme;
      if (_phase == _SheetState.error) _phase = _SheetState.input;
    });
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
        _detectedName = hostname;
        _detectedVersion = version;
        if (widget.editing != null) {
          // 编辑模式：保留原 detected 状态，允许改名称/图标。
          setState(() {
            _nameCtrl.text = hostname;
            _phase = _SheetState.detected;
          });
        } else {
          // 新建连接：探测成功立即进入配对流程，配对成功后才显示名称+图标编辑。
          await _openPairSheet();
        }
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
    final parts = _currentUrlParts;
    if (parts == null) return;
    final scanResult = LanScanResult(
      serverId: '',
      name: _detectedName ?? parts.host,
      host: parts.host,
      port: parts.port,
      scheme: parts.scheme,
      version: _detectedVersion ?? '',
      pairingOpen: true,
    );
    final result = await showModalBottomSheet<Connection>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => PairSheet(server: scanResult, skipSuccess: true),
    );
    if (!mounted) return;
    if (result == null) {
      // 用户取消配对：回到输入态，方便重试或改 IP。
      setState(() => _phase = _SheetState.input);
      return;
    }
    // 配对成功 → 进入 detected 状态，允许用户改名称+图标，再点"保存"落库。
    setState(() {
      _pairedConn = result;
      _nameCtrl.text = result.name;
      _emoji = result.emoji;
      _phase = _SheetState.detected;
    });
  }

  Future<void> _saveAndClose() async {
    final paired = _pairedConn;
    if (paired == null) return;
    final name =
        _nameCtrl.text.trim().isNotEmpty ? _nameCtrl.text.trim() : paired.name;
    // Only update if name/emoji changed from what PairSheet saved
    if (name != paired.name || _emoji != paired.emoji) {
      await ref.read(connectionsProvider.notifier).update(
            paired.copyWith(name: name, emoji: _emoji),
          );
    }
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _openQrScan() async {
    final result = await Navigator.of(context).push<PawTermQrResult>(
      MaterialPageRoute(builder: (_) => const QrScanScreen()),
    );
    if (result == null || !mounted) return;

    setState(() {
      _phase = _SheetState.detecting;
      _errorMsg = null;
    });
    try {
      final deviceId = await ConnectionsNotifier.getOrCreateDeviceId();
      final deviceName = await ConnectionsNotifier.getDeviceName();
      final claimResp = await http
          .post(
            Uri.parse('${result.url}/api/pair/qr-claim'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'deviceId': deviceId,
              'deviceName': deviceName,
              'claim': result.claim,
            }),
          )
          .timeout(const Duration(seconds: 10));
      if (!mounted) return;
      if (claimResp.statusCode == 200) {
        final body = jsonDecode(claimResp.body) as Map<String, dynamic>;
        final deviceToken = body['deviceToken'] as String;
        final serverId = body['serverId'] as String? ?? '';

        String name = Uri.tryParse(result.url)?.host ??
            result.url.replaceFirst(RegExp(r'^https?://'), '').split(':').first;
        try {
          final healthResp = await http
              .get(Uri.parse('${result.url}/health'))
              .timeout(const Duration(seconds: 5));
          if (healthResp.statusCode == 200) {
            final h = jsonDecode(healthResp.body) as Map<String, dynamic>;
            name = h['hostname'] as String? ?? name;
          }
        } catch (_) {}

        // Check for existing connection with same serverId
        final existing = ref
            .read(connectionsProvider)
            .where((c) => c.serverId == serverId)
            .firstOrNull;
        if (existing != null) {
          final notifier = ref.read(connectionsProvider.notifier);
          final updated =
              await notifier.updateUrl(existing.id, result.url) ?? existing;
          await notifier.update(
            updated.copyWith(token: deviceToken, lastSeen: DateTime.now()),
          );
        } else {
          await ref.read(connectionsProvider.notifier).add(Connection(
                id: ConnectionsNotifier.newId(),
                name: name,
                emoji: '🖥️',
                url: result.url,
                token: deviceToken,
                serverId: serverId.isNotEmpty ? serverId : null,
                lastSeen: DateTime.now(),
              ));
        }
        if (mounted) Navigator.of(context).pop();
      } else {
        final s = ref.read(stringsProvider);
        setState(() {
          _errorMsg = s.addConnectionServerReturnedTpl
              .replaceAll('{code}', '${claimResp.statusCode}');
          _phase = _SheetState.error;
        });
      }
    } catch (e) {
      if (!mounted) return;
      final s = ref.read(stringsProvider);
      setState(() {
        _errorMsg = s.addConnectionUnreachable;
        _phase = _SheetState.error;
      });
    }
  }

  Future<void> _openLanScan() async {
    await showModalBottomSheet<Connection>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const LanScanSheet(),
    );
    // Connection already saved to store by PairSheet or LanScanSheet.
    // Just close this sheet regardless of whether we got a result.
    if (mounted) Navigator.of(context).pop();
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
                      color: t.border, borderRadius: BorderRadius.circular(2)),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                isEditing ? s.addConnectionEditTitle : s.addConnectionTitle,
                style: TextStyle(
                    fontSize: 17, fontWeight: FontWeight.w700, color: t.text),
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

              // Scheme + host + port.
              _Label(s.addConnectionUrl),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 96,
                    child: DropdownButtonFormField<String>(
                      value: _scheme,
                      items: const [
                        DropdownMenuItem(value: 'http', child: Text('http://')),
                        DropdownMenuItem(
                            value: 'https', child: Text('https://')),
                      ],
                      onChanged: (_phase == _SheetState.input ||
                              _phase == _SheetState.error ||
                              isEditing)
                          ? (value) {
                              if (value == null) return;
                              setState(() {
                                _scheme = value;
                                _portCtrl.text =
                                    '${defaultPortForScheme(value)}';
                                if (_phase == _SheetState.error) {
                                  _phase = _SheetState.input;
                                }
                              });
                            }
                          : null,
                      style: TextStyle(
                          fontFamily: 'monospace', fontSize: 13, color: t.text),
                      decoration: const InputDecoration(
                        contentPadding:
                            EdgeInsets.symmetric(horizontal: 10, vertical: 13),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _ipCtrl,
                      enabled: _phase == _SheetState.input ||
                          _phase == _SheetState.error ||
                          isEditing,
                      keyboardType: TextInputType.url,
                      style: TextStyle(
                          fontFamily: 'monospace', fontSize: 13, color: t.text),
                      decoration: InputDecoration(
                        hintText: s.addConnectionUrlHintLan,
                      ),
                      onChanged: (value) {
                        _maybeApplyPastedUrl(value);
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
                          fontFamily: 'monospace', fontSize: 13, color: t.text),
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
              Text(
                  s.addConnectionPortNote.replaceAll(
                      '{port}', '${BuildDefaults.defaultServerPort}'),
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
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: t.error.withValues(alpha: 0.08),
                    border: Border.all(color: t.error.withValues(alpha: 0.25)),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(children: [
                    Icon(Icons.error_outline, size: 14, color: t.error),
                    const SizedBox(width: 8),
                    Expanded(
                        child: Text(_errorMsg!,
                            style: TextStyle(fontSize: 12, color: t.error))),
                  ]),
                ),
                const SizedBox(height: 16),
              ],

              // Detected result + name + emoji
              if (_phase == _SheetState.detected) ...[
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: t.accent.withValues(alpha: 0.07),
                    border: Border.all(color: t.accent.withValues(alpha: 0.2)),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(children: [
                    Icon(Icons.check_circle_outline, size: 14, color: t.accent),
                    const SizedBox(width: 8),
                    Text(
                      _pairedConn != null
                          ? '${s.pairSheetSuccess}${_detectedVersion != null && _detectedVersion!.isNotEmpty ? ' · v$_detectedVersion' : ''}'
                          : s.addConnectionDetectedTpl.replaceAll(
                              '{ver}',
                              _detectedVersion != null
                                  ? ' · v$_detectedVersion'
                                  : ''),
                      style: TextStyle(fontSize: 12, color: t.accent),
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
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      side: BorderSide(color: t.border),
                      foregroundColor: t.textMuted,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                    child: Text(s.addConnectionCancel,
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w600)),
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
                                _saveAndClose();
                              }
                            } else {
                              _detect();
                            }
                          },
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                    child: Text(
                      _phase == _SheetState.detected
                          ? s.addConnectionSave
                          : s.addConnectionConnectBtn,
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w600),
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
              fontSize: 12, fontWeight: FontWeight.w500, color: t.textMuted)),
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
                color: isSelected ? t.accent.withValues(alpha: 0.5) : t.border,
                width: isSelected ? 1.5 : 1,
              ),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Center(child: Text(e, style: const TextStyle(fontSize: 20))),
          ),
        );
      }).toList(),
    );
  }
}
