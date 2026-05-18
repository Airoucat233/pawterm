import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../api/protocol.dart';
import '../theme.dart';
import 'diff_view.dart';

/// 工具调用卡片 — 把 ToolUseBlock 和它对应的 ToolResultBlock（按 id 配对）
/// 合并成一个折叠卡。
///
/// 折叠态：单行 [icon] [name] [summary ←→ 横滑] [✓/✗/⏳] [▾]
/// 展开态：分两段
///   Input  — 调用参数（diff/命令/JSON……）+ pretty|raw segmented control
///   Output — 工具返回（文本，>4000 字符截断）
class ToolCallCard extends StatefulWidget {
  final ToolUseBlock toolUse;
  /// 可选：和这次调用匹配的结果（通过 tool_use_id 配对）。null 表示尚未返回。
  final ToolResultBlock? result;
  /// Task 工具专用：子 Agent 流式对话消息列表（keyed by parent_tool_use_id）。
  /// 非 null 表示这是一个 Task 调用，展开后显示嵌套子 Agent 对话。
  final List<IncomingMessage>? subAgentMsgs;

  const ToolCallCard({
    super.key,
    required this.toolUse,
    this.result,
    this.subAgentMsgs,
  });

  @override
  State<ToolCallCard> createState() => _ToolCallCardState();
}

class _ToolCallCardState extends State<ToolCallCard> {
  bool _expanded = false;
  bool _viewRaw = false;

  ToolUseBlock get toolUse => widget.toolUse;
  ToolResultBlock? get result => widget.result;

