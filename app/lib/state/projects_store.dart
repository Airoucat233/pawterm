import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../api/chat_api.dart' show SessionHolder;
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
  /// 从会话列表预加载的 holder 信息。非 null 表示该 session 当前被另一个
  /// claude CLI 进程持有，可直接跳过 /chat/status 查询并展示接管弹窗。
  final SessionHolder? preloadedHolder;

  const CurrentSession({
    required this.cwd,
    required this.label,
    this.resumeId,
    this.readOnly = false,
    this.preloadedHolder,
  });

  CurrentSession copyWith({String? cwd, String? resumeId, String? label, bool? readOnly, SessionHolder? preloadedHolder}) =>
      CurrentSession(
        cwd: cwd ?? this.cwd,
        resumeId: resumeId ?? this.resumeId,
        label: label ?? this.label,
        readOnly: readOnly ?? this.readOnly,
        preloadedHolder: preloadedHolder ?? this.preloadedHolder,
      );
}

final currentSessionProvider = StateProvider<CurrentSession?>((ref) => null);

class ModelOption {
  final String id;
  final String label;
  final String tier;
  final String description;
  const ModelOption(this.id, this.label, this.tier, this.description);
}

const knownModels = <ModelOption>[
  ModelOption('claude-sonnet-4-6', 'Sonnet 4.6', 'fast', '日常推荐'),
  ModelOption('claude-opus-4-7', 'Opus 4.7', 'powerful', '深度推理'),
  ModelOption('claude-haiku-4-5', 'Haiku 4.5', 'cheap', '轻量快速'),
];

final currentModelProvider = StateProvider<ModelOption>((ref) => knownModels.first);
