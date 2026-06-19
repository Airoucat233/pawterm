import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Claude SDK 内部状态（仅 Claude，不影响 Codex）：
///   - 'compacting': SDK 正在压缩对话上下文，用户触发 /compact 或自动触发
///   - 'requesting': SDK 正在向 Anthropic API 发请求等回包
///   - null: 空闲（无内部操作进行中）
///
/// 按 sessionKey 做 family 隔离：写入侧用事件所属 runtime 的 key 写，渲染侧
/// 用 currentSessionKeyProvider（当前显示 session）的 key 读。后台 session 的
/// compacting 状态结构上不可能串到当前页面——不同 key 各存各的。
///
/// 仅 Claude session 会 setState；Codex 路径不接这个事件，对应 key 永远是 null。
final claudeSessionStatusProvider =
    StateProvider.family<String?, String>((ref, sessionKey) => null);
