import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

class ServerEntry {
  final String id;
  final String name;
  final String emoji;
  final String url;
  final String? token;
  final DateTime? lastConnected;

  const ServerEntry({
    required this.id,
    required this.name,
    required this.emoji,
    required this.url,
    this.token,
    this.lastConnected,
  });

  String get httpBase => url;
  String get wsBase => url.replaceFirst(RegExp(r'^http'), 'ws');

  Map<String, String> get authHeaders =>
      token != null && token!.isNotEmpty
          ? {'Authorization': 'Bearer $token'}
          : const {};

  ServerEntry copyWith({
    String? name,
    String? emoji,
    String? url,
    String? token,
    DateTime? lastConnected,
  }) =>
      ServerEntry(
        id: id,
        name: name ?? this.name,
        emoji: emoji ?? this.emoji,
        url: url ?? this.url,
        token: token ?? this.token,
        lastConnected: lastConnected ?? this.lastConnected,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'emoji': emoji,
        'url': url,
        if (token != null) 'token': token,
        'lastConnected': lastConnected?.toIso8601String(),
      };

  factory ServerEntry.fromJson(Map<String, dynamic> j) => ServerEntry(
        id: j['id'] as String,
        name: j['name'] as String,
        emoji: j['emoji'] as String? ?? '🖥️',
        url: j['url'] as String,
        token: j['token'] as String?,
        lastConnected: j['lastConnected'] != null
            ? DateTime.tryParse(j['lastConnected'] as String)
            : null,
      );
}

class ConnectionsNotifier extends StateNotifier<List<ServerEntry>> {
  ConnectionsNotifier() : super([]) {
    _load();
  }

  static const _key = 'connections_v1';
  static const _uuid = Uuid();

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return;
    try {
      final list = (jsonDecode(raw) as List)
          .cast<Map<String, dynamic>>()
          .map(ServerEntry.fromJson)
          .toList();
      state = list;
    } catch (_) {}
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _key, jsonEncode(state.map((e) => e.toJson()).toList()));
  }

  Future<ServerEntry> add({
    required String name,
    required String emoji,
    required String url,
    String? token,
  }) async {
    final entry = ServerEntry(id: _uuid.v4(), name: name, emoji: emoji, url: url, token: token);
    state = [...state, entry];
    await _save();
    return entry;
  }

  Future<void> update(ServerEntry entry) async {
    state = [for (final e in state) e.id == entry.id ? entry : e];
    await _save();
  }

  Future<void> remove(String id) async {
    state = state.where((e) => e.id != id).toList();
    await _save();
  }

  Future<void> touch(String id) async {
    state = [
      for (final e in state)
        e.id == id ? e.copyWith(lastConnected: DateTime.now()) : e,
    ];
    await _save();
  }
}

final connectionsProvider =
    StateNotifierProvider<ConnectionsNotifier, List<ServerEntry>>(
        (_) => ConnectionsNotifier());

final activeConnectionProvider = StateProvider<ServerEntry?>((_) => null);

// ─── PairedServer — device-token based persistent pairing ────────────────────

class PairedServer {
  final String serverId;
  final String deviceToken;
  final String name;
  final String host;
  final int port;
  final List<String> recentHosts;
  final DateTime lastSeen;

  const PairedServer({
    required this.serverId,
    required this.deviceToken,
    required this.name,
    required this.host,
    required this.port,
    this.recentHosts = const [],
    required this.lastSeen,
  });

  String get httpBase => 'http://$host:$port';

  Map<String, String> get authHeaders =>
      {'Authorization': 'Bearer $deviceToken'};

  PairedServer copyWith({
    String? name,
    String? host,
    int? port,
    List<String>? recentHosts,
    DateTime? lastSeen,
  }) =>
      PairedServer(
        serverId: serverId,
        deviceToken: deviceToken,
        name: name ?? this.name,
        host: host ?? this.host,
        port: port ?? this.port,
        recentHosts: recentHosts ?? this.recentHosts,
        lastSeen: lastSeen ?? this.lastSeen,
      );

  Map<String, dynamic> toJson() => {
        'serverId': serverId,
        'deviceToken': deviceToken,
        'name': name,
        'host': host,
        'port': port,
        'recentHosts': recentHosts,
        'lastSeen': lastSeen.toIso8601String(),
      };

  factory PairedServer.fromJson(Map<String, dynamic> j) => PairedServer(
        serverId: j['serverId'] as String,
        deviceToken: j['deviceToken'] as String,
        name: j['name'] as String,
        host: j['host'] as String,
        port: j['port'] as int,
        recentHosts: ((j['recentHosts'] as List?) ?? []).cast<String>(),
        lastSeen: j['lastSeen'] != null
            ? DateTime.tryParse(j['lastSeen'] as String) ?? DateTime.now()
            : DateTime.now(),
      );
}

class PairedServersNotifier extends StateNotifier<List<PairedServer>> {
  PairedServersNotifier() : super([]) {
    _load();
  }

  static const _key = 'paired_servers';
  static const _deviceIdKey = 'device_id';

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return;
    try {
      final list = (jsonDecode(raw) as List)
          .cast<Map<String, dynamic>>()
          .map(PairedServer.fromJson)
          .toList();
      state = list;
    } catch (_) {}
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _key, jsonEncode(state.map((e) => e.toJson()).toList()));
  }

  /// Returns a stable per-install device ID.
  static Future<String> getOrCreateDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString(_deviceIdKey);
    if (id == null) {
      id = const Uuid().v4();
      await prefs.setString(_deviceIdKey, id);
    }
    return id;
  }

  /// Returns a human-readable device name without extra dependencies.
  static String get deviceName {
    try {
      if (Platform.isAndroid) return 'Android device';
      if (Platform.isIOS) return 'iPhone / iPad';
      return '${Platform.operatingSystem} device';
    } catch (_) {
      return 'Mobile device';
    }
  }

  Future<PairedServer> add(PairedServer server) async {
    // Remove any existing entry for the same serverId, then append new.
    state = [
      ...state.where((e) => e.serverId != server.serverId),
      server,
    ];
    await _save();
    return server;
  }

  Future<void> update(PairedServer server) async {
    state = [
      for (final e in state) e.serverId == server.serverId ? server : e,
    ];
    await _save();
  }

  Future<void> remove(String serverId) async {
    state = state.where((e) => e.serverId != serverId).toList();
    await _save();
  }

  /// Updates host for a known server (e.g. after LAN rediscovery).
  /// Moves the old host into recentHosts and updates lastSeen.
  Future<void> updateHost(String serverId, String newHost) async {
    state = [
      for (final e in state)
        if (e.serverId == serverId)
          e.copyWith(
            host: newHost,
            recentHosts: newHost != e.host
                ? [e.host, ...e.recentHosts.where((h) => h != newHost)]
                    .take(5)
                    .toList()
                : e.recentHosts,
            lastSeen: DateTime.now(),
          )
        else
          e,
    ];
    await _save();
  }
}

final pairedServersProvider =
    StateNotifierProvider<PairedServersNotifier, List<PairedServer>>(
        (_) => PairedServersNotifier());
