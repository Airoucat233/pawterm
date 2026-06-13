import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';

import type { AgentKind, AgentRuntime, CodexRuntime, ClaudeRuntime, GeminiRuntime, SessionRuntimeRecord } from '@pawterm/shared';
import { configPath } from './config.js';

type RuntimeBySession = Record<string, SessionRuntimeRecord>;
type RuntimeStoreFile = {
  sessions?: RuntimeBySession;
};
type RuntimePatch = Record<string, unknown> | Partial<AgentRuntime> | AgentRuntime;

const STORE_PATH = resolve(dirname(configPath), 'session-runtime.json');

function key(agent: AgentKind, cwd: string, sessionId: string): string {
  return `${agent}|${cwd}|${sessionId}`;
}

export function defaultRuntimeForAgent(agent: AgentKind): AgentRuntime {
  if (agent === 'codex') {
    return {
      agent: 'codex',
      sandbox: 'workspace-write',
      approval_policy: 'on-request',
      reasoning_effort: 'medium',
    };
  }
  if (agent === 'gemini') return { agent: 'gemini' };
  return { agent: 'claude', permission_mode: 'acceptEdits' };
}

function readStore(): RuntimeStoreFile {
  if (!existsSync(STORE_PATH)) return {};
  try {
    return JSON.parse(readFileSync(STORE_PATH, 'utf-8')) as RuntimeStoreFile;
  } catch {
    return {};
  }
}

function writeStore(store: RuntimeStoreFile): void {
  mkdirSync(dirname(STORE_PATH), { recursive: true });
  writeFileSync(STORE_PATH, JSON.stringify(store, null, 2));
}

export function normalizeRuntime(agent: AgentKind, runtime?: Partial<AgentRuntime>): AgentRuntime {
  const base = defaultRuntimeForAgent(agent);
  const merged = { ...base, ...(runtime ?? {}), agent } as AgentRuntime;
  if (agent === 'codex') {
    const codex = merged as CodexRuntime;
    return {
      agent: 'codex',
      sandbox: codex.sandbox ?? 'workspace-write',
      approval_policy: codex.approval_policy ?? 'on-request',
      reasoning_effort: codex.reasoning_effort ?? 'medium',
      ...(typeof codex.model === 'string' && codex.model.trim().length > 0 ? { model: codex.model } : {}),
    };
  }
  if (agent === 'claude') {
    const claude = merged as ClaudeRuntime;
    return {
      agent: 'claude',
      permission_mode: claude.permission_mode ?? 'acceptEdits',
      ...(typeof claude.model === 'string' && claude.model.trim().length > 0 ? { model: claude.model } : {}),
    };
  }
  const gemini = merged as GeminiRuntime;
  return {
    agent: 'gemini',
    ...(typeof gemini.model === 'string' && gemini.model.trim().length > 0 ? { model: gemini.model } : {}),
    ...(typeof gemini.approval_policy === 'string' && gemini.approval_policy.trim().length > 0
      ? { approval_policy: gemini.approval_policy }
      : {}),
  };
}

export function getSessionRuntime(agent: AgentKind, cwd: string, sessionId: string): SessionRuntimeRecord {
  const store = readStore();
  const existing = store.sessions?.[key(agent, cwd, sessionId)];
  const runtime = normalizeRuntime(agent, existing?.runtime as Partial<AgentRuntime> | undefined);
  return {
    agent,
    cwd,
    sessionId,
    runtime,
    updatedAt: existing?.updatedAt ?? 0,
  };
}

export function setSessionRuntime(
  agent: AgentKind,
  cwd: string,
  sessionId: string,
  patch: RuntimePatch,
): SessionRuntimeRecord {
  const store = readStore();
  const sessions = store.sessions ?? {};
  const existing = sessions[key(agent, cwd, sessionId)];
  const runtime = normalizeRuntime(agent, {
    ...(existing?.runtime as Partial<AgentRuntime> | undefined),
    ...(patch as Record<string, unknown>),
  } as Partial<AgentRuntime>);
  const record: SessionRuntimeRecord = {
    agent,
    cwd,
    sessionId,
    runtime,
    updatedAt: Date.now(),
  };
  sessions[key(agent, cwd, sessionId)] = record;
  writeStore({ ...store, sessions });
  return record;
}
