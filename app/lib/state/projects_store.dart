import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../api/agents_api.dart';
import '../api/chat_api.dart';
import '../api/sessions_api.dart';
import 'server_config.dart';

class Project {
  final String name;
  final String path;
  const Project({required this.name, required this.path});

  factory Project.fromJson(Map<String, dynamic> json) =>
      Project(name: json['name'] as String, path: json['path'] as String);
}

final projectsProvider = FutureProvider<List<Project>>((ref) async {
  final conn = ref.watch(activeConnectionProvider);
  if (conn == null) return [];
  final resp = await http
      .get(Uri.parse('${conn.apiBase}/projects'), headers: conn.authHeaders)
      .timeout(const Duration(seconds: 5));
  if (resp.statusCode != 200) {
    throw Exception('HTTP ${resp.statusCode}: ${resp.body}');
  }
  final list = jsonDecode(resp.body) as List;
  return list
      .map((e) => Project.fromJson(Map<String, dynamic>.from(e)))
      .toList();
});

final selectedProjectProvider = StateProvider<Project?>((ref) => null);

/// Sessions list for a given project path. Family keyed by cwd.
final sessionsProvider =
    FutureProvider.family<List<SessionSummary>, String>((ref, cwd) async {
  final conn = ref.watch(activeConnectionProvider);
  if (conn == null) return [];
  final api = SessionsApi(conn.apiBase, token: conn.token);
  return api.list(cwd);
});

class CurrentSession {
  /// project working directory
  final String cwd;

  /// session_id to resume; null means start a fresh session
  final String? resumeId;

  /// human label shown in app bar
  final String label;

  /// 只读模式：不开 WebSocket、只通过 HTTP 翻历史，禁用输入。
  /// 用于"该 session 正被另一个 CLI 终端持有，用户选择不抢占"的场景。
  final bool readOnly;
  final AgentKind agent;
  final Map<String, dynamic> runtime;

  factory CurrentSession({
    required String cwd,
    required String label,
    String? resumeId,
    bool readOnly = false,
    AgentKind agent = AgentKind.claude,
    Map<String, dynamic>? runtime,
  }) =>
      CurrentSession._(
        cwd: cwd,
        label: label,
        resumeId: resumeId,
        readOnly: readOnly,
        agent: agent,
        runtime: Map.unmodifiable(runtime ?? defaultRuntimeForAgent(agent)),
      );

  const CurrentSession._({
    required this.cwd,
    required this.label,
    this.resumeId,
    this.readOnly = false,
    required this.agent,
    required this.runtime,
  });

  static Map<String, dynamic> defaultRuntimeForAgent(AgentKind agent) =>
      switch (agent) {
        AgentKind.claude => {
            'agent': 'claude',
            'permission_mode': 'acceptEdits'
          },
        AgentKind.codex => {
            'agent': 'codex',
            'sandbox': 'workspace-write',
            'approval_policy': 'on-request',
            'reasoning_effort': 'medium'
          },
        AgentKind.gemini => {'agent': 'gemini'},
      };

  CurrentSession copyWith({
    String? cwd,
    String? resumeId,
    String? label,
    bool? readOnly,
    AgentKind? agent,
    Map<String, dynamic>? runtime,
  }) =>
      CurrentSession(
        cwd: cwd ?? this.cwd,
        resumeId: resumeId ?? this.resumeId,
        label: label ?? this.label,
        readOnly: readOnly ?? this.readOnly,
        agent: agent ?? this.agent,
        runtime: runtime ?? this.runtime,
      );

  Map<String, dynamic> toJson() => {
        'cwd': cwd,
        if (resumeId != null) 'resumeId': resumeId,
        'label': label,
        'readOnly': readOnly,
        'agent': agent.wire,
        'runtime': runtime,
      };

  factory CurrentSession.fromJson(Map<String, dynamic> json) => CurrentSession(
        cwd: json['cwd'] as String? ?? '',
        resumeId: json['resumeId'] as String?,
        label: json['label'] as String? ?? '',
        readOnly: json['readOnly'] as bool? ?? false,
        agent: AgentKind.fromWire(json['agent'] as String?),
        runtime: Map<String, dynamic>.from(json['runtime'] ?? const {}),
      );
}

final currentSessionProvider = StateProvider<CurrentSession?>((ref) => null);

