import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/protocol.dart';

/// 全局当前最近一次收到的限流信息。
///
/// SDK 通过 SDKRateLimitEvent 在以下时机推送：
///   1. 每次发请求前的预检
///   2. utilization 跨越阈值（typically 80%, 90%, 95%）
///   3. status 切换（allowed → allowed_warning / rejected）
///
/// 这个 provider 是全局而非 per-session：限流额度本身就是账号级别的，
/// 跨 cwd / agent 共享。我们用它驱动 composer 上方的 chip 显示。
///
/// 初始为 null —— 表示"尚未收到过限流事件"，chip 此时不显示，避免
/// 还没建立会话就出现一条空状态。一旦收到第一个事件就一直保留最新值。
final rateLimitInfoProvider = StateProvider<RateLimitInfo?>((ref) => null);
