import 'dart:convert';

import 'package:http/http.dart' as http;

enum AgentKind {
  claude,
  codex,
  gemini;

  String get wire => name;

  static AgentKind fromWire(String? value) => switch (value) {
        'codex' => AgentKind.codex,
        'gemini' => AgentKind.gemini,
        _ => AgentKind.claude,
      };

  /// 这个 agent 在对话页的 UI 能力声明（P3 plugin 架构的能力层）。
  /// 渲染/分发逻辑应查询这里，而不是写 `if (agent == AgentKind.claude)`。
  AgentProfile get profile => AgentProfile.of(this);
}

/// 单个 agent 的对话页 UI 能力声明。把"哪个 agent 有哪些特性"集中成数据，
/// 取代散落各处的 `if (agent == ...)` 分支——这是 god-class → plugin 绞杀式
/// 重构的地基（见 docs/agent-chat-architecture.md：继承管机制、组合管能力）。
///
/// 注意：这套是**客户端 UI 渲染能力**（thinking 卡 / tasks chip / 审批卡 /
/// 权限选择器 / realtime 快照…）。服务端能力（streaming/history/...）走另一套
/// [AgentCapabilities]，从 /agents 响应解析，二者关注点不同。
class AgentProfile {
  /// 显示 thinking 卡 + thinking-tokens 角标（Claude 的 redacted-thinking）。
  final bool thinking;

  /// 显示后台 tasks chip（SDK 0.3.x task 生命周期，仅 Claude）。
  final bool tasks;

  /// 有"权限模式"概念（default/acceptEdits/plan/auto/dontAsk/bypass 选择器）。
  /// Codex 用 approval_policy / sandbox，不是这套，故为 false。
  final bool permissionMode;

  /// realtime item 快照增量 upsert（Codex 的 item/started→completed）。
  final bool realtime;

  /// 工具/命令审批卡（Codex 一直有；Claude 经权限对齐后也会有）。
  final bool approvals;

  /// 支持运行时切 model。
  final bool modelSwitch;

  const AgentProfile({
    this.thinking = false,
    this.tasks = false,
    this.permissionMode = false,
    this.realtime = false,
    this.approvals = false,
    this.modelSwitch = false,
  });

  static const _claude = AgentProfile(
    thinking: true,
    tasks: true,
    permissionMode: true,
    approvals: true,
    modelSwitch: true,
  );

  static const _codex = AgentProfile(
    realtime: true,
    approvals: true,
    modelSwitch: true,
  );

  static const _gemini = AgentProfile(
    modelSwitch: true,
  );

  static AgentProfile of(AgentKind kind) => switch (kind) {
        AgentKind.claude => _claude,
        AgentKind.codex => _codex,
        AgentKind.gemini => _gemini,
      };
}

class AgentCapabilities {
  final bool streaming;
  final bool history;
  final bool approvals;
  final bool modelSwitch;
  final bool runtimeSwitch;
  final bool rawEvents;

  const AgentCapabilities({
    required this.streaming,
    required this.history,
    required this.approvals,
    required this.modelSwitch,
    required this.runtimeSwitch,
    required this.rawEvents,
  });

  factory AgentCapabilities.fromJson(Map<String, dynamic> json) =>
      AgentCapabilities(
        streaming: json['streaming'] as bool? ?? false,
        history: json['history'] as bool? ?? false,
        approvals: json['approvals'] as bool? ?? false,
        modelSwitch: json['modelSwitch'] as bool? ?? false,
        runtimeSwitch: json['runtimeSwitch'] as bool? ?? false,
        rawEvents: json['rawEvents'] as bool? ?? false,
      );
}

class AgentInfo {
  final AgentKind kind;
  final String label;
  final String status;
  final String? statusMessage;
  final Map<String, dynamic> defaultRuntime;
  final AgentCapabilities capabilities;

  const AgentInfo({
    required this.kind,
    required this.label,
    required this.status,
    this.statusMessage,
    required this.defaultRuntime,
    required this.capabilities,
  });

  factory AgentInfo.fromJson(Map<String, dynamic> json) => AgentInfo(
        kind: AgentKind.fromWire(json['kind'] as String?),
        label: json['label'] as String? ?? 'Agent',
        status: json['status'] as String? ?? 'disabled',
        statusMessage: json['statusMessage'] as String?,
        defaultRuntime: Map.unmodifiable(
            Map<String, dynamic>.from(json['defaultRuntime'] ?? {})),
        capabilities: AgentCapabilities.fromJson(
            Map<String, dynamic>.from(json['capabilities'] ?? {})),
      );
}

class AgentsApi {
  final String baseUrl;
  final String? token;
  AgentsApi(this.baseUrl, {this.token});
  String get _apiBase => baseUrl.endsWith('/api') ? baseUrl : '$baseUrl/api';

  Map<String, String> get _auth =>
      token != null ? {'Authorization': 'Bearer $token'} : const {};

  Future<List<AgentInfo>> list() async {
    final resp = await http.get(Uri.parse('$_apiBase/agents'), headers: _auth);
    if (resp.statusCode != 200) {
      throw Exception('agents HTTP ${resp.statusCode}: ${resp.body}');
    }
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    final list = (body['agents'] as List? ?? const []);
    return list
        .map((e) => AgentInfo.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }
}
