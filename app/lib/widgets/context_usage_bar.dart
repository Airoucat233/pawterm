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

    // 参考 claude-hud 的紧凑风格：只占右半边、单行 —— 一根细进度条 + 百分比，
    // 按阈值变色（绿/黄/红）。不再占满整行、不再单列 token 文字。
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 4),
      child: Row(
        children: [
          const Spacer(),
          Expanded(
            child: Row(
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: pct,
                      minHeight: 3,
                      backgroundColor: t.border,
                      valueColor: AlwaysStoppedAnimation<Color>(color),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  '${usage.percentage.toStringAsFixed(0)}%',
                  style: TextStyle(
                    fontSize: 9.5,
                    color: color,
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
