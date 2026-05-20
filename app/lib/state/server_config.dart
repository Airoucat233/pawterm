// app/lib/state/server_config.dart
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// Single model replacing the former ServerEntry + PairedServer split.
/// [serverId] non-null means the connection was established via PIN/QR pairing.
/// Manual (unauthenticated) connections have serverId == null.
class Connection {
  final String id;               // local UUID, list key
  final String name;             // user-editable display name
  final String emoji;
  final String url;              // http://host:port — single source of truth for address
  final String? token;           // device token from pairing (null = no auth)
  final String? serverId;        // stable server identity; null = manually added
  final List<String> recentHosts; // past IPs for cross-network reconnect
  final DateTime? lastConnected;
  final DateTime? lastSeen;

  const Connection({
    required this.id,
    required this.name,
    required this.emoji,
    required this.url,
    this.token,
    this.serverId,
    this.recentHosts = const [],
    this.lastConnected,
    this.lastSeen,
  });

  bool get isPaired => serverId != null && token != null;

  String get httpBase => url;
  String get wsBase => url.replaceFirst(RegExp(r'^http'), 'ws');
  String get host => Uri.parse(url).host;
  int get port => Uri.parse(url).port;

  Map<String, String> get authHeaders =>
      token != null && token!.isNotEmpty
          ? {'Authorization': 'Bearer $token'}
          : const {};

  Connection copyWith({
    String? name,
    String? emoji,
    String? url,
    String? token,
    String? serverId,
    List<String>? recentHosts,
    DateTime? lastConnected,
    DateTime? lastSeen,
  }) =>
      Connection(
        id: id,
        name: name ?? this.name,
        emoji: emoji ?? this.emoji,
        url: url ?? this.url,
        token: token ?? this.token,
        serverId: serverId ?? this.serverId,
        recentHosts: recentHosts ?? this.recentHosts,
        lastConnected: lastConnected ?? this.lastConnected,
        lastSeen: lastSeen ?? this.lastSeen,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'emoji': emoji,
        'url': url,
        if (token != null) 'token': token,
        if (serverId != null) 'serverId': serverId,
        'recentHosts': recentHosts,
        'lastConnected': lastConnected?.toIso8601String(),
        'lastSeen': lastSeen?.toIso8601String(),
      };

  factory Connection.fromJson(Map<String, dynamic> j) => Connection(
        id: j['id'] as String,
        name: j['name'] as String,
        emoji: j['emoji'] as String? ?? '🖥️',
        url: j['url'] as String,
        token: j['token'] as String?,
        serverId: j['serverId'] as String?,
        recentHosts: ((j['recentHosts'] as List?) ?? []).cast<String>(),
        lastConnected: j['lastConnected'] != null
            ? DateTime.tryParse(j['lastConnected'] as String)
            : null,
        lastSeen: j['lastSeen'] != null
            ? DateTime.tryParse(j['lastSeen'] as String)
            : null,
      );
}

class ConnectionsNotifier extends StateNotifier<List<Connection>> {
  ConnectionsNotifier() : super([]) {
    _load();
  }

  static const _key = 'connections_v2';   // new key — clean break from v1 + paired_servers
  static const _deviceIdKey = 'device_id';
  static const _uuid = Uuid();

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return;
    try {
      final list = (jsonDecode(raw) as List)
          .cast<Map<String, dynamic>>()
          .map(Connection.fromJson)
          .toList();
      state = list;
    } catch (_) {}
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _key, jsonEncode(state.map((e) => e.toJson()).toList()));
  }

  Future<Connection> add(Connection conn) async {
    state = [...state, conn];
    await _save();
    return conn;
  }

  Future<void> update(Connection conn) async {
    state = [for (final e in state) e.id == conn.id ? conn : e];
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

  /// Updates url for a paired connection after LAN rediscovery.
  /// Pushes old host into recentHosts (capped at 5).
  Future<void> updateUrl(String id, String newUrl) async {
    state = [
      for (final c in state)
        if (c.id == id)
          c.copyWith(
            url: newUrl,
            lastSeen: DateTime.now(),
            recentHosts: newUrl != c.url
                ? [
                    c.host,
                    ...c.recentHosts
                        .where((h) => h != Uri.parse(newUrl).host),
                  ].take(5).toList()
                : c.recentHosts,
          )
        else
          c,
    ];
    await _save();
  }

  // ─── Static helpers (formerly on PairedServersNotifier) ───────────────────

  static Future<String> getOrCreateDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString(_deviceIdKey);
    if (id == null) {
      id = const Uuid().v4();
      await prefs.setString(_deviceIdKey, id);
    }
    return id;
  }

  static String get deviceName {
    try {
      if (Platform.isAndroid) return 'Android device';
      if (Platform.isIOS) return 'iPhone / iPad';
      return '${Platform.operatingSystem} device';
    } catch (_) {
      return 'Mobile device';
    }
  }

  /// Creates a new [Connection] ID.
  static String newId() => _uuid.v4();
}

final connectionsProvider =
    StateNotifierProvider<ConnectionsNotifier, List<Connection>>(
        (_) => ConnectionsNotifier());

final activeConnectionProvider = StateProvider<Connection?>((_) => null);
