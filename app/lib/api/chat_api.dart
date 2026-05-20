import 'dart:convert';

import 'package:http/http.dart' as http;

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
  }) async {
    final resp = await http.post(
      Uri.parse('$httpBase/chat/stream'),
      headers: {'Content-Type': 'application/json', ..._auth},
      body: jsonEncode({
        'uuid': uuid,
        'cwd': cwd,
        'text': text,
        'device_id': deviceId,
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
  Uri eventsUrl(String uuid) =>
      Uri.parse('$httpBase/chat/events').replace(queryParameters: {'uuid': uuid});

  /// Check run state: live / done / running / unknown.
  Future<TurnStatus> status(String uuid) async {
    final resp = await http
        .get(Uri.parse('$httpBase/chat/status?uuid=${Uri.encodeQueryComponent(uuid)}'), headers: _auth)
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
      Uri.parse('$httpBase/chat/answer'),
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
  Future<void> interrupt(String uuid) async {
    await http.post(
      Uri.parse('$httpBase/chat/interrupt'),
      headers: {'Content-Type': 'application/json', ..._auth},
      body: jsonEncode({'uuid': uuid}),
    );
  }

  /// Change model mid-run.
  Future<void> model(String uuid, String modelId) async {
    await http.post(
      Uri.parse('$httpBase/chat/model'),
      headers: {'Content-Type': 'application/json', ..._auth},
      body: jsonEncode({'uuid': uuid, 'model': modelId}),
    );
  }

  /// Change permission mode mid-run.
  Future<void> permission(String uuid, String mode) async {
    await http.post(
      Uri.parse('$httpBase/chat/permission'),
      headers: {'Content-Type': 'application/json', ..._auth},
      body: jsonEncode({'uuid': uuid, 'mode': mode}),
    );
  }

  /// Take over a session from another holder.
  /// Throws [ChatApiException] with status 409 if the holder could not be stopped.
  Future<void> takeover(String uuid, {required String deviceId}) async {
    final resp = await http.post(
      Uri.parse('$httpBase/chat/takeover'),
      headers: {'Content-Type': 'application/json', ..._auth},
      body: jsonEncode({'uuid': uuid, 'device_id': deviceId}),
    );
    if (resp.statusCode != 200) {
      throw ChatApiException(resp.statusCode, resp.body);
    }
  }
}
