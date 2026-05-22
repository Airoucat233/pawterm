import 'package:flutter/material.dart';

import '../api/agents_api.dart';
import '../theme.dart';

class AgentBadge extends StatelessWidget {
  final AgentKind agent;
  final bool compact;

  const AgentBadge({super.key, required this.agent, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final label = switch (agent) {
      AgentKind.claude => 'Claude',
      AgentKind.codex => 'Codex',
      AgentKind.gemini => 'Gemini',
    };
    final color = switch (agent) {
      AgentKind.claude => t.toolTodo,
      AgentKind.codex => t.accent,
      AgentKind.gemini => t.toolRead,
    };
    return Container(
      height: compact ? 20 : 24,
      padding: EdgeInsets.symmetric(horizontal: compact ? 7 : 9),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.28), width: 0.5),
      ),
      alignment: Alignment.center,
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: compact ? 10 : 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
