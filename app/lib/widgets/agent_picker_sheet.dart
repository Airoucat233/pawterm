import 'package:flutter/material.dart';

import '../api/agents_api.dart';
import '../theme.dart';
import 'agent_badge.dart';

class AgentPickerSheet extends StatefulWidget {
  final List<AgentInfo> agents;
  final AgentKind selected;
  final ValueChanged<AgentKind> onSelected;

  const AgentPickerSheet({
    super.key,
    required this.agents,
    required this.selected,
    required this.onSelected,
  });

  @override
  State<AgentPickerSheet> createState() => _AgentPickerSheetState();
}

class _AgentPickerSheetState extends State<AgentPickerSheet> {
  late AgentKind _selected = widget.selected;

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 18),
        decoration: BoxDecoration(
          color: t.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
          border: Border(top: BorderSide(color: t.border, width: 0.5)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 42,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: t.border,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
            Text('选择 Agent',
                style: TextStyle(
                    color: t.text, fontSize: 17, fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * 0.58,
              ),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: widget.agents.length,
                itemBuilder: (context, index) {
                  final agent = widget.agents[index];
                  return _AgentOption(
                    info: agent,
                    selected: agent.kind == _selected,
                    onTap: agent.status == 'ready'
                        ? () => setState(() => _selected = agent.kind)
                        : null,
                  );
                },
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              height: 46,
              child: FilledButton(
                onPressed: () => widget.onSelected(_selected),
                style: FilledButton.styleFrom(
                  backgroundColor: t.accent,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                child: const Text('设为本项目默认'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AgentOption extends StatelessWidget {
  final AgentInfo info;
  final bool selected;
  final VoidCallback? onTap;

  const _AgentOption(
      {required this.info, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final desc = switch (info.kind) {
      AgentKind.claude => '适合继续 Claude 历史会话和 Claude 权限模式',
      AgentKind.codex => 'OpenAI 编程 Agent，支持 sandbox 和审批流',
      AgentKind.gemini => '预留 Provider，后续可接入 Gemini CLI',
    };
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Opacity(
        opacity: onTap == null ? 0.52 : 1,
        child: Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: selected ? t.accentSubt : t.surfaceHi,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected ? t.accent.withValues(alpha: 0.45) : t.borderSubt,
              width: 0.5,
            ),
          ),
          child: Row(
            children: [
              AgentBadge(agent: info.kind),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      info.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: t.text,
                          fontWeight: FontWeight.w700,
                          fontSize: 14),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      info.statusMessage ?? desc,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: t.textMuted, fontSize: 12, height: 1.35),
                    ),
                  ],
                ),
              ),
              if (selected)
                Icon(Icons.check_rounded, size: 18, color: t.accent),
            ],
          ),
        ),
      ),
    );
  }
}
