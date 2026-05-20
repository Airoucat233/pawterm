import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../i18n/locale_provider.dart';
import '../i18n/strings.dart';
import '../state/lan_scanner.dart';
import '../state/server_config.dart';
import '../theme.dart';
import 'pair_sheet.dart';

export '../state/lan_scanner.dart' show LanScanResult;

/// Bottom sheet that scans the LAN for PawTerm servers.
///
/// Returns on pop:
///  - [Connection] when a server was paired or a known server was tapped
///  - null if dismissed
class LanScanSheet extends ConsumerStatefulWidget {
  const LanScanSheet({super.key});

  @override
  ConsumerState<LanScanSheet> createState() => _LanScanSheetState();
}

class _LanScanSheetState extends ConsumerState<LanScanSheet> {
  bool _scanning = false;
  bool _done = false;
  List<LanScanResult> _results = [];
  StreamSubscription<List<LanScanResult>>? _sub;
  final TextEditingController _portCtrl = TextEditingController(text: '8765');
  Map<String, Connection> _connByServerId = {};

  @override
  void initState() {
    super.initState();
    _startScan();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _portCtrl.dispose();
    super.dispose();
  }

  void _startScan() {
    final port = int.tryParse(_portCtrl.text.trim());
    if (port == null || port < 1 || port > 65535) return;
    _sub?.cancel();

    // Build serverId → Connection map for already-paired display
    final connections = ref.read(connectionsProvider);
    final connMap = <String, Connection>{
      for (final c in connections)
        if (c.serverId != null) c.serverId!: c,
    };

    setState(() {
      _scanning = true;
      _done = false;
      _results = [];
      _connByServerId = connMap;
    });

    final pairedIds = connMap.keys.toSet();

    _sub = LanScanner.scan(ports: {port}).listen(
      (snapshot) {
        if (!mounted) return;
        for (final r in snapshot) {
          r.alreadyPaired = pairedIds.contains(r.serverId);
        }
        setState(() => _results = snapshot);
      },
      onDone: () {
        if (!mounted) return;
        setState(() {
          _scanning = false;
          _done = true;
        });
      },
    );
  }

  Future<void> _onTapResult(LanScanResult result) async {
    if (result.alreadyPaired) {
      final conn = _connByServerId[result.serverId];
      if (conn != null) {
        final freshUrl = result.httpBase;
        if (freshUrl != conn.url) {
          await ref.read(connectionsProvider.notifier).updateUrl(conn.id, freshUrl);
        }
        if (mounted) Navigator.of(context).pop(conn);
      } else {
        if (mounted) Navigator.of(context).pop();
      }
      return;
    }

    // New pairing — open PairSheet; it saves the Connection internally.
    final paired = await showModalBottomSheet<Connection>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => PairSheet(server: result),
    );

