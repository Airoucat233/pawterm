import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// 服务端文件系统 API 客户端。
class FilesApi {
  final String baseUrl;
  FilesApi(this.baseUrl);

  /// 列出 [path] 下的文件夹和文件。
  Future<FsListing> ls(String path) async {
    final uri = Uri.parse('$baseUrl/fs/ls').replace(queryParameters: {'path': path});
    final resp = await http.get(uri).timeout(const Duration(seconds: 10));
    if (resp.statusCode == 403) {
      throw FsForbiddenException(path);
    }
    if (resp.statusCode != 200) {
      throw Exception('HTTP ${resp.statusCode}: ${resp.body}');
    }
    final json = jsonDecode(resp.body) as Map<String, dynamic>;
    final entries = (json['entries'] as List? ?? [])
        .map((e) => FsEntry.fromJson(Map<String, dynamic>.from(e)))
        .toList();
    return FsListing(path: json['path'] as String? ?? path, entries: entries);
  }

  /// 流式下载 [path] 指向的文件到本地 [destFile]，并通过 [onProgress] 报告进度。
  /// 返回最终文件路径。可由 [cancelToken] 取消。
  Future<File> download({
    required String remotePath,
    required File destFile,
    void Function(int received, int? total)? onProgress,
    Completer<void>? cancelToken,
  }) async {
    final uri = Uri.parse('$baseUrl/fs/download')
        .replace(queryParameters: {'path': remotePath});
    final client = http.Client();
    try {
      final req = http.Request('GET', uri);
      final streamed = await client.send(req).timeout(const Duration(seconds: 15));
      if (streamed.statusCode == 403) throw FsForbiddenException(remotePath);
      if (streamed.statusCode == 404) throw FsNotFoundException(remotePath);
      if (streamed.statusCode != 200) {
        throw Exception('HTTP ${streamed.statusCode}');
      }
      final total = streamed.contentLength;
      var received = 0;
      // 父目录可能尚未存在
      await destFile.parent.create(recursive: true);
      final sink = destFile.openWrite();
      try {
        await for (final chunk in streamed.stream) {
          if (cancelToken?.isCompleted ?? false) {
            await sink.close();
            await destFile.delete().catchError((_) => destFile);
            throw FsCancelledException();
          }
          sink.add(chunk);
          received += chunk.length;
          onProgress?.call(received, total);
        }
      } finally {
        await sink.flush();
        await sink.close();
      }
      return destFile;
    } finally {
      client.close();
    }
  }
}

class FsEntry {
  final String name;
  final String path;
  final bool isDir;
  final int sizeBytes;
  final int modifiedMs;

  const FsEntry({
    required this.name,
    required this.path,
    required this.isDir,
    required this.sizeBytes,
    required this.modifiedMs,
  });

  factory FsEntry.fromJson(Map<String, dynamic> j) => FsEntry(
        name: j['name'] as String? ?? '',
        path: j['path'] as String? ?? '',
        isDir: (j['isDir'] as bool?) ?? false,
        sizeBytes: (j['sizeBytes'] as num?)?.toInt() ?? 0,
        modifiedMs: (j['modifiedMs'] as num?)?.toInt() ?? 0,
      );
}

class FsListing {
  final String path;
  final List<FsEntry> entries;
  const FsListing({required this.path, required this.entries});
}

class FsForbiddenException implements Exception {
  final String path;
  FsForbiddenException(this.path);
  @override
  String toString() => '路径不在允许范围: $path';
}

class FsNotFoundException implements Exception {
  final String path;
  FsNotFoundException(this.path);
  @override
  String toString() => '文件不存在: $path';
}

class FsCancelledException implements Exception {
  @override
  String toString() => '下载已取消';
}
