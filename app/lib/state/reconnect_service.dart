import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'lan_scanner.dart';
import 'server_config.dart';

enum ReconnectStatus { idle, scanning, found, notFound }

class ReconnectState {
  final ReconnectStatus status;
  final String? updatedConnectionId;   // Connection.id (was: updatedServerId)

  const ReconnectState({
    this.status = ReconnectStatus.idle,
    this.updatedConnectionId,
  });
}

class ReconnectNotifier extends StateNotifier<ReconnectState> {
  final Ref _ref;
  StreamSubscription<List<ConnectivityResult>>? _connSub;
  Timer? _debounce;
  bool _running = false;

  ReconnectNotifier(this._ref) : super(const ReconnectState()) {
    _startListening();
    _scheduleRun(delay: const Duration(seconds: 2));
  }

  void _startListening() {
    _connSub = Connectivity().onConnectivityChanged.listen((results) {
      final hasNetwork = results.any((r) =>
          r == ConnectivityResult.wifi ||
          r == ConnectivityResult.mobile ||
          r == ConnectivityResult.ethernet);
      if (hasNetwork) {
        _debounce?.cancel();
        _debounce = Timer(const Duration(seconds: 2), _run);
      }
    });
  }

  void _scheduleRun({Duration delay = Duration.zero}) {
    Future.delayed(delay, _run);
  }

  Future<void> _run() async {
    if (_running) return;

    // Only consider paired connections (those with a serverId)
    final paired = _ref
        .read(connectionsProvider)
        .where((c) => c.serverId != null)
        .toList();
    if (paired.isEmpty) return;

    _running = true;
    state = const ReconnectState(status: ReconnectStatus.scanning);

    final sweepPorts = <int>{8765, for (final c in paired) c.port};

    String? foundId;
    try {
      try {
        await for (final snapshot in LanScanner.scan(ports: sweepPorts)) {
          for (final found in snapshot) {
            final match = paired
                .where((c) => c.serverId == found.serverId)
                .firstOrNull;
            if (match != null) {
              await _ref
                  .read(connectionsProvider.notifier)
                  .updateUrl(match.id, found.httpBase);
              foundId = match.id;
            }
          }
        }
      } catch (_) {}

      if (foundId != null) {
        state = ReconnectState(
            status: ReconnectStatus.found, updatedConnectionId: foundId);
      } else {
        // Fallback: probe recentHosts for each paired connection
        for (final conn in paired) {
          if (conn.recentHosts.isEmpty) continue;
          final liveHost =
              await LanScanner.probeRecentHosts(conn.recentHosts, conn.port);
          if (liveHost != null) {
            final freshUrl = 'http://$liveHost:${conn.port}';
            await _ref
                .read(connectionsProvider.notifier)
                .updateUrl(conn.id, freshUrl);
            foundId = conn.id;
            break;
          }
        }
        state = foundId != null
            ? ReconnectState(
                status: ReconnectStatus.found, updatedConnectionId: foundId)
            : const ReconnectState(status: ReconnectStatus.notFound);
      }
    } finally {
      _running = false;
    }
  }

  @override
  void dispose() {
    _connSub?.cancel();
    _debounce?.cancel();
    super.dispose();
  }
}

final reconnectProvider =
    StateNotifierProvider<ReconnectNotifier, ReconnectState>(
        (ref) => ReconnectNotifier(ref));
