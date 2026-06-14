// app/lib/state/server_config.dart
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'connection_url.dart';

/// Single model replacing the former ServerEntry + PairedServer split.
/// [serverId] non-null means the connection was established via PIN/QR pairing.
/// Manual (unauthenticated) connections have serverId == null.
class Connection {
  final String id; // local UUID, list key
  final String name; // user-editable display name
  final String emoji;
  final String url; // scheme://host:port — single source of truth for address
  final String? token; // device token from pairing (null = no auth)
  final String? serverId; // stable server identity; null = manually added
  final List<String> recentHosts; // past IPs for cross-network reconnect
  final List<String> recentUrls; // past full base URLs for reconnect
  final List<String> pinnedUrls; // stable addresses kept across pruning
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
    this.recentUrls = const [],
    this.pinnedUrls = const [],
    this.lastConnected,
    this.lastSeen,
  });

  bool get isPaired => serverId != null && token != null;

  String get httpBase => url;
  String get apiBase => '${url.replaceFirst(RegExp(r'/$'), '')}/api';
  String get wsBase => webSocketBaseForHttpBase(url);
  String get host => Uri.parse(url).host;
  int get port => Uri.parse(url).port;

  Map<String, String> get authHeaders => token != null && token!.isNotEmpty
      ? {'Authorization': 'Bearer $token'}
      : const {};

  Connection copyWith({
    String? name,
    String? emoji,
    String? url,
    String? token,
    String? serverId,
    List<String>? recentHosts,
    List<String>? recentUrls,
    List<String>? pinnedUrls,
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
        recentUrls: recentUrls ?? this.recentUrls,
        pinnedUrls: pinnedUrls ?? this.pinnedUrls,
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
        'recentUrls': recentUrls,
        'pinnedUrls': pinnedUrls,
        'lastConnected': lastConnected?.toIso8601String(),
        'lastSeen': lastSeen?.toIso8601String(),
      };

  factory Connection.fromJson(Map<String, dynamic> j) {
    final url = j['url'] as String;
    final recentHosts = ((j['recentHosts'] as List?) ?? []).cast<String>();
    final rawRecentUrls = ((j['recentUrls'] as List?) ?? []).cast<String>();
    final pinnedUrls = ((j['pinnedUrls'] as List?) ?? []).cast<String>();
    final uri = Uri.tryParse(url);
    final legacyUrls = rawRecentUrls.isNotEmpty || uri == null
        ? const <String>[]
        : [
            for (final host in recentHosts) '${uri.scheme}://$host:${uri.port}',
          ];
    final recentUrls = rawRecentUrls.isNotEmpty ? rawRecentUrls : legacyUrls;
    return Connection(
      id: j['id'] as String,
      name: j['name'] as String,
      emoji: j['emoji'] as String? ?? '🖥️',
      url: url,
      token: j['token'] as String?,
      serverId: j['serverId'] as String?,
      recentHosts: recentHosts,
      recentUrls: _normalizeUrlList(recentUrls),
      pinnedUrls: _normalizeUrlList(pinnedUrls),
      lastConnected: j['lastConnected'] != null
          ? DateTime.tryParse(j['lastConnected'] as String)
          : null,
      lastSeen: j['lastSeen'] != null
          ? DateTime.tryParse(j['lastSeen'] as String)
          : null,
    );
  }

  static List<String> _normalizeUrlList(Iterable<String> urls) {
    final seen = <String>{};
    return [
      for (final url in urls)
        if (url.trim().isNotEmpty)
          if (seen.add(url.trim().replaceFirst(RegExp(r'/$'), '')))
            url.trim().replaceFirst(RegExp(r'/$'), ''),
    ];
  }
}

class ConnectionsNotifier extends StateNotifier<List<Connection>> {
  ConnectionsNotifier() : super([]) {
    _load();
  }

  static const _key =
      'connections_v2'; // new key — clean break from v1 + paired_servers
  static const _deviceIdKey = 'device_id';
  static const _uuid = Uuid();
  static const int maxRecentUrls = 3;
  static const int maxPinnedUrls = 5;

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

