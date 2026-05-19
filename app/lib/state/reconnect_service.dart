import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'lan_scanner.dart';
import 'server_config.dart';

enum ReconnectStatus { idle, scanning, found, notFound }

class ReconnectState {
  final ReconnectStatus status;
  final String? updatedServerId;

  const ReconnectState({
    this.status = ReconnectStatus.idle,
    this.updatedServerId,
  });
}

class ReconnectNotifier extends StateNotifier<ReconnectState> {
  final Ref _ref;
  StreamSubscription<List<ConnectivityResult>>? _connSub;
  Timer? _debounce;
  bool _running = false;

  ReconnectNotifier(this._ref) : super(const ReconnectState()) {
    _startListening();
    // Initial scan on startup
    _scheduleRun(delay: const Duration(seconds: 2));
  }

  void _startListening() {
    _connSub = Connectivity().onConnectivityChanged.listen((results) {
      final hasNetwork = results.any((r) =>
          r == ConnectivityResult.wifi ||
          r == ConnectivityResult.mobile ||
          r == ConnectivityResult.ethernet);
      if (hasNetwork) {
        // Debounce: network changes fire multiple times during handoff
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
    final pairedServers = _ref.read(pairedServersProvider);
    if (pairedServers.isEmpty) return;

    _running = true;
    state = const ReconnectState(status: ReconnectStatus.scanning);

    String? foundServerId;
    try {
      await for (final snapshot in LanScanner.scan()) {
        for (final found in snapshot) {
          // Match against any known paired server
          final match = pairedServers
              .where((p) => p.serverId == found.serverId)
              .firstOrNull;
          if (match != null && found.host != match.host) {
            // Host changed — update stored host
            await _ref
                .read(pairedServersProvider.notifier)
                .updateHost(match.serverId, found.host);
            foundServerId = match.serverId;
          } else if (match != null) {
            // Same host — touch lastSeen
            await _ref
                .read(pairedServersProvider.notifier)
                .updateHost(match.serverId, found.host);
            foundServerId = match.serverId;
          }
        }
      }
    } catch (_) {}

    if (foundServerId != null) {
      state = ReconnectState(
          status: ReconnectStatus.found, updatedServerId: foundServerId);
    } else {
      // Fallback: probe recentHosts for active paired servers
      for (final paired in pairedServers) {
        if (paired.recentHosts.isEmpty) continue;
        final liveHost = await LanScanner.probeRecentHosts(
            paired.recentHosts, paired.port);
        if (liveHost != null) {
          await _ref
              .read(pairedServersProvider.notifier)
              .updateHost(paired.serverId, liveHost);
          foundServerId = paired.serverId;
          break;
        }
      }
      state = foundServerId != null
          ? ReconnectState(
              status: ReconnectStatus.found, updatedServerId: foundServerId)
          : const ReconnectState(status: ReconnectStatus.notFound);
    }

    _running = false;
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
