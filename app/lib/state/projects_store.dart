import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

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
      .get(Uri.parse('${conn.httpBase}/projects'), headers: conn.authHeaders)
      .timeout(const Duration(seconds: 5));
  if (resp.statusCode != 200) {
    throw Exception('HTTP ${resp.statusCode}: ${resp.body}');
  }
  final list = jsonDecode(resp.body) as List;
  return list.map((e) => Project.fromJson(Map<String, dynamic>.from(e))).toList();
});

final selectedProjectProvider = StateProvider<Project?>((ref) => null);

/// Sessions list for a given project path. Family keyed by cwd.
final sessionsProvider = FutureProvider.family<List<SessionSummary>, String>((ref, cwd) async {
  final conn = ref.watch(activeConnectionProvider);
  if (conn == null) return [];
  final api = SessionsApi(conn.httpBase, token: conn.token);
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

  static Map<String, dynamic> defaultRuntimeForAgent(AgentKind agent) => switch (agent) {
        AgentKind.claude => {'agent': 'claude', 'permission_mode': 'acceptEdits'},
        AgentKind.codex => {'agent': 'codex', 'sandbox': 'workspace-write', 'approval_policy': 'on-request'},
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
}

final currentSessionProvider = StateProvider<CurrentSession?>((ref) => null);

class ModelOption {
  final String id;
  final String label;
  final String tier;
  final String description;
  const ModelOption(this.id, this.label, this.tier, this.description);

  factory ModelOption.fromServer(ServerModelInfo m) => ModelOption(
    m.id, m.label, m.tier,
    switch (m.tier) {
      'powerful' => '深度推理',
      'cheap'    => '轻量快速',
      _          => '日常推荐',
    },
  );

  static ModelOption custom(String id) =>
      ModelOption(id, id.split('.').last.split('-').take(3).join('-'), 'fast', '自定义');
}

const knownModels = <ModelOption>[
  ModelOption('claude-sonnet-4-6', 'Sonnet 4.6', 'fast', '日常推荐'),
  ModelOption('claude-opus-4-7', 'Opus 4.7', 'powerful', '深度推理'),
  ModelOption('claude-haiku-4-5', 'Haiku 4.5', 'cheap', '轻量快速'),
];

final currentModelProvider = StateProvider<ModelOption>((ref) => knownModels.first);
