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

  void _notifyCodexApprovalIfNeeded(
    _ChatSessionRuntime runtime,
    _PendingCodexApproval approval,
    Connection config,
  ) {
    final uuid = runtime.sessionId;
    final session = runtime.session;
    if (uuid == null || session == null) return;
    final requestId = approval.toolUse.id;
    if (!runtime.codex.notifiedApprovalIds.add(requestId)) return;
    final payload = _completionPayloadFor(session, resumeId: uuid);
    final title = _approvalNotificationTitle(session, approval.toolUse.name);
    final body = _approvalNotificationBody(approval.toolUse);
    if (_appInForeground) {
      ChatCompletionNotifier.instance.showInAppApproval(
        payload: payload,
        requestId: requestId,
        title: title,
        body: body,
      );
      return;
    }
    unawaited(StreamingForegroundService.instance.complete(payload));
    unawaited(ChatCompletionNotifier.instance.notifyCodexApproval(
      payload: payload,
      apiBase: config.apiBase,
      token: config.token,
      uuid: uuid,
      requestId: requestId,
      method: approval.toolUse.name,
      title: title,
      body: body,
      appInForeground: _appInForeground,
    ));
  }

  String _approvalNotificationTitle(CurrentSession session, String method) {
    final sessionName = _notificationSessionName(session);
    if (method == 'item/commandExecution/requestApproval') {
      return '$sessionName 等待确认命令';
    }
    if (method == 'item/fileChange/requestApproval') {
      return '$sessionName 等待确认文件修改';
    }
    if (method == 'item/permissions/requestApproval') {
      return '$sessionName 等待确认权限';
    }
    return '$sessionName 等待确认';
  }

  String _approvalNotificationBody(ToolUseBlock toolUse) {
    final input = toolUse.input;
    final reason = input['reason']?.toString().trim();
    if (toolUse.name == 'item/commandExecution/requestApproval') {
      final command = input['command']?.toString().trim();
      if (command != null && command.isNotEmpty) return command;
    }
    if (toolUse.name == 'item/fileChange/requestApproval') {
      final grantRoot = input['grantRoot']?.toString().trim();
      if (grantRoot != null && grantRoot.isNotEmpty) return grantRoot;
    }
    if (reason != null && reason.isNotEmpty) return reason;
    return '需要你确认后继续';
  }

  void _scheduleCodexApprovalSideEffects({_ChatSessionRuntime? runtime}) {
    final target = runtime ?? _runtime;
    final config = ref.read(activeConnectionProvider);
    final activeApproval = _withRuntime(
      target,
      () => _latestPendingCodexApproval(_buildToolResultIndex()),
    );
    if (activeApproval == null || config == null || target.sessionId == null) {
      return;
    }
    if (!_appInForeground) {
      _notifyCodexApprovalIfNeeded(target, activeApproval, config);
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _notifyCodexApprovalIfNeeded(target, activeApproval, config);
      if (_isCurrentSessionRuntime(target)) {
        _showCodexApprovalSheetIfNeeded(target, activeApproval);
      }
    });
  }

  Future<void> _showCodexApprovalSheetIfNeeded(
    _ChatSessionRuntime runtime,
    _PendingCodexApproval approval,
  ) async {
    final requestId = approval.toolUse.id;
    if (!_isCurrentSessionRuntime(runtime)) return;
    if (runtime.codex.dismissedApprovalPopoverId == requestId) return;
    if (runtime.codex.suppressedApprovalSheetIds.contains(requestId)) return;
    final pendingApprovals = _withRuntime(
      runtime,
      () => _pendingCodexApprovals(_buildToolResultIndex()),
    );
    if (pendingApprovals.length > 1) {
      runtime.codex.suppressedApprovalSheetIds.addAll(
        pendingApprovals.map((item) => item.toolUse.id),
      );
      return;
    }
    if (!runtime.codex.presentedApprovalSheetIds.add(requestId)) return;

    FocusManager.instance.primaryFocus?.unfocus();
    final submitted = await showModalBottomSheet<bool>(
      context: context,
      requestFocus: false,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.32),
      builder: (sheetContext) => _ApprovalBottomSheet(
        toolUse: approval.toolUse,
        result: approval.result,
        onSubmit: (id, decision, scope) {
          _sendCodexApprovalForRuntime(runtime, id, decision, scope);
          Navigator.of(sheetContext).pop(true);
        },
      ),
    );
    if (!mounted) return;
    void markDismissed() {
      runtime.codex.dismissedApprovalPopoverId = requestId;
      if (submitted != true) {
        runtime.codex.presentedApprovalSheetIds.remove(requestId);
      }
    }

    if (submitted == true) {
      if (_isActiveRuntime(runtime)) {
        rebuild(markDismissed);
      } else {
        markDismissed();
      }
    } else {
      if (_isActiveRuntime(runtime)) {
        rebuild(markDismissed);
      } else {
        markDismissed();
      }
    }
  }

  _PendingCodexApproval? _latestPendingCodexApproval(
    Map<String, ToolResultBlock> toolResults,
  ) {
    final pending = _pendingCodexApprovals(toolResults);
    for (final approval in pending) {
      if (approval.toolUse.id != _runtime.codex.dismissedApprovalPopoverId) {
        return approval;
      }
    }
    return null;
  }

  List<_PendingCodexApproval> _pendingCodexApprovals(
    Map<String, ToolResultBlock> toolResults,
  ) {
    final pending = <_PendingCodexApproval>[];
    for (final m in _messages.reversed) {
      final content = switch (m) {
        UserMsg(:final content) => content,
        AssistantMsg(:final content) => content,
        _ => const <ContentBlock>[],
      };
      for (final block in content.reversed) {
        if (block is! ToolUseBlock) continue;
        if (!_isCodexApprovalRequestName(block.name)) continue;
        final result = toolResults[block.id];
        if (result == null) {
          pending.add(_PendingCodexApproval(toolUse: block, result: result));
          continue;
        }
      }
    }
    return pending;
  }
}