/// 每个 agent 的用户自定义 runtime 覆盖层（跨 cwd 共享）。
///
/// 数据流：用户在 runtime sheet 改 permission_mode / model / thinking 等任意
/// 字段时，除了写当前 session.runtime + 通知服务端持久化之外，还会调
/// agentRuntimeOverridesProvider.patch()，把这一份"用户偏好"按 agent 维度
/// 保存下来。下次同 agent 新建任意 cwd 的 session 时，main_shell 的
/// _defaultRuntimeForAgent 会把 overrides merge 进 server defaults。
///
/// 为什么不绑定 cwd：用户的意图（"我希望 Claude 默认走 bypassPermissions"）
/// 通常是跨项目的偏好，按项目分实际只会让人困惑。Codex 那边也是按 agent
/// 维度配 reasoning_effort / sandbox。
///
/// 存储：SharedPreferences key 'agent_runtime_overrides_v1'，
/// `{claude: {permission_mode: 'bypassPermissions', model: '...'}, codex: {...}}`
class AgentRuntimeOverridesNotifier
    extends StateNotifier<Map<AgentKind, Map<String, dynamic>>> {
  AgentRuntimeOverridesNotifier() : super(const {}) {
    _load();
  }

  static const _key = 'agent_runtime_overrides_v1';
  bool _dirtyBeforeLoad = false;
  bool _loaded = false;

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) {
      _loaded = true;
      return;
    }
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final loaded = <AgentKind, Map<String, dynamic>>{};
      decoded.forEach((k, v) {
        if (v is! Map) return;
        final agent = AgentKind.fromWire(k);
        loaded[agent] = Map<String, dynamic>.from(v);
      });
      state = _dirtyBeforeLoad ? {...loaded, ...state} : loaded;
    } catch (_) {
      // 解析失败：清掉脏 prefs，回退到空 overrides。
    }
    _loaded = true;
  }

  Map<String, dynamic> forAgent(AgentKind agent) =>
      state[agent] ?? const <String, dynamic>{};

  /// 增量合并 patch 到指定 agent 的 overrides，立刻持久化。
  /// 传 null 值的字段会被显式移除（让 server default 重新生效）。
  Future<void> patch(AgentKind agent, Map<String, dynamic> patch) async {
    if (!_loaded) _dirtyBeforeLoad = true;
    final existing = state[agent] ?? const <String, dynamic>{};
    final merged = {...existing, ...patch};
    merged.removeWhere((_, v) => v == null);
    state = {...state, agent: merged};
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _key, jsonEncode(state.map((k, v) => MapEntry(k.wire, v))));
  }

  Future<void> clear(AgentKind agent) async {
    if (!_loaded) _dirtyBeforeLoad = true;
    final next = Map<AgentKind, Map<String, dynamic>>.from(state);
    next.remove(agent);
    state = next;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _key, jsonEncode(state.map((k, v) => MapEntry(k.wire, v))));
  }
}

final agentRuntimeOverridesProvider = StateNotifierProvider<
    AgentRuntimeOverridesNotifier, Map<AgentKind, Map<String, dynamic>>>(
  (ref) => AgentRuntimeOverridesNotifier(),
);

class ModelOption {
  final String id;
  final String label;
  final String tier;
  final String description;
  const ModelOption(this.id, this.label, this.tier, this.description);

  factory ModelOption.fromServer(ServerModelInfo m) => ModelOption(
        m.id,
        m.label,
        m.tier,
        m.description?.trim().isNotEmpty == true
            ? m.description!.trim()
            : switch (m.tier) {
                'powerful' => '深度推理',
                'cheap' => '轻量快速',
                'coding' => 'Codex 优化',
                _ => '日常推荐',
              },
      );

  static ModelOption custom(String id) =>
      ModelOption(id, _customModelLabel(id), 'fast', '自定义');
}

String _customModelLabel(String id) {
  final trimmed = id.trim();
  if (trimmed.isEmpty) return trimmed;
  final providerParts = trimmed.split(RegExp(r'[/:\s]'));
  return providerParts.isNotEmpty ? providerParts.last : trimmed;
}

// ID 跟 server `/models` 默认值、packages/shared protocol.ts 的 KNOWN_MODELS
// 三处保持一致。Fable 是 Claude Code 2.1 引入的 coding 档位（"fable-mythos"），
// 服务端 fallback 默认带上；列表里保留以便 picker 没拉到 server 数据时也能
// 兜底显示一份和最新 CLI 对齐的清单。
const knownModels = <ModelOption>[
  ModelOption('claude-sonnet-4-6', 'Sonnet 4.6', 'fast', '日常推荐'),
  ModelOption('claude-opus-4-8', 'Opus 4.8', 'powerful', '深度推理'),
  ModelOption('claude-haiku-4-5', 'Haiku 4.5', 'cheap', '轻量快速'),
  ModelOption('claude-fable-5', 'Fable 5', 'coding', 'Coding 优化'),
];

final currentModelProvider =
    StateProvider<ModelOption>((ref) => knownModels.first);
