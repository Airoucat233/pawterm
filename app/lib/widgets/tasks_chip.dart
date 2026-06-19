import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/open_chat_windows.dart';
import '../state/tasks_state.dart';
import '../theme.dart';

/// 顶部 spinner 行上的 tasks 计数 chip：显示"完成/总数"（几杠几），点击
/// 展开任务列表。仅 Claude session（tasksProvider 只在 Claude 路径写入；
/// Codex total==0 自然隐藏）。任务全部完成时放一轮烟花特效；轮末
/// purgeCompleted 清空后 chip 自然消失。
class TasksChip extends ConsumerStatefulWidget {
  const TasksChip({super.key});

  @override
  ConsumerState<TasksChip> createState() => _TasksChipState();
}

class _TasksChipState extends ConsumerState<TasksChip>
    with SingleTickerProviderStateMixin {
  late final AnimationController _burst = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );
  bool _wasAllDone = false;

  @override
  void dispose() {
    _burst.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sessionKey = ref.watch(currentSessionKeyProvider);
    final counts = sessionKey == null
        ? const TaskCounts(0, 0)
        : ref.watch(taskCountsProvider(sessionKey));

    // 全部完成的瞬间（false→true）放一轮烟花。在 build 里只记录状态，动画
    // 启动放到 post-frame，避免 build 期间触发动画。
    if (counts.allDone && !_wasAllDone) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _burst.forward(from: 0);
      });
    }
    _wasAllDone = counts.allDone;

    if (counts.total == 0) return const SizedBox.shrink();
    final t = AppTokens.of(context);
    final done = counts.allDone;
    final accent = done ? t.success : t.accent;

    final chip = InkWell(
      onTap: () => _showSheet(context),
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: accent.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: accent.withValues(alpha: 0.25), width: 0.5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(done ? Icons.celebration_rounded : Icons.bolt_rounded,
                size: 12, color: accent),
            const SizedBox(width: 4),
            Text(
              '${counts.completed}/${counts.total}',
              style: TextStyle(
                color: accent,
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                fontFamily: 'monospace',
              ),
            ),
          ],
        ),
      ),
    );

    // 烟花覆盖层：不撑大布局，溢出绘制到 chip 周围。
    return AnimatedBuilder(
      animation: _burst,
      builder: (context, child) {
        if (_burst.isDismissed) return child!;
        return CustomPaint(
          foregroundPainter: _FireworksPainter(_burst.value),
          child: child,
        );
      },
      child: chip,
    );
  }

  void _showSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _TasksSheet(),
    );
  }
}

/// 轻量烟花：一圈粒子从 chip 中心向外飞、半径放大、透明度衰减。
class _FireworksPainter extends CustomPainter {
  final double progress; // 0..1
  _FireworksPainter(this.progress);

  static const _colors = [
    Color(0xFFFFD166),
    Color(0xFFEF476F),
    Color(0xFF06D6A0),
    Color(0xFF118AB2),
    Color(0xFFFF9F1C),
    Color(0xFFA06CD5),
  ];
  static const _count = 14;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxR = math.max(size.width, size.height) * 1.6;
    // ease-out：先快后慢。
    final eased = 1 - math.pow(1 - progress, 3).toDouble();
    final radius = maxR * eased;
    final opacity = (1 - progress).clamp(0.0, 1.0);
    if (opacity <= 0) return;
    for (var i = 0; i < _count; i++) {
      final angle = (i / _count) * 2 * math.pi + progress * 0.6;
      final r = radius * (0.6 + 0.4 * ((i % 3) / 2));
      final p = center + Offset(math.cos(angle), math.sin(angle)) * r;
      final paint = Paint()
        ..color = _colors[i % _colors.length].withValues(alpha: opacity)
        ..style = PaintingStyle.fill;
      canvas.drawCircle(p, 2.0 * (1 - 0.5 * progress), paint);
    }
  }

  @override
  bool shouldRepaint(_FireworksPainter old) => old.progress != progress;
}

class _TasksSheet extends ConsumerWidget {
  const _TasksSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppTokens.of(context);
    final sessionKey = ref.watch(currentSessionKeyProvider);
    final tasks = sessionKey == null
        ? const <String, TaskRecord>{}
        : ref.watch(tasksProvider(sessionKey));
    final active = tasks.values.where((tk) => tk.isActive).toList();
    final completed = tasks.values.where((tk) => !tk.isActive).toList();
    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.7,
      ),
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        border: Border.all(color: t.border),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 12, bottom: 6),
            child: Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: t.border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 16, 10),
            child: Row(
              children: [
                Icon(Icons.bolt_rounded, size: 16, color: t.accent),
                const SizedBox(width: 6),
                Text(
                  '后台任务',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: t.text,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${active.length} 活跃 · ${completed.length} 完成',
                  style: TextStyle(fontSize: 11, color: t.textDim),
                ),
              ],
            ),
          ),
          Divider(color: t.borderSubt, height: 0.5),
          Flexible(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 6),
              children: [
                if (active.isEmpty && completed.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      '当前会话没有后台任务',
                      style: TextStyle(fontSize: 13, color: t.textDim),
                    ),
                  ),
                for (final task in active) _TaskRow(task: task, isActive: true),
                if (active.isNotEmpty && completed.isNotEmpty)
                  Divider(color: t.borderSubt, height: 0.5),
                for (final task in completed)
                  _TaskRow(task: task, isActive: false),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TaskRow extends StatelessWidget {
  final TaskRecord task;
  final bool isActive;
  const _TaskRow({required this.task, required this.isActive});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final color = _statusColor(t, task.status, isActive);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 6,
            height: 6,
            margin: const EdgeInsets.only(top: 6, right: 8),
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    if (task.taskType != null) ...[
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(
                          color: t.surfaceHi,
                          borderRadius: BorderRadius.circular(3),
                          border:
                              Border.all(color: t.borderSubt, width: 0.5),
                        ),
                        child: Text(
                          task.taskType!,
                          style: TextStyle(
                            fontSize: 9,
                            color: t.textMuted,
                            fontWeight: FontWeight.w700,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                    ],
                    Expanded(
                      child: Text(
                        task.description.isEmpty
                            ? task.subagentType ??
                                task.workflowName ??
                                task.taskId
                            : task.description,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: t.text,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                _meta(t),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _meta(AppTokens t) {
    final usage = task.usage;
    final parts = <String>[];
    if (task.status != null) parts.add(task.status!);
    if (task.subagentType != null) parts.add('agent=${task.subagentType}');
    if (usage != null) {
      parts.add('${usage.totalTokens} tok');
      if (usage.toolUses > 0) parts.add('${usage.toolUses} tools');
      if (usage.durationMs > 0) {
        parts.add('${(usage.durationMs / 1000).toStringAsFixed(1)}s');
      }
    }
    if (task.lastToolName != null) parts.add('→ ${task.lastToolName}');
    if (task.error != null) parts.add('error: ${task.error}');
    return Text(
      parts.join(' · '),
      style: TextStyle(
        fontSize: 10.5,
        color: t.textDim,
        fontFamily: 'monospace',
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }

  Color _statusColor(AppTokens t, String? status, bool active) {
    if (!active) {
      return switch (status) {
        'completed' => t.success,
        'failed' => t.error,
        _ => t.textDim,
      };
    }
    return switch (status) {
      'paused' => t.warning,
      _ => t.accent,
    };
  }
}
