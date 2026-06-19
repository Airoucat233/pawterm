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

    String fmt(int n) => n >= 1000
        ? '${(n / 1000).toStringAsFixed(n >= 10000 ? 0 : 1)}k'
        : '$n';

    // 贴输入框底边、左对齐、极小高度：一根迷你细条 + 「大小 + 百分比」，
    // 按阈值变色（绿/黄/红）。
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 2),
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
            '${fmt(usage.totalTokens)}/${fmt(usage.maxTokens)} · ${usage.percentage.toStringAsFixed(0)}%',
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
