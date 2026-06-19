part of 'chat_tab.dart';

/// Codex 专属的对话页逻辑，从 god-class 拆出到这个 part 文件。
///
/// 这是 _ChatTabState 的 extension —— part 文件与 chat_tab.dart 同一个 library，
/// 因此能访问全部私有成员（`_runtime` / `_messages` / `_codexRealtimeSnapshots`
/// 等），调用方写 `_upsertCodexRealtimeSnapshot(...)` 解析到这里，语义与原来在
/// 类内时**完全一致**。纯位移、零行为改动（P3 Codex 抽取的安全做法）。
extension _CodexChatLogic on _ChatTabState {
  /// 这条 wire 消息是不是 Codex 的 realtime item 快照
  /// （item/started → item/completed 的增量更新，按 UUID upsert）。
  bool _isCodexRealtimeSnapshot(Map<String, dynamic> json, String? wireUuid) {
    if (wireUuid == null || wireUuid.isEmpty) return false;
    if (json['agent'] != 'codex') return false;
    final nativeEvent = json['native_event'];
    return nativeEvent is String && nativeEvent.startsWith('item/');
  }

  /// 把 Codex realtime 快照按 UUID 原地 upsert：已存在就替换最新 native 形状，
  /// 否则 append。返回 true 表示这条已作为快照处理（调用方不再走普通追加）。
  bool _upsertCodexRealtimeSnapshot(
    String? wireUuid,
    IncomingMessage msg,
    Map<String, dynamic> json,
  ) {
    if (!_isCodexRealtimeSnapshot(json, wireUuid)) return false;
    final uuid = wireUuid!;
    final existing = _codexRealtimeSnapshots[uuid];
    if (existing != null) {
      final index = _messages.indexOf(existing);
      if (index >= 0) {
        _debugRaw.remove(existing);
        _messages[index] = msg;
        _debugTrack(msg, json);
        _codexRealtimeSnapshots[uuid] = msg;
        return true;
      }
    }
    _messages.add(msg);
    _debugTrack(msg, json);
    _codexRealtimeSnapshots[uuid] = msg;
    return true;
  }

  /// 把 Codex app-server approval 决策通过 REST 回给 server。
  void _sendCodexApproval(String requestId, String decision, String? scope) {
    _sendCodexApprovalForRuntime(_runtime, requestId, decision, scope);
  }

  void _sendCodexApprovalForRuntime(
    _ChatSessionRuntime runtime,
    String requestId,
    String decision,
    String? scope,
  ) {
    final uuid = runtime.sessionId;
    final api = runtime.chatApi;
    if (uuid == null || api == null) return;
    void markAnswered() {
      runtime.codex.notifiedApprovalIds.remove(requestId);
      runtime.codex.codexApprovalDecisions[requestId] =
          scope == 'session' ? 'accept:session' : decision;
      runtime.codex.dismissedApprovalPopoverId = requestId;
    }

    if (mounted && _isActiveRuntime(runtime)) {
      rebuild(markAnswered);
    } else {
      markAnswered();
    }
    ref
        .read(inAppChatNotificationsProvider.notifier)
        .dismissApprovalsForRequest(requestId);
    unawaited(api
        .answerCodexApproval(uuid, requestId, decision, scope: scope)
        .catchError(
      (Object error) {
        void markError() {
          runtime.error = '$error';
        }

        if (mounted && _isActiveRuntime(runtime)) {
          rebuild(markError);
        } else {
          markError();
        }
      },
    ));
  }
}
