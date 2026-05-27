import 'dart:convert';

import 'package:http/http.dart' as http;

import '../state/projects_store.dart';

class DuplicateProjectException implements Exception {
  final String path;
  const DuplicateProjectException(this.path);
  @override
  String toString() => '该目录已在项目列表';
}

class DirectoryExistsException implements Exception {
  final String path;
  const DirectoryExistsException(this.path);
  @override
  String toString() => '目录已存在';
}

class ProjectsApi {
  final String baseUrl;
  final String? _token;
  ProjectsApi(this.baseUrl, {String? token}) : _token = token;
  String get _apiBase => baseUrl.endsWith('/api') ? baseUrl : '$baseUrl/api';

  Map<String, String> get _auth =>
      _token != null ? {'Authorization': 'Bearer $_token'} : const {};

  Future<List<String>> browse(String path) async {
    final uri =
        Uri.parse('$_apiBase/browse').replace(queryParameters: {'path': path});
    final resp =
        await http.get(uri, headers: _auth).timeout(const Duration(seconds: 5));
    if (resp.statusCode != 200) return [];
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    return (body['dirs'] as List).cast<String>();
  }

  /// Adds a project. [name] is optional — server defaults to basename(path).
  /// Throws [DuplicateProjectException] on 409.
  Future<Project> addProject({String? name, required String path}) async {
    final resp = await http
        .post(
          Uri.parse('$_apiBase/projects'),
          headers: {'Content-Type': 'application/json', ..._auth},
          body: jsonEncode({
            if (name != null && name.trim().isNotEmpty) 'name': name.trim(),
            'path': path,
          }),
        )
        .timeout(const Duration(seconds: 5));
    if (resp.statusCode == 409) throw DuplicateProjectException(path);
    if (resp.statusCode != 200) {
      throw Exception('HTTP ${resp.statusCode}: ${resp.body}');
    }
    final json = jsonDecode(resp.body) as Map<String, dynamic>;
    return Project.fromJson(json);
  }

  /// Removes a project from the server config. Does NOT delete sessions on disk.
  Future<void> removeProject(String path) async {
    final uri = Uri.parse('$_apiBase/projects')
        .replace(queryParameters: {'path': path});
    final resp = await http
        .delete(uri, headers: _auth)
        .timeout(const Duration(seconds: 5));
    if (resp.statusCode != 200) {
      throw Exception('HTTP ${resp.statusCode}: ${resp.body}');
    }
  }

  /// Creates a new subdirectory `name` under `parent`. Returns the absolute path.
  /// Throws [DirectoryExistsException] on 409.
  Future<String> mkdir({required String parent, required String name}) async {
    final resp = await http
        .post(
          Uri.parse('$_apiBase/browse/mkdir'),
          headers: {'Content-Type': 'application/json', ..._auth},
          body: jsonEncode({'parent': parent, 'name': name}),
        )
        .timeout(const Duration(seconds: 5));
    if (resp.statusCode == 409) throw DirectoryExistsException(parent);
    if (resp.statusCode != 200) {
      throw Exception('HTTP ${resp.statusCode}: ${resp.body}');
    }
    final json = jsonDecode(resp.body) as Map<String, dynamic>;
    return json['path'] as String;
  }
}
