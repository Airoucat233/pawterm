import 'dart:convert';

import 'package:http/http.dart' as http;

class GitApi {
  final String baseUrl;
  final String? _token;
  GitApi(this.baseUrl, {String? token}) : _token = token;

  String get _apiBase => baseUrl.endsWith('/api') ? baseUrl : '$baseUrl/api';

  Map<String, String> get _auth =>
      _token != null ? {'Authorization': 'Bearer $_token'} : const {};

  Future<GitStatus> status(String cwd) async {
    final resp = await http
        .get(
          Uri.parse('$_apiBase/git/status')
              .replace(queryParameters: {'cwd': cwd}),
          headers: _auth,
        )
        .timeout(const Duration(seconds: 6));
    if (resp.statusCode != 200) {
      throw Exception('Git status HTTP ${resp.statusCode}: ${resp.body}');
    }
    return GitStatus.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  Future<String> diff({required String cwd, required String path}) async {
    final resp = await http
        .get(
          Uri.parse('$_apiBase/git/diff')
              .replace(queryParameters: {'cwd': cwd, 'path': path}),
          headers: _auth,
        )
        .timeout(const Duration(seconds: 8));
    if (resp.statusCode != 200) {
      throw Exception('Git diff HTTP ${resp.statusCode}: ${resp.body}');
    }
    final json = jsonDecode(resp.body) as Map<String, dynamic>;
    return json['diff'] as String? ?? '';
  }
}

class GitStatus {
  final String cwd;
  final String branch;
  final List<GitChangedFile> files;

  const GitStatus({
    required this.cwd,
    required this.branch,
    required this.files,
  });

  factory GitStatus.fromJson(Map<String, dynamic> json) => GitStatus(
        cwd: json['cwd'] as String? ?? '',
        branch: json['branch'] as String? ?? 'HEAD',
        files: ((json['files'] as List?) ?? const [])
            .map((item) =>
                GitChangedFile.fromJson(Map<String, dynamic>.from(item as Map)))
            .toList(),
      );
}

class GitChangedFile {
  final String xy;
  final String path;

  const GitChangedFile({required this.xy, required this.path});

  factory GitChangedFile.fromJson(Map<String, dynamic> json) => GitChangedFile(
        xy: json['xy'] as String? ?? '??',
        path: json['path'] as String? ?? '',
      );

  String get label {
    final trimmed = xy.trim();
    return trimmed.isEmpty ? 'M' : trimmed;
  }
}
