import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../api/protocol.dart';
import '../theme.dart';
import 'ask_user_question.dart';
import 'tool_call_card.dart';

class MessageView extends StatelessWidget {
  final IncomingMessage message;
  /// tool_use_id → ToolResultBlock 索引（由 ChatTab 提前扫一遍消息列表得到）。
  /// 让 ToolUseBlock 渲染时能找到对应 result，合并成一个折叠卡。
  final Map<String, ToolResultBlock>? toolResults;
  /// tool_use_id → sub-agent messages（Task 工具专用）。
  /// ToolCallCard 展开时用于渲染嵌套的子 Agent 对话流。
  final Map<String, List<IncomingMessage>>? subMsgsMap;
  /// 提交 AskUserQuestion 答案的回调（仅 AskUserQuestion 工具需要）。
  final void Function(
    String toolUseId,
    Map<String, String> answers,
    Map<String, Map<String, String>>? annotations,
  )? onAnswerQuestion;
  /// 原始 SSE event data（仅 debug 打包时传入，release 为 null）。
  /// 长按消息可查看。
  final Map<String, dynamic>? rawJson;

  const MessageView({
    super.key,
    required this.message,
    this.toolResults,
    this.subMsgsMap,
    this.onAnswerQuestion,
    this.rawJson,
  });

  @override
  Widget build(BuildContext context) {
    final content = _buildContent(context);
    // debug 打包：长按弹出原始 SSE 数据
    if (kDebugMode && rawJson != null) {
      return GestureDetector(
        onLongPress: () => _showRawSheet(context),
        child: content,
      );
    }
    return content;
  }