  @override
  Widget build(BuildContext context) {
    if (toolUse.name == 'TodoWrite') return _todoWriteCard(context);

    final t = AppTokens.of(context);
    final color = _colorFor(t, toolUse.name);
    final icon = _iconFor(toolUse.name);
    final hasInputBody = !_isBodyEmpty(toolUse.name);
    final hasOutput = result != null;
    // Task tool: expandable as soon as sub-agent messages are being tracked
    final canExpand = hasInputBody || hasOutput || (widget.subAgentMsgs != null);

    return InkWell(
      onTap: canExpand ? () => setState(() => _expanded = !_expanded) : null,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.only(top: 1, bottom: 2),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Container(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            decoration: BoxDecoration(
              color: t.surface,
              border: Border(
                top: BorderSide(color: t.border, width: 0.5),
                right: BorderSide(color: t.border, width: 0.5),
                bottom: BorderSide(color: t.border, width: 0.5),
                left: BorderSide(color: color, width: 3),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(icon, size: 14, color: color),
                    const SizedBox(width: 8),
                    Text(
                      toolUse.name,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: t.text,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: _summary(t, toolUse.name, toolUse.input),
                      ),
                    ),
                    _statusBadge(t),
                    if (canExpand) ...[
                      const SizedBox(width: 6),
                      Icon(
                        _expanded ? Icons.expand_less : Icons.expand_more,
                        size: 14,
                        color: t.textDim,
                      ),
                    ],
                  ],
                ),
                if (_expanded && canExpand) ...[
                  const SizedBox(height: 10),
                  if (hasInputBody) ...[
                    Row(
                      children: [
                        _SectionLabel('Input', t),
                        const Spacer(),
                        if (_showViewToggle(toolUse.name))
                          _SegmentedControl(
                            isRaw: _viewRaw,
                            onChanged: (v) => setState(() => _viewRaw = v),
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    _renderBody(context, t, toolUse.name, toolUse.input),
                  ],
                  // Sub-agent transcript (Task tool)
                  if (widget.subAgentMsgs != null) ...[
                    if (hasInputBody) const SizedBox(height: 10),
                    _SubAgentTranscript(messages: widget.subAgentMsgs!),
                  ],
                  if (hasOutput) ...[
                    if (hasInputBody || widget.subAgentMsgs != null) const SizedBox(height: 10),
                    _SectionLabel('Output', t),
                    const SizedBox(height: 4),
                    _outputBody(t, result!),
                  ],
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _statusBadge(AppTokens t) {
    if (result == null) {
      return SizedBox(
        width: 12,
        height: 12,
        child: CircularProgressIndicator(strokeWidth: 1.5, color: t.textDim),
      );
    }
    if (result!.isError) return Icon(Icons.close_rounded, size: 14, color: t.error);
    return Icon(Icons.check_rounded, size: 14, color: t.success);
  }

  Widget _outputBody(AppTokens t, ToolResultBlock r) {
    final text = _extractText(r.content);
    final truncated = text.length > 4000 ? '${text.substring(0, 4000)}\n…(truncated)' : text;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: t.bg,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
          color: r.isError ? t.error.withValues(alpha: 0.3) : t.borderSubt,
          width: 0.5,
        ),
      ),
      child: SelectableText(
        truncated,
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: 11,
          color: r.isError ? t.error : t.textMuted,
          height: 1.5,
        ),
      ),
    );
  }

  String _extractText(dynamic content) {
    if (content == null) return '';
    if (content is String) return content;
    if (content is List) {
      return content.map((b) {
        if (b is Map && b['text'] != null) return b['text'].toString();
        return b.toString();
      }).join('\n');
    }
    return content.toString();
  }

  bool _isBodyEmpty(String name) => false;

  /// TodoWrite 显示逻辑：
  ///   - 0 个完成 → 首次创建，显示「已创建 N 个任务」
  ///   - 全部完成 → 最终汇报，显示「全部完成 N/N」
  ///   - 中间状态 → 隐藏（只更新 TodoChip，不占 message 空间）
  ///   点击可展开查看完整任务列表。
  Widget _todoWriteCard(BuildContext context) {
    final t = AppTokens.of(context);
    final rawList = toolUse.input['todos'] as List<dynamic>? ?? const [];
    final total = rawList.length;
    if (total == 0) return const SizedBox.shrink();
    final completed =
        rawList.where((e) => (e as Map)['status'] == 'completed').length;
    // 中间状态 → 完全隐藏，不渲染任何 widget
    if (completed > 0 && completed < total) return const SizedBox.shrink();

    final isFirst = completed == 0;
    final color = isFirst ? t.accent : t.success;
    final label = isFirst ? '已创建 $total 个任务' : '全部完成 $completed/$total';

    return InkWell(
      onTap: () => setState(() => _expanded = !_expanded),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: BoxDecoration(
          color: t.surfaceHi,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: t.border, width: 0.5),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(
                  isFirst ? Icons.checklist : Icons.check_circle_outline,
                  size: 13,
                  color: color,
                ),
                const SizedBox(width: 8),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    color: color,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const Spacer(),
                Icon(
                  _expanded ? Icons.expand_less : Icons.expand_more,
                  size: 14,
                  color: t.textDim,
                ),
              ],
            ),
            if (_expanded) ...[
              const SizedBox(height: 8),
              _TodoList(todos: rawList),
            ],
          ],
        ),
      ),
    );
  }

  /// 所有工具（TodoWrite 除外，它有独立卡片）都显示 pretty|raw 切换，
  /// 保证用户始终能看到原始 JSON 输入。
  bool _showViewToggle(String name) => name != 'TodoWrite';

  Color _colorFor(AppTokens t, String name) {
    switch (name) {
      case 'Edit':
      case 'Write':
      case 'MultiEdit':
        return t.toolEdit;
      case 'Bash':
        return t.toolBash;
      case 'Read':
        return t.toolRead;
      case 'Grep':
      case 'Glob':
        return t.toolGrep;
      case 'TodoWrite':
        return t.toolTodo;
      case 'WebFetch':
      case 'WebSearch':
        return t.toolWebFetch;
      default:
        return t.textMuted;
    }
  }

  IconData _iconFor(String name) {
    switch (name) {
      case 'Read':
        return Icons.description_outlined;
      case 'Edit':
      case 'MultiEdit':
        return Icons.edit_outlined;
      case 'Write':
        return Icons.note_add_outlined;
      case 'Bash':
        return Icons.terminal;
      case 'Grep':
        return Icons.search;
      case 'Glob':
        return Icons.folder_open_outlined;
      case 'TodoWrite':
        return Icons.checklist;
      case 'WebFetch':
      case 'WebSearch':
        return Icons.public;
      case 'Task':
        return Icons.smart_toy_outlined;
      default:
        return Icons.build_outlined;
    }
  }

  /// 标题行摘要文本。
  /// - Bash：主命令（第一个 token）+ … + 尾部（让用户同时看到命令类型和目标）
  /// - 文件操作：仅保留文件名（…/filename），路径可横划查看
  /// - 其他：完整 pattern 或空
  Widget _summary(AppTokens t, String name, Map<String, dynamic> input) {
    final String text;
    switch (name) {
      case 'Edit':
      case 'Write':
      case 'MultiEdit':
      case 'Read':
        final path = (input['file_path'] ?? '').toString();
        text = path.contains('/') ? '…/${path.split('/').last}' : path;
      case 'Bash':
        // description 字段是人可读的意图描述，比截断命令更适合做标题
        final desc = (input['description'] ?? '').toString().trim();
        if (desc.isNotEmpty) {
          text = desc;
        } else {
          final cmd = (input['command'] ?? '').toString().trim();
          final firstSpace = cmd.indexOf(' ');
          if (firstSpace < 0 || firstSpace >= cmd.length - 1) {
            text = cmd;
          } else {
            final head = cmd.substring(0, firstSpace);
            final rest = cmd.substring(firstSpace + 1);
            if (rest.length <= 28) {
              text = '$head $rest';
            } else {
              final tailRaw = cmd.substring(cmd.length - 20);
              text = '$head … $tailRaw';
            }
          }
        }
      case 'Grep':
      case 'Glob':
        text = (input['pattern'] ?? '').toString();
      case 'Task':
        final raw = (input['description'] ?? input['prompt'] ?? '').toString().trim();
        text = raw.length > 60 ? '${raw.substring(0, 60)}…' : raw;
      default:
        return const SizedBox.shrink();
    }
    if (text.isEmpty) return const SizedBox.shrink();
    return Text(
      text,
      style: TextStyle(
        fontFamily: 'monospace',
        fontSize: 11,
        color: t.textMuted,
      ),
    );
  }

  Widget _renderBody(BuildContext context, AppTokens t, String name, Map<String, dynamic> input) {
    // raw 模式：直接显示 JSON
    if (_viewRaw) return _JsonBlock(value: input);

    switch (name) {
      case 'Edit':
      case 'MultiEdit':
        return DiffView(
          oldString: (input['old_string'] ?? '').toString(),
          newString: (input['new_string'] ?? '').toString(),
        );
      case 'Write':
        return _FilePreview(content: (input['content'] ?? '').toString());
      case 'Bash':
        return _BashLine(command: (input['command'] ?? '').toString());
      case 'TodoWrite':
        return _TodoList(todos: input['todos']);
      default:
        final hasNested = input.values.any((v) => v is Map || v is List);
        return hasNested ? _JsonBlock(value: input) : _KeyValueList(map: input);
    }
  }
}

