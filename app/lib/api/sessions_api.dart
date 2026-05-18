import 'dart:convert';

import 'package:http/http.dart' as http;

import 'chat_api.dart' show SessionHolder;

class SessionSummary {
  final String sessionId;
  final String? summary;
  final String? title;
  final List<String> tags;
  final int? lastModified;
  final String? cwd;
  final int? numMessages;
  final double? totalCostUsd;
  /// 若该 session 当前被某个 claude CLI 进程持有，此字段不为 null。
  /// 可用于在点击会话时直接跳过 /chat/status 查询。
  final SessionHolder? holder;

  SessionSummary({
    required this.sessionId,
    this.summary,
    this.title,
    this.tags = const [],
    this.lastModified,
    this.cwd,
    this.numMessages,
    this.totalCostUsd,
    this.holder,
  });

  String get displayTitle => title ?? summary ?? '(Untitled)';

  factory SessionSummary.fromJson(Map<String, dynamic> json) {
    final tagsRaw = json['tags'] as List? ?? const [];
    final holderJson = json['holder'] as Map<String, dynamic>?;
    return SessionSummary(
      sessionId: json['session_id'] as String,
      summary: json['summary'] as String?,
      title: json['title'] as String?,
      tags: tagsRaw.map((e) => e.toString()).toList(),
      lastModified: (json['last_modified'] as num?)?.toInt(),
      cwd: json['cwd'] as String?,
      numMessages: (json['num_messages'] as num?)?.toInt(),
      totalCostUsd: (json['total_cost_usd'] as num?)?.toDouble(),
      holder: holderJson != null ? SessionHolder.fromJson(holderJson) : null,
    );
  }
}


class SessionsApi {
  final String baseUrl;
  final String? _token;
  SessionsApi(this.baseUrl, {String? token}) : _token = token;

  Map<String, String> get _auth =>
      _token != null ? {'Authorization': 'Bearer $_token'} : const {};

  Uri _u(String path, [Map<String, dynamic>? query]) {
    final q = query?.map((k, v) => MapEntry(k, v.toString()));
    return Uri.parse('$baseUrl$path').replace(queryParameters: q);
  }

  Future<List<SessionSummary>> list(String cwd, {int limit = 50}) async {
    final resp = await http.get(_u('/sessions', {'cwd': cwd, 'limit': limit}), headers: _auth);
    if (resp.statusCode != 200) {
      throw Exception('list_sessions HTTP ${resp.statusCode}: ${resp.body}');
    }
    final list = jsonDecode(resp.body) as List;
    return list.map((e) => SessionSummary.fromJson(Map<String, dynamic>.from(e))).toList();
  }

  Future<void> rename(String sessionId, String cwd, String title) async {
    final resp = await http.post(_u('/sessions/$sessionId/rename', {'cwd': cwd, 'title': title}), headers: _auth);
    if (resp.statusCode != 200) throw Exception(resp.body);
  }

  Future<void> tag(String sessionId, String cwd, String tag) async {
    final resp = await http.post(_u('/sessions/$sessionId/tag', {'cwd': cwd, 'tag': tag}), headers: _auth);
    if (resp.statusCode != 200) throw Exception(resp.body);
  }

  Future<String?> fork(String sessionId, String cwd, {String? title}) async {
    final query = {'cwd': cwd};
    if (title != null) query['title'] = title;
    final resp = await http.post(_u('/sessions/$sessionId/fork', query), headers: _auth);
    if (resp.statusCode != 200) throw Exception(resp.body);
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    return body['session_id'] as String?;
  }

  Future<void> delete(String sessionId, String cwd) async {
    final resp = await http.delete(_u('/sessions/$sessionId', {'cwd': cwd}), headers: _auth);
    if (resp.statusCode != 200) throw Exception(resp.body);
  }
}
