import 'dart:convert';

import 'package:flutter/material.dart';

import '../api/protocol.dart';
import '../theme.dart';

class CodexApprovalCard extends StatefulWidget {
  final ToolUseBlock toolUse;
  final ToolResultBlock? answeredResult;
  final String? localDecision;
  final bool initiallyExpanded;
  final void Function(String requestId, String decision) onSubmit;

  const CodexApprovalCard({
    super.key,
    required this.toolUse,
    required this.answeredResult,
    this.localDecision,
    this.initiallyExpanded = true,
    required this.onSubmit,
  });

  @override
  State<CodexApprovalCard> createState() => _CodexApprovalCardState();
}

class _CodexApprovalCardState extends State<CodexApprovalCard> {
  String? _localDecision;
  late bool _expanded;
  bool _viewRaw = false;

  @override
  void initState() {
    super.initState();
    _expanded = widget.answeredResult == null && widget.localDecision == null
        ? widget.initiallyExpanded
        : false;
  }

  @override
  void didUpdateWidget(covariant CodexApprovalCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final wasAnswered = _decisionFromResult(oldWidget.answeredResult) ??
        oldWidget.localDecision ??
        _localDecision;
    final isAnswered = _decisionFromResult(widget.answeredResult) ??
        widget.localDecision ??
        _localDecision;
    if (wasAnswered == null && isAnswered != null && _expanded) {
      _expanded = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final decision = _decisionFromResult(widget.answeredResult) ??
        widget.localDecision ??
        _localDecision;
    final answered = decision != null;
    final method = widget.toolUse.name;
    final input = widget.toolUse.input;
    final title = _title(method);
    final details = _details(method, input);
    final reason = _reason(input);
    final decisionLabel = _decisionLabel(decision);
    final decisionColor = _decisionColor(t, decision);
    final statusLabel = decisionLabel ?? '等待确认';
    final statusColor = answered ? decisionColor : t.warning;
    final actions = _actionsFor(method, t);

    return AnimatedOpacity(
      duration: const Duration(milliseconds: 160),
      opacity: 1,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        decoration: BoxDecoration(
          color: t.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border(
            top: BorderSide(color: t.border, width: 0.5),
            right: BorderSide(color: t.border, width: 0.5),
            bottom: BorderSide(color: t.border, width: 0.5),
            left: BorderSide(
              color: answered ? decisionColor : t.warning,
              width: 3,
            ),
          ),
        ),
        padding: const EdgeInsets.fromLTRB(12, 9, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InkWell(
              onTap: () => setState(() => _expanded = !_expanded),
              onDoubleTap:
                  _expanded ? () => setState(() => _expanded = false) : null,
              borderRadius: BorderRadius.circular(6),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Icon(Icons.privacy_tip_outlined,
                        size: 15, color: statusColor),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: t.text,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      statusLabel,
                      style: TextStyle(
                        color: statusColor,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(
                      _expanded
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      size: 18,
                      color: t.textDim,
                    ),
                  ],
                ),
              ),
            ),
            if (!_expanded && reason != null) ...[
              const SizedBox(height: 6),
              Text(
                reason,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: t.textMuted,
                  fontSize: 11.5,
                  height: 1.35,
                ),
              ),
            ],
            if (_expanded) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      method,
                      style: TextStyle(
                        color: t.textDim,
                        fontSize: 10,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                  _SegmentedControl(
                    isRaw: _viewRaw,
                    onChanged: (value) => setState(() => _viewRaw = value),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (_viewRaw)
                _DetailBox(text: _rawPayload(), t: t)
              else
                _PrettyApprovalDetails(
                  reason: reason,
                  details: details,
                  t: t,
                ),
              if (!answered) ...[
                const SizedBox(height: 10),
                Row(
                  children: [
                    for (var i = 0; i < actions.length; i++) ...[
                      if (i > 0) const SizedBox(width: 8),
                      Expanded(
                        child: _ActionButton(
                          label: actions[i].label,
                          color: actions[i].color,
                          onTap: () => _submit(actions[i].decision),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  void _submit(String decision) {
    if (_localDecision != null ||
        widget.localDecision != null ||
        widget.answeredResult != null) {
      return;
    }
    setState(() {
      _localDecision = decision;
      _expanded = false;
    });
    widget.onSubmit(widget.toolUse.id, decision);
  }

  String? _decisionFromResult(ToolResultBlock? result) {
    if (result == null) return null;
    final content = result.content;
    if (content is String && content.trim().isNotEmpty) {
      return content.trim();
    }
    return 'resolved';
  }

  String? _decisionLabel(String? decision) => switch (decision) {
        null => null,
        'accept' => '已允许本次',
        'acceptForSession' => '本会话已允许',
        'decline' => '已拒绝',
        'cancel' => '已取消',
        'resolved' => '已处理',
        _ => '已处理: $decision',
      };

  Color _decisionColor(AppTokens t, String? decision) => switch (decision) {
        'decline' || 'cancel' => t.error,
        'accept' || 'acceptForSession' => t.success,
        _ => t.textDim,
      };

  List<_ApprovalAction> _actionsFor(String method, AppTokens t) {
    if (method == 'item/permissions/requestApproval') {
      return [
        _ApprovalAction('拒绝', 'decline', t.error),
        _ApprovalAction('允许本次', 'accept', t.accent),
        _ApprovalAction('本会话允许', 'acceptForSession', t.warning),
      ];
    }
    if (method == 'item/fileChange/requestApproval') {
      return [
        _ApprovalAction('拒绝', 'decline', t.error),
        _ApprovalAction('允许修改', 'accept', t.accent),
      ];
    }
    if (method == 'item/commandExecution/requestApproval') {
      return [
        _ApprovalAction('拒绝', 'decline', t.error),
        _ApprovalAction('允许执行', 'accept', t.accent),
      ];
    }
    return [
      _ApprovalAction('拒绝', 'decline', t.error),
      _ApprovalAction('允许', 'accept', t.accent),
    ];
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

  List<_ApprovalDetail> _details(String method, Map<String, dynamic> input) {
    final details = <_ApprovalDetail>[];
    if (method == 'item/commandExecution/requestApproval') {
      final command = input['command']?.toString();
      final cwd = input['cwd']?.toString();
      if (command != null && command.isNotEmpty) {
        details.add(_ApprovalDetail('command', command, monospace: true));
      }
      if (cwd != null && cwd.isNotEmpty) {
        details.add(_ApprovalDetail('cwd', cwd, monospace: true));
      }
    } else if (method == 'item/fileChange/requestApproval') {
      final grantRoot = input['grantRoot']?.toString();
      if (grantRoot != null && grantRoot.isNotEmpty) {
        details.add(_ApprovalDetail('grant root', grantRoot, monospace: true));
      }
    } else if (method == 'item/permissions/requestApproval') {
      final cwd = input['cwd']?.toString();
      if (cwd != null && cwd.isNotEmpty) {
        details.add(_ApprovalDetail('cwd', cwd, monospace: true));
      }
      details
          .add(_ApprovalDetail('permissions', _pretty(input['permissions'])));
    }
    return details;
  }

  String _rawPayload() {
    return _pretty(
        widget.toolUse.rawPayload ?? {'input': widget.toolUse.input});
  }

  String? _reason(Map<String, dynamic> input) {
    final reason = input['reason']?.toString().trim();
    if (reason != null && reason.isNotEmpty) return reason;
    return null;
  }

  String _pretty(Object? value) {
    try {
      return const JsonEncoder.withIndent('  ').convert(value);
    } catch (_) {
      return value.toString();
    }
  }
}

class _ApprovalDetail {
  final String label;
  final String value;
  final bool monospace;

  const _ApprovalDetail(
    this.label,
    this.value, {
    this.monospace = false,
  });
}

class _ApprovalAction {
  final String label;
  final String decision;
  final Color color;

  const _ApprovalAction(this.label, this.decision, this.color);
}

class _PrettyApprovalDetails extends StatelessWidget {
  final String? reason;
  final List<_ApprovalDetail> details;
  final AppTokens t;

  const _PrettyApprovalDetails({
    required this.reason,
    required this.details,
    required this.t,
  });

  @override
  Widget build(BuildContext context) {
    final hasReason = reason != null && reason!.trim().isNotEmpty;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: t.bg,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: t.borderSubt, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (hasReason) ...[
            _SectionLabel('reason', t),
            const SizedBox(height: 4),
            SelectableText(
              reason!,
              style: TextStyle(
                color: t.text,
                fontSize: 12,
                height: 1.45,
              ),
            ),
            if (details.isNotEmpty) const SizedBox(height: 10),
          ],
          if (details.isNotEmpty) ...[
            _SectionLabel('details', t),
            const SizedBox(height: 6),
            for (final detail in details) ...[
              _DetailRow(detail: detail, t: t),
              if (detail != details.last) const SizedBox(height: 6),
            ],
          ],
          if (!hasReason && details.isEmpty)
            Text(
              'No structured approval details.',
              style: TextStyle(color: t.textDim, fontSize: 11.5),
            ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  final AppTokens t;

  const _SectionLabel(this.text, this.t);

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: TextStyle(
        color: t.textDim,
        fontSize: 9.5,
        fontWeight: FontWeight.w700,
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  final _ApprovalDetail detail;
  final AppTokens t;

  const _DetailRow({required this.detail, required this.t});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 74,
          child: Text(
            detail.label,
            style: TextStyle(
              color: t.textDim,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Expanded(
          child: SelectableText(
            detail.value,
            style: TextStyle(
              color: t.textMuted,
              fontSize: 11.5,
              height: 1.4,
              fontFamily: detail.monospace ? 'monospace' : null,
            ),
          ),
        ),
      ],
    );
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

class _SegmentedControl extends StatelessWidget {
  final bool isRaw;
  final ValueChanged<bool> onChanged;

  const _SegmentedControl({required this.isRaw, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Container(
      height: 22,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: t.border, width: 0.5),
      ),
      clipBehavior: Clip.hardEdge,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _Seg(
            label: 'pretty',
            selected: !isRaw,
            onTap: () => onChanged(false),
            t: t,
          ),
          Container(width: 0.5, color: t.border),
          _Seg(
            label: 'raw',
            selected: isRaw,
            onTap: () => onChanged(true),
            t: t,
          ),
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

  const _Seg({
    required this.label,
    required this.selected,
    required this.onTap,
    required this.t,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: selected ? null : onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        color: selected ? t.accent : Colors.transparent,
        child: Text(
          label,
          style: TextStyle(
            fontSize: 10,
            color: selected ? Colors.white : t.textMuted,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          ),
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
