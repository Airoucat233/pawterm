import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:xterm/xterm.dart';

import '../../i18n/locale_provider.dart';
import '../../state/projects_store.dart';
import '../../state/server_config.dart';
import '../../theme.dart';
import 'shell_cwd_bar.dart';
import 'shell_search_bar.dart';

class ShellTab extends ConsumerStatefulWidget {
  const ShellTab({super.key});

  @override
  ConsumerState<ShellTab> createState() => _ShellTabState();
}

class _ShellTabState extends ConsumerState<ShellTab> {
  WebSocketChannel? _channel;
  Terminal? _terminal;
  final TerminalController _controller = TerminalController();
  bool _ctrlSticky = false;
  bool _altSticky = false;
  // ignore: unused_field  // tracks ready state; read-path wired up in future reconnect UI
  bool _connected = false;
  bool _searching = false;
  String? _error;
  String? _connectedCwd;

  @override
  void dispose() {
    _channel?.sink.close();
    _controller.dispose();
    super.dispose();
  }

  // Remember every cwd we attempted (regardless of success/failure) so a dead
  // server doesn't trigger an infinite reconnect loop. User must manually
  // press reconnect to retry.
  String? _attemptedCwd;
  bool _shellAttempting = false;

  void _ensureConnectedFor(String cwd) {
    if (_shellAttempting) return; // connection attempt already in-flight
    if (_attemptedCwd == cwd) return;

    _channel?.sink.close();
    _shellAttempting = true;
    _attemptedCwd = cwd;

    final config = ref.read(activeConnectionProvider);
    if (config == null) {
      _shellAttempting = false;
      return;
    }

    _terminal = Terminal(maxLines: 5000);
    _terminal!.onOutput = (data) {
      _send({'type': 'input', 'data': data});
    };
    _terminal!.onResize = (w, h, _, __) {
      _send({'type': 'resize', 'cols': w, 'rows': h});
    };

    final wsUri = Uri.parse('${config.wsBase}/ws/shell');
    _channel = WebSocketChannel.connect(wsUri);
    _channel!.stream.listen(_onMessage, onError: _onError, onDone: _onDone);

    _send({
      'type': 'init',
      'cwd': cwd,
      'cols': _terminal!.viewWidth,
      'rows': _terminal!.viewHeight,
    });

    setState(() {
      _connected = false;
      _error = null;
      _connectedCwd = cwd;
    });
  }

  void _send(Map<String, dynamic> msg) {
    try {
      _channel?.sink.add(jsonEncode(msg));
    } catch (_) {}
  }

  void _onMessage(dynamic raw) {
    if (raw is! String) return;
    final msg = jsonDecode(raw) as Map<String, dynamic>;
    switch (msg['type']) {
      case 'ready':
        _shellAttempting = false;
        setState(() => _connected = true);
        break;
      case 'output':
        _terminal?.write(msg['data'] as String);
        break;
      case 'cwd':
        // 服务端从 PTY 输出嗅探到的 OSC 7 cwd（用户 cd 后实时跟随）
        final newCwd = msg['cwd'] as String?;
        if (newCwd != null && newCwd.isNotEmpty && newCwd != _connectedCwd) {
          setState(() => _connectedCwd = newCwd);
        }
        break;
      case 'exit':
        _terminal?.write('\r\n[process exited ${msg['code']}]\r\n');
        setState(() => _connected = false);
        break;
      case 'error':
        setState(() => _error = msg['message'] as String?);
        break;
    }
  }

  void _onError(Object err) {
    _shellAttempting = false;
    setState(() {
      _connected = false;
      _error = err.toString();
    });
  }

  void _onDone() {
    _shellAttempting = false;
    setState(() => _connected = false);
  }

  void _restart() {
    final cwd = _connectedCwd ?? _attemptedCwd;
    _connectedCwd = null;
    _attemptedCwd = null;
    _shellAttempting = false;
    _channel?.sink.close();
    _channel = null;
    if (cwd != null) _ensureConnectedFor(cwd);
  }

  void _sendSpecial(String seq) {
    _send({'type': 'input', 'data': seq});
  }

  void _interrupt() => _send({'type': 'signal', 'signal': 'SIGINT'});