// ── Segmented control (pretty | raw) ─────────────────────────────────

class _SegmentedControl extends StatelessWidget {
  final bool isRaw;
  final ValueChanged<bool> onChanged;
  const _SegmentedControl({required this.isRaw, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Container(
      height: 20,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: t.border, width: 0.5),
      ),
      clipBehavior: Clip.hardEdge,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _Seg(label: 'pretty', selected: !isRaw, onTap: () => onChanged(false), t: t),
          Container(width: 0.5, color: t.border),
          _Seg(label: 'raw', selected: isRaw, onTap: () => onChanged(true), t: t),
        ],
      ),
    );
  }
}

class _Seg extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final AppTokens t;
  const _Seg({required this.label, required this.selected, required this.onTap, required this.t});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        color: selected ? t.accent : Colors.transparent,
        child: Text(
          label,
          style: TextStyle(
            fontSize: 10,
            color: selected ? Colors.white : t.textMuted,
            fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
      ),
    );
  }
}

// ── Section label ─────────────────────────────────────────────────────

class _SectionLabel extends StatelessWidget {
  final String text;
  final AppTokens tokens;
  const _SectionLabel(this.text, this.tokens);

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: TextStyle(
        fontSize: 9.5,
        fontWeight: FontWeight.w600,
        letterSpacing: 1.0,
        color: tokens.textDim,
      ),
    );
  }
}

// ── Input body widgets ────────────────────────────────────────────────

class _BashLine extends StatelessWidget {
  final String command;
  const _BashLine({required this.command});
  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: t.bg,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: t.borderSubt, width: 0.5),
      ),
      child: SelectableText(
        '\$ $command',
        style: TextStyle(fontFamily: 'monospace', fontSize: 11, color: t.text),
      ),
    );
  }
}

class _FilePreview extends StatelessWidget {
  final String content;
  const _FilePreview({required this.content});
  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final truncated = content.length > 800 ? '${content.substring(0, 800)}\n…' : content;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: t.bg,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: t.borderSubt, width: 0.5),
      ),
      child: SelectableText(
        truncated,
        style: TextStyle(fontFamily: 'monospace', fontSize: 11, color: t.text),
      ),
    );
  }
}

class _KeyValueList extends StatelessWidget {
  final Map<String, dynamic> map;
  const _KeyValueList({required this.map});
  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: map.entries.map((e) {
        return Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: RichText(
            text: TextSpan(
              style: TextStyle(fontFamily: 'monospace', fontSize: 11, color: t.text),
              children: [
                TextSpan(text: '${e.key}: ', style: TextStyle(color: t.textMuted)),
                TextSpan(text: e.value.toString()),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }
}

/// Pretty-JSON 代码块。
class _JsonBlock extends StatelessWidget {
  final Object? value;
  const _JsonBlock({required this.value});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    const enc = JsonEncoder.withIndent('  ');
    String text;
    try {
      text = enc.convert(value);
    } catch (_) {
      text = value.toString();
    }
    final truncated = text.length > 4000 ? '${text.substring(0, 4000)}\n…(truncated)' : text;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: t.bg,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: t.borderSubt, width: 0.5),
      ),
      child: SelectableText(
        truncated,
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: 11,
          color: t.textMuted,
          height: 1.5,
        ),
      ),
    );
  }
}

