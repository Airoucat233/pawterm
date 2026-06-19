import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../i18n/locale_provider.dart';
import '../state/open_chat_windows.dart';
import '../state/session_status_state.dart';
import '../state/thinking_tokens_state.dart';
import '../theme.dart';

/// "AI 在忙"的字符 spinner —— **两个 agent（Claude / Codex）共用**的活动指示
/// 器（以前叫 CcSpinner，Cc=claude-code 是历史误导，其实并非 Claude 专属）。
/// 视觉风格复刻自 claude-code CLI 的字符 spinner（`Spinner/utils.ts` macOS 集）。
/// 帧序列 = 正向 + 反向，共 12 帧 "开花-合上" 循环，约 80ms/帧。
class AiSpinner extends StatefulWidget {
  final double size;
  final Color color;

  /// false 时冻住不动画（用于"等待用户操作"态——AI 没在忙，而是在等你）。
  final bool animate;
  const AiSpinner({
    super.key,
    this.size = 16,
    required this.color,
    this.animate = true,
  });

  @override
  State<AiSpinner> createState() => _AiSpinnerState();
}

class _AiSpinnerState extends State<AiSpinner>
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
    // 冻住态：不走 AnimatedBuilder，定格在"开花"满帧（✽），静止显示。
    if (!widget.animate) return _glyph('✽');
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) {
        final i = (_ctrl.value * _frames.length).floor() % _frames.length;
        return _glyph(_frames[i]);
      },
    );
  }

  Widget _glyph(String char) {
    // 显式设置 width 和 height，确保 bounding box 与行内 Text 对齐。
    // height 取 size * 1.4 ≈ 文字行高（fontSize * defaultLineHeight）。
    return SizedBox(
      width: widget.size * 1.2,
      height: widget.size * 1.4,
      child: Center(
        child: Text(
          char,
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
  }
}

/// 流式响应的"状态模式"，复刻自 claude-code 的 SpinnerMode。
/// requesting → 等待第一个 token
/// thinking → 模型在 thinking 块中（内容不显示）
/// thoughtFor → thinking 刚结束的过渡态，显示"已思考 Xs"约 2 秒
/// responding → 生成普通文本
/// toolInput → 生成工具调用参数
/// awaitingAnswer → AI 在等用户回答 AskUserQuestion（不是在忙）
/// awaitingApproval → AI 在等用户批准某个操作（审批卡，不是在忙）
///
/// 后两个是"等待用户"态：spinner 冻住不动、变黄、文案变"等待你…"——因为此时
/// AI 没在工作，是在等你。按"等到的是问题还是审批"区分文案，不按 agent，
/// 所以 Codex 只会命中 awaitingApproval，Claude 命中 awaitingAnswer（以后加了
/// 工具审批也会命中 awaitingApproval）。
enum AiStreamMode {
  requesting,
  thinking,
  thoughtFor,
  responding,
  toolInput,
  awaitingAnswer,
  awaitingApproval,
}

/// 是否是"等待用户"态（spinner 该冻住变黄）。
bool isAwaitingUser(AiStreamMode mode) =>
    mode == AiStreamMode.awaitingAnswer ||
    mode == AiStreamMode.awaitingApproval;

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
class AiSpinnerLine extends ConsumerStatefulWidget {
  final DateTime startedAt;
  final AiStreamMode mode;

  /// 仅在 [mode] == thoughtFor 时有意义：本轮 thinking 耗时秒数。
  final int? thoughtSeconds;

  final Color color;
  final Color dimColor;
  final VoidCallback? onStop;

  /// 放在右侧（Spacer 之后、Stop 之前）的可选附加 widget，比如 TodoChip。
  final Widget? trailing;
  final List<Widget> actions;

  const AiSpinnerLine({
    super.key,
    required this.startedAt,
    required this.mode,
    this.thoughtSeconds,
    required this.color,
    required this.dimColor,
    this.onStop,
    this.trailing,
    this.actions = const [],
  });

  @override
  ConsumerState<AiSpinnerLine> createState() => _AiSpinnerLineState();
}

class _AiSpinnerLineState extends ConsumerState<AiSpinnerLine> {
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
    // SDK 内部状态优先级最高：compacting 直接覆盖普通 mode 文案。
    // 这只在 Claude session 上会触发（写 provider 的地方做了 agent 守卫），
    // Codex session 永远是 null，照常走下面的 mode switch。
    final sessionKey = ref.watch(currentSessionKeyProvider);
    final claudeStatus = sessionKey == null
        ? null
        : ref.watch(claudeSessionStatusProvider(sessionKey));
    if (claudeStatus == 'compacting') return '正在压缩上下文…';
    switch (widget.mode) {
      case AiStreamMode.requesting:
        return s.spinnerRequesting;
      case AiStreamMode.thinking:
        return s.spinnerThinking;
      case AiStreamMode.thoughtFor:
        final sec = widget.thoughtSeconds ?? 0;
        return s.spinnerThoughtForTpl.replaceAll('{s}', '$sec');
      case AiStreamMode.responding:
        final verbs = s.spinnerRespondingVerbs;
        return '${verbs[_verbIndex % verbs.length]}…';
      case AiStreamMode.toolInput:
        return s.spinnerToolInput;
      case AiStreamMode.awaitingAnswer:
        return '等待你回答…';
      case AiStreamMode.awaitingApproval:
        return '等待你确认…';
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(stringsProvider);
    // "等待用户"态：spinner 冻住不动、变黄、文案"等待你…"——AI 不是在忙，是在等你。
    final awaiting = isAwaitingUser(widget.mode);
    final accent = awaiting ? AppTokens.of(context).warning : widget.color;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          AiSpinner(size: 14, color: accent, animate: !awaiting),
          const SizedBox(width: 8),
          // Flexible + ellipsis：右侧胶囊（tasks / todo / 重新编辑）多时让文案
          // 收缩，而不是把胶囊挤出屏幕。
          Flexible(
            child: Text(
              _label(ref),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                height: 1.2,
                color: accent,
                fontWeight: FontWeight.w500,
              ),
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
          // Thinking tokens pill：仅在 thinking 阶段 SDK 推过 tokens 时显示。
          // ThinkingTokensProvider 只在 Claude session 写入，Codex 永远是 0
          // 不显示。值 < 100 时也不显示（信号太弱）。
          Builder(builder: (_) {
            final sessionKey = ref.watch(currentSessionKeyProvider);
            final tokens = sessionKey == null
                ? 0
                : ref.watch(thinkingTokensProvider(sessionKey));
            if (tokens < 100) return const SizedBox.shrink();
            final label = tokens >= 1000
                ? '${(tokens / 1000).toStringAsFixed(1)}k'
                : tokens.toString();
            return Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: widget.color.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(4),
                ),
                // Claude Code CLI 风格：'↑ {tokens} tokens'（↑ = 本轮输出/思考
                // token，随生成增长）。复刻 CLI spinner 的 token 展示。
                child: Text(
                  '↑ $label tokens',
                  style: TextStyle(
                    fontSize: 10,
                    color: widget.color,
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            );
          }),
          const Spacer(),
          if (widget.trailing != null) ...[
            widget.trailing!,
            const SizedBox(width: 8),
          ],
          for (final action in widget.actions) ...[
            action,
            const SizedBox(width: 6),
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
