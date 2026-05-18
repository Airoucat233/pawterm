import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../i18n/locale_provider.dart';

/// claude-code CLI 风格的字符 spinner。
/// 字符序列复刻自 `src/components/Spinner/utils.ts`（macOS 集合）。
/// 帧序列 = 正向 + 反向，共 12 帧 "开花-合上" 循环，约 80ms/帧。
class CcSpinner extends StatefulWidget {
  final double size;
  final Color color;
  const CcSpinner({super.key, this.size = 16, required this.color});

  @override
  State<CcSpinner> createState() => _CcSpinnerState();
}

class _CcSpinnerState extends State<CcSpinner>
    with SingleTickerProviderStateMixin {
  static const _chars = ['·', '✢', '✳', '✶', '✻', '✽'];
  static final List<String> _frames =
      [..._chars, ..._chars.reversed].toList(growable: false);

  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: 80 * _frames.length),
    )..repeat();
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
      builder: (_, __) {
        final i = (_ctrl.value * _frames.length).floor() % _frames.length;
        // 显式设置 width 和 height，确保 bounding box 与行内 Text 对齐。
        // height 取 size * 1.4 ≈ 文字行高（fontSize * defaultLineHeight）。
        return SizedBox(
          width: widget.size * 1.2,
          height: widget.size * 1.4,
          child: Center(
            child: Text(
              _frames[i],
              textAlign: TextAlign.center,
              strutStyle: StrutStyle(
                fontSize: widget.size,
                height: 1.0,
                forceStrutHeight: true,
              ),
              style: TextStyle(
                fontSize: widget.size,
                color: widget.color,
                height: 1.0,
                fontFamilyFallback: const ['Apple Color Emoji'],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 流式响应的"状态模式"，复刻自 claude-code 的 SpinnerMode。
/// requesting → 等待第一个 token
/// thinking → 模型在 thinking 块中（内容不显示）
/// thoughtFor → thinking 刚结束的过渡态，显示"已思考 Xs"约 2 秒
/// responding → 生成普通文本
/// toolInput → 生成工具调用参数
enum CcStreamMode { requesting, thinking, thoughtFor, responding, toolInput }

/// 把秒数格式化成 `12s` / `1m30s` / `1h2m30s` 紧凑形式。
/// - 总是从最高非零位开始；
/// - 中间为 0 的单位省略：3630s → `1h30s`、3600s → `1h`、3660s → `1h1m`。
String _formatElapsed(int seconds) {
  if (seconds < 60) return '${seconds}s';
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  final s = seconds % 60;
  final parts = StringBuffer();
  if (h > 0) parts.write('${h}h');
  if (m > 0) parts.write('${m}m');
  if (s > 0) parts.write('${s}s');
  return parts.toString();
}

/// 一整行的"响应中"状态：spinner + 文案 + 经过秒数 + 停止按钮。
/// 支持随 [mode] 动态切换文案，thinking → thoughtFor 至少持续 2s（防抖）。
class CcSpinnerLine extends ConsumerStatefulWidget {
  final DateTime startedAt;
  final CcStreamMode mode;

  /// 仅在 [mode] == thoughtFor 时有意义：本轮 thinking 耗时秒数。
  final int? thoughtSeconds;

  final Color color;
  final Color dimColor;
  final VoidCallback? onStop;
  /// 放在右侧（Spacer 之后、Stop 之前）的可选附加 widget，比如 TodoChip。
  final Widget? trailing;

  const CcSpinnerLine({
    super.key,
    required this.startedAt,
    required this.mode,
    this.thoughtSeconds,
    required this.color,
    required this.dimColor,
    this.onStop,
    this.trailing,
  });

  @override
  ConsumerState<CcSpinnerLine> createState() => _CcSpinnerLineState();
}

class _CcSpinnerLineState extends ConsumerState<CcSpinnerLine> {
  late int _verbIndex;
  Timer? _tick;
  int _elapsed = 0;

  @override
  void initState() {
    super.initState();
    // Pick a stable verb index for this spinner instance.
    _verbIndex = DateTime.now().millisecondsSinceEpoch;
    _tickNow();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => _tickNow());
  }

  void _tickNow() {
    final v = DateTime.now().difference(widget.startedAt).inSeconds;
    if (mounted && v != _elapsed) setState(() => _elapsed = v);
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  String _label(WidgetRef ref) {
    final s = ref.watch(stringsProvider);
    switch (widget.mode) {
      case CcStreamMode.requesting:
        return s.spinnerRequesting;
      case CcStreamMode.thinking:
        return s.spinnerThinking;
      case CcStreamMode.thoughtFor:
        final sec = widget.thoughtSeconds ?? 0;
        return s.spinnerThoughtForTpl.replaceAll('{s}', '$sec');
      case CcStreamMode.responding:
        final verbs = s.spinnerRespondingVerbs;
        return '${verbs[_verbIndex % verbs.length]}…';
      case CcStreamMode.toolInput:
        return s.spinnerToolInput;
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(stringsProvider);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          CcSpinner(size: 14, color: widget.color),
          const SizedBox(width: 8),
          Text(
            _label(ref),
            style: TextStyle(
              fontSize: 12,
              height: 1.2,
              color: widget.color,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(width: 10),
          Text(
            _formatElapsed(_elapsed),
            style: TextStyle(
              fontSize: 11,
              height: 1.2,
              color: widget.dimColor,
              fontFamily: 'monospace',
            ),
          ),
          const Spacer(),
          if (widget.trailing != null) ...[
            widget.trailing!,
            const SizedBox(width: 8),
          ],
          if (widget.onStop != null)
            InkWell(
              onTap: widget.onStop,
              borderRadius: BorderRadius.circular(6),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                child: Text(
                  s.spinnerStop,
                  style: TextStyle(
                    fontSize: 11,
                    color: widget.dimColor,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
