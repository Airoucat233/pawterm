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
///  - [PairedServer] when user completes a new pairing via [PairSheet]
///  - [LanScanResult] when user taps an already-paired server (caller handles
///    switching to that server via existing ServerEntry or PairedServer)
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

  @override
  void initState() {
    super.initState();
    _startScan();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _startScan() {
    _sub?.cancel();
    setState(() {
      _scanning = true;
      _done = false;
      _results = [];
    });

    final pairedServers = ref.read(pairedServersProvider);
    final pairedIds = pairedServers.map((s) => s.serverId).toSet();

    _sub = LanScanner.scan().listen(
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
      // Already paired — return the result directly; caller connects.
      if (mounted) Navigator.of(context).pop(result);
      return;
    }

    // Open pair sheet; it pops with PairedServer on success, or null on dismiss.
    final paired = await showModalBottomSheet<PairedServer>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => PairSheet(server: result),
    );

    // If pairing succeeded, propagate PairedServer up to AddConnectionSheet.
    if (paired != null && mounted) {
      Navigator.of(context).pop(paired);
    }
    // If null (user dismissed pair sheet), stay on this LAN scan sheet.
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
                      return _ServerTile(result: r, onTap: _onTapResult, t: t, s: s);
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
  final Future<void> Function(LanScanResult) onTap;
  final AppTokens t;
  final Strings s;

  const _ServerTile({
    required this.result,
    required this.onTap,
    required this.t,
    required this.s,
  });

  @override
  Widget build(BuildContext context) {
    final idSuffix = result.serverId.length >= 6
        ? result.serverId.substring(result.serverId.length - 6)
        : result.serverId;

    return ListTile(
      leading: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: result.alreadyPaired ? t.accentSubt : t.surfaceHi,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(
          result.alreadyPaired
              ? Icons.link_rounded
              : Icons.computer_rounded,
          size: 18,
          color: result.alreadyPaired ? t.accent : t.textMuted,
        ),
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(
              result.name,
              style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: t.text),
            ),
          ),
          if (result.alreadyPaired)
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: t.accentSubt,
                borderRadius: BorderRadius.circular(4),
                border:
                    Border.all(color: t.accent.withValues(alpha: 0.3)),
              ),
              child: Text(
                s.pairSheetAlreadyPaired,
                style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: t.accent),
              ),
            ),
          if (!result.alreadyPaired && result.pairingOpen) ...[
            const SizedBox(width: 4),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: const Color(0xFF22C55E).withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(
                    color: const Color(0xFF22C55E).withValues(alpha: 0.4)),
              ),
              child: Text(
                s.pairSheetPinOpen,
                style: const TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF22C55E)),
              ),
            ),
          ],
        ],
      ),
      subtitle: Text(
        '${result.host}:${result.port}  ·  …$idSuffix'
        '${result.version.isNotEmpty ? "  ·  v${result.version}" : ""}',
        style: TextStyle(fontSize: 12, color: t.textMuted),
      ),
      trailing: Icon(Icons.chevron_right, color: t.textDim, size: 18),
      onTap: () => onTap(result),
    );
  }
}
