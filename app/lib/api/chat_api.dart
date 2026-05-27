import 'dart:convert';

import 'package:http/http.dart' as http;

import 'agents_api.dart';

/// Run state reported by GET /chat/status?uuid=
enum TurnState { live, done, running, unknown }

class TurnStatus {
  final TurnState state;

  /// Only present when state == running: the device id holding the session.
  /// "server" means a PC CLI process; any other string is a mobile device id.
  final String? holderDeviceId;

  TurnStatus(this.state, {this.holderDeviceId});

  factory TurnStatus.fromJson(Map<String, dynamic> j) {
    final s = j['state'] as String? ?? 'unknown';
    return TurnStatus(
      switch (s) {
        'live' => TurnState.live,
        'done' => TurnState.done,
        'running' => TurnState.running,
        _ => TurnState.unknown,
      },
      holderDeviceId: j['holder_device_id'] as String?,
    );
  }
}

class ChatApiException implements Exception {
  final int status;
  final String message;
  ChatApiException(this.status, this.message);
  @override
  String toString() => 'ChatApiException($status): $message';
}

/// REST client — mirrors chat-rest.ts endpoints.
/// SSE stream is handled separately via SseClient.
class ChatApi {
  final String httpBase;
  final String? _token;
  ChatApi(this.httpBase, {String? token}) : _token = token;
  String get _apiBase => httpBase.endsWith('/api') ? httpBase : '$httpBase/api';

  Map<String, String> get _auth =>
      _token != null ? {'Authorization': 'Bearer $_token'} : const {};

  /// Send a message and start streaming the response.
  /// Events arrive via GET /chat/events?uuid= (SseClient).
  /// Throws [ChatApiException] with status 409 if a run is already active.
  Future<void> stream({
    required String uuid,
    required String cwd,
    required String text,
    required String deviceId,
    String? model,
    String? permissionMode,
    AgentKind agent = AgentKind.claude,
    Map<String, dynamic>? runtime,
  }) async {
    final resp = await http.post(
      Uri.parse('$_apiBase/chat/stream'),
      headers: {'Content-Type': 'application/json', ..._auth},
      body: jsonEncode({
        'uuid': uuid,
        'cwd': cwd,
        'text': text,
        'device_id': deviceId,
        'agent': agent.wire,
        if (runtime != null) 'runtime': runtime,
        if (model != null) 'model': model,
        if (permissionMode != null) 'permission_mode': permissionMode,
      }),
    );
    if (resp.statusCode == 409) {
      throw ChatApiException(409, 'run already active');
    }
    if (resp.statusCode != 200) {
      throw ChatApiException(resp.statusCode, resp.body);
    }
  }

  /// Returns the SSE URL to pass to SseClient for the given session.
  Uri eventsUrl(String uuid, {AgentKind agent = AgentKind.claude}) =>
      Uri.parse('$_apiBase/chat/events')
          .replace(queryParameters: {'uuid': uuid, 'agent': agent.wire});

  /// Check run state: live / done / running / unknown.
  Future<TurnStatus> status(String uuid,
      {AgentKind agent = AgentKind.claude}) async {
    final resp = await http
        .get(
          Uri.parse('$_apiBase/chat/status')
              .replace(queryParameters: {'uuid': uuid, 'agent': agent.wire}),
          headers: _auth,
        )
        .timeout(const Duration(seconds: 4));
    if (resp.statusCode != 200) return TurnStatus(TurnState.unknown);
    return TurnStatus.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  /// Answer a pending AskUserQuestion tool call.
  Future<void> answer(
    String uuid,
    String toolUseId,
    Map<String, String> answers,
    Map<String, Map<String, String>>? annotations,
  ) async {
    final resp = await http.post(
      Uri.parse('$_apiBase/chat/answer'),
      headers: {'Content-Type': 'application/json', ..._auth},
      body: jsonEncode({
        'uuid': uuid,
        'tool_use_id': toolUseId,
        'answers': answers,
        if (annotations != null) 'annotations': annotations,
      }),
    );
    if (resp.statusCode != 200) {
      throw ChatApiException(resp.statusCode, resp.body);
    }
  }

  /// Interrupt the active run.
  Future<void> interrupt(String uuid,
      {AgentKind agent = AgentKind.claude}) async {
    await http.post(
      Uri.parse('$_apiBase/chat/interrupt'),
      headers: {'Content-Type': 'application/json', ..._auth},
      body: jsonEncode({'uuid': uuid, 'agent': agent.wire}),
    );
  }

  Future<void> runtime(
      String uuid, AgentKind agent, Map<String, dynamic> runtime) async {
    final resp = await http.post(
      Uri.parse('$_apiBase/chat/runtime'),
      headers: {'Content-Type': 'application/json', ..._auth},
      body: jsonEncode({'uuid': uuid, 'agent': agent.wire, 'runtime': runtime}),
    );
    if (resp.statusCode != 200) {
      throw ChatApiException(resp.statusCode, resp.body);
    }
  }

  /// Change model mid-run.
  Future<void> model(String uuid, String modelId) async {
    await http.post(
      Uri.parse('$_apiBase/chat/model'),
      headers: {'Content-Type': 'application/json', ..._auth},
      body: jsonEncode({'uuid': uuid, 'model': modelId}),
    );
  }

  /// Change permission mode mid-run.
  Future<void> permission(String uuid, String mode) async {
    await http.post(
      Uri.parse('$_apiBase/chat/permission'),
      headers: {'Content-Type': 'application/json', ..._auth},
      body: jsonEncode({'uuid': uuid, 'mode': mode}),
    );
  }

  /// Fetch available models and current provider from the server.
  Future<ServerModels> fetchModels() async {
    final resp = await http.get(
      Uri.parse('$_apiBase/models'),
      headers: _auth,
    );
    if (resp.statusCode != 200) {
      throw ChatApiException(resp.statusCode, resp.body);
    }
    return ServerModels.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  /// Take over a session from another holder.
  /// Throws [ChatApiException] with status 409 if the holder could not be stopped.
  Future<void> takeover(String uuid, {required String deviceId}) async {
    final resp = await http.post(
      Uri.parse('$_apiBase/chat/takeover'),
      headers: {'Content-Type': 'application/json', ..._auth},
      body: jsonEncode({'uuid': uuid, 'device_id': deviceId}),
    );
    if (resp.statusCode != 200) {
      throw ChatApiException(resp.statusCode, resp.body);
    }
  }
}

class ServerModelInfo {
  final String id;
  final String label;
  final String tier;
  const ServerModelInfo(
      {required this.id, required this.label, required this.tier});

  factory ServerModelInfo.fromJson(Map<String, dynamic> j) => ServerModelInfo(
        id: j['id'] as String,
        label: j['label'] as String,
        tier: j['tier'] as String? ?? 'fast',
      );
}

class ServerModels {
  final String provider; // 'anthropic' | 'bedrock' | 'vertex' | 'unknown'
  final String current;
  final List<ServerModelInfo> models;
  const ServerModels(
      {required this.provider, required this.current, required this.models});

  factory ServerModels.fromJson(Map<String, dynamic> j) => ServerModels(
        provider: j['provider'] as String? ?? 'anthropic',
        current: j['current'] as String? ?? '',
        models: ((j['models'] as List?) ?? [])
            .cast<Map<String, dynamic>>()
            .map(ServerModelInfo.fromJson)
            .toList(),
      );

  String get providerLabel => switch (provider) {
        'bedrock' => 'AWS Bedrock',
        'vertex' => 'Vertex AI',
        _ => 'Anthropic',
      };
}
