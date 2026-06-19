// Wire protocol between the Flutter app and the PawTerm server.

sealed class OutgoingMessage {
  Map<String, dynamic> toJson();
}

class InitMessage extends OutgoingMessage {
  final String cwd;
  final String permissionMode;
  InitMessage({required this.cwd, this.permissionMode = 'acceptEdits'});

  @override
  Map<String, dynamic> toJson() => {
        'type': 'init',
        'cwd': cwd,
        'permission_mode': permissionMode,
      };
}

class UserTextMessage extends OutgoingMessage {
  final String text;
  UserTextMessage(this.text);

  @override
  Map<String, dynamic> toJson() => {'type': 'user_message', 'text': text};
}

class InterruptMessage extends OutgoingMessage {
  @override
  Map<String, dynamic> toJson() => {'type': 'interrupt'};
}

class PingMessage extends OutgoingMessage {
  @override
  Map<String, dynamic> toJson() => {'type': 'ping'};
}

abstract class IncomingMessage {
  static IncomingMessage fromJson(Map<String, dynamic> json) {
    final type = json['type'] as String?;
    switch (type) {
      case 'session_ready':
        return SessionReady(
          sessionKey: json['session_key'] as String? ?? '',
          cwd: json['cwd'] as String? ?? '',
          permissionMode: json['permission_mode'] as String? ?? 'acceptEdits',
          busy: json['busy'] as bool? ?? false,
        );
      case 'assistant':
        return AssistantMsg(
          model: json['model'] as String?,
          content: ((json['content'] as List?) ?? [])
              .map((b) => ContentBlock.fromJson(Map<String, dynamic>.from(b)))
              .toList(),
          timestamp: (json['timestamp'] as num?)?.toInt(),
          parentToolUseId: json['parent_tool_use_id'] as String?,
        );
      case 'user':
        return UserMsg(
          content: ((json['content'] as List?) ?? [])
              .map((b) => ContentBlock.fromJson(Map<String, dynamic>.from(b)))
              .toList(),
          timestamp: (json['timestamp'] as num?)?.toInt(),
          parentToolUseId: json['parent_tool_use_id'] as String?,
        );
      case 'result':
        return ResultMsg(
          durationMs: (json['duration_ms'] as num?)?.toInt(),
          totalCostUsd: (json['total_cost_usd'] as num?)?.toDouble(),
          sessionId: json['session_id'] as String?,
          numTurns: (json['num_turns'] as num?)?.toInt(),
          isError: (json['is_error'] as bool?) ?? false,
          timestamp: (json['timestamp'] as num?)?.toInt(),
        );
      case 'system':
        return SystemMsg(
          subtype: json['subtype'] as String?,
          data: Map<String, dynamic>.from(json['data'] ?? {}),
        );
      case 'error':
        return ErrorMsg(message: json['message'] as String? ?? 'Unknown error');
      case 'pong':
        return PongMsg();
      case 'stream_block_start':
        return StreamBlockStart(
          index: (json['index'] as num?)?.toInt() ?? 0,
          kind: json['kind'] as String? ?? 'unknown',
          parentToolUseId: json['parent_tool_use_id'] as String?,
        );
      case 'stream_delta':
        return StreamDelta(
          index: (json['index'] as num?)?.toInt() ?? 0,
          kind: json['kind'] as String? ?? 'text',
          text: json['text'] as String? ?? '',
          parentToolUseId: json['parent_tool_use_id'] as String?,
        );
      case 'stream_block_stop':
        return StreamBlockStop(
          index: (json['index'] as num?)?.toInt() ?? 0,
          parentToolUseId: json['parent_tool_use_id'] as String?,
        );
      case 'compact_boundary':
        return CompactBoundaryMsg(
          trigger: json['trigger'] as String?,
          preTokens: (json['pre_tokens'] as num?)?.toInt(),
          postTokens: (json['post_tokens'] as num?)?.toInt(),
          durationMs: (json['duration_ms'] as num?)?.toInt(),
          timestamp: (json['timestamp'] as num?)?.toInt(),
        );
      case 'task_notification':
        return TaskNotificationMsg(
          taskId: json['task_id'] as String?,
          toolUseId: json['tool_use_id'] as String?,
          status: json['status'] as String?,
          summary: json['summary'] as String?,
          outputFile: json['output_file'] as String?,
          usage: _parseTaskUsage(json['usage']),
          skipTranscript: json['skip_transcript'] as bool? ?? false,
        );
      case 'task_started':
        return TaskStartedMsg(
          taskId: json['task_id'] as String? ?? '',
          toolUseId: json['tool_use_id'] as String?,
          description: json['description'] as String? ?? '',
          subagentType: json['subagent_type'] as String?,
          taskType: json['task_type'] as String?,
          workflowName: json['workflow_name'] as String?,
          prompt: json['prompt'] as String?,
          skipTranscript: json['skip_transcript'] as bool? ?? false,
        );
      case 'task_updated':
        return TaskUpdatedMsg(
          taskId: json['task_id'] as String? ?? '',
          patch: TaskStatePatch.fromJson(
              Map<String, dynamic>.from(json['patch'] ?? const {})),
        );
      case 'task_progress':
        return TaskProgressMsg(
          taskId: json['task_id'] as String? ?? '',
          toolUseId: json['tool_use_id'] as String?,
          description: json['description'] as String? ?? '',
          subagentType: json['subagent_type'] as String?,
          usage: _parseTaskUsage(json['usage']),
          lastToolName: json['last_tool_name'] as String?,
          summary: json['summary'] as String?,
        );
      case 'rate_limit_info':
        return RateLimitInfoMsg(
          info: RateLimitInfo.fromJson(
            Map<String, dynamic>.from(json['info'] ?? const {}),
          ),
          timestamp: (json['timestamp'] as num?)?.toInt(),
        );
      case 'session_status':
        return SessionStatusMsg(
          status: json['status'] as String?, // 'compacting' | 'requesting' | null
          compactResult: json['compact_result'] as String?,
          compactError: json['compact_error'] as String?,
        );
      case 'informational':
        return InformationalMsg(
          content: json['content'] as String? ?? '',
          level: json['level'] as String? ?? 'info',
          toolUseId: json['tool_use_id'] as String?,
        );
      case 'tool_progress':
        return ToolProgressMsg(
          toolUseId: json['tool_use_id'] as String? ?? '',
          toolName: json['tool_name'] as String? ?? '',
          elapsedSeconds: (json['elapsed_seconds'] as num?)?.toDouble() ?? 0,
          parentToolUseId: json['parent_tool_use_id'] as String?,
        );
      case 'thinking_tokens':
        return ThinkingTokensMsg(
          estimatedTokens: (json['estimated_tokens'] as num?)?.toInt() ?? 0,
          estimatedTokensDelta:
              (json['estimated_tokens_delta'] as num?)?.toInt() ?? 0,
        );
      case 'context_usage':
        return ContextUsageMsg(
          totalTokens: (json['total_tokens'] as num?)?.toInt() ?? 0,
          maxTokens: (json['max_tokens'] as num?)?.toInt() ?? 0,
          percentage: (json['percentage'] as num?)?.toDouble() ?? 0,
          autoCompactThreshold:
              (json['auto_compact_threshold'] as num?)?.toDouble(),
          autoCompactEnabled: json['auto_compact_enabled'] as bool? ?? false,
        );
      default:
        return UnknownMsg(raw: json);
    }
  }
}

