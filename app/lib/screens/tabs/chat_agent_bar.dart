import 'package:flutter/material.dart';

import '../../api/agents_api.dart';
import '../../theme.dart';
import '../../widgets/agent_badge.dart';

class ChatAgentBar extends StatelessWidget {
  final AgentKind agent;
  final Map<String, dynamic> runtime;

  const ChatAgentBar({
    super.key,
    required this.agent,
    required this.runtime,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final summary = _runtimeSummary(agent, runtime);

    return Container(
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      color: t.surface,
      child: Row(
        children: [
          AgentBadge(agent: agent, compact: true),
          const SizedBox(width: 8),
          Icon(Icons.tune_rounded, size: 13, color: t.textDim),
          const SizedBox(width: 5),
          Expanded(
            child: Text(
              summary,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: t.textMuted,
                fontSize: 11,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _runtimeSummary(AgentKind agent, Map<String, dynamic> runtime) {
    final model = (runtime['model'] ?? '').toString().trim();
    final parts = <String>[];
    if (model.isNotEmpty) parts.add(model);

    switch (agent) {
      case AgentKind.claude:
        parts.add((runtime['permission_mode'] ?? 'acceptEdits').toString());
      case AgentKind.codex:
        final sandbox = (runtime['sandbox'] ?? 'workspace-write').toString();
        final approval =
            (runtime['approval_policy'] ?? 'on-request').toString();
        final effort = (runtime['reasoning_effort'] ?? '').toString().trim();
        parts.add(sandbox);
        parts.add(approval);
        if (effort.isNotEmpty) parts.add(effort);
      case AgentKind.gemini:
        final approval = (runtime['approval_policy'] ?? '').toString().trim();
        if (approval.isNotEmpty) parts.add(approval);
    }

    return parts.isEmpty ? '默认运行时' : parts.join(' / ');
  }
}
