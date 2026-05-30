import 'dart:convert';

import 'package:flutter/material.dart';

import '../api/protocol.dart';
import '../theme.dart';

class CodexApprovalCard extends StatefulWidget {
  final ToolUseBlock toolUse;
  final ToolResultBlock? answeredResult;
  final void Function(String requestId, String decision) onSubmit;

  const CodexApprovalCard({
    super.key,
    required this.toolUse,
    required this.answeredResult,
    required this.onSubmit,
  });

  @override
  State<CodexApprovalCard> createState() => _CodexApprovalCardState();
}

class _CodexApprovalCardState extends State<CodexApprovalCard> {
  bool _submitted = false;

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final answered = widget.answeredResult != null || _submitted;
    final method = widget.toolUse.name;
    final input = widget.toolUse.input;
    final title = _title(method);
    final summary = _summary(method, input);

    return AnimatedOpacity(
      duration: const Duration(milliseconds: 160),
      opacity: answered ? 0.72 : 1,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        decoration: BoxDecoration(
          color: t.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border(
            top: BorderSide(color: t.border, width: 0.5),
            right: BorderSide(color: t.border, width: 0.5),
            bottom: BorderSide(color: t.border, width: 0.5),
            left: BorderSide(color: t.warning, width: 3),
          ),
        ),
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.privacy_tip_outlined, size: 15, color: t.warning),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(
                      color: t.text,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Text(
                  answered ? '已处理' : '等待确认',
                  style: TextStyle(
                    color: answered ? t.textDim : t.warning,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              method,
              style: TextStyle(
                color: t.textDim,
                fontSize: 10,
                fontFamily: 'monospace',
              ),
            ),
            const SizedBox(height: 8),
            _DetailBox(text: summary, t: t),
            if (!answered) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: _ActionButton(
                      label: '拒绝',
                      color: t.error,
                      onTap: () => _submit('decline'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _ActionButton(
                      label: '允许本次',
                      color: t.accent,
                      onTap: () => _submit('accept'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _ActionButton(
                      label: '本会话允许',
                      color: t.warning,
                      onTap: () => _submit('acceptForSession'),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _submit(String decision) {
    if (_submitted || widget.answeredResult != null) return;
    setState(() => _submitted = true);
    widget.onSubmit(widget.toolUse.id, decision);
  }

  String _title(String method) {
    if (method == 'item/commandExecution/requestApproval') {
      return 'Codex 请求执行命令';
    }
    if (method == 'item/fileChange/requestApproval') {
      return 'Codex 请求修改文件';
    }
    if (method == 'item/permissions/requestApproval') {
      return 'Codex 请求额外权限';
    }
    return 'Codex 请求审批';
  }

  String _summary(String method, Map<String, dynamic> input) {
    final reason = input['reason']?.toString();
    final lines = <String>[];
    if (reason != null && reason.trim().isNotEmpty) {
      lines.add('reason: $reason');
    }
    if (method == 'item/commandExecution/requestApproval') {
      final command = input['command']?.toString();
      final cwd = input['cwd']?.toString();
      if (command != null && command.isNotEmpty) lines.add('command: $command');
      if (cwd != null && cwd.isNotEmpty) lines.add('cwd: $cwd');
    } else if (method == 'item/fileChange/requestApproval') {
      final grantRoot = input['grantRoot']?.toString();
      if (grantRoot != null && grantRoot.isNotEmpty) {
        lines.add('grantRoot: $grantRoot');
      }
    } else if (method == 'item/permissions/requestApproval') {
      final cwd = input['cwd']?.toString();
      if (cwd != null && cwd.isNotEmpty) lines.add('cwd: $cwd');
      lines.add('permissions: ${_pretty(input['permissions'])}');
    }
    if (lines.isEmpty) return _pretty(input);
    return lines.join('\n');
  }

  String _pretty(Object? value) {
    try {
      return const JsonEncoder.withIndent('  ').convert(value);
    } catch (_) {
      return value.toString();
    }
  }
}

class _DetailBox extends StatelessWidget {
  final String text;
  final AppTokens t;

  const _DetailBox({required this.text, required this.t});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: t.bg,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: t.borderSubt, width: 0.5),
      ),
      child: SelectableText(
        text,
        style: TextStyle(
          color: t.textMuted,
          fontSize: 11,
          height: 1.45,
          fontFamily: 'monospace',
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _ActionButton({
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        foregroundColor: color,
        side: BorderSide(color: color.withValues(alpha: 0.45)),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 9),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
      ),
      child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
    );
  }
}