TaskUsage? _parseTaskUsage(dynamic raw) {
  if (raw is! Map) return null;
  return TaskUsage(
    totalTokens: (raw['total_tokens'] as num?)?.toInt() ?? 0,
    toolUses: (raw['tool_uses'] as num?)?.toInt() ?? 0,
    durationMs: (raw['duration_ms'] as num?)?.toInt() ?? 0,
  );
}

/// SDKRateLimitEvent → wire `rate_limit_info`。承载 claude.ai 订阅用户的
/// 5h / 7d 窗口配额。我们用这个驱动 composer 上方的限流提示 chip。
class RateLimitInfo {
  final String status; // 'allowed' | 'allowed_warning' | 'rejected'
  final int? resetsAt;
  final String? rateLimitType;
  final double? utilization;
  final String? overageStatus;
  final int? overageResetsAt;
  final bool? isUsingOverage;
  final bool? overageInUse;
  final double? surpassedThreshold;

  const RateLimitInfo({
    required this.status,
    this.resetsAt,
    this.rateLimitType,
    this.utilization,
    this.overageStatus,
    this.overageResetsAt,
    this.isUsingOverage,
    this.overageInUse,
    this.surpassedThreshold,
  });

  factory RateLimitInfo.fromJson(Map<String, dynamic> j) => RateLimitInfo(
        status: (j['status'] as String?) ?? 'allowed',
        resetsAt: (j['resets_at'] as num?)?.toInt(),
        rateLimitType: j['rate_limit_type'] as String?,
        utilization: (j['utilization'] as num?)?.toDouble(),
        overageStatus: j['overage_status'] as String?,
        overageResetsAt: (j['overage_resets_at'] as num?)?.toInt(),
        isUsingOverage: j['is_using_overage'] as bool?,
        overageInUse: j['overage_in_use'] as bool?,
        surpassedThreshold: (j['surpassed_threshold'] as num?)?.toDouble(),
      );
}

