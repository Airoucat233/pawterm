import type { AgentKind, AgentRuntime, ClaudeRuntime, PermissionMode } from '@pawterm/shared';

export type AgentQuery = AgentKind | 'all';

const validAgents = new Set(['claude', 'codex', 'gemini']);
const validPermissionModes = new Set(['default', 'acceptEdits', 'plan', 'bypassPermissions']);
const validCodexSandboxes = new Set(['read-only', 'workspace-write', 'danger-full-access']);
const validCodexApprovalPolicies = new Set(['untrusted', 'on-request', 'never']);
const validReasoningEfforts = new Set(['low', 'medium', 'high', 'xhigh']);

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

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
  if (body.permission_mode && !validPermissionModes.has(body.permission_mode)) {
    throw badRequest(`Invalid Claude permission_mode: ${body.permission_mode}`);
  }
  return {
    agent: 'claude',
    permission_mode: body.permission_mode ?? 'acceptEdits',
    ...(body.model ? { model: body.model } : {}),
  };
}

export function parseRuntimeFromChatBody(body: {
  agent?: string;
  runtime?: unknown;
  model?: string;
  permission_mode?: PermissionMode;
}): AgentRuntime {
  const agent = parseAgentQuery(body.agent);
  if (agent === 'all') {
    throw new Error('agent=all is not valid for chat runtime');
  }
  if (body.runtime) {
    return parseFullRuntime(agent, body.runtime);
  }
  if (agent === 'claude') return parseClaudeRuntimeFromBody(body);
  if (agent === 'codex') {
    return {
      agent: 'codex',
      ...(body.model ? { model: body.model } : {}),
      sandbox: 'workspace-write',
      approval_policy: 'on-request',
    };
  }
  return { agent: 'gemini' };
}

function parseFullRuntime(agent: AgentKind, runtime: unknown): AgentRuntime {
  if (!isRecord(runtime)) throw badRequest('runtime must be an object');
  if (runtime['agent'] !== agent) {
    throw badRequest(`runtime agent mismatch: route=${agent} runtime=${String(runtime['agent'])}`);
  }
  if (agent === 'claude') {
    const permissionMode = runtime['permission_mode'];
    if (typeof permissionMode !== 'string' || !validPermissionModes.has(permissionMode)) {
      throw badRequest('Claude runtime requires valid permission_mode');
    }
    return {
      agent: 'claude',
      permission_mode: permissionMode as PermissionMode,
      ...(typeof runtime['model'] === 'string' ? { model: runtime['model'] } : {}),
    };
  }
  if (agent === 'codex') {
    const sandbox = runtime['sandbox'];
    const approvalPolicy = runtime['approval_policy'];
    const reasoningEffort = runtime['reasoning_effort'];
    if (typeof sandbox !== 'string' || !validCodexSandboxes.has(sandbox)) {
      throw badRequest('Codex runtime requires valid sandbox');
    }
    if (typeof approvalPolicy !== 'string' || !validCodexApprovalPolicies.has(approvalPolicy)) {
      throw badRequest('Codex runtime requires valid approval_policy');
    }
    if (reasoningEffort !== undefined && (typeof reasoningEffort !== 'string' || !validReasoningEfforts.has(reasoningEffort))) {
      throw badRequest(`Invalid Codex reasoning_effort: ${String(reasoningEffort)}`);
    }
    return {
      agent: 'codex',
      sandbox: sandbox as 'read-only' | 'workspace-write' | 'danger-full-access',
      approval_policy: approvalPolicy as 'untrusted' | 'on-request' | 'never',
      ...(typeof runtime['model'] === 'string' ? { model: runtime['model'] } : {}),
      ...(typeof reasoningEffort === 'string' ? { reasoning_effort: reasoningEffort as 'low' | 'medium' | 'high' | 'xhigh' } : {}),
    };
  }
  return {
    agent: 'gemini',
    ...(typeof runtime['model'] === 'string' ? { model: runtime['model'] } : {}),
    ...(typeof runtime['approval_policy'] === 'string' ? { approval_policy: runtime['approval_policy'] } : {}),
  };
}

export function parseRuntimePatchForAgent(
  agentValue: string | undefined,
  runtime: unknown,
): { agent: AgentKind; patch: Partial<AgentRuntime> } {
  const agent = parseAgentQuery(agentValue);
  if (agent === 'all') throw badRequest('agent=all is not valid for chat runtime');
  if (!isRecord(runtime)) throw badRequest('runtime required');
  if (runtime['agent'] !== undefined && runtime['agent'] !== agent) {
    throw badRequest(`runtime agent mismatch: route=${agent} runtime=${String(runtime['agent'])}`);
  }

  if (agent === 'claude') {
    const patch: Partial<ClaudeRuntime> = { agent: 'claude' };
    if (runtime['model'] !== undefined) {
      if (typeof runtime['model'] !== 'string') throw badRequest('Claude runtime model must be a string');
      patch.model = runtime['model'];
    }
    if (runtime['permission_mode'] !== undefined) {
      if (typeof runtime['permission_mode'] !== 'string' || !validPermissionModes.has(runtime['permission_mode'])) {
        throw badRequest(`Invalid Claude permission_mode: ${String(runtime['permission_mode'])}`);
      }
      patch.permission_mode = runtime['permission_mode'] as PermissionMode;
    }
    return { agent, patch };
  }

  return { agent, patch: { agent } as Partial<AgentRuntime> };
}
