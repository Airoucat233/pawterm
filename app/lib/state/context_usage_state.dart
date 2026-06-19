import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/protocol.dart';

/// 按 sessionKey 隔离的上下文窗口占用（SDK getContextUsage，每轮 result 后
/// server 推 context_usage）。写入侧用事件所属 session 的 key，渲染侧用
/// currentSessionKeyProvider 的 key —— 与其它 live-status provider 一致，
/// 不会串页。null 表示还没收到过。
final contextUsageProvider =
    StateProvider.family<ContextUsageMsg?, String>((ref, sessionKey) => null);