  void _showRawSheet(BuildContext context) {
    const enc = JsonEncoder.withIndent('  ');
    String text;
    try {
      text = enc.convert(rawJson);
    } catch (_) {
      text = rawJson.toString();
    }
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) {
        final t = AppTokens.of(context);
        return DraggableScrollableSheet(
          initialChildSize: 0.6,
          maxChildSize: 0.92,
          minChildSize: 0.3,
          expand: false,
          builder: (_, ctrl) => Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      'Raw Message',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: t.text,
                      ),
                    ),
                    const Spacer(),
                    GestureDetector(
                      onTap: () => Navigator.of(context).pop(),
                      child: Icon(Icons.close, size: 18, color: t.textDim),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: t.bg,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: t.border, width: 0.5),
                    ),
                    child: SingleChildScrollView(
                      controller: ctrl,
                      padding: const EdgeInsets.all(12),
                      child: SelectableText(
                        text,
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11,
                          color: t.textMuted,
                          height: 1.5,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildContent(BuildContext context) {
    final t = AppTokens.of(context);
    final msg = message;

    if (msg is AssistantMsg) {
      // 复刻 claude-code 终端样式：不再有 "CLAUDE" 大写头；每个可视 block
      // 用 ⏺ gutter 标记，整轮多条 assistant message 视觉上自然连成一片。
      final visible = msg.content.where((b) => b is! ThinkingBlock).toList();
      if (visible.isEmpty) return const SizedBox.shrink();
      // 先渲染所有 block，过滤掉完全不可见的（如 TodoWrite 中间状态）
      final rows = <Widget>[];
      for (int i = 0; i < visible.length; i++) {
        final b = visible[i];
        final content = _renderBlock(context, b);
        final color = _gutterColor(t, b, toolResults);
        // 相邻两个工具卡片之间用更小的间距（1px），其余保持 6px
        final nextIsTool = i + 1 < visible.length && visible[i + 1] is ToolUseBlock;
        final bottomSpacing = (b is ToolUseBlock && nextIsTool) ? 1.0 : 6.0;
        final row = _gutterRow(
          context, content, color,
          dotTopOffset: b is ToolUseBlock ? 13.0 : 2.0,
          bottomSpacing: bottomSpacing,
        );
        if (row is! SizedBox) rows.add(row);
      }
      if (rows.isEmpty) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: rows,
        ),
      );
    }

    if (msg is UserMsg) {
      // UserMsg 可能携带：
      // - 用户输入的 text（→ 右侧气泡 / 或 command-chip）
      // - tool_result（→ 已合并到上方 ToolCallCard，这里跳过）
      // 全是 tool_result 的 UserMsg（常见）整体不渲染，避免出现 0 高度空 item。
      final children = <Widget>[];
      for (final b in msg.content) {
        if (b is TextBlock) {
          final chip = _tryParseCommandChip(b.text);
          children.add(chip ?? _UserBubble(text: b.text));
        }
        // 其它 block：tool_result 已经被 ToolCallCard 接管；其它非 text 类型本就没有渲染。
      }
      if (children.isEmpty) return const SizedBox.shrink();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      );
    }

    if (msg is ResultMsg) {
      return _ResultLine(message: msg);
    }

    if (msg is CompactBoundaryMsg) {
      return _CompactBoundaryLine(message: msg);
    }

    if (msg is ErrorMsg) {
      return Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: t.error.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: t.error.withValues(alpha: 0.4), width: 0.5),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.error_outline, color: t.error, size: 16),
            const SizedBox(width: 8),
            Expanded(
              child: Text(msg.message, style: TextStyle(color: t.error, fontSize: 12)),
            ),
          ],
        ),
      );
    }

    return const SizedBox.shrink();
  }

  /// 复刻 claude-code 终端的 BLACK_CIRCLE gutter。
  /// 用 U+25CF `●`（Geometric Shapes，纯文本字符）而非 U+23FA `⏺`（emoji
  /// presentation，Android/iOS 会渲染成橙底方块）。
  ///
  /// [dotColor]：TextBlock→accent，tool 成功→success，tool 失败→error。
  /// [centerDot]：true 时 dot 放在固定高度容器里居中，适用于 ToolCallCard——
  ///   卡片展开后 dot 仍锚在第一行中心而不跟着整体居中。
  ///   高度 = ToolCallCard 折叠态 header 高度：margin(4+4) + padding(10+10) + icon(14) = 42px。
  Widget _gutterRow(
    BuildContext context,
    Widget content,
    Color dotColor, {
    double dotTopOffset = 2,
    double bottomSpacing = 6,
  }) {
    if (content is SizedBox) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.only(bottom: bottomSpacing),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 18,
            child: Padding(
              padding: EdgeInsets.only(top: dotTopOffset),
              child: Text(
                '●',
                style: TextStyle(fontSize: 11, color: dotColor, height: 1.4),
              ),
            ),
          ),
          Expanded(child: content),
        ],
      ),
    );
  }

  /// 根据 block 类型和 tool result 状态决定 gutter 圆点颜色。
  Color _gutterColor(
    AppTokens t,
    ContentBlock block,
    Map<String, ToolResultBlock>? toolResults,
  ) {
    if (block is TextBlock) return t.success;
    if (block is ToolUseBlock) {
      final result = toolResults?[block.id];
      if (result == null) return t.accent;     // 未返回 / 流式中
      if (result.isError) return t.error;
      return t.success;
    }
    return t.textDim;
  }

  Widget _renderBlock(BuildContext context, ContentBlock block) {
    final t = AppTokens.of(context);

    if (block is TextBlock) {
      // 外层 _gutterRow 已经管 bottom 间距，这里不再叠加
      return MarkdownBody(
          data: block.text,
          selectable: true,
          styleSheet: MarkdownStyleSheet(
            p: TextStyle(color: t.text, fontSize: 13, height: 1.6),
            code: TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
              color: t.accent,
              backgroundColor: t.surfaceHi,
            ),
            codeblockDecoration: BoxDecoration(
              color: t.surfaceHi,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: t.border, width: 0.5),
            ),
            codeblockPadding: const EdgeInsets.all(10),
            blockquoteDecoration: BoxDecoration(
              color: t.surfaceHi,
              border: Border(left: BorderSide(color: t.accent, width: 3)),
            ),
            h1: TextStyle(color: t.text, fontSize: 16, fontWeight: FontWeight.w600),
            h2: TextStyle(color: t.text, fontSize: 14, fontWeight: FontWeight.w600),
            h3: TextStyle(color: t.text, fontSize: 13, fontWeight: FontWeight.w600),
            listBullet: TextStyle(color: t.textMuted, fontSize: 13),
          ),
        );
    }

    if (block is ThinkingBlock) {
      // 历史会话与最终消息里完全不显示 thinking 内容。
      // claude-code CLI 同样不渲染 thinking_delta（参见 docs/streaming-response.md）。
      return const SizedBox.shrink();
    }

    if (block is ToolUseBlock) {
      final result = toolResults?[block.id];
      // 仅在工具调用 pending 或成功时渲染交互 Widget；
      // error result 说明调用失败（工具不存在 / 超时），fallback 到 ToolCallCard。
      if (block.name.endsWith('AskUserQuestion') &&
          onAnswerQuestion != null &&
          result?.isError != true) {
        return AskUserQuestionWidget(
          toolUse: block,
          answeredResult: result,
          onSubmit: onAnswerQuestion!,
        );
      }
      // TodoWrite 中间状态完全隐藏（只显示首次创建 0/N 和全部完成 N/N 这两次）。
      // 注意：这里必须在实例化 ToolCallCard 之前判断；_gutterRow 检查的是 widget
      // 实例类型，ToolCallCard 实例永远不是 SizedBox，所以必须在此层拦截。
      if (block.name == 'TodoWrite') {
        final rawList = block.input['todos'] as List<dynamic>? ?? const [];
        final total = rawList.length;
        final completed =
            rawList.where((e) => (e as Map)['status'] == 'completed').length;
        if (total == 0 || (completed > 0 && completed < total)) {
          return const SizedBox.shrink();
        }
      }
      return ToolCallCard(
        toolUse: block,
        result: result,
        subAgentMsgs: subMsgsMap?[block.id],
      );
    }

    if (block is ToolResultBlock) {
      // ToolResult 已经被合并到上方对应 ToolCallCard 里展示了——这里不再单独出。
      return const SizedBox.shrink();
    }

    return const SizedBox.shrink();
  }
}