  Future<void> _paste() async {
    final data = await Clipboard.getData('text/plain');
    final text = data?.text;
    if (text != null && text.isNotEmpty) {
      _send({'type': 'input', 'data': text});
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final s = ref.watch(stringsProvider);
    final session = ref.watch(currentSessionProvider);

    if (session == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.terminal, size: 40, color: t.textDim),
              const SizedBox(height: 12),
              Text(
                s.shellEmptyTitle,
                style: TextStyle(fontSize: 14, color: t.textMuted, fontWeight: FontWeight.w500),
              ),
              const SizedBox(height: 4),
              Text(
                s.shellEmptyPickProject,
                style: TextStyle(fontSize: 12, color: t.textDim),
              ),
            ],
          ),
        ),
      );
    }

    // (re)connect on session change.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _ensureConnectedFor(session.cwd);
    });

    if (_terminal == null) {
      return Center(
        child: CircularProgressIndicator(strokeWidth: 2, color: t.accent),
      );
    }

    return Column(
      children: [
        if (_error != null)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            color: t.error.withValues(alpha: 0.08),
            child: Row(
              children: [
                Icon(Icons.error_outline, color: t.error, size: 14),
                const SizedBox(width: 8),
                Expanded(child: Text(_error!, style: TextStyle(color: t.error, fontSize: 12))),
                TextButton(
                  onPressed: _restart,
                  child: Text(s.shellReconnect, style: TextStyle(color: t.accent, fontSize: 12)),
                ),
              ],
            ),
          ),
        ShellCwdBar(cwd: _connectedCwd ?? session.cwd),
        if (_searching)
          ShellSearchBar(
            terminal: _terminal!,
            controller: _controller,
            onClose: () => setState(() => _searching = false),
          ),
        Expanded(
          child: ColoredBox(
            color: t.bg,
            child: TerminalView(
              _terminal!,
              controller: _controller,
              theme: TerminalTheme(
                cursor: t.accent,
                selection: t.accent.withValues(alpha: 0.25),
                foreground: t.text,
                background: t.bg,
                black: const Color(0xFF000000),
                white: const Color(0xFFFFFFFF),
                red: const Color(0xFFE06C75),
                green: const Color(0xFF7BD88F),
                yellow: const Color(0xFFE5C07B),
                blue: const Color(0xFF61AFEF),
                magenta: const Color(0xFFC678DD),
                cyan: const Color(0xFF56B6C2),
                brightBlack: const Color(0xFF5C6370),
                brightRed: const Color(0xFFE06C75),
                brightGreen: const Color(0xFF7BD88F),
                brightYellow: const Color(0xFFE5C07B),
                brightBlue: const Color(0xFF61AFEF),
                brightMagenta: const Color(0xFFC678DD),
                brightCyan: const Color(0xFF56B6C2),
                brightWhite: const Color(0xFFFFFFFF),
                searchHitBackground: const Color(0xFFAAAAFF),
                searchHitBackgroundCurrent: const Color(0xFFFFFFAA),
                searchHitForeground: const Color(0xFF000000),
              ),
              padding: const EdgeInsets.all(8),
              textStyle: const TerminalStyle(
                fontSize: 12,
                fontFamily: 'monospace',
                fontFamilyFallback: ['SymbolsNerdFontMono'],
              ),
              autofocus: true,
            ),
          ),
        ),
        SafeArea(top: false, child: _VirtualKeyBar(
          ctrl: _ctrlSticky,
          alt: _altSticky,
          searching: _searching,
          onCtrl: () => setState(() => _ctrlSticky = !_ctrlSticky),
          onAlt: () => setState(() => _altSticky = !_altSticky),
          onEsc: () => _sendSpecial('\x1b'),
          onTab: () => _sendSpecial('\t'),
          onShiftTab: () => _sendSpecial('\x1b[Z'),
          onUp: () => _sendSpecial('\x1b[A'),
          onDown: () => _sendSpecial('\x1b[B'),
          onLeft: () => _sendSpecial('\x1b[D'),
          onRight: () => _sendSpecial('\x1b[C'),
          onEnter: () => _sendSpecial('\r'),
          onPaste: _paste,
          onInterrupt: _interrupt,
          onToggleSearch: () => setState(() => _searching = !_searching),
        )),
      ],
    );
  }
}

class _VirtualKeyBar extends StatelessWidget {
  final bool ctrl;
  final bool alt;
  final bool searching;
  final VoidCallback onCtrl;
  final VoidCallback onAlt;
  final VoidCallback onEsc;
  final VoidCallback onTab;
  final VoidCallback onShiftTab;
  final VoidCallback onUp;
  final VoidCallback onDown;
  final VoidCallback onLeft;
  final VoidCallback onRight;
  final VoidCallback onEnter;
  final VoidCallback onPaste;
  final VoidCallback onInterrupt;
  final VoidCallback onToggleSearch;

  const _VirtualKeyBar({
    required this.ctrl,
    required this.alt,
    required this.searching,
    required this.onCtrl,
    required this.onAlt,
    required this.onEsc,
    required this.onTab,
    required this.onShiftTab,
    required this.onUp,
    required this.onDown,
    required this.onLeft,
    required this.onRight,
    required this.onEnter,
    required this.onPaste,
    required this.onInterrupt,
    required this.onToggleSearch,
  });

  Widget _key(BuildContext context, String label, VoidCallback onTap, {bool active = false}) {
    final t = AppTokens.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: active ? t.accent : t.surface,
            border: Border.all(
              color: active ? t.accent : t.border,
              width: 0.5,
            ),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: active ? Colors.white : t.text,
              fontSize: 12,
              fontFamily: 'monospace',
              fontWeight: active ? FontWeight.w600 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Container(
      color: t.surface,
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            _key(context, 'Esc', onEsc),
            _key(context, 'Tab', onTab),
            _key(context, '⇧Tab', onShiftTab),
            _key(context, 'Ctrl', onCtrl, active: ctrl),
            _key(context, 'Alt', onAlt, active: alt),
            const SizedBox(width: 8),
            _key(context, '←', onLeft),
            _key(context, '↓', onDown),
            _key(context, '↑', onUp),
            _key(context, '→', onRight),
            const SizedBox(width: 8),
            _key(context, '↵', onEnter),
            _key(context, '^C', onInterrupt),
            _key(context, '📋', onPaste),
            _key(context, '🔍', onToggleSearch, active: searching),
          ],
        ),
      ),
    );
  }
}
