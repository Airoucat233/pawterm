import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/context_usage_state.dart';
import '../state/open_chat_windows.dart';
import '../state/prefs.dart';
import '../theme.dart';

/// 输入框上方的上下文窗口占用进度条（绿/黄/红）。数据来自 SDK getContextUsage，
/// 每轮 result 后 server 推 context_usage。设置里「上下文占用条」可关。仅当前
/// 显示的 Claude 会话有数据。
class ContextUsageBar extends ConsumerWidget {
  const ContextUsageBar({super.key});

  static const _green = Color(0xFF34C759);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(showContextBarProvider)) return const SizedBox.shrink();
    final key = ref.watch(currentSessionKeyProvider);
    if (key == null) return const SizedBox.shrink();
    final usage = ref.watch(contextUsageProvider(key));
    if (usage == null || usage.maxTokens <= 0) return const SizedBox.shrink();

    final t = AppTokens.of(context);
    final pct = (usage.percentage.clamp(0, 100)) / 100.0;
    // <70% 绿，70–85% 黄，>=85% 红。
    final color = pct >= 0.85
        ? t.error
        : pct >= 0.70
            ? t.warning
            : _green;

    // 1,000,000 → 1M（惯用叫法），千位 → k。
    String fmt(int n) {
      if (n >= 1000000) {
        final m = n / 1000000;
        return '${m == m.roundToDouble() ? m.toStringAsFixed(0) : m.toStringAsFixed(1)}M';
      }
      if (n >= 1000) return '${(n / 1000).toStringAsFixed(0)}k';
      return '$n';
    }

    // 贴输入框底边、左对齐、极小高度：迷你细条 + 「总大小 · 百分比」，按阈值变色。
    // 放在 composer 的 SafeArea 内、输入框正下方；上下间距由这里 + composer 底
    // padding 控制成一致的小间距。
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
      child: Row(
        children: [
          SizedBox(
            width: 44,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: pct,
                minHeight: 2.5,
                backgroundColor: t.border,
                valueColor: AlwaysStoppedAnimation<Color>(color),
              ),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '${fmt(usage.maxTokens)} · ${usage.percentage.toStringAsFixed(0)}%',
            style: TextStyle(
              fontSize: 9,
              height: 1.1,
              color: color,
              fontFamily: 'monospace',
            ),
          ),
          const Spacer(),
        ],
      ),
    );
  }
}
