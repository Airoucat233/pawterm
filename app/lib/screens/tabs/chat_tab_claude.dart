part of 'chat_tab.dart';

/// Claude 专属的对话页逻辑，从 god-class 拆出到这个 part 文件。
///
/// 与 chat_tab_codex.dart 对称：每个 agent 的专属逻辑（wire 消息处理、运行时
/// 切换等）都有自己的 part 文件 + extension on _ChatTabState。Claude 当前逻辑
/// 比 Codex 少，但**未来 Claude 扩展往这里塞**——_handleWireMessage 只做中央
/// 分发，agent 专属处理委托到各自的文件，骨架对称、各有其家。
///
/// part 与 chat_tab.dart 同库，extension 能访问全部私有成员，调用语义不变；
/// 纯位移、零行为改动。setState 经 _ChatTabState.rebuild() 转发（@protected）。
extension _ClaudeChatLogic on _ChatTabState {
  /// 切换 Claude 权限模式（default/acceptEdits/plan/auto/dontAsk/bypass）。
  /// 权限模式是 agent 能力：只有声明了 permissionMode 的 agent 有这套选择器。
  void _switchPermissionMode(CcPermissionMode m) {
    final session = ref.read(currentSessionProvider);
    if (!(session?.agent.profile.permissionMode ?? false)) return;
    // 1) UI 全局态，picker 当前选中项靠这个
    ref.read(permissionModeProvider.notifier).set(m);
    // 2) 写回 session.runtime['permission_mode']，让依赖 session.runtime 的逻辑
    //    （runtime sheet 高亮、新建同 cwd session 的 default 计算）拿到正确值。
    final nextRuntime = {...session!.runtime, 'permission_mode': m.wire};
    final next = session.copyWith(runtime: nextRuntime);
    ref.read(currentSessionProvider.notifier).state = next;
    _runtime.session = next;
    // 3) 通知服务端切 live SDK + 持久化 sessionRuntime。
    if (_sessionId != null && _chatApi != null) {
      unawaited(_chatApi!.permission(_sessionId!, m.wire));
    }
    // 4) 更新 agent-level overrides，下次新建 session 直接拿用户偏好（跨 cwd）。
    ref
        .read(agentRuntimeOverridesProvider.notifier)
        .patch(session.agent, {'permission_mode': m.wire});
  }

  /// 处理 Claude SDK 专属的 wire 消息（session status / informational /
  /// tool progress / thinking tokens / 后台 task 生命周期）。命中并处理返回
  /// true，调用方（_handleWireMessage 中央分发）据此判定已消费；非 Claude 类型
  /// 返回 false，落回默认追加。与 Codex 的 _upsertCodexRealtimeSnapshot 对称。
  bool _applyClaudeWireMessage(
    IncomingMessage msg,
    _ChatSessionRuntime eventRuntime,
    Map<String, dynamic> json,
  ) {
    if (msg is ContextUsageMsg) {
      // 上下文窗口实时占用 → 按事件 session 的 key 写 family provider，
      // 给 composer 上方的进度条用。不进消息流。
      final liveKey = _liveStatusKey(eventRuntime);
      if (liveKey != null) {
        ref.read(contextUsageProvider(liveKey).notifier).state = msg;
      }
      return true;
    } else if (msg is SessionStatusMsg) {
      // SDK 内部状态 'compacting'/'requesting'/null。按事件 session 的 key 写
      // family provider，后台 session 不会串到当前页面。不进消息流。
      final liveKey = _liveStatusKey(eventRuntime);
      if (liveKey != null) {
        ref.read(claudeSessionStatusProvider(liveKey).notifier).state =
            msg.status;
      }
      return true;
    } else if (msg is InformationalMsg) {
      // warning/suggestion 才 SnackBar 弹；只对前台显示的 Claude session。
      if (_isActiveClaudeRuntime(eventRuntime) &&
          (msg.level == 'warning' || msg.level == 'suggestion')) {
        final t = AppTokens.of(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content:
                Text(msg.content, style: const TextStyle(fontSize: 12.5)),
            backgroundColor: msg.level == 'warning' ? t.error : t.warning,
            duration: const Duration(seconds: 5),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return true;
    } else if (msg is ToolProgressMsg) {
      // 工具进度：按事件 session 的 key 写 family provider 给 tool_call_card。
      final liveKey = _liveStatusKey(eventRuntime);
      if (liveKey != null && msg.toolUseId.isNotEmpty) {
        final notifier = ref.read(toolProgressProvider(liveKey).notifier);
        notifier.state = {
          ...notifier.state,
          msg.toolUseId: msg.elapsedSeconds,
        };
      }
      return true;
    } else if (msg is ThinkingTokensMsg) {
      // thinking 阶段估算 token：按事件 session 的 key 写，给 spinner thinking pill。
      final liveKey = _liveStatusKey(eventRuntime);
      if (liveKey != null) {
        ref.read(thinkingTokensProvider(liveKey).notifier).state =
            msg.estimatedTokens;
      }
      return true;
    } else if (msg is TaskStartedMsg) {
      // SDK 0.3.x 后台 task：按事件 session 的 key 写 tasks store。
      final liveKey = _liveStatusKey(eventRuntime);
      if (liveKey != null) {
        ref.read(tasksProvider(liveKey).notifier).start(msg);
      }
      return true;
    } else if (msg is TaskUpdatedMsg) {
      final liveKey = _liveStatusKey(eventRuntime);
      if (liveKey != null) {
        ref.read(tasksProvider(liveKey).notifier).update(msg);
      }
      return true;
    } else if (msg is TaskProgressMsg) {
      final liveKey = _liveStatusKey(eventRuntime);
      if (liveKey != null) {
        ref.read(tasksProvider(liveKey).notifier).progress(msg);
      }
      return true;
    } else if (msg is TaskNotificationMsg) {
      // SDK 0.3.x 路径：有 task_id 就合并终态。harness XML 路径：task_id 为
      // null 时不进 store，让 message_view 的 InlineTaskNotification 渲染。
      final liveKey = _liveStatusKey(eventRuntime);
      if (liveKey != null && msg.taskId != null) {
        ref.read(tasksProvider(liveKey).notifier).notify(msg);
      }
      // 老路径：仍按原逻辑加入消息流（非 SDK 路径触发时）。
      if (msg.taskId == null || !msg.skipTranscript) {
        _messages.add(msg);
        _debugTrack(msg, json);
      }
      return true;
    }
    return false;
  }
}
