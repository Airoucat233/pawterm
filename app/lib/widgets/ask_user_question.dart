import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../api/protocol.dart';
import '../theme.dart';

class AskUserQuestionWidget extends StatefulWidget {
  final ToolUseBlock toolUse;

  /// 已配对的 tool_result；非空 = answered 态
  final ToolResultBlock? answeredResult;

  /// 提交回调：把答案 + annotations 通过 REST 发回 server
  final void Function(
    String toolUseId,
    Map<String, String> answers,
    Map<String, Map<String, String>>? annotations,
  ) onSubmit;

  const AskUserQuestionWidget({
    super.key,
    required this.toolUse,
    required this.answeredResult,
    required this.onSubmit,
  });

  @override
  State<AskUserQuestionWidget> createState() => _AskUserQuestionWidgetState();
}

class _AskUserQuestionWidgetState extends State<AskUserQuestionWidget> {
  late final List<_Question> _questions;

  /// 用户当前选择：questionIdx → 选中的 option label 集合
  /// 单选时集合 size ≤ 1；多选时可多。
  final List<Set<String>> _selections = [];

  /// 自定义文本（"Other" 输入），questionIdx → 文本
  final Map<int, String> _customTexts = {};
  Map<String, String>? _localAnswers;
  bool _submitted = false;

  @override
  void initState() {
    super.initState();
    _questions = _parseQuestions(widget.toolUse.input);
    for (int i = 0; i < _questions.length; i++) {
      _selections.add(<String>{});
    }
  }

