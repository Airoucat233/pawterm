import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../i18n/locale_provider.dart';
import '../state/server_config.dart';
import '../theme.dart';
import 'lan_scan_sheet.dart';
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
  late final TextEditingController _urlCtrl;
  late final TextEditingController _nameCtrl;
  late final TextEditingController _tokenCtrl;
  late String _emoji;

  _SheetState _phase = _SheetState.input;
  String? _detectedName;
  String? _detectedVersion;
  String? _errorMsg;

  @override
  void initState() {
    super.initState();
    final e = widget.editing;
    _urlCtrl = TextEditingController(
        text: e != null ? e.url.replaceFirst(RegExp(r'^https?://'), '') : '');
    _nameCtrl = TextEditingController(text: e?.name ?? '');
    _tokenCtrl = TextEditingController(text: e?.token ?? '');
    _emoji = e?.emoji ?? '🖥️';
    if (e != null) _phase = _SheetState.detected;
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _nameCtrl.dispose();
    _tokenCtrl.dispose();
    super.dispose();
  }

  String get _normalizedUrl {
    var v = _urlCtrl.text.trim();
    if (v.isEmpty) return '';
    if (!kIsWeb && Platform.isAndroid) {
      v = v.replaceFirst(RegExp(r'^(https?://)?localhost'), 'http://10.0.2.2');
    }
    if (!v.startsWith('http')) v = 'http://$v';
    final uri = Uri.tryParse(v);
    if (uri == null) return v;
    final hostPart = v.replaceFirst(RegExp(r'^https?://'), '').split('/').first;
    final hasExplicitPort = hostPart.contains(':');
    if (!hasExplicitPort) {
      v = '${uri.scheme}://${uri.host}:8765${uri.path.isEmpty ? '' : uri.path}';
    }
    return v.endsWith('/') ? v.substring(0, v.length - 1) : v;
  }

  String? get _token {
    final t = _tokenCtrl.text.trim();
    return t.isEmpty ? null : t;
  }

  Map<String, String> get _authHeaders =>
      _token != null ? {'Authorization': 'Bearer $_token'} : const {};

  Future<void> _detect() async {
    final url = _normalizedUrl;
    if (url.isEmpty) return;

    setState(() {
      _phase = _SheetState.detecting;
      _errorMsg = null;
    });

    try {
      final res = await http
          .get(Uri.parse('$url/health'), headers: _authHeaders)
          .timeout(const Duration(seconds: 8));
      if (res.statusCode == 401) {
        final s = ref.read(stringsProvider);
        setState(() {
          _errorMsg = s.addConnectionUnauthorized;
          _phase = _SheetState.error;
        });
        return;
      }
      if (res.statusCode == 200) {
        final body = jsonDecode(res.body) as Map<String, dynamic>;
        final hostname = body['hostname'] as String? ?? url;
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
          _errorMsg = s.addConnectionServerReturnedTpl.replaceAll('{code}', '${res.statusCode}');
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
    final url = _normalizedUrl;
    final name = _nameCtrl.text.trim().isNotEmpty
        ? _nameCtrl.text.trim()
        : (_detectedName ?? url);
    final notifier = ref.read(connectionsProvider.notifier);
    if (widget.editing != null) {
      await notifier.update(widget.editing!.copyWith(
        name: name,
        emoji: _emoji,
        url: url,
        token: _token,
      ));
    } else {
      await notifier.add(name: name, emoji: _emoji, url: url, token: _token);
    }
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _openQrScan() async {
    final result = await Navigator.of(context).push<PawTermQrResult>(
      MaterialPageRoute(builder: (_) => const QrScanScreen()),
    );
    if (result == null || !mounted) return;
    _urlCtrl.text = result.url.replaceFirst(RegExp(r'^https?://'), '');
    _tokenCtrl.text = result.token;
    setState(() => _phase = _SheetState.input);
    await _detect();
  }

  Future<void> _openLanScan() async {
    final result = await showModalBottomSheet<LanScanResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const LanScanSheet(),
    );
    if (result == null || !mounted) return;
    _urlCtrl.text = result.url.replaceFirst(RegExp(r'^https?://'), '');
    _tokenCtrl.text = result.token;
    _detectedName = result.hostname;
    _detectedVersion = result.version;
    _nameCtrl.text = result.hostname;
    setState(() => _phase = _SheetState.detected);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final s = ref.watch(stringsProvider);
    final isEditing = widget.editing != null;

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
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
                  width: 36, height: 4,
                  decoration: BoxDecoration(color: t.border, borderRadius: BorderRadius.circular(2)),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                isEditing ? s.addConnectionEditTitle : s.addConnectionTitle,
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: t.text),
              ),
              const SizedBox(height: 20),

              // Quick-connect buttons (only when adding new)
              if (!isEditing) ...[
                Row(children: [
                  Expanded(
                    child: _ActionButton(
                      icon: Icons.qr_code_scanner_rounded,
                      label: s.addConnectionScanQr,
                      onTap: _openQrScan,
                      t: t,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _ActionButton(
                      icon: Icons.wifi_find_rounded,
                      label: s.addConnectionFindLan,
                      onTap: _openLanScan,
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

              // URL field
              _Label(s.addConnectionUrl),
              TextField(
                controller: _urlCtrl,
                enabled: _phase == _SheetState.input ||
                    _phase == _SheetState.error ||
                    isEditing,
                keyboardType: TextInputType.url,
                style: TextStyle(fontFamily: 'monospace', fontSize: 13, color: t.text),
                decoration: InputDecoration(
                  hintText: s.addConnectionUrlHintLan,
                  suffixText: ':8765',
                  suffixStyle: TextStyle(color: t.textDim, fontFamily: 'monospace', fontSize: 12),
                ),
                onChanged: (_) {
                  if (_phase == _SheetState.error) setState(() => _phase = _SheetState.input);
                },
                onSubmitted: (_) {
                  if (_phase == _SheetState.input || _phase == _SheetState.error) _detect();
                },
              ),
              const SizedBox(height: 6),
              Text(s.addConnectionPortNote,
                  style: TextStyle(fontSize: 11, color: t.textDim)),
              const SizedBox(height: 14),

              // Token field
              _Label(s.addConnectionToken),
              TextField(
                controller: _tokenCtrl,
                enabled: _phase == _SheetState.input ||
                    _phase == _SheetState.error ||
                    isEditing,
                obscureText: true,
                style: TextStyle(fontFamily: 'monospace', fontSize: 13, color: t.text),
                decoration: InputDecoration(
                  hintText: s.addConnectionTokenHint,
                ),
                onChanged: (_) {
                  if (_phase == _SheetState.error) setState(() => _phase = _SheetState.input);
                },
              ),
              const SizedBox(height: 16),

              // Detecting indicator
              if (_phase == _SheetState.detecting) ...[
                Row(children: [
                  SizedBox(
                    width: 16, height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2, color: t.accent),
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
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: t.error.withValues(alpha: 0.08),
                    border: Border.all(color: t.error.withValues(alpha: 0.25)),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(children: [
                    Icon(Icons.error_outline, size: 14, color: t.error),
                    const SizedBox(width: 8),
                    Expanded(child: Text(_errorMsg!, style: TextStyle(fontSize: 12, color: t.error))),
                  ]),
                ),
                const SizedBox(height: 16),
              ],

              // Detected result + name + emoji
              if (_phase == _SheetState.detected) ...[
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: t.accent.withValues(alpha: 0.07),
                    border: Border.all(color: t.accent.withValues(alpha: 0.2)),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(children: [
                    Icon(Icons.check_circle_outline, size: 14, color: t.accent),
                    const SizedBox(width: 8),
                    Text(
                      s.addConnectionDetectedTpl.replaceAll('{ver}',
                          _detectedVersion != null ? ' · v$_detectedVersion' : ''),
                      style: TextStyle(fontSize: 12, color: t.accent),
                    ),
                  ]),
                ),
                const SizedBox(height: 16),

                _Label(s.addConnectionName),
                TextField(
                  controller: _nameCtrl,
                  style: TextStyle(fontSize: 14, color: t.text),
                  decoration: InputDecoration(hintText: s.addConnectionNameNicknameHint),
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
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    child: Text(s.addConnectionCancel,
                        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
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
                              _save();
                            } else {
                              _detect();
                            }
                          },
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    child: Text(
                      _phase == _SheetState.detected ? s.addConnectionSave : s.addConnectionConnectBtn,
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
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
          color: t.accentSubt,
          border: Border.all(color: t.accent.withValues(alpha: 0.25)),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          children: [
            Icon(icon, size: 24, color: t.accent),
            const SizedBox(height: 6),
            Text(
              label,
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: t.accent),
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
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: t.textMuted)),
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