// ── command / system-reminder 标签解析 ────────────────────────
//
// Claude Code 协议里，用户 text 内容可能携带带标签的"结构化消息"，例如：
//   <command-name>/model</command-name>
//   <command-message>model</command-message>
//   <command-args>claude-sonnet-4-6</command-args>
//
//   <local-command-stdout>Set model to claude-sonnet-4-6</local-command-stdout>
//
//   <system-reminder>...</system-reminder>
//
// 这些是协议级 envelope，不是用户原文输入，应该用单独的紧凑样式渲染，避免
// 跟普通消息混淆。

Widget? _tryParseCommandChip(String text) {
  final trimmed = text.trim();
  // 1) 斜杠命令调用
  final cmdName = _extractTag(trimmed, 'command-name');
  if (cmdName != null) {
    final args = _extractTag(trimmed, 'command-args');
    return _CommandCallChip(name: cmdName, args: args);
  }
  // 2) 命令输出
  final stdout = _extractTag(trimmed, 'local-command-stdout');
  if (stdout != null) {
    return _CommandOutputChip(text: stdout, isError: false);
  }
  final stderr = _extractTag(trimmed, 'local-command-stderr');
  if (stderr != null) {
    return _CommandOutputChip(text: stderr, isError: true);
  }
  // 3) 系统提示（隐藏；这些是注入给模型的，不该出现在主流里）
  if (trimmed.startsWith('<system-reminder>')) {
    return const SizedBox.shrink();
  }
  // 4) compact / resume 时 SDK 注入的"上下文摘要" — 不是用户输入，
  //    渲染成可折叠的 system chip 而非用户气泡。
  if (trimmed.startsWith('This session is being continued from a previous conversation')) {
    return _SystemNoteChip(
      icon: Icons.history_outlined,
      label: '上下文摘要',
      detail: trimmed,
    );
  }
  // 5) 本地命令注入的免责声明（"Caveat: The messages below were generated..."）
  if (trimmed.startsWith('<local-command-caveat>')) {
    return const SizedBox.shrink();
  }
  // 6) SDK 写入的手动中断标记（多个变体：by user / by user for tool use / …）
  if (trimmed.startsWith('[Request interrupted by user')) {
    return const _InterruptedChip();
  }
  return null;
}

