import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 各 tool_use_id 当前的执行已用秒数。
///
/// SDK 周期推送 SDKToolProgressMessage 时 setState；tool_call_card 按
/// toolUseId 读取并显示 "已执行 12s" 之类的提示。
///
/// **仅 Claude session 写**：chat_tab.dart 在处理 ToolProgressMsg 时已加
/// agent 守卫，Codex 路径压根不写这个 provider。Codex 自己的 tool 进度
/// 由 Codex provider 的 item-snapshot 机制处理，跟这条无关。
///
/// 内存增长控制：tool 结果到达（ToolResultBlock 出现在消息流）后应该
/// 显式清理对应 entry，避免长会话累积。具体清理点见 chat_tab.dart
/// 处理 AssistantMsg 的 _applyAssistantSideEffects。
final toolProgressProvider =
    StateProvider<Map<String, double>>((ref) => const {});
