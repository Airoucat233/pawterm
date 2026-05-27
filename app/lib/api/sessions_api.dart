import 'dart:convert';

import 'package:http/http.dart' as http;

import 'agents_api.dart';

class SessionSummary {
  final AgentKind agent;
  final String sessionId;
  final String? summary;
  final String? title;
  final List<String> tags;
  final int? lastModified;
  final String? cwd;
  final int? numMessages;
  final double? totalCostUsd;

  /// 当前持有该 session 的设备 id。
  ///   null      → 空闲
  ///   "server"  → PC 端 claude CLI 占用
  ///   其他      → 某台移动设备正在 streaming
  final String? holderDeviceId;

  SessionSummary({
    this.agent = AgentKind.claude,
    required this.sessionId,
    this.summary,
    this.title,
    this.tags = const [],
    this.lastModified,
    this.cwd,
    this.numMessages,
    this.totalCostUsd,
    this.holderDeviceId,
  });

  String get displayTitle => title ?? summary ?? '(未命名)';

  factory SessionSummary.fromJson(Map<String, dynamic> json) {
    final tagsRaw = json['tags'] as List? ?? const [];
    return SessionSummary(
      agent: AgentKind.fromWire(json['agent'] as String?),
      sessionId: json['session_id'] as String,
      summary: json['summary'] as String?,
      title: json['title'] as String?,
      tags: tagsRaw.map((e) => e.toString()).toList(),
      lastModified: (json['last_modified'] as num?)?.toInt(),
      cwd: json['cwd'] as String?,
      numMessages: (json['num_messages'] as num?)?.toInt(),
      totalCostUsd: (json['total_cost_usd'] as num?)?.toDouble(),
      holderDeviceId: json['holder_device_id'] as String?,
    );
  }
}

class SessionsApi {
  final String baseUrl;
  final String? _token;
  SessionsApi(this.baseUrl, {String? token}) : _token = token;
  String get _apiBase => baseUrl.endsWith('/api') ? baseUrl : '$baseUrl/api';

  Map<String, String> get _auth =>
      _token != null ? {'Authorization': 'Bearer $_token'} : const {};

  Uri _u(String path, [Map<String, dynamic>? query]) {
    final q = query?.map((k, v) => MapEntry(k, v.toString()));
    return Uri.parse('$_apiBase$path').replace(queryParameters: q);
  }

  Future<List<SessionSummary>> list(String cwd,
      {int limit = 50, String agent = 'all'}) async {
    final resp = await http.get(
        _u('/sessions', {'cwd': cwd, 'limit': limit, 'agent': agent}),
        headers: _auth);
    if (resp.statusCode != 200) {
      throw Exception('list_sessions HTTP ${resp.statusCode}: ${resp.body}');
    }
    final list = jsonDecode(resp.body) as List;
    return list
        .map((e) => SessionSummary.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  Future<void> rename(String sessionId, String cwd, String title) async {
    final resp = await http.post(
        _u('/sessions/$sessionId/rename', {'cwd': cwd, 'title': title}),
        headers: _auth);
    if (resp.statusCode != 200) throw Exception(resp.body);
  }

  Future<void> tag(String sessionId, String cwd, String tag) async {
    final resp = await http.post(
        _u('/sessions/$sessionId/tag', {'cwd': cwd, 'tag': tag}),
        headers: _auth);
    if (resp.statusCode != 200) throw Exception(resp.body);
  }

  Future<String?> fork(String sessionId, String cwd, {String? title}) async {
    final query = {'cwd': cwd};
    if (title != null) query['title'] = title;
    final resp =
        await http.post(_u('/sessions/$sessionId/fork', query), headers: _auth);
    if (resp.statusCode != 200) throw Exception(resp.body);
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    return body['session_id'] as String?;
  }

  Future<void> delete(String sessionId, String cwd) async {
    final resp = await http.delete(_u('/sessions/$sessionId', {'cwd': cwd}),
        headers: _auth);
    if (resp.statusCode != 200) throw Exception(resp.body);
  }
}