    if (paired != null && mounted) {
      Navigator.of(context).pop(paired);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final s = ref.watch(stringsProvider);

    final subtitle = _scanning
        ? s.lanScanScanning
        : _results.isEmpty
            ? s.lanScanNoResults
            : s.lanScanDoneTpl.replaceAll('{n}', '${_results.length}');

    return Container(
      constraints:
          BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.75),
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        border: Border.all(color: t.border),
      ),
      child: Column(
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
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(s.lanScanTitle,
                          style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w700,
                              color: t.text)),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          if (_scanning) ...[
                            SizedBox(
                              width: 12,
                              height: 12,
                              child: CircularProgressIndicator(
                                  strokeWidth: 1.5, color: t.accent),
                            ),
                            const SizedBox(width: 6),
                          ],
                          Text(subtitle,
                              style: TextStyle(
                                  fontSize: 12, color: t.textMuted)),
                        ],
                      ),
                    ],
                  ),
                ),
                // Port chip — 编辑后回车/失焦触发重扫；subnet sweep 用这个端口。
                Container(
                  margin: const EdgeInsets.only(left: 8),
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: t.surfaceHi,
                    border: Border.all(color: t.border),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        s.addConnectionPort,
                        style: TextStyle(
                            fontSize: 11,
                            color: t.textDim,
                            fontWeight: FontWeight.w500),
                      ),
                      const SizedBox(width: 6),
                      SizedBox(
                        width: 44,
                        child: TextField(
                          controller: _portCtrl,
                          keyboardType: TextInputType.number,
                          textAlign: TextAlign.center,
                          textInputAction: TextInputAction.done,
                          style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 13,
                              color: t.text,
                              fontWeight: FontWeight.w600),
                          decoration: const InputDecoration(
                            isDense: true,
                            contentPadding: EdgeInsets.symmetric(
                                horizontal: 2, vertical: 4),
                            border: InputBorder.none,
                            isCollapsed: true,
                          ),
                          onSubmitted: (_) {
                            FocusScope.of(context).unfocus();
                            _startScan();
                          },
                          onEditingComplete: () {
                            FocusScope.of(context).unfocus();
                            _startScan();
                          },
                        ),
                      ),
                    ],
                  ),
                ),
                if (_done)
                  TextButton(
                    onPressed: _startScan,
                    child: Text(s.lanScanRetry,
                        style:
                            TextStyle(fontSize: 13, color: t.accent)),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _results.isEmpty && _done
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(s.lanScanNoResults,
                          style:
                              TextStyle(color: t.textMuted, fontSize: 14)),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: _results.length,
                    itemBuilder: (ctx, i) {
                      final r = _results[i];
                      return _ServerTile(
                        result: r,
                        pairedConn: r.alreadyPaired ? _connByServerId[r.serverId] : null,
                        onTap: _onTapResult,
                        t: t,
                        s: s,
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _ServerTile extends StatelessWidget {
  final LanScanResult result;
  final Connection? pairedConn;
  final Future<void> Function(LanScanResult) onTap;
  final AppTokens t;
  final Strings s;

  const _ServerTile({
    required this.result,
    required this.pairedConn,
    required this.onTap,
    required this.t,
    required this.s,
  });

  @override
  Widget build(BuildContext context) {
    final conn = pairedConn;
    final displayName = conn?.name ?? result.name;
    final ipChanged = conn != null && conn.host != result.host;

    return ListTile(
      leading: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: result.alreadyPaired ? t.accentSubt : t.surfaceHi,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Center(
          child: result.alreadyPaired
              ? Text(conn?.emoji ?? '🖥️', style: const TextStyle(fontSize: 18))
              : Icon(Icons.computer_rounded, size: 18, color: t.textMuted),
        ),
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(
              displayName,
              style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: t.text),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (result.alreadyPaired)
            _Badge(
              label: ipChanged ? 'IP 已更新' : s.pairSheetAlreadyPaired,
              color: ipChanged ? const Color(0xFFF59E0B) : t.accent,
              bgColor: ipChanged
                  ? const Color(0xFFF59E0B).withValues(alpha: 0.12)
                  : t.accentSubt,
              borderColor: ipChanged
                  ? const Color(0xFFF59E0B).withValues(alpha: 0.4)
                  : t.accent.withValues(alpha: 0.3),
            ),
          if (!result.alreadyPaired && result.pairingOpen) ...[
            const SizedBox(width: 4),
            _Badge(
              label: s.pairSheetPinOpen,
              color: const Color(0xFF22C55E),
              bgColor: const Color(0xFF22C55E).withValues(alpha: 0.1),
              borderColor: const Color(0xFF22C55E).withValues(alpha: 0.4),
            ),
          ],
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Show machine hostname if it differs from display name
          if (conn != null && result.name != displayName)
            Text(
              result.name,
              style: TextStyle(fontSize: 11.5, color: t.textMuted),
              overflow: TextOverflow.ellipsis,
            ),
          Text(
            [
              '${result.host}:${result.port}',
              if (ipChanged) '(原: ${conn.host})',
              if (result.version.isNotEmpty) 'v${result.version}',
            ].join('  ·  '),
            style: TextStyle(
                fontSize: 11.5,
                fontFamily: 'monospace',
                color: t.textMuted),
          ),
        ],
      ),
      trailing: Icon(Icons.chevron_right, color: t.textDim, size: 18),
      onTap: () => onTap(result),
    );
  }
}

class _Badge extends StatelessWidget {
  final String label;
  final Color color;
  final Color bgColor;
  final Color borderColor;
  const _Badge({
    required this.label,
    required this.color,
    required this.bgColor,
    required this.borderColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: borderColor),
      ),
      child: Text(
        label,
        style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w600,
            color: color),
      ),
    );
  }
}