class _TodoList extends StatelessWidget {
  final dynamic todos;
  const _TodoList({required this.todos});
  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    if (todos is! List) return Text(todos.toString());
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: (todos as List).map((todo) {
        if (todo is! Map) return Text(todo.toString());
        final status = todo['status'] as String? ?? 'pending';
        final content = todo['content']?.toString() ?? '';
        final activeForm = todo['activeForm']?.toString() ?? '';
        final (iconData, color) = switch (status) {
          'completed' => (Icons.check_circle, t.success),
          'in_progress' => (Icons.radio_button_checked, t.accent),
          _ => (Icons.radio_button_unchecked, t.textDim),
        };
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(iconData, size: 14, color: color),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  status == 'in_progress' && activeForm.isNotEmpty ? activeForm : content,
                  style: TextStyle(
                    fontSize: 12,
                    color: status == 'completed' ? t.textDim : t.text,
                    decoration: status == 'completed' ? TextDecoration.lineThrough : null,
                  ),
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }
}

// ── Sub-agent transcript (Task tool expanded view) ────────────────────

/// Renders the nested sub-agent conversation inside an expanded Task tool card.
/// Receives the list of [IncomingMessage]s routed via [parent_tool_use_id].
class _SubAgentTranscript extends StatelessWidget {
  final List<IncomingMessage> messages;
  const _SubAgentTranscript({required this.messages});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);

    // Build sub-agent tool-result index from its own UserMsgs.
    final toolResults = <String, ToolResultBlock>{};
    for (final m in messages) {
      if (m is UserMsg) {
        for (final b in m.content) {
          if (b is ToolResultBlock && b.toolUseId.isNotEmpty) {
            toolResults[b.toolUseId] = b;
          }
        }
      }
    }

    final rows = <Widget>[];
    for (final m in messages) {
      if (m is StreamingAssistant) {
        final text = m.text.toString();
        if (text.isNotEmpty) {
          rows.add(_SubMdRow(text: text));
        }
      } else if (m is AssistantMsg) {
        for (final b in m.content) {
          if (b is TextBlock && b.text.trim().isNotEmpty) {
            rows.add(_SubMdRow(text: b.text));
          } else if (b is ToolUseBlock) {
            rows.add(Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: ToolCallCard(
                toolUse: b,
                result: toolResults[b.id],
                // No recursive sub-agent tracking for nested tasks.
              ),
            ));
          }
          // ThinkingBlock: skip (same policy as main transcript)
        }
      }
      // UserMsg (tool_result only): skip — results shown in tool cards above.
    }

    return Container(
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(
            color: t.textDim.withValues(alpha: 0.25),
            width: 1.5,
          ),
        ),
      ),
      padding: const EdgeInsets.only(left: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header label
          Row(
            children: [
              Icon(Icons.smart_toy_outlined, size: 11, color: t.textDim),
              const SizedBox(width: 4),
              Text(
                'Sub-agent',
                style: TextStyle(
                  fontSize: 10,
                  color: t.textDim,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          if (rows.isEmpty)
            Text(
              '等待子 Agent…',
              style: TextStyle(
                fontSize: 11,
                color: t.textDim,
                fontStyle: FontStyle.italic,
              ),
            )
          else
            ...rows,
        ],
      ),
    );
  }
}

/// Compact markdown row used inside the sub-agent transcript.
class _SubMdRow extends StatelessWidget {
  final String text;
  const _SubMdRow({required this.text});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: MarkdownBody(
        data: text,
        selectable: true,
        styleSheet: MarkdownStyleSheet(
          p: TextStyle(color: t.text, fontSize: 12, height: 1.5),
          code: TextStyle(
            fontFamily: 'monospace',
            fontSize: 11,
            color: t.accent,
            backgroundColor: t.surfaceHi,
          ),
          codeblockDecoration: BoxDecoration(
            color: t.surfaceHi,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: t.border, width: 0.5),
          ),
          codeblockPadding: const EdgeInsets.all(8),
          h1: TextStyle(color: t.text, fontSize: 14, fontWeight: FontWeight.w600),
          h2: TextStyle(color: t.text, fontSize: 13, fontWeight: FontWeight.w600),
          h3: TextStyle(color: t.text, fontSize: 12, fontWeight: FontWeight.w600),
          listBullet: TextStyle(color: t.textMuted, fontSize: 12),
        ),
      ),
    );
  }
}
