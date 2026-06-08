import 'dart:convert';

import 'package:http/http.dart' as http;

class SessionFileRef {
  final String id;
  final String sessionId;
  final String path;
  final String name;
  final String? cwd;

  const SessionFileRef({
    required this.id,
    required this.sessionId,
    required this.path,
    required this.name,
    this.cwd,
  });

  factory SessionFileRef.fromJson(Map<String, dynamic> json) => SessionFileRef(
        id: json['id'] as String? ?? '',
        sessionId: json['sessionId'] as String? ?? '',
        path: json['path'] as String? ?? '',
        name: json['name'] as String? ?? '',
        cwd: json['cwd'] as String?,
      );
}

class SessionFilesApi {
  final String baseUrl;
  final String? _token;

  SessionFilesApi(this.baseUrl, {String? token}) : _token = token;

  String get _apiBase => baseUrl.endsWith('/api') ? baseUrl : '$baseUrl/api';

  Map<String, String> get _headers => {
        if (_token != null) 'Authorization': 'Bearer $_token',
        'Content-Type': 'application/json',
      };

  Uri _u(String path, [Map<String, dynamic>? query]) {
    final q = query?.map((k, v) => MapEntry(k, v.toString()));
    return Uri.parse('$_apiBase$path').replace(queryParameters: q);
  }

  Future<List<SessionFileRef>> list(String sessionId) async {
    final resp = await http.get(
      _u('/session-files', {'sessionId': sessionId}),
      headers: _headers,
    );
    if (resp.statusCode != 200) throw Exception(resp.body);
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    final raw = body['files'] as List? ?? const [];
    return raw
        .map((e) => SessionFileRef.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  Future<SessionFileRef> add({
    required String sessionId,
    required String path,
    String? cwd,
  }) async {
    final resp = await http.post(
      _u('/session-files'),
      headers: _headers,
      body: jsonEncode({
        'action': 'add',
        'sessionId': sessionId,
        'payload': {
          'path': path,
          if (cwd != null) 'cwd': cwd,
        },
      }),
    );
    if (resp.statusCode != 200) throw Exception(resp.body);
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    return SessionFileRef.fromJson(
        Map<String, dynamic>.from(body['file'] as Map));
  }

  Future<void> remove({required String sessionId, required String id}) async {
    final resp = await http.post(
      _u('/session-files'),
      headers: _headers,
      body: jsonEncode({'action': 'remove', 'sessionId': sessionId, 'id': id}),
    );
    if (resp.statusCode != 200) throw Exception(resp.body);
  }
}
