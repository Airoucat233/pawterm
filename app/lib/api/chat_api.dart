import 'dart:convert';

import 'package:http/http.dart' as http;

/// Turn state reported by GET /chat/:uuid/status
enum TurnState { live, done, running, unknown }

class TurnStatus {
  final TurnState state;
  TurnStatus(this.state);
  factory TurnStatus.fromJson(Map<String, dynamic> j) {
    final s = j['state'] as String? ?? 'unknown';
    return TurnStatus(switch (s) {
      'live' => TurnState.live,
      'done' => TurnState.done,
      'running' => TurnState.running,
      _ => TurnState.unknown,
    });
  }
}

class ChatApiException implements Exception {
  final int status;
  final String message;
  ChatApiException(this.status, this.message);
  @override
  String toString() => 'ChatApiException($status): $message';
}

/// REST 客户端：与 chat-rest.ts 一一对应。
/// SSE 事件流是另一条 socket（见 SseClient），不在此类中处理。
class ChatApi {
  final String httpBase;
  ChatApi(this.httpBase);

  /// Start a new turn: send first message, optionally specifying model/permission.
  /// [uuid] is the Claude session UUID (client-generated for new sessions, or
  /// the existing resumeId for existing sessions).
  Future<void> turn({
    required String uuid,
    required String cwd,
    required String text,
    String? model,
    String? permissionMode,
  }) async {
    final resp = await http.post(
      Uri.parse('$httpBase/chat/$uuid/turn'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'cwd': cwd,
        'text': text,
        if (model != null) 'model': model,
        if (permissionMode != null) 'permission_mode': permissionMode,
      }),
    );
    if (resp.statusCode == 409) {
      throw ChatApiException(409, 'turn already active');
    }
    if (resp.statusCode != 200) {
      throw ChatApiException(resp.statusCode, resp.body);
    }
  }

  Future<TurnStatus> status(String uuid) async {
    final resp = await http
        .get(Uri.parse('$httpBase/chat/$uuid/status'))
        .timeout(const Duration(seconds: 4));
    if (resp.statusCode != 200) return TurnStatus(TurnState.unknown);
    return TurnStatus.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  Future<void> answerQuestion(
    String uuid,
    String toolUseId,
    Map<String, String> answers,
    Map<String, Map<String, String>>? annotations,
  ) async {
    final resp = await http.post(
      Uri.parse('$httpBase/chat/$uuid/answer-question'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'tool_use_id': toolUseId,
        'answers': answers,
        if (annotations != null) 'annotations': annotations,
      }),
    );
    if (resp.statusCode != 200) {
      throw ChatApiException(resp.statusCode, resp.body);
    }
  }

  Future<void> interrupt(String uuid) async {
    await http.post(Uri.parse('$httpBase/chat/$uuid/interrupt'));
  }

  Future<void> setModel(String uuid, String model) async {
    await http.post(
      Uri.parse('$httpBase/chat/$uuid/set-model'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'model': model}),
    );
  }

  Future<void> setPermissionMode(String uuid, String mode) async {
    await http.post(
      Uri.parse('$httpBase/chat/$uuid/set-permission-mode'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'mode': mode}),
    );
  }

  Future<void> close(String uuid) async {
    await http.delete(Uri.parse('$httpBase/chat/$uuid'));
  }
}