  /// Updates url for a paired connection after rediscovery or re-pairing.
  /// Pushes old host into recentHosts (capped at 5).
  Future<Connection?> updateUrl(String id, String newUrl) async {
    Connection? updated;
    state = [
      for (final c in state)
        if (c.id == id)
          updated = c.copyWith(
            url: newUrl,
            lastSeen: DateTime.now(),
            recentHosts: newUrl != c.url
                ? [
                    c.host,
                    ...c.recentHosts.where((h) => h != Uri.parse(newUrl).host),
                  ].take(5).toList()
                : c.recentHosts,
            recentUrls: newUrl != c.url
                ? _pruneRecentUrls(
                    [
                      c.url,
                      ...c.recentUrls,
                    ],
                    currentUrl: newUrl,
                    pinnedUrls: c.pinnedUrls,
                  )
                : c.recentUrls,
          )
        else
          c,
    ];
    await _save();
    return updated;
  }

  Future<void> pinUrl(String id, String url) async {
    final normalized = _normalizeUrl(url);
    if (normalized.isEmpty) return;
    state = [
      for (final c in state)
        if (c.id == id)
          c.copyWith(
            pinnedUrls: _prunePinnedUrls([normalized, ...c.pinnedUrls]),
            recentUrls: c.recentUrls
                .where((u) => _normalizeUrl(u) != normalized)
                .toList(),
          )
        else
          c,
    ];
    await _save();
  }

  Future<void> unpinUrl(String id, String url) async {
    final normalized = _normalizeUrl(url);
    state = [
      for (final c in state)
        c.id == id
            ? c.copyWith(
                pinnedUrls: c.pinnedUrls
                    .where((u) => _normalizeUrl(u) != normalized)
                    .toList(),
              )
            : c,
    ];
    await _save();
  }

  Future<void> removeRecentUrl(String id, String url) async {
    final normalized = _normalizeUrl(url);
    state = [
      for (final c in state)
        c.id == id
            ? c.copyWith(
                recentUrls: c.recentUrls
                    .where((u) => _normalizeUrl(u) != normalized)
                    .toList(),
              )
            : c,
    ];
    await _save();
  }

  Future<void> clearRecentUrls(String id) async {
    state = [
      for (final c in state) c.id == id ? c.copyWith(recentUrls: const []) : c,
    ];
    await _save();
  }

  static List<String> _pruneRecentUrls(
    Iterable<String> urls, {
    required String currentUrl,
    required List<String> pinnedUrls,
  }) {
    final current = _normalizeUrl(currentUrl);
    final pinned =
        pinnedUrls.map(_normalizeUrl).where((u) => u.isNotEmpty).toSet();
    final seen = <String>{};
    final result = <String>[];
    for (final raw in urls) {
      final url = _normalizeUrl(raw);
      if (url.isEmpty || url == current || pinned.contains(url)) continue;
      if (!seen.add(url)) continue;
      result.add(url);
      if (result.length >= maxRecentUrls) break;
    }
    return result;
  }

  static List<String> _prunePinnedUrls(Iterable<String> urls) {
    final seen = <String>{};
    final result = <String>[];
    for (final raw in urls) {
      final url = _normalizeUrl(raw);
      if (url.isEmpty || !seen.add(url)) continue;
      result.add(url);
      if (result.length >= maxPinnedUrls) break;
    }
    return result;
  }

  static String _normalizeUrl(String url) =>
      url.trim().replaceFirst(RegExp(r'/$'), '');

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

  static Future<String> getDeviceName() async {
    try {
      final info = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final d = await info.androidInfo;
        final brand = d.brand.isNotEmpty ? d.brand : '';
        final model = d.model.isNotEmpty ? d.model : 'Android';
        // Avoid redundant prefix like "samsung Samsung Galaxy S24"
        if (brand.isNotEmpty &&
            !model.toLowerCase().startsWith(brand.toLowerCase())) {
          return '${_capitalize(brand)} $model';
        }
        return model;
      }
      if (Platform.isIOS) {
        final d = await info.iosInfo;
        return d.name.isNotEmpty ? d.name : d.utsname.machine;
      }
      return '${Platform.operatingSystem} device';
    } catch (_) {
      return 'Mobile device';
    }
  }

  static String _capitalize(String s) =>
      s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

  /// Creates a new [Connection] ID.
  static String newId() => _uuid.v4();
}

final connectionsProvider =
    StateNotifierProvider<ConnectionsNotifier, List<Connection>>(
        (_) => ConnectionsNotifier());

/// 本设备的唯一 deviceId，首次启动时生成并持久化。
final deviceIdProvider = FutureProvider<String>(
  (_) => ConnectionsNotifier.getOrCreateDeviceId(),
);

final activeConnectionProvider = StateProvider<Connection?>((_) => null);
