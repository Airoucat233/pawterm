import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/protocol.dart';
import '../i18n/locale_provider.dart';
import '../theme.dart';
import '../utils/time_format.dart';
import 'tool_call_card.dart';

class MessageView extends StatelessWidget {
  final IncomingMessage message;
  /// tool_use_id → ToolResultBlock 索引（由 ChatTab 提前扫一遍消息列表得到）。
  /// 让 ToolUseBlock 渲染时能找到对应 result，合并成一个折叠卡。
  final Map<String, ToolResultBlock>? toolResults;

  const MessageView({super.key, required this.message, this.toolResults});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final msg = message;

    if (msg is AssistantMsg) {
      // 过滤掉不渲染的块（目前是 thinking）。如果过滤后没有任何可视块，
      // 整条消息就不渲染——避免出现一个孤零零的 "CLAUDE" 头加空白。
      final visible = msg.content.where((b) => b is! ThinkingBlock).toList();
      if (visible.isEmpty) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(bottom: 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Header(label: 'CLAUDE', color: t.accent, timestamp: msg.timestamp),
            const SizedBox(height: 6),
            ...visible.map((b) => _renderBlock(context, b)),
          ],
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

  Widget _renderBlock(BuildContext context, ContentBlock block) {
    final t = AppTokens.of(context);

    if (block is TextBlock) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: MarkdownBody(
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
        ),
      );
    }

    if (block is ThinkingBlock) {
      // 历史会话与最终消息里完全不显示 thinking 内容。
      // claude-code CLI 同样不渲染 thinking_delta（参见 docs/streaming-response.md）。
      return const SizedBox.shrink();
    }

    if (block is ToolUseBlock) {
      return ToolCallCard(
        toolUse: block,
        result: toolResults?[block.id],
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
              color: t.accent,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(14),
                topRight: Radius.circular(14),
                bottomLeft: Radius.circular(14),
                bottomRight: Radius.circular(4),
              ),
            ),
            child: SelectableText(
              text,
              style: const TextStyle(
                fontSize: 14,
                color: Colors.white,
                height: 1.45,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Header extends ConsumerWidget {
  final String label;
  final Color color;
  final int? timestamp;
  const _Header({required this.label, required this.color, this.timestamp});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppTokens.of(context);
    final s = ref.watch(stringsProvider);
    final ts = tsFromMillis(timestamp);
    return Row(
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.2,
            color: color,
          ),
        ),
        if (ts != null) ...[
          const SizedBox(width: 8),
          Text(
            formatMessageTime(ts, yesterdayLabel: s.timeYesterday),
            style: TextStyle(fontFamily: 'monospace', fontSize: 10, color: t.textDim),
          ),
        ],
      ],
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
