import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:nsd/nsd.dart' as nsd;

class LanScanResult {
  final String serverId;
  final String name;
  final String host;
  final int port;
  final String version;
  final bool pairingOpen;
  bool alreadyPaired; // mutable so caller can fill it

  LanScanResult({
    required this.serverId,
    required this.name,
    required this.host,
    required this.port,
    required this.version,
    required this.pairingOpen,
    this.alreadyPaired = false,
  });
}

class LanScanner {
  static const String _serviceType = '_pawterm._tcp';
  static const Duration _timeout = Duration(seconds: 4);
  static const Duration _probeTimeout = Duration(milliseconds: 1500);
  static const int _maxConcurrent = 30;

  /// Scan via mDNS + subnet sweep. Returns a snapshot after [_timeout].
  /// Emits incremental updates via the stream.
  static Stream<List<LanScanResult>> scan() async* {
    final results = <String, LanScanResult>{}; // keyed by serverId

    void addOrUpdate(LanScanResult r) {
      results[r.serverId] = r;
    }

    final controller = StreamController<List<LanScanResult>>();

    // mDNS discovery (nsd 5.x: ipLookupType replaces explicit resolve())
    Future<void> runMdns() async {
      nsd.Discovery? discovery;
      try {
        discovery = await nsd.startDiscovery(
          _serviceType,
          ipLookupType: nsd.IpLookupType.any,
        );
        discovery.addServiceListener((service, status) async {
          if (status != nsd.ServiceStatus.found) return;
          final port = service.port ?? 8765;
          // Prefer IPv4 from the resolved address list; fall back to first.
          final addresses = service.addresses;
          if (addresses == null || addresses.isEmpty) return;
          InternetAddress? picked;
          for (final a in addresses) {
            if (a.type == InternetAddressType.IPv4) { picked = a; break; }
          }
          picked ??= addresses.first;
          final host = picked.address;
          if (host.isEmpty) return;
          final info = await _probeHealth(host, port);
          if (info != null && !controller.isClosed) {
            final r = _toResult(host, port, info);
            if (r != null) {
              addOrUpdate(r);
              controller.add(List.unmodifiable(results.values.toList()));
            }
          }
        });
      } catch (_) {
        // mDNS unavailable — subnet fallback will cover
      }
      await Future.delayed(_timeout);
      try {
        if (discovery != null) await nsd.stopDiscovery(discovery);
      } catch (_) {}
    }

    // Subnet sweep fallback
    Future<void> runSubnetSweep(int targetPort) async {
      final myIp = await _getLocalIp();
      if (myIp == null) return;
      final parts = myIp.split('.');
      if (parts.length != 4) return;
      final prefix = '${parts[0]}.${parts[1]}.${parts[2]}';

      // Probe in batches of _maxConcurrent; stop early if controller closed.
      final pending = List.generate(254, (i) => '$prefix.${i + 1}');
      while (pending.isNotEmpty && !controller.isClosed) {
        final batch = pending.take(_maxConcurrent).toList();
        pending.removeRange(0, batch.length);
        await Future.wait(batch.map((ip) async {
          if (controller.isClosed) return;
          final info = await _probeHealth(ip, targetPort);
          if (info != null && !controller.isClosed) {
            final r = _toResult(ip, targetPort, info);
            if (r != null) {
              addOrUpdate(r);
              controller.add(List.unmodifiable(results.values.toList()));
            }
          }
        }), eagerError: false);
      }
    }

    // Run both in parallel; close controller after _timeout regardless.
    runMdns().ignore();
    runSubnetSweep(8765).ignore();
    Future.delayed(_timeout, () {
      if (!controller.isClosed) controller.close();
    });

    // Forward stream events until controller closes (after _timeout).
    await for (final snapshot in controller.stream) {
      yield snapshot;
    }
  }

  static Future<Map<String, dynamic>?> _probeHealth(
      String host, int port) async {
    try {
      final resp = await http
          .get(Uri.parse('http://$host:$port/health'))
          .timeout(_probeTimeout);
      if (resp.statusCode == 200) {
        return jsonDecode(resp.body) as Map<String, dynamic>;
      }
    } catch (_) {}
    return null;
  }

  static LanScanResult? _toResult(
      String host, int port, Map<String, dynamic> health) {
    final serverId = health['serverId'] as String?;
    if (serverId == null || serverId.isEmpty) return null;
    return LanScanResult(
      serverId: serverId,
      name: health['hostname'] as String? ?? host,
      host: host,
      port: port,
      version: health['version'] as String? ?? '',
      pairingOpen: health['pairingOpen'] as bool? ?? false,
    );
  }

  static Future<String?> _getLocalIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
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

  /// Probe a list of hosts in order, return first that responds.
  static Future<String?> probeRecentHosts(
      List<String> hosts, int port) async {
    for (final host in hosts) {
      final info = await _probeHealth(host, port);
      if (info != null) return host;
    }
    return null;
  }
}
