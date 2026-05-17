import 'dart:io';
import 'dart:convert';

import 'package:http/http.dart' as http;

class UploadedFile {
  final String path;
  final int size;
  UploadedFile({required this.path, required this.size});

  factory UploadedFile.fromJson(Map<String, dynamic> json) =>
      UploadedFile(path: json['path'] as String, size: json['size'] as int);
}

class UploadException implements Exception {
  final int status;
  final String message;
  UploadException(this.status, this.message);
  @override
  String toString() => 'UploadException($status): $message';
}

class UploadApi {
  final String httpBase;
  UploadApi(this.httpBase);

  Future<UploadedFile> upload(File file, String cwd) async {
    final uri = Uri.parse('$httpBase/upload').replace(queryParameters: {'cwd': cwd});
    final req = http.MultipartRequest('POST', uri);
    req.files.add(await http.MultipartFile.fromPath('file', file.path));
    final streamed = await req.send();
    final resp = await http.Response.fromStream(streamed);
    if (resp.statusCode >= 200 && resp.statusCode < 300) {
      return UploadedFile.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
    }
    String msg = resp.body;
    try {
      msg = (jsonDecode(resp.body) as Map<String, dynamic>)['error']?.toString() ?? resp.body;
    } catch (_) {}
    throw UploadException(resp.statusCode, msg);
  }
}
