import 'dart:convert';

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
