import 'dart:convert';

import 'package:http/http.dart' as http;

class SessionSummary {
  final String sessionId;
  final String? summary;
  final String? title;
  final List<String> tags;
  final int? lastModified;
  final String? cwd;
  final int? numMessages;
  final double? totalCostUsd;

  SessionSummary({
    required this.sessionId,
    this.summary,
    this.title,
    this.tags = const [],
    this.lastModified,
    this.cwd,
    this.numMessages,
    this.totalCostUsd,
  });

  String get displayTitle => title ?? summary ?? '(Untitled)';

  factory SessionSummary.fromJson(Map<String, dynamic> json) {
    final tagsRaw = json['tags'] as List? ?? const [];
    return SessionSummary(
      sessionId: json['session_id'] as String,
      summary: json['summary'] as String?,
      title: json['title'] as String?,
      tags: tagsRaw.map((e) => e.toString()).toList(),
      lastModified: (json['last_modified'] as num?)?.toInt(),
      cwd: json['cwd'] as String?,
      numMessages: (json['num_messages'] as num?)?.toInt(),
      totalCostUsd: (json['total_cost_usd'] as num?)?.toDouble(),
    );
  }
}

/// 当前某条 session 的活跃持有者（某个 claude CLI 进程）。
/// 见服务端 `holder-detect.ts` —— 实际数据来自 `~/.claude/sessions/<pid>.json`。
class SessionHolder {
  final int pid;
  final String cwd;
  final int startedAt;
  final String? kind;

  const SessionHolder({
    required this.pid,
    required this.cwd,
    required this.startedAt,
    this.kind,
  });

  factory SessionHolder.fromJson(Map<String, dynamic> json) => SessionHolder(
        pid: (json['pid'] as num).toInt(),
        cwd: json['cwd'] as String? ?? '',
        startedAt: (json['startedAt'] as num?)?.toInt() ?? 0,
        kind: json['kind'] as String?,
      );
}

class SessionsApi {
  final String baseUrl;
  SessionsApi(this.baseUrl);

  Uri _u(String path, [Map<String, dynamic>? query]) {
    final q = query?.map((k, v) => MapEntry(k, v.toString()));
    return Uri.parse('$baseUrl$path').replace(queryParameters: q);
  }

  Future<List<SessionSummary>> list(String cwd, {int limit = 50}) async {
    final resp = await http.get(_u('/sessions', {'cwd': cwd, 'limit': limit}));
    if (resp.statusCode != 200) {
      throw Exception('list_sessions HTTP ${resp.statusCode}: ${resp.body}');
    }
    final list = jsonDecode(resp.body) as List;
    return list.map((e) => SessionSummary.fromJson(Map<String, dynamic>.from(e))).toList();
  }

  /// resume 之前调一次：返回 null = 没人持有，可以放心 resume；
  /// 返回非 null = 当前有 CLI 进程在写这条 session，需要让用户选「接管 / 只读」。
  Future<SessionHolder?> holder(String sessionId) async {
    final resp = await http.get(_u('/sessions/$sessionId/holder')).timeout(const Duration(seconds: 4));
    if (resp.statusCode != 200) return null;
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    final h = body['holder'];
    if (h == null) return null;
    return SessionHolder.fromJson(Map<String, dynamic>.from(h));
  }

  Future<void> rename(String sessionId, String cwd, String title) async {
    final resp = await http.post(_u('/sessions/$sessionId/rename', {'cwd': cwd, 'title': title}));
    if (resp.statusCode != 200) throw Exception(resp.body);
  }

  Future<void> tag(String sessionId, String cwd, String tag) async {
    final resp = await http.post(_u('/sessions/$sessionId/tag', {'cwd': cwd, 'tag': tag}));
    if (resp.statusCode != 200) throw Exception(resp.body);
  }

  Future<String?> fork(String sessionId, String cwd, {String? title}) async {
    final query = {'cwd': cwd};
    if (title != null) query['title'] = title;
    final resp = await http.post(_u('/sessions/$sessionId/fork', query));
    if (resp.statusCode != 200) throw Exception(resp.body);
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    return body['session_id'] as String?;
  }

  Future<void> delete(String sessionId, String cwd) async {
    final resp = await http.delete(_u('/sessions/$sessionId', {'cwd': cwd}));
    if (resp.statusCode != 200) throw Exception(resp.body);
  }
}
