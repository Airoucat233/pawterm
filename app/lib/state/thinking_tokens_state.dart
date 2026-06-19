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
/// 按 sessionKey 做 family 隔离：写入侧用事件所属 runtime 的 key，渲染侧用
/// currentSessionKeyProvider 的 key。后台 session 的 thinking 角标不会串到
/// 当前页面。仅 Claude session 写；Codex 对应 key 永远停在 0。
final thinkingTokensProvider =
    StateProvider.family<int, String>((ref, sessionKey) => 0);
