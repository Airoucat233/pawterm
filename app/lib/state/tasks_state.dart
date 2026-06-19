import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/protocol.dart';

/// 单个后台 task 的本地累积状态。
///
/// SDK 0.3.x 把 task 生命周期拆成 task_started / task_updated /
/// task_progress / task_notification 四个事件。我们在本地合并成一个
/// 累积 record：started 是创建，updated 改字段，progress 改实时计量，
/// notification 是终态。
class TaskRecord {
  final String taskId;
  final String? toolUseId;
  final String description;
  final String? subagentType;
  final String? taskType;
  final String? workflowName;
  final String? prompt;
  final bool skipTranscript;

  /// 'pending' | 'running' | 'completed' | 'failed' | 'killed' | 'paused' | null
  final String? status;
  final int? endTime;
  final String? error;
  final bool? isBackgrounded;

  /// progress: usage + last tool
  final TaskUsage? usage;
  final String? lastToolName;
  final String? summary;

  /// notification: terminal output
  final String? outputFile;
  final String? finalSummary;

  /// 创建时间，本地打的 unix ms。task_started 到达时设置。
  final int createdAt;

  const TaskRecord({
    required this.taskId,
    this.toolUseId,
    required this.description,
    this.subagentType,
    this.taskType,
    this.workflowName,
    this.prompt,
    this.skipTranscript = false,
    this.status,
    this.endTime,
    this.error,
    this.isBackgrounded,
    this.usage,
    this.lastToolName,
    this.summary,
    this.outputFile,
    this.finalSummary,
    required this.createdAt,
  });

  TaskRecord copyWith({
    String? description,
    String? status,
    int? endTime,
    String? error,
    bool? isBackgrounded,
    TaskUsage? usage,
    String? lastToolName,
    String? summary,
    String? outputFile,
    String? finalSummary,
  }) {
    return TaskRecord(
      taskId: taskId,
      toolUseId: toolUseId,
      description: description ?? this.description,
      subagentType: subagentType,
      taskType: taskType,
      workflowName: workflowName,
      prompt: prompt,
      skipTranscript: skipTranscript,
      status: status ?? this.status,
      endTime: endTime ?? this.endTime,
      error: error ?? this.error,
      isBackgrounded: isBackgrounded ?? this.isBackgrounded,
      usage: usage ?? this.usage,
      lastToolName: lastToolName ?? this.lastToolName,
      summary: summary ?? this.summary,
      outputFile: outputFile ?? this.outputFile,
      finalSummary: finalSummary ?? this.finalSummary,
      createdAt: createdAt,
    );
  }

  /// 是否处于"活跃"状态。terminal 的几种 status 之外都算活跃。
  bool get isActive {
    return switch (status) {
      'completed' || 'failed' || 'killed' => false,
      _ => true,
    };
  }
}

/// 当前会话所有后台 task 的状态 store。
///
/// **仅 Claude session 写**：chat_tab 写入处加 agent 守卫。Codex
/// 不通过 SDK 0.3.x 的 task 事件，永远是空 map。
///
/// Map key 是 task_id。
class TasksNotifier extends StateNotifier<Map<String, TaskRecord>> {
  TasksNotifier() : super(const {});

  void start(TaskStartedMsg msg) {
    state = {
      ...state,
      msg.taskId: TaskRecord(
        taskId: msg.taskId,
        toolUseId: msg.toolUseId,
        description: msg.description,
        subagentType: msg.subagentType,
        taskType: msg.taskType,
        workflowName: msg.workflowName,
        prompt: msg.prompt,
        skipTranscript: msg.skipTranscript,
        status: 'running',
        createdAt: DateTime.now().millisecondsSinceEpoch,
      ),
    };
  }

  void update(TaskUpdatedMsg msg) {
    final existing = state[msg.taskId];
    if (existing == null) return;
    state = {
      ...state,
      msg.taskId: existing.copyWith(
        description: msg.patch.description,
        status: msg.patch.status,
        endTime: msg.patch.endTime,
        error: msg.patch.error,
        isBackgrounded: msg.patch.isBackgrounded,
      ),
    };
  }

  void progress(TaskProgressMsg msg) {
    final existing = state[msg.taskId];
    if (existing == null) {
      // started 没收到就先收到 progress（理论上 SDK 顺序保证；保险起见
      // 也创建一个 stub），保证后续事件能合并。
      state = {
        ...state,
        msg.taskId: TaskRecord(
          taskId: msg.taskId,
          toolUseId: msg.toolUseId,
          description: msg.description,
          subagentType: msg.subagentType,
          usage: msg.usage,
          lastToolName: msg.lastToolName,
          summary: msg.summary,
          status: 'running',
          createdAt: DateTime.now().millisecondsSinceEpoch,
        ),
      };
      return;
    }
    state = {
      ...state,
      msg.taskId: existing.copyWith(
        description: msg.description.isEmpty ? null : msg.description,
        usage: msg.usage,
        lastToolName: msg.lastToolName,
        summary: msg.summary,
      ),
    };
  }

  /// SDK 0.3.x 的终态 notification。harness XML 路径走 chat_tab 的
  /// 现有 TaskNotificationMsg 渲染，不进这个 store。
  void notify(TaskNotificationMsg msg) {
    final id = msg.taskId;
    if (id == null) return;
    final existing = state[id];
    if (existing == null) return;
    state = {
      ...state,
      id: existing.copyWith(
        status: msg.status,
        outputFile: msg.outputFile,
        finalSummary: msg.summary,
        usage: msg.usage,
      ),
    };
  }

  /// 一轮 result 到达时清掉已完成的 task。运行中的保留以备下一轮继续观察。
  void purgeCompleted() {
    final next = <String, TaskRecord>{
      for (final entry in state.entries)
        if (entry.value.isActive) entry.key: entry.value,
    };
    if (next.length != state.length) state = next;
  }

  /// session 切换 / 用户退出时调用。
  void clear() {
    state = const {};
  }
}

/// 按 sessionKey 做 family 隔离：写入侧用事件所属 runtime 的 key，渲染侧
/// （TasksChip）用 currentSessionKeyProvider 的 key。后台 Claude session 的
/// 后台任务不会串到当前页面的 chip 上。
final tasksProvider =
    StateNotifierProvider.family<TasksNotifier, Map<String, TaskRecord>, String>(
        (ref, sessionKey) => TasksNotifier());

/// 指定 session 当前活跃 task 数量（>0 时 chat tab 上的 TasksChip 才显示）。
final activeTasksCountProvider = Provider.family<int, String>((ref, sessionKey) {
  return ref.watch(tasksProvider(sessionKey)).values.where((t) => t.isActive).length;
});
