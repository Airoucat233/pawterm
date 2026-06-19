import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../i18n/locale_provider.dart';
import '../state/todo_list.dart';
import '../theme.dart';

// ─── Fireworks particle system ─────────────────────────────────────────────

const _kParticleColors = [
  Color(0xFFFFD700), // gold
  Color(0xFFFF6B6B), // coral
  Color(0xFF4ECDC4), // teal
  Color(0xFF96E6A1), // mint
  Color(0xFFFF9F1C), // amber
  Color(0xFFCBAFF0), // lavender
];

class _Particle {
  final Offset vel; // px/s, with initial upward bias baked in
  final Color color;
  final double r; // radius px
  const _Particle({required this.vel, required this.color, required this.r});
}

List<_Particle> _buildParticles() {
  final rng = math.Random();
  return List.generate(26, (_) {
    final angle = rng.nextDouble() * math.pi * 2;
    final speed = 90.0 + rng.nextDouble() * 190;
    return _Particle(
      vel: Offset(math.cos(angle) * speed, math.sin(angle) * speed - 60),
      color: _kParticleColors[rng.nextInt(_kParticleColors.length)],
      r: 3.0 + rng.nextDouble() * 3.5,
    );
  });
}

class _FireworkPainter extends CustomPainter {
  final List<_Particle> ps;
  final double t; // 0..1
  final Offset origin;

  const _FireworkPainter({
    required this.ps,
    required this.t,
    required this.origin,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..style = PaintingStyle.fill;
    for (final p in ps) {
      final pos = origin + Offset(p.vel.dx * t, p.vel.dy * t + 280 * t * t);
      final alpha = (1.0 - t * t * 0.85).clamp(0.0, 1.0);
      final radius = (p.r * (1.0 - t * 0.4)).clamp(0.0, double.infinity);
      paint.color = p.color.withValues(alpha: alpha);
      canvas.drawCircle(pos, radius, paint);
    }
  }

  @override
  bool shouldRepaint(_FireworkPainter old) => old.t != t;
}

/// 全屏透明层，跑完 [duration] 后自动回调 [onDone]。
class _FireworksLayer extends StatefulWidget {
  final Offset origin;
  final VoidCallback onDone;
  const _FireworksLayer({required this.origin, required this.onDone});

  @override
  State<_FireworksLayer> createState() => _FireworksLayerState();
}

class _FireworksLayerState extends State<_FireworksLayer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final List<_Particle> _ps;

  @override
  void initState() {
    super.initState();
    _ps = _buildParticles();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 950),
    )
      ..addStatusListener((s) {
        if (s == AnimationStatus.completed) widget.onDone();
      })
      ..forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) => CustomPaint(
        painter: _FireworkPainter(ps: _ps, t: _ctrl.value, origin: widget.origin),
        child: const SizedBox.expand(),
      ),
    );
  }
}

// ─── TodoChip ──────────────────────────────────────────────────────────────

/// 全局 TodoList 进度 chip：进度 N/M + 当前进行中任务的预览。
/// 更新时触发 scale-pulse 动效；清空时放烟花 + chip 淡出消失。
class TodoChip extends ConsumerStatefulWidget {
  const TodoChip({super.key});

  @override
  ConsumerState<TodoChip> createState() => _TodoChipState();
}

