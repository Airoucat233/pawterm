import 'dart:convert';

import 'package:http/http.dart' as http;

class Idea {
  final String id;
  final String text;
  final String status;
  final int createdAt;
  final int updatedAt;

  const Idea({
    required this.id,
    required this.text,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
  });

  factory Idea.fromJson(Map<String, dynamic> json) => Idea(
        id: json['id'] as String? ?? '',
        text: json['text'] as String? ?? '',
        status: json['status'] as String? ?? 'active',
        createdAt: (json['createdAt'] as num?)?.toInt() ?? 0,
        updatedAt: (json['updatedAt'] as num?)?.toInt() ?? 0,
      );
}

class IdeasApi {
  final String baseUrl;
  final String? _token;

  IdeasApi(this.baseUrl, {String? token}) : _token = token;

  String get _apiBase => baseUrl.endsWith('/api') ? baseUrl : '$baseUrl/api';

  Map<String, String> get _headers => {
        if (_token != null) 'Authorization': 'Bearer $_token',
        'Content-Type': 'application/json',
      };

  Uri _u(String path, [Map<String, dynamic>? query]) {
    final q = query?.map((k, v) => MapEntry(k, v.toString()));
    return Uri.parse('$_apiBase$path').replace(queryParameters: q);
  }

  Future<List<Idea>> list({String status = 'active'}) async {
    final resp =
        await http.get(_u('/ideas', {'status': status}), headers: _headers);
    if (resp.statusCode != 200) throw Exception(resp.body);
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    final raw = body['ideas'] as List? ?? const [];
    return raw.map((e) => Idea.fromJson(Map<String, dynamic>.from(e))).toList();
  }

  Future<Idea> create(String text) =>
      _ideaAction('create', payload: {'text': text});

  Future<Idea> update(String id, String text) =>
      _ideaAction('update', id: id, payload: {'text': text});

  Future<Idea> archive(String id) => _ideaAction('archive', id: id);

  Future<Idea> unarchive(String id) => _ideaAction('unarchive', id: id);

  Future<void> delete(String id) async {
    final resp = await http.post(
      _u('/ideas'),
      headers: _headers,
      body: jsonEncode({'action': 'delete', 'id': id}),
    );
    if (resp.statusCode != 200) throw Exception(resp.body);
  }

  Future<Idea> _ideaAction(
    String action, {
    String? id,
    Map<String, dynamic>? payload,
  }) async {
    final resp = await http.post(
      _u('/ideas'),
      headers: _headers,
      body: jsonEncode({
        'action': action,
        if (id != null) 'id': id,
        if (payload != null) 'payload': payload,
      }),
    );
    if (resp.statusCode != 200) throw Exception(resp.body);
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    return Idea.fromJson(Map<String, dynamic>.from(body['idea'] as Map));
  }
}
