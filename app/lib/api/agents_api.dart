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