class RateLimitInfoMsg extends IncomingMessage {
  final RateLimitInfo info;
  final int? timestamp;
  RateLimitInfoMsg({required this.info, this.timestamp});
}

/// SDKStatusMessage → wire `session_status`。
///   - status='compacting': /compact 进行中
///   - status='requesting': SDK 正在发请求等回包
///   - status=null + compactResult: compaction 结束（success / failed）
class SessionStatusMsg extends IncomingMessage {
  final String? status; // 'compacting' | 'requesting' | null
  final String? compactResult; // 'success' | 'failed' | null
  final String? compactError;
  SessionStatusMsg({this.status, this.compactResult, this.compactError});
}

/// SDKInformationalMessage → wire `informational`。SDK 自发的提示文案。
class InformationalMsg extends IncomingMessage {
  final String content;
  final String level; // 'info' | 'notice' | 'suggestion' | 'warning'
  final String? toolUseId;
  InformationalMsg({
    required this.content,
    required this.level,
    this.toolUseId,
  });
}

/// SDKToolProgressMessage → wire `tool_progress`。
/// SDK 周期推送的工具执行进度信号，给 tool_call_card 显示"已执行 Xs"。
/// 仅 Claude SDK 路径触发，Codex 不发。
class ToolProgressMsg extends IncomingMessage {
  final String toolUseId;
  final String toolName;
  final double elapsedSeconds;
  final String? parentToolUseId;
  ToolProgressMsg({
    required this.toolUseId,
    required this.toolName,
    required this.elapsedSeconds,
    this.parentToolUseId,
  });
}

/// 上下文窗口实时占用（SDK getContextUsage，每轮 result 后 server 推一次）。
/// 驱动 composer 上方的绿/黄/红进度条。percentage 是 0–100。
class ContextUsageMsg extends IncomingMessage {
  final int totalTokens;
  final int maxTokens;
  final double percentage;
  final double? autoCompactThreshold;
  final bool autoCompactEnabled;
  ContextUsageMsg({
    required this.totalTokens,
    required this.maxTokens,
    required this.percentage,
    this.autoCompactThreshold,
    this.autoCompactEnabled = false,
  });
}

/// jsonl 里的 `system / compact_boundary` 行：会话上下文被压缩的边界标记。
/// 之前的消息在 jsonl 中仍在，但 SDK 在 resume 时会跳过，所以视觉上"消息消失"。
/// 我们在历史流里画一条分隔线，告诉用户这里发生了什么。
class CompactBoundaryMsg extends IncomingMessage {
  final String? trigger; // 'manual' | 'auto' | null
  final int? preTokens;
  final int? postTokens;
  final int? durationMs;
  final int? timestamp;
  CompactBoundaryMsg({
    this.trigger,
    this.preTokens,
    this.postTokens,
    this.durationMs,
    this.timestamp,
  });
}

/// SDKThinkingTokensMessage → wire `thinking_tokens`。
/// SDK 在 redacted-thinking 阶段周期推送当前 thinking 块累计 token 估算 +
/// 本次增量。仅 Claude SDK 路径，Codex 不发。
class ThinkingTokensMsg extends IncomingMessage {
  final int estimatedTokens;
  final int estimatedTokensDelta;
  ThinkingTokensMsg({
    required this.estimatedTokens,
    required this.estimatedTokensDelta,
  });
}