String? _extractTag(String input, String tag) {
  final re = RegExp('<$tag>([\\s\\S]*?)</$tag>');
  final m = re.firstMatch(input);
  return m?.group(1)?.trim();
}

class _CommandCallChip extends StatelessWidget {
  final String name;
  final String? args;
  const _CommandCallChip({required this.name, this.args});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Align(
        alignment: Alignment.center,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 320),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: t.surfaceHi,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: t.border, width: 0.5),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.terminal, size: 13, color: t.textDim),
              const SizedBox(width: 6),
              Flexible(
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: name.startsWith('/') ? name : '/$name',
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                          color: t.text,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (args != null && args!.isNotEmpty)
                        TextSpan(
                          text: '  $args',
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                            color: t.textMuted,
                          ),
                        ),
                    ],
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CommandOutputChip extends StatelessWidget {
  final String text;
  final bool isError;
  const _CommandOutputChip({required this.text, required this.isError});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final color = isError ? t.error : t.textMuted;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Align(
        alignment: Alignment.center,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 360),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: t.surface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isError ? t.error.withValues(alpha: 0.25) : t.border,
              width: 0.5,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                isError ? Icons.error_outline : Icons.subdirectory_arrow_right,
                size: 13,
                color: color,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  text,
                  style: TextStyle(
                    fontSize: 12,
                    color: color,
                    fontFamily: 'monospace',
                    height: 1.45,
                  ),
                  maxLines: 6,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 系统注入的元信息块（如 resume 时的 compact summary）。默认折叠成一行 chip，
/// 点击展开看完整内容 —— 既不当用户气泡，又不完全隐藏。
class _SystemNoteChip extends StatefulWidget {
  final IconData icon;
  final String label;
  final String detail;
  const _SystemNoteChip({required this.icon, required this.label, required this.detail});

  @override
  State<_SystemNoteChip> createState() => _SystemNoteChipState();
}

class _SystemNoteChipState extends State<_SystemNoteChip> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Align(
        alignment: Alignment.center,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Container(
            decoration: BoxDecoration(
              color: t.surface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: t.border, width: 0.5),
            ),
            clipBehavior: Clip.hardEdge,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                InkWell(
                  onTap: () => setState(() => _open = !_open),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(widget.icon, size: 13, color: t.textDim),
                        const SizedBox(width: 6),
                        Text(
                          widget.label,
                          style: TextStyle(fontSize: 12, color: t.textMuted, fontWeight: FontWeight.w500),
                        ),
                        const SizedBox(width: 4),
                        Icon(
                          _open ? Icons.expand_less : Icons.expand_more,
                          size: 14,
                          color: t.textDim,
                        ),
                      ],
                    ),
                  ),
                ),
                if (_open)
                  Container(
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: t.bg,
                      border: Border(top: BorderSide(color: t.borderSubt, width: 0.5)),
                    ),
                    padding: const EdgeInsets.all(10),
                    child: SelectableText(
                      widget.detail.length > 8000
                          ? '${widget.detail.substring(0, 8000)}\n…(truncated)'
                          : widget.detail,
                      style: TextStyle(
                        fontSize: 11,
                        color: t.textMuted,
                        fontFamily: 'monospace',
                        height: 1.5,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 用户消息气泡（用于 UserMsg 历史 text 块）。与 chat_tab 里的 _UserMessage
/// 同样视觉规格：右对齐、绿色气泡、最大宽度 78%。
class _UserBubble extends StatelessWidget {
  final String text;
  const _UserBubble({required this.text});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final maxW = MediaQuery.of(context).size.width * 0.78;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Align(
        alignment: Alignment.centerRight,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxW),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: t.accentSubt,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(14),
                topRight: Radius.circular(14),
                bottomLeft: Radius.circular(14),
                bottomRight: Radius.circular(4),
              ),
              border: Border.all(
                color: t.accent.withValues(alpha: 0.18),
                width: 0.5,
              ),
            ),
            child: SelectableText(
              text,
              style: TextStyle(
                fontSize: 14,
                color: t.text,
                height: 1.45,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ResultLine extends StatelessWidget {
  final ResultMsg message;
  const _ResultLine({required this.message});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final duration = message.durationMs != null ? '${(message.durationMs! / 1000).toStringAsFixed(1)}s' : '-';
    final cost = message.totalCostUsd != null ? '\$${message.totalCostUsd!.toStringAsFixed(4)}' : '-';
    final turns = message.numTurns?.toString() ?? '-';
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 16),
      child: Row(
        children: [
          Text(
            cost,
            style: TextStyle(fontFamily: 'monospace', fontSize: 10, color: t.textDim),
          ),
          _sep(t),
          Text(duration, style: TextStyle(fontFamily: 'monospace', fontSize: 10, color: t.textDim)),
          _sep(t),
          Text('turn $turns', style: TextStyle(fontFamily: 'monospace', fontSize: 10, color: t.textDim)),
        ],
      ),
    );
  }

  Widget _sep(AppTokens t) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Text('·', style: TextStyle(color: t.textDim, fontSize: 11)),
      );
}

