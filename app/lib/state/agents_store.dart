import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/agents_api.dart';
import 'server_config.dart';

final agentsProvider = FutureProvider<List<AgentInfo>>((ref) async {
  final conn = ref.watch(activeConnectionProvider);
  if (conn == null) return [];
  return AgentsApi(conn.apiBase, token: conn.token).list();
});

final projectDefaultAgentProvider =
    StateNotifierProvider<ProjectDefaultAgentNotifier, Map<String, AgentKind>>(
  (ref) => ProjectDefaultAgentNotifier(),
);

class ProjectDefaultAgentNotifier
    extends StateNotifier<Map<String, AgentKind>> {
  ProjectDefaultAgentNotifier() : super(const {}) {
    _load();
  }

  static const _key = 'project_default_agents_v1';
  bool _dirtyBeforeLoad = false;
  bool _loaded = false;

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) {
      _loaded = true;
      return;
    }
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    final loaded =
        decoded.map((k, v) => MapEntry(k, AgentKind.fromWire(v as String?)));
    state = _dirtyBeforeLoad ? {...loaded, ...state} : loaded;
    _loaded = true;
  }

  Future<void> setDefault(String cwd, AgentKind agent) async {
    if (!_loaded) _dirtyBeforeLoad = true;
    state = {...state, cwd: agent};
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _key, jsonEncode(state.map((k, v) => MapEntry(k, v.wire))));
  }

  AgentKind forProject(String cwd) => state[cwd] ?? AgentKind.claude;
}