class StreamBlockStart extends IncomingMessage {
  final int index;
  final String kind;
  final String? parentToolUseId;
  StreamBlockStart(
      {required this.index, required this.kind, this.parentToolUseId});
}

class StreamDelta extends IncomingMessage {
  final int index;
  final String kind;
  final String text;
  final String? parentToolUseId;
  StreamDelta(
      {required this.index,
      required this.kind,
      required this.text,
      this.parentToolUseId});
}

class StreamBlockStop extends IncomingMessage {
  final int index;
  final String? parentToolUseId;
  StreamBlockStop({required this.index, this.parentToolUseId});
}

class SessionReady extends IncomingMessage {
  final String sessionKey;
  final String cwd;
  final String permissionMode;

  /// 服务端 attach 已有 session 时为 true：当前有 in-flight 的流式响应，
  /// 客户端应立即恢复 spinner / streaming UI，不必等下一个事件。
  final bool busy;
  SessionReady({
    required this.sessionKey,
    required this.cwd,
    required this.permissionMode,
    this.busy = false,
  });
}

class AssistantMsg extends IncomingMessage {
  final List<ContentBlock> content;
  final String? model;
  final int? timestamp; // epoch ms; null when server didn't tag it
  /// Non-null when this message belongs to a sub-agent (Task tool).
  /// Value is the tool_use_id of the Task call that spawned the sub-agent.
  final String? parentToolUseId;
  AssistantMsg(
      {required this.content,
      this.model,
      this.timestamp,
      this.parentToolUseId});
}

class UserMsg extends IncomingMessage {
  final List<ContentBlock> content;
  final int? timestamp;

  /// Non-null when this message belongs to a sub-agent (Task tool).
  final String? parentToolUseId;
  UserMsg({required this.content, this.timestamp, this.parentToolUseId});
}

/// In-progress assistant message built char-by-char from stream deltas.
/// Not a wire protocol type; created locally by the chat state machine to
/// represent a streaming response before the final AssistantMsg arrives.
class StreamingAssistant extends IncomingMessage {
  final StringBuffer text = StringBuffer();
  bool stopped = false;
}

class ResultMsg extends IncomingMessage {
  final int? durationMs;
  final double? totalCostUsd;
  final String? sessionId;
  final int? numTurns;
  final bool isError;
  final int? timestamp;
  ResultMsg({
    this.durationMs,
    this.totalCostUsd,
    this.sessionId,
    this.numTurns,
    this.isError = false,
    this.timestamp,
  });
}

class SystemMsg extends IncomingMessage {
  final String? subtype;
  final Map<String, dynamic> data;
  SystemMsg({this.subtype, required this.data});
}

class ErrorMsg extends IncomingMessage {
  final String message;
  ErrorMsg({required this.message});
}

class PongMsg extends IncomingMessage {}

class UnknownMsg extends IncomingMessage {
  final Map<String, dynamic> raw;
  UnknownMsg({required this.raw});
}

/// Harness 注入的后台任务通知（如后台 Agent 完成/失败）。
/// 由 server/src/serialize.ts 从 XML `<task-notification>` 块解析而来。
class TaskNotificationMsg extends IncomingMessage {
  /// 触发本通知的 task_id（Task 工具调用的 tool_use_id 或 SDK 后台任务 ID）。
  final String? taskId;

  /// SDK 0.3.x 后台 task：触发它的 tool_use_id。harness XML 路径下为 null。
  final String? toolUseId;

  /// 任务状态：'completed' | 'killed' | 'failed' | 'stopped' | 'info' 等。
  final String? status;

  /// 人读摘要，如 "Task completed successfully"。
  final String? summary;

  /// SDK 0.3.x 后台 task：完整输出文件路径（仅 'shell' 类 task 有）。
  final String? outputFile;

  /// SDK 0.3.x 后台 task：token / 工具使用统计。
  final TaskUsage? usage;

  /// 设为 true 时建议从 transcript 隐藏，仅在 tasks panel 显示。
  final bool skipTranscript;

  TaskNotificationMsg({
    this.taskId,
    this.toolUseId,
    this.status,
    this.summary,
    this.outputFile,
    this.usage,
    this.skipTranscript = false,
  });
}

/// SDK 0.3.x BackgroundTask 通用 usage 字段。
class TaskUsage {
  final int totalTokens;
  final int toolUses;
  final int durationMs;
  const TaskUsage({
    required this.totalTokens,
    required this.toolUses,
    required this.durationMs,
  });
}

