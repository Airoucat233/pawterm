import type { AgentKind, ClaudeRuntime, PermissionMode } from '@pawterm/shared';

export type AgentQuery = AgentKind | 'all';

const validAgents = new Set(['claude', 'codex', 'gemini']);

function badRequest(message: string): Error {
  const error = new Error(message);
  (error as Error & { statusCode?: number }).statusCode = 400;
  return error;
}

export function parseAgentQuery(
  value: string | undefined,
  opts: { allowAll?: boolean } = {},
): AgentQuery {
  if (!value) return 'claude';
  if (value === 'all') {
    if (opts.allowAll) return 'all';
    throw badRequest('agent=all is not valid for this route');
  }
  if (validAgents.has(value)) return value as AgentKind;
  throw badRequest(`Unknown agent: ${value}`);
}

export function parseClaudeRuntimeFromBody(body: {
  model?: string;
  permission_mode?: PermissionMode;
}): ClaudeRuntime {
  return {
    agent: 'claude',
    permission_mode: body.permission_mode ?? 'acceptEdits',
    ...(body.model ? { model: body.model } : {}),
  };
}
