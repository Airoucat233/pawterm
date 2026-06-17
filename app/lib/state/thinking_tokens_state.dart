import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 当前 turn 估算的 thinking tokens 累计值。
///
/// SDK 在 redacted-thinking 阶段（API 只回 ping）周期推送
/// SDKThinkingTokensMessage。我们把 estimated_tokens 写到这里，
/// chat 顶部 spinner 上展示一个 "≈ 1.2k thinking" 角标。
///
/// 重置时机：
///   - 收到 ResultMsg（一轮结束）→ 0
///   - 收到 AssistantMsg 最终消息（streaming 结束）→ 0
///   - 用户发新消息 → 0
///
/// **仅 Claude session 写**：chat_tab 写入处加 agent 守卫，Codex
/// 永远停在 0。
final thinkingTokensProvider = StateProvider<int>((ref) => 0);
