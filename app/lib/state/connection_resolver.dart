import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/build_defaults.dart';
import 'lan_scanner.dart';
import 'server_config.dart';

class ConnectionResolveResult {
  final String url;
  final String? serverId;

  const ConnectionResolveResult({
    required this.url,
    this.serverId,
  });
}

class ConnectionResolver {
  const ConnectionResolver();

  Future<ConnectionResolveResult?> resolve(Connection conn) async {
    final candidates = <String>[
      conn.url,
      ...conn.recentUrls.where((u) => u != conn.url),
    ];

    for (final url in candidates) {
      final health = await probeHealthUrl(url);
      if (health == null) continue;
      final serverId = health['serverId'] as String?;
      if (conn.serverId == null || conn.serverId == serverId) {
        return ConnectionResolveResult(url: url, serverId: serverId);
      }
    }

    if (conn.serverId == null) return null;
    final ports = <int>{BuildDefaults.defaultServerPort, conn.port};
    try {
      await for (final snapshot in LanScanner.scan(
        ports: ports,
        requestNearbyWifiPermission: false,
      )) {
        for (final found in snapshot) {
          if (found.serverId == conn.serverId) {
            return ConnectionResolveResult(
              url: found.httpBase,
              serverId: found.serverId,
            );
          }
        }
      }
    } catch (_) {}
    return null;
  }

  static Future<Map<String, dynamic>?> probeHealthUrl(String baseUrl) async {
    try {
      final uri = Uri.parse(baseUrl.replaceFirst(RegExp(r'/$'), ''))
          .replace(path: '/health');
      final resp = await http.get(uri).timeout(const Duration(seconds: 2));
      if (resp.statusCode != 200) return null;
      return jsonDecode(resp.body) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }
}
