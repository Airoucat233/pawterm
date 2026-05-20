import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

class SseEvent {
  final String? id;
  final String type;
  final String data;
  SseEvent({this.id, required this.type, required this.data});
}

/// 轻量 SSE 客户端：解析 wire format、维护 Last-Event-ID、自动指数退避重连。
/// 内部事件用 `__` 前缀的伪 type 投递（`__client_error`、`__gap`），便于上层
/// 区分协议事件和传输层信号。
class SseClient {
  final Uri url;
  final Map<String, String> headers;
  String? _lastEventId;
  http.Client? _httpClient;
  StreamSubscription<List<int>>? _sub;
  final _events = StreamController<SseEvent>.broadcast();
  bool _closed = false;
  int _backoffMs = 1000;
  static const _maxBackoffMs = 30000;

  SseClient({required this.url, this.headers = const {}});

  Stream<SseEvent> get events => _events.stream;

  /// 进入持续重连循环。close() 之前不会自然返回。
  Future<void> connect() async {
    while (!_closed) {
      try {
        await _connectOnce();
        if (_closed) return;
      } catch (e) {
        if (_closed) return;
        _events.add(SseEvent(type: '__client_error', data: e.toString()));
      }
      if (_closed) return;
      await Future.delayed(Duration(milliseconds: _backoffMs));
      _backoffMs = (_backoffMs * 2).clamp(1000, _maxBackoffMs);
    }
  }

  Future<void> _connectOnce() async {
    _httpClient?.close();
    _httpClient = http.Client();
    final request = http.Request('GET', url);
    request.headers.addAll({
      'Accept': 'text/event-stream',
      'Cache-Control': 'no-cache',
      ...headers,
    });
    if (_lastEventId != null) {
      request.headers['Last-Event-ID'] = _lastEventId!;
    }
    final response = await _httpClient!.send(request);
    if (response.statusCode == 412) {
      _events.add(SseEvent(type: '__gap', data: 'event gap, reload required'));
      _closed = true;
      return;
    }
    if (response.statusCode == 401) {
      _events.add(SseEvent(type: '__auth_error', data: 'token rejected by server'));
      _closed = true;
      return;
    }
    if (response.statusCode != 200) {
      throw Exception('SSE HTTP ${response.statusCode}');
    }
    _backoffMs = 1000;

    final buffer = StringBuffer();
    final completer = Completer<void>();
    _sub = response.stream.listen(
      (chunk) {
        buffer.write(utf8.decode(chunk, allowMalformed: true));
        _drainBuffer(buffer);
      },
      onDone: () {
        if (!completer.isCompleted) completer.complete();
      },
      onError: (e) {
        if (!completer.isCompleted) completer.completeError(e);
      },
      cancelOnError: true,
    );
    await completer.future;
  }

  void _drainBuffer(StringBuffer buffer) {
    final str = buffer.toString();
    int sep;
    int startIdx = 0;
    while ((sep = str.indexOf('\n\n', startIdx)) >= 0) {
      final block = str.substring(startIdx, sep);
      _parseEvent(block);
      startIdx = sep + 2;
    }
    final remaining = str.substring(startIdx);
    buffer.clear();
    buffer.write(remaining);
  }

  void _parseEvent(String block) {
    String? id;
    String type = 'message';
    final dataLines = <String>[];
    for (final line in block.split('\n')) {
      if (line.isEmpty) continue;
      if (line.startsWith(':')) continue; // SSE comment (heartbeat)
      final colon = line.indexOf(':');
      if (colon < 0) continue;
      final field = line.substring(0, colon);
      var value = line.substring(colon + 1);
      if (value.startsWith(' ')) value = value.substring(1);
      switch (field) {
        case 'id':
          id = value;
          break;
        case 'event':
          type = value;
          break;
        case 'data':
          dataLines.add(value);
          break;
      }
    }
    if (dataLines.isEmpty && id == null) return; // pure comment block
    if (id != null) _lastEventId = id;
    if (_closed) return;
    _events.add(SseEvent(id: id, type: type, data: dataLines.join('\n')));
  }

  Future<void> close() async {
    _closed = true;
    await _sub?.cancel();
    _httpClient?.close();
    if (!_events.isClosed) await _events.close();
  }
}