class _TodoChipState extends ConsumerState<TodoChip>
    with TickerProviderStateMixin {
  // Pulse on update
  late final AnimationController _pulseCtrl;
  late final Animation<double> _pulseScale;

  // Fade-out on clear
  late final AnimationController _outCtrl;
  late final Animation<double> _fadeOut;

  List<TodoItem> _cachedTodos = []; // last non-empty snapshot for vanish frame
  bool _vanishing = false;
  bool _gone = false;
  final _chipKey = GlobalKey();

  @override
  void initState() {
    super.initState();

    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 520),
    );
    _pulseScale = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween(begin: 1.0, end: 1.12)
            .chain(CurveTween(curve: Curves.easeOut)),
        weight: 40,
      ),
      TweenSequenceItem(
        tween: Tween(begin: 1.12, end: 1.0)
            .chain(CurveTween(curve: Curves.easeIn)),
        weight: 60,
      ),
    ]).animate(_pulseCtrl);

    _outCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 480),
    );
    _fadeOut = Tween<double>(begin: 1.0, end: 0.0)
        .animate(CurvedAnimation(parent: _outCtrl, curve: Curves.easeIn));
    _outCtrl.addStatusListener((s) {
      if (s == AnimationStatus.completed && mounted) {
        setState(() => _gone = true);
      }
    });
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    _outCtrl.dispose();
    super.dispose();
  }

  void _triggerVanish(BuildContext context) {
    if (_vanishing || _gone || !mounted) return;

    // Chip center in screen coordinates → fireworks origin
    final box = _chipKey.currentContext?.findRenderObject() as RenderBox?;
    Offset origin = const Offset(120, 120);
    if (box != null && box.hasSize) {
      origin = box.localToGlobal(box.size.center(Offset.zero));
    }

    setState(() => _vanishing = true);

    // Fire particles via Overlay，约束在 chip 附近 280×280 区域
    final overlay = Overlay.of(context, rootOverlay: true);
    const half = 140.0;
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => Positioned(
        left: origin.dx - half,
        top: origin.dy - half,
        width: half * 2,
        height: half * 2,
        child: IgnorePointer(
          child: _FireworksLayer(
            origin: const Offset(half, half),
            onDone: entry.remove,
          ),
        ),
      ),
    );
    overlay.insert(entry);

    // Fade chip label out over 480 ms
    _outCtrl.forward();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final s = ref.watch(stringsProvider);
    final todos = ref.watch(todoListProvider);

    // Pulse 动效：只在 provider 值真正变化时触发，不在每次 build 时触发
    ref.listen<int>(todoUpdatedAtProvider, (prev, next) {
      if (_vanishing || !mounted) return;
      _pulseCtrl.forward(from: 0);
    });

    // 状态迁移：列表清空 → 烟花 + 淡出；任务回来 → 重置显示
    ref.listen<List<TodoItem>>(todoListProvider, (prev, next) {
      if (!_vanishing && !_gone && (prev?.isNotEmpty ?? false) && next.isEmpty) {
        // 需要先等 layout 完成才能拿到 chip 位置
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _triggerVanish(context);
        });
      }
      if (_gone && next.isNotEmpty) {
        setState(() {
          _gone = false;
          _vanishing = false;
        });
        _outCtrl.reset();
      }
    });

    // Keep a copy of the last non-empty list so the chip can render during vanish
    if (todos.isNotEmpty) _cachedTodos = todos;

    if (_gone) return const SizedBox.shrink();
    if (todos.isEmpty && !_vanishing) return const SizedBox.shrink();

    final renderTodos = _vanishing ? _cachedTodos : todos;
    if (renderTodos.isEmpty) return const SizedBox.shrink();

    final done = renderTodos.where((e) => e.isCompleted).length;
    final label = s.todoChipTpl
        .replaceAll('{done}', '$done')
        .replaceAll('{total}', '${renderTodos.length}');

    return FadeTransition(
      opacity: _fadeOut,
      child: ScaleTransition(
        scale: _pulseScale,
        child: InkWell(
          onTap: _vanishing ? null : () => _openSheet(context),
          borderRadius: BorderRadius.circular(8),
          child: Container(
            key: _chipKey,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: t.accentSubt,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: t.accent.withValues(alpha: 0.25)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.checklist, size: 12, color: t.accent),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 11,
                    color: t.accent,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                // 只显示「图标 + 几杠几」，进行中任务文字移到点开的详情面板里，
                // 让 chip 在 spinner 行里保持最小占宽。
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _openSheet(BuildContext context) {
    showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'todo-panel',
      barrierColor: Colors.black45,
      transitionDuration: const Duration(milliseconds: 240),
      pageBuilder: (ctx, _, __) => const _TodoSheet(),
      transitionBuilder: (ctx, anim, _, child) => SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(1, 0),
          end: Offset.zero,
        ).animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
        child: child,
      ),
    );
  }
}

// ─── Side panel ────────────────────────────────────────────────────────────

class _TodoSheet extends ConsumerStatefulWidget {
  const _TodoSheet();

  @override
  ConsumerState<_TodoSheet> createState() => _TodoSheetState();
}

class _TodoSheetState extends ConsumerState<_TodoSheet> {
  double _dragX = 0; // 向右拖拽的累计偏移（clamp >= 0）
  double _panelWidth = 300;