  bool get _isFormMode {
    if (_questions.length > 1) return true;
    return _questions.any((q) => q.multiSelect);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final answeredAnswers =
        _answersFromResult(widget.answeredResult) ?? _localAnswers;
    final answered = answeredAnswers != null;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: t.border, width: 0.5),
      ),
      child: Opacity(
        opacity: answered ? 0.75 : 1.0,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (answered)
              _AnswerReceipt(answers: answeredAnswers, t: t)
            else
              for (int i = 0; i < _questions.length; i++) ...[
                _QuestionInteractivePanel(
                  index: i,
                  question: _questions[i],
                  readOnly: _submitted,
                  selected: _selections[i],
                  customText: _customTexts[i],
                  onTapOption: (label) => _onTapOption(i, label),
                  onCustomTextSubmitted: (text) => _onCustomText(i, text),
                ),
                if (i < _questions.length - 1) const SizedBox(height: 24),
              ],
            if (!answered && _isFormMode && !_submitted) ...[
              const SizedBox(height: 16),
              _SubmitButton(
                enabled: _canSubmit(),
                onTap: _submit,
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _onTapOption(int qIdx, String label) {
    final q = _questions[qIdx];
    setState(() {
      if (q.multiSelect) {
        if (_selections[qIdx].contains(label)) {
          _selections[qIdx].remove(label);
        } else {
          _selections[qIdx].add(label);
        }
        _customTexts.remove(qIdx);
      } else {
        _selections[qIdx]
          ..clear()
          ..add(label);
        _customTexts.remove(qIdx);
      }
    });
    // 单 Q 单选 + 非 form 模式：立即提交
    if (!_isFormMode && !q.multiSelect) {
      _submit();
    }
  }

  void _onCustomText(int qIdx, String text) {
    if (text.isEmpty) return;
    setState(() {
      _customTexts[qIdx] = text;
      _selections[qIdx]
        ..clear()
        ..add('__OTHER__');
    });
    if (!_isFormMode) {
      _submit();
    }
  }

  bool _canSubmit() {
    for (int i = 0; i < _questions.length; i++) {
      if (_selections[i].isEmpty && _customTexts[i] == null) return false;
    }
    return true;
  }

  void _submit() {
    if (_submitted || widget.answeredResult != null) return;
    if (!_canSubmit()) return;

    final answers = <String, String>{};
    final annotations = <String, Map<String, String>>{};
    for (int i = 0; i < _questions.length; i++) {
      final q = _questions[i];
      final selected = _selections[i];
      final custom = _customTexts[i];
      String answer;
      if (custom != null && selected.contains('__OTHER__')) {
        answer = custom;
      } else if (q.multiSelect) {
        answer = selected.join(', ');
      } else {
        answer = selected.first;
      }
      answers[q.question] = answer;
      // 把所选 option 的 preview 一并回传（仅单选有 preview）
      if (!q.multiSelect && !selected.contains('__OTHER__')) {
        final picked = q.options.firstWhere(
          (o) => o.label == selected.first,
          orElse: () => _Option(label: '', description: ''),
        );
        if (picked.preview != null) {
          annotations[q.question] = {'preview': picked.preview!};
        }
      }
    }
    setState(() {
      _submitted = true;
      _localAnswers = answers;
    });
    widget.onSubmit(
      widget.toolUse.id,
      answers,
      annotations.isEmpty ? null : annotations,
    );
  }

  Map<String, String>? _answersFromResult(ToolResultBlock? result) {
    if (result == null) return null;
    final text = _extractText(result.content);
    if (text.trim().isEmpty) return const {};
    final matches = RegExp(
            r'Q: ([\s\S]*?)\nA: ([\s\S]*?)(?=\n(?:selected preview:|notes:|Q: )|$)')
        .allMatches(text);
    final answers = <String, String>{};
    for (final match in matches) {
      final q = match.group(1)?.trim();
      final a = match.group(2)?.trim();
      if (q != null && q.isNotEmpty && a != null && a.isNotEmpty) {
        answers[q] = a;
      }
    }
    return answers.isEmpty ? null : answers;
  }

  String _extractText(dynamic content) {
    if (content == null) return '';
    if (content is String) return content;
    if (content is List) {
      return content.map((item) {
        if (item is Map && item['text'] != null) return item['text'].toString();
        return item.toString();
      }).join('\n');
    }
    return content.toString();
  }
}

// ── Data models ────────────────────────────────────────────────

class _Question {
  final String question;
  final String header;
  final bool multiSelect;
  final List<_Option> options;
  _Question({
    required this.question,
    required this.header,
    required this.multiSelect,
    required this.options,
  });
}

class _AnswerReceipt extends StatelessWidget {
  final Map<String, String> answers;
  final AppTokens t;

  const _AnswerReceipt({required this.answers, required this.t});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: t.success.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border:
            Border.all(color: t.success.withValues(alpha: 0.25), width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.check_circle_outline, size: 14, color: t.success),
              const SizedBox(width: 6),
              Text(
                '已回答',
                style: TextStyle(
                  color: t.success,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          if (answers.isNotEmpty) ...[
            const SizedBox(height: 8),
            for (final entry in answers.entries)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: RichText(
                  text: TextSpan(
                    style: TextStyle(fontSize: 12, color: t.textMuted),
                    children: [
                      TextSpan(
                        text: '${entry.key}: ',
                        style: TextStyle(
                          color: t.textDim,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      TextSpan(
                        text: entry.value,
                        style: TextStyle(color: t.text),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _Option {
  final String label;
  final String description;
  final String? preview;
  _Option({required this.label, required this.description, this.preview});
}

List<_Question> _parseQuestions(Map<String, dynamic> input) {
  final list = (input['questions'] as List?) ?? [];
  return list.map((q) {
    final m = q as Map<String, dynamic>;
    final opts = ((m['options'] as List?) ?? []).map((o) {
      final om = o as Map<String, dynamic>;
      return _Option(
        label: om['label'] as String,
        description: om['description'] as String? ?? '',
        preview: om['preview'] as String?,
      );
    }).toList();
    return _Question(
      question: m['question'] as String,
      header: m['header'] as String,
      multiSelect: (m['multiSelect'] as bool?) ?? false,
      options: opts,
    );
  }).toList();
}

// ── Interactive panel ─────────────────────────────────────────

class _QuestionInteractivePanel extends StatelessWidget {
  final int index;
  final _Question question;
  final bool readOnly;
  final Set<String> selected;
  final String? customText;
  final void Function(String label) onTapOption;
  final void Function(String text) onCustomTextSubmitted;

  const _QuestionInteractivePanel({
    required this.index,
    required this.question,
    required this.readOnly,
    required this.selected,
    required this.customText,
    required this.onTapOption,
    required this.onCustomTextSubmitted,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // header + question
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: t.accentSubt,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                question.header,
                style: TextStyle(
                  fontSize: 10,
                  color: t.accent,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                question.question,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: t.text,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        // options
        for (final o in question.options)
          _OptionTile(
            option: o,
            selected: selected.contains(o.label),
            multiSelect: question.multiSelect,
            disabled: readOnly,
            onTap: () {
              if (readOnly) return;
              onTapOption(o.label);
            },
          ),
        // "Other" 一行
        _OtherTile(
          selected: selected.contains('__OTHER__'),
          customText: customText,
          disabled: readOnly,
          onTap: () async {
            if (readOnly) return;
            final result = await showDialog<String>(
              context: context,
              builder: (ctx) => _CustomInputDialog(initial: customText ?? ''),
            );
            if (result != null && result.isNotEmpty) {
              onCustomTextSubmitted(result);
            }
          },
        ),
        // readOnly 时展示用户当时选了什么
        if (readOnly && selected.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8, left: 4),
            child: Text(
              selected.contains('__OTHER__')
                  ? '→ 你输入了：${customText ?? ''}'
                  : '→ 你选了：${selected.join(', ')}',
              style: TextStyle(fontSize: 12, color: t.textMuted),
            ),
          ),
      ],
    );
  }
}

// ── Option tile ───────────────────────────────────────────────

class _OptionTile extends StatelessWidget {
  final _Option option;
  final bool selected;
  final bool multiSelect;
  final bool disabled;
  final VoidCallback onTap;
  const _OptionTile({
    required this.option,
    required this.selected,
    required this.multiSelect,
    required this.disabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: GestureDetector(
        onTap: disabled ? null : onTap,
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: selected ? t.accentSubt : t.surfaceHi,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected
                  ? t.accent.withValues(alpha: 0.5)
                  : Colors.transparent,
              width: 1,
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (multiSelect)
                Padding(
                  padding: const EdgeInsets.only(right: 8, top: 2),
                  child: Icon(
                    selected ? Icons.check_box : Icons.check_box_outline_blank,
                    size: 18,
                    color: selected ? t.accent : t.textMuted,
                  ),
                ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      option.label,
                      style: TextStyle(
                          fontSize: 14,
                          color: t.text,
                          fontWeight: FontWeight.w500),
                    ),
                    if (option.description.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          option.description,
                          style: TextStyle(fontSize: 12, color: t.textMuted),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                ),
              ),
              // Preview 触发图标（Task 11 接 bottom sheet）
              if (option.preview != null)
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () =>
                      _showPreview(context, option.label, option.preview!),
                  child: Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Icon(Icons.visibility_outlined,
                        size: 18, color: t.textMuted),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _showPreview(BuildContext context, String optionLabel, String preview) {
    final t = AppTokens.of(context);
    // Rudimentary HTML detection: if we see <tag> patterns, fall back to plain text.
    final looksHtml = RegExp(r'<\s*\w+[^>]*>').hasMatch(preview);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return DraggableScrollableSheet(
          initialChildSize: 0.9,
          minChildSize: 0.5,
          maxChildSize: 0.95,
          expand: false,
          builder: (ctx2, scroll) {
            return Container(
              decoration: BoxDecoration(
                color: t.surface,
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(18)),
              ),
              child: Column(
                children: [
                  // drag handle
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: t.border,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  // title row
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 4, 4, 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            optionLabel,
                            style: TextStyle(
                              color: t.text,
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        IconButton(
                          icon: Icon(Icons.close_rounded, color: t.textMuted),
                          onPressed: () => Navigator.of(ctx2).pop(),
                        ),
                      ],
                    ),
                  ),
                  Divider(color: t.borderSubt, height: 1, thickness: 0.5),
                  // body
                  Expanded(
                    child: SingleChildScrollView(
                      controller: scroll,
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                      child: looksHtml
                          ? Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(8),
                                  margin: const EdgeInsets.only(bottom: 12),
                                  decoration: BoxDecoration(
                                    color: t.warning.withValues(alpha: 0.1),
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(
                                      color: t.warning.withValues(alpha: 0.3),
                                    ),
                                  ),
                                  child: Text(
                                    'Preview 含 HTML，显示原文：',
                                    style: TextStyle(
                                        fontSize: 11, color: t.warning),
                                  ),
                                ),
                                SelectableText(
                                  preview,
                                  style: TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 12,
                                    color: t.textMuted,
                                    height: 1.5,
                                  ),
                                ),
                              ],
                            )
                          : MarkdownBody(
                              data: preview,
                              styleSheet:
                                  MarkdownStyleSheet.fromTheme(Theme.of(ctx2)),
                            ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

// ── Other tile ────────────────────────────────────────────────

class _OtherTile extends StatelessWidget {
  final bool selected;
  final String? customText;
  final bool disabled;
  final VoidCallback onTap;
  const _OtherTile({
    required this.selected,
    required this.customText,
    required this.disabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: GestureDetector(
        onTap: disabled ? null : onTap,
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: selected ? t.accentSubt : t.surfaceHi,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected
                  ? t.accent.withValues(alpha: 0.5)
                  : Colors.transparent,
              width: 1,
            ),
          ),
          child: Row(
            children: [
              Icon(Icons.edit_outlined, size: 16, color: t.textMuted),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  selected && customText != null && customText!.isNotEmpty
                      ? customText!
                      : '自定义…',
                  style: TextStyle(
                    fontSize: 14,
                    fontStyle: FontStyle.italic,
                    color: selected ? t.text : t.textMuted,
                  ),
                  maxLines: 1,
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

// ── Custom input dialog ───────────────────────────────────────

class _CustomInputDialog extends StatefulWidget {
  final String initial;
  const _CustomInputDialog({required this.initial});

  @override
  State<_CustomInputDialog> createState() => _CustomInputDialogState();
}

class _CustomInputDialogState extends State<_CustomInputDialog> {
  late final TextEditingController _c;

  @override
  void initState() {
    super.initState();
    _c = TextEditingController(text: widget.initial);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return AlertDialog(
      backgroundColor: t.surface,
      title: Text('自定义输入', style: TextStyle(color: t.text, fontSize: 16)),
      content: TextField(
        controller: _c,
        autofocus: true,
        cursorColor: t.accent,
        style: TextStyle(color: t.text, fontSize: 14),
        decoration: InputDecoration(
          hintText: '输入你的回答…',
          hintStyle: TextStyle(color: t.textDim),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text('取消', style: TextStyle(color: t.textMuted)),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(_c.text.trim()),
          child: Text('确定', style: TextStyle(color: t.accent)),
        ),
      ],
    );
  }
}

// ── Submit button ─────────────────────────────────────────────

class _SubmitButton extends StatelessWidget {
  final bool enabled;
  final VoidCallback onTap;
  const _SubmitButton({required this.enabled, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final bg = enabled
        ? (dark ? t.text : const Color(0xFF101828))
        : (dark ? t.borderSubt : const Color(0xFFD0D5DD));
    final fg = enabled
        ? (dark ? const Color(0xFF0B1210) : Colors.white)
        : (dark ? t.textDim : Colors.white);
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: Container(
        height: 40,
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(10),
        ),
        alignment: Alignment.center,
        child: Text(
          '提交',
          style:
              TextStyle(color: fg, fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}