/// SDKTaskUpdatedMessage.patch 的 Dart 镜像。
class TaskStatePatch {
  final String? status; // 'pending' | 'running' | 'completed' | 'failed' | 'killed' | 'paused'
  final String? description;
  final int? endTime;
  final int? totalPausedMs;
  final String? error;
  final bool? isBackgrounded;

  const TaskStatePatch({
    this.status,
    this.description,
    this.endTime,
    this.totalPausedMs,
    this.error,
    this.isBackgrounded,
  });

  factory TaskStatePatch.fromJson(Map<String, dynamic> j) => TaskStatePatch(
        status: j['status'] as String?,
        description: j['description'] as String?,
        endTime: (j['end_time'] as num?)?.toInt(),
        totalPausedMs: (j['total_paused_ms'] as num?)?.toInt(),
        error: j['error'] as String?,
        isBackgrounded: j['is_backgrounded'] as bool?,
      );
}

class TaskStartedMsg extends IncomingMessage {
  final String taskId;
  final String? toolUseId;
  final String description;
  final String? subagentType;
  final String? taskType;
  final String? workflowName;
  final String? prompt;
  final bool skipTranscript;
  TaskStartedMsg({
    required this.taskId,
    this.toolUseId,
    required this.description,
    this.subagentType,
    this.taskType,
    this.workflowName,
    this.prompt,
    this.skipTranscript = false,
  });
}

class TaskUpdatedMsg extends IncomingMessage {
  final String taskId;
  final TaskStatePatch patch;
  TaskUpdatedMsg({required this.taskId, required this.patch});
}

class TaskProgressMsg extends IncomingMessage {
  final String taskId;
  final String? toolUseId;
  final String description;
  final String? subagentType;
  final TaskUsage? usage;
  final String? lastToolName;
  final String? summary;
  TaskProgressMsg({
    required this.taskId,
    this.toolUseId,
    required this.description,
    this.subagentType,
    this.usage,
    this.lastToolName,
    this.summary,
  });
}

sealed class ContentBlock {
  static ContentBlock fromJson(Map<String, dynamic> json) {
    final type = json['type'] as String?;
    switch (type) {
      case 'text':
        return TextBlock(text: json['text'] as String? ?? '');
      case 'thinking':
        return ThinkingBlock(text: json['text'] as String? ?? '');
      case 'tool_use':
        return ToolUseBlock(
          id: json['id'] as String? ?? '',
          name: json['name'] as String? ?? '',
          input: Map<String, dynamic>.from(json['input'] ?? {}),
          nativeType: json['native_type'] as String?,
          nativeEvent: json['native_event'] as String?,
          rawPayload: json['raw_payload'],
        );
      case 'tool_result':
        return ToolResultBlock(
          toolUseId: json['tool_use_id'] as String? ?? '',
          content: json['content'],
          isError: (json['is_error'] as bool?) ?? false,
          nativeType: json['native_type'] as String?,
          nativeEvent: json['native_event'] as String?,
          rawPayload: json['raw_payload'],
        );
      default:
        return UnknownBlock(raw: json);
    }
  }
}

class TextBlock extends ContentBlock {
  final String text;
  TextBlock({required this.text});
}

class ThinkingBlock extends ContentBlock {
  final String text;
  ThinkingBlock({required this.text});
}

class ToolUseBlock extends ContentBlock {
  final String id;
  final String name;
  final Map<String, dynamic> input;
  final String? nativeType;
  final String? nativeEvent;
  final dynamic rawPayload;
  ToolUseBlock({
    required this.id,
    required this.name,
    required this.input,
    this.nativeType,
    this.nativeEvent,
    this.rawPayload,
  });
}

class ToolResultBlock extends ContentBlock {
  final String toolUseId;
  final dynamic content;
  final bool isError;
  final String? nativeType;
  final String? nativeEvent;
  final dynamic rawPayload;
  ToolResultBlock({
    required this.toolUseId,
    required this.content,
    required this.isError,
    this.nativeType,
    this.nativeEvent,
    this.rawPayload,
  });
}

class UnknownBlock extends ContentBlock {
  final Map<String, dynamic> raw;
  UnknownBlock({required this.raw});
}
