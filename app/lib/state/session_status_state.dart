import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Claude SDK 内部状态（仅 Claude，不影响 Codex）：
///   - 'compacting': SDK 正在压缩对话上下文，用户触发 /compact 或自动触发
///   - 'requesting': SDK 正在向 Anthropic API 发请求等回包
///   - null: 空闲（无内部操作进行中）
///
/// 这是个全局值（同时只可能有一个 Claude session 在 compact），用来
/// 在 chat 模式条上加 "正在压缩上下文" 提示，避免用户以为卡了。
///
/// 仅 Claude session 会 setState；Codex 路径不接这个事件，状态永远是 null。
final claudeSessionStatusProvider = StateProvider<String?>((ref) => null);