/// "上下文已压缩"分隔线：左右两条虚线 + 中央 chip。
/// jsonl 里写的是 `{ type:'system', subtype:'compact_boundary' }`，SDK 重新加载
/// 时会从该点起算，导致回看历史"前面消息消失"——我们在这里告诉用户原因。
class _CompactBoundaryLine extends StatelessWidget {
  final CompactBoundaryMsg message;
  const _CompactBoundaryLine({required this.message});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final trigger = message.trigger == 'manual'
        ? '手动'
        : message.trigger == 'auto'
            ? '自动'
            : null;
    final pre = message.preTokens;
    final post = message.postTokens;
    final stat = (pre != null && post != null)
        ? '${_fmtK(pre)} → ${_fmtK(post)} tok'
        : null;
    final parts = <String>[
      '上下文已压缩',
      if (trigger != null) trigger,
      if (stat != null) stat,
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(child: _dashed(t)),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: t.surfaceHi,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: t.border, width: 0.5),
            ),
            child: Text(
              parts.join(' · '),
              style: TextStyle(
                fontSize: 10,
                color: t.textMuted,
                fontFamily: 'monospace',
                letterSpacing: 0.2,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(child: _dashed(t)),
        ],
      ),
    );
  }

  Widget _dashed(AppTokens t) => Container(
        height: 0.5,
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(color: t.borderSubt, width: 0.5),
          ),
        ),
      );

  String _fmtK(int n) {
    if (n < 1000) return '$n';
    return '${(n / 1000).toStringAsFixed(n >= 10000 ? 0 : 1)}k';
  }
}

/// SDK 写入的手动中断标记：居中小 chip，样式区别于用户气泡。
class _InterruptedChip extends StatelessWidget {
  const _InterruptedChip();

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(child: _dash(t)),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: t.surfaceHi,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: t.border, width: 0.5),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.stop_circle_outlined, size: 11, color: t.textDim),
                const SizedBox(width: 4),
                Text(
                  '已中断',
                  style: TextStyle(
                    fontSize: 10,
                    color: t.textMuted,
                    fontFamily: 'monospace',
                    letterSpacing: 0.2,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Expanded(child: _dash(t)),
        ],
      ),
    );
  }

  Widget _dash(AppTokens t) => Container(
        height: 0.5,
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: t.borderSubt, width: 0.5)),
        ),
      );
}
