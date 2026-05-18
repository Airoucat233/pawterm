import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../i18n/locale_provider.dart';
import '../theme.dart';

class LanScanResult {
  final String url;
  final String token;
  final String hostname;
  final String version;
  const LanScanResult({
    required this.url,
    required this.token,
    required this.hostname,
    required this.version,
  });
}

class _FoundServer {
  final String ip;
  final int port;
  final String hostname;
  final String version;
  _FoundServer({
    required this.ip,
    required this.port,
    required this.hostname,
    required this.version,
  });
  String get url => 'http://$ip:$port';
}

class LanScanSheet extends ConsumerStatefulWidget {
  final int port;
  const LanScanSheet({super.key, this.port = 8765});

  @override
  ConsumerState<LanScanSheet> createState() => _LanScanSheetState();
}

class _LanScanSheetState extends ConsumerState<LanScanSheet> {
  bool _scanning = false;
  bool _done = false;
  final List<_FoundServer> _results = [];

  @override
  void initState() {
    super.initState();
    _scan();
  }

  Future<String?> _getLocalIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      // Prefer WiFi: wlan* (Android), en* (iOS). Skip cellular: rmnet*, ccmni*, pdp*, utun*
      const wifiPrefixes = ['wlan', 'en'];
      const skipPrefixes = ['rmnet', 'ccmni', 'pdp', 'utun', 'ipsec', 'ppp'];
      for (final iface in interfaces) {
        final name = iface.name.toLowerCase();
        if (!wifiPrefixes.any((p) => name.startsWith(p))) continue;
        if (skipPrefixes.any((p) => name.startsWith(p))) continue;
        for (final addr in iface.addresses) {
          if (!addr.isLinkLocal) return addr.address;
        }
      }
      // Fallback: any non-cellular non-link-local address
      for (final iface in interfaces) {
        final name = iface.name.toLowerCase();
        if (skipPrefixes.any((p) => name.startsWith(p))) continue;
        for (final addr in iface.addresses) {
          if (!addr.isLinkLocal) return addr.address;
        }
      }
    } catch (_) {}
    return null;
  }

  Future<Map<String, dynamic>?> _probe(String ip, int port) async {
    try {
      final resp = await http
          .get(Uri.parse('http://$ip:$port/health'))
          .timeout(const Duration(milliseconds: 800));
      if (resp.statusCode == 200) {
        return jsonDecode(resp.body) as Map<String, dynamic>;
      }
    } catch (_) {}
    return null;
  }

  Future<void> _scan() async {
    setState(() {
      _scanning = true;
      _done = false;
      _results.clear();
    });

    final myIp = await _getLocalIp();
    if (myIp == null || !mounted) {
      if (mounted) setState(() { _scanning = false; _done = true; });
      return;
    }

    final parts = myIp.split('.');
    if (parts.length != 4) {
      if (mounted) setState(() { _scanning = false; _done = true; });
      return;
    }
    final prefix = '${parts[0]}.${parts[1]}.${parts[2]}';

    final futures = List.generate(254, (i) async {
      final ip = '$prefix.${i + 1}';
      final info = await _probe(ip, widget.port);
      if (info != null && mounted) {
        setState(() {
          _results.add(_FoundServer(
            ip: ip,
            port: widget.port,
            hostname: info['hostname'] as String? ?? ip,
            version: info['version'] as String? ?? '',
          ));
        });
      }
    });

    await Future.wait(futures, eagerError: false);
    if (mounted) setState(() { _scanning = false; _done = true; });
  }

  Future<void> _onTapServer(_FoundServer server) async {
    final s = ref.read(stringsProvider);
    final t = AppTokens.of(context);
    final tokenCtrl = TextEditingController();
    String? errMsg;

    final result = await showDialog<LanScanResult>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          backgroundColor: t.surface,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text(
            s.lanScanEnterToken,
            style: TextStyle(color: t.text, fontSize: 16, fontWeight: FontWeight.w600),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${server.hostname}  •  ${server.url}',
                style: TextStyle(fontSize: 12, color: t.textMuted),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: tokenCtrl,
                autofocus: true,
                style: TextStyle(fontFamily: 'monospace', fontSize: 13, color: t.text),
                decoration: InputDecoration(
                  hintText: s.lanScanTokenHint,
                  hintStyle: TextStyle(fontSize: 12, color: t.textDim),
                ),
              ),
              if (errMsg != null) ...[
                const SizedBox(height: 8),
                Text(errMsg!, style: TextStyle(fontSize: 12, color: t.error)),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(s.genericCancel, style: TextStyle(color: t.textMuted)),
            ),
            FilledButton(
              onPressed: () async {
                final token = tokenCtrl.text.trim();
                if (token.isEmpty) return;
                final unauthorizedMsg = ref.read(stringsProvider).addConnectionUnauthorized;
                // Verify token against a protected endpoint
                try {
                  final check = await http.get(
                    Uri.parse('${server.url}/projects'),
                    headers: {'Authorization': 'Bearer $token'},
                  ).timeout(const Duration(seconds: 5));
                  if (check.statusCode == 401) {
                    setDialogState(() => errMsg = unauthorizedMsg);
                    return;
                  }
                } catch (_) {}
                if (!ctx.mounted) return;
                Navigator.of(ctx).pop(LanScanResult(
                  url: server.url,
                  token: token,
                  hostname: server.hostname,
                  version: server.version,
                ));
              },
              style: FilledButton.styleFrom(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              child: Text(s.lanScanConnectBtn),
            ),
          ],
        ),
      ),
    );

    tokenCtrl.dispose();
    if (result != null && mounted) {
      Navigator.of(context).pop(result);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final s = ref.watch(stringsProvider);

    String subtitle;
    if (_scanning) {
      subtitle = s.lanScanScanning;
    } else if (_results.isEmpty) {
      subtitle = s.lanScanNoResults;
    } else {
      subtitle = s.lanScanDoneTpl.replaceAll('{n}', '${_results.length}');
    }

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.75,
      ),
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
            width: 36, height: 4,
            decoration: BoxDecoration(color: t.border, borderRadius: BorderRadius.circular(2)),
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
                          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: t.text)),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          if (_scanning) ...[
                            SizedBox(
                              width: 12, height: 12,
                              child: CircularProgressIndicator(strokeWidth: 1.5, color: t.accent),
                            ),
                            const SizedBox(width: 6),
                          ],
                          Text(subtitle, style: TextStyle(fontSize: 12, color: t.textMuted)),
                        ],
                      ),
                    ],
                  ),
                ),
                if (_done)
                  TextButton(
                    onPressed: _scan,
                    child: Text(s.lanScanRetry, style: TextStyle(fontSize: 13, color: t.accent)),
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
                          style: TextStyle(color: t.textMuted, fontSize: 14)),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: _results.length,
                    itemBuilder: (ctx, i) {
                      final server = _results[i];
                      return ListTile(
                        leading: Container(
                          width: 36, height: 36,
                          decoration: BoxDecoration(
                            color: t.accentSubt,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Icon(Icons.computer_rounded, size: 18, color: t.accent),
                        ),
                        title: Text(server.hostname,
                            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: t.text)),
                        subtitle: Text(
                          '${server.url}${server.version.isNotEmpty ? "  ·  v${server.version}" : ""}',
                          style: TextStyle(fontSize: 12, color: t.textMuted),
                        ),
                        trailing: Icon(Icons.chevron_right, color: t.textDim, size: 18),
                        onTap: () => _onTapServer(server),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