  void _onDragUpdate(DragUpdateDetails d) {
    final dx = d.delta.dx;
    // 只允许向右拖（正方向），向左拖最多归零，不能把面板拖出左边界
    setState(() {
      _dragX = (_dragX + dx).clamp(0.0, double.infinity);
    });
  }

  void _onDragEnd(DragEndDetails d) {
    final vel = d.primaryVelocity ?? 0;
    // 快速右滑（>300 px/s）或拖超过面板宽度 35% → 关闭
    if (vel > 300 || _dragX > _panelWidth * 0.35) {
      Navigator.of(context).pop();
    } else {
      setState(() => _dragX = 0); // 未达阈值：弹回
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final s = ref.watch(stringsProvider);
    final todos = ref.watch(todoListProvider);
    final done = todos.where((e) => e.isCompleted).length;

    _panelWidth = (MediaQuery.of(context).size.width * 0.82).clamp(0.0, 340.0);
    final slotWidth = _panelWidth + 16; // +16 吸收两侧 padding(8+8)

    return Stack(
      children: [
        Positioned(
          top: 0,
          bottom: 0,
          right: 0,
          width: slotWidth,
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Transform.translate(
                offset: Offset(_dragX, 0),
                child: GestureDetector(
                  onHorizontalDragUpdate: _onDragUpdate,
                  onHorizontalDragEnd: _onDragEnd,
                  child: Material(
                    type: MaterialType.transparency,
                    child: Container(
                      decoration: BoxDecoration(
                        color: t.surface,
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: t.border),
                      ),
                      child: Column(
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(20, 20, 16, 12),
                            child: Row(
                              children: [
                                Icon(Icons.checklist, size: 16, color: t.accent),
                                const SizedBox(width: 8),
                                Text(
                                  s.todoSheetTitle,
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                    color: t.text,
                                  ),
                                ),
                                const Spacer(),
                                if (todos.isNotEmpty)
                                  Text(
                                    '$done / ${todos.length}',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: t.textDim,
                                      fontFamily: 'monospace',
                                    ),
                                  ),
                                const SizedBox(width: 8),
                                InkWell(
                                  onTap: () => Navigator.of(context).pop(),
                                  borderRadius: BorderRadius.circular(6),
                                  child: Padding(
                                    padding: const EdgeInsets.all(4),
                                    child: Icon(Icons.close, size: 16, color: t.textDim),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Divider(color: t.borderSubt, height: 0.5),
                          Expanded(
                            child: todos.isEmpty
                                ? Center(
                                    child: Text(
                                      s.todoEmpty,
                                      style: TextStyle(fontSize: 13, color: t.textDim),
                                    ),
                                  )
                                : ListView.separated(
                                    padding: const EdgeInsets.symmetric(vertical: 4),
                                    itemCount: todos.length,
                                    separatorBuilder: (_, __) => Divider(
                                        color: t.borderSubt, height: 0.5, indent: 50),
                                    itemBuilder: (_, i) => _TodoRow(item: todos[i]),
                                  ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ─── Row item ──────────────────────────────────────────────────────────────

class _TodoRow extends ConsumerWidget {
  final TodoItem item;
  const _TodoRow({required this.item});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppTokens.of(context);
    final s = ref.watch(stringsProvider);
    final (icon, color) = switch (item.status) {
      'completed' => (Icons.check_circle, t.success),
      'in_progress' => (Icons.radio_button_checked, t.accent),
      _ => (Icons.radio_button_unchecked, t.textDim),
    };
    final statusLabel = switch (item.status) {
      'completed' => s.todoStatusCompleted,
      'in_progress' => s.todoStatusInProgress,
      _ => s.todoStatusPending,
    };
    final text = item.isInProgress && item.activeForm.isNotEmpty
        ? item.activeForm
        : item.content;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(icon, size: 16, color: color),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  text,
                  style: TextStyle(
                    fontSize: 13,
                    color: item.isCompleted ? t.textDim : t.text,
                    decoration:
                        item.isCompleted ? TextDecoration.lineThrough : null,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  statusLabel,
                  style: TextStyle(
                    fontSize: 10,
                    color: color.withValues(alpha: 0.8),
                    letterSpacing: 0.2,
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
