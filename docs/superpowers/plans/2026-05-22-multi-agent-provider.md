# Multi-Agent Provider Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a clean multi-Agent architecture for Claude Code and Codex, with Agent-aware sessions, runtime settings, App interaction surfaces, and tool cards that preserve each Agent's native names.

**Architecture:** Introduce an `AgentProvider` boundary in the server, move existing Claude logic behind `ClaudeAgentProvider`, add Codex through `codex app-server`, and extend the shared protocol/App state with `AgentKind`, `AgentRuntime`, and Agent-aware sessions. The App uses a Project -> Agent -> Session flow and reuses tool renderers without renaming native tool/event names.

**Tech Stack:** TypeScript, Fastify, Vitest, `@anthropic-ai/claude-agent-sdk`, Codex CLI app-server protocol, Flutter/Dart, Riverpod, SharedPreferences

---

## File Map

| File | Action | Responsibility |
|---|---|---|
| `packages/shared/src/protocol.ts` | Modify | Agent types, runtime union, Agent metadata on chat events |
| `packages/shared/src/sessions.ts` | Modify | Add `agent` to `SessionSummary` |
| `server/src/agents/types.ts` | Create | Provider interfaces and runtime helpers |
| `server/src/agents/registry.ts` | Create | Provider registration and lookup |
| `server/src/agents/claude/provider.ts` | Create | Claude provider wrapper around existing SDK/session/history behavior |
| `server/src/agents/claude/session.ts` | Create | Move `ChatSession` implementation from current `session-manager.ts` |
| `server/src/agents/claude/serialize.ts` | Create | Move current `messageToWire` and preserve Claude tool names |
| `server/src/agents/claude/sessions.ts` | Create | Move Claude `~/.claude/projects` history/session logic |
| `server/src/agents/codex/client.ts` | Create | JSON-RPC transport to Codex app-server |
| `server/src/agents/codex/serialize.ts` | Create | Codex ThreadItem/notification to PawTerm wire conversion |
| `server/src/agents/codex/provider.ts` | Create | Codex provider using app-server thread/turn APIs |
| `server/src/session-manager.ts` | Modify | Compatibility re-export during migration |
| `server/src/serialize.ts` | Modify | Compatibility re-export during migration |
| `server/src/sessions-api.ts` | Modify | Dispatch sessions/history by `agent` |
| `server/src/chat-rest.ts` | Modify | Dispatch turns/runtime/interrupt by `agent` |
| `server/src/index.ts` | Modify | Register `/agents`, keep `/models` for Claude compatibility |
| `server/src/__tests__/agents-protocol.test.ts` | Create | Protocol/runtime helper tests |
| `server/src/__tests__/agents-registry.test.ts` | Create | Registry tests |
| `server/src/__tests__/codex-serialize.test.ts` | Create | Codex native naming tests |
| `server/src/__tests__/chat-agent-runtime.test.ts` | Create | Chat body compatibility tests |
| `app/lib/api/agents_api.dart` | Create | `/agents` client and Agent model parsing |
| `app/lib/api/protocol.dart` | Modify | Dart Agent metadata and raw payload on tool blocks |
| `app/lib/api/sessions_api.dart` | Modify | Add `AgentKind agent`, `agent` query filter |
| `app/lib/api/chat_api.dart` | Modify | Send `agent` and runtime to `/chat/stream`; add `/chat/runtime` |
| `app/lib/state/agents_store.dart` | Create | Agent list and per-project default Agent |
| `app/lib/state/projects_store.dart` | Modify | Add Agent/runtime to `CurrentSession`; sessions family supports filter |
| `app/lib/widgets/agent_badge.dart` | Create | Compact Agent label/badge |
| `app/lib/widgets/agent_picker_sheet.dart` | Create | Project Agent picker bottom sheet |
| `app/lib/screens/project_picker_screen.dart` | Modify | Current Agent card and All/Claude/Codex session filter |
| `app/lib/screens/main_shell.dart` | Modify | Preserve `CurrentSession.agent` through top bar/session switcher |
| `app/lib/screens/tabs/chat_agent_bar.dart` | Create | Chat top Agent runtime summary |
| `app/lib/screens/tabs/chat_tab.dart` | Modify | Agent-aware stream/start/runtime UI wiring |
| `app/lib/widgets/tool_call_card.dart` | Modify | Native title rule, Agent-specific renderer selection, raw payload foldout |
| `docs/superpowers/mockups/multi-agent-mobile-demo.html` | Keep | Interaction reference only |

Compilation note: server tasks 1-5 should complete before `pnpm --filter @cc/server run typecheck` is expected to pass. App tasks 9-13 should complete before `flutter analyze` is expected to pass.

---

## Task 1: Shared Protocol Agent Types

**Files:**
- Modify: `packages/shared/src/protocol.ts`
- Modify: `packages/shared/src/sessions.ts`
- Verify: `pnpm --filter @pawterm/shared run typecheck`

- [ ] **Step 1: Add Agent protocol types**

In `packages/shared/src/protocol.ts`, insert after `PermissionMode`:

```ts
export type AgentKind = 'claude' | 'codex' | 'gemini';

export type AgentStatus =
  | 'ready'
  | 'not_installed'
  | 'not_logged_in'
  | 'disabled'
  | 'error';

export interface AgentCapabilities {
  streaming: boolean;
  history: boolean;
  approvals: boolean;
  modelSwitch: boolean;
  runtimeSwitch: boolean;
  rawEvents: boolean;
}

export interface AgentSessionRef {
  agent: AgentKind;
  id: string;
}

export interface ClaudeRuntime {
  agent: 'claude';
  model?: string;
  permission_mode: PermissionMode;
}

export interface CodexRuntime {
  agent: 'codex';
  model?: string;
  reasoning_effort?: 'low' | 'medium' | 'high' | 'xhigh';
  sandbox: 'read-only' | 'workspace-write' | 'danger-full-access';
  approval_policy: 'untrusted' | 'on-request' | 'never';
}

export interface GeminiRuntime {
  agent: 'gemini';
  model?: string;
  approval_policy?: string;
}

export type AgentRuntime = ClaudeRuntime | CodexRuntime | GeminiRuntime;

export interface AgentInfo {
  kind: AgentKind;
  label: string;
  status: AgentStatus;
  statusMessage?: string;
  defaultRuntime: AgentRuntime;
  capabilities: AgentCapabilities;
}

export interface AgentsResponse {
  agents: AgentInfo[];
}

export interface AgentEventMeta {
  agent?: AgentKind;
  session_ref?: AgentSessionRef;
  native_type?: string;
  native_name?: string;
  native_event?: string;
  raw_payload?: unknown;
}
```

- [ ] **Step 2: Extend chat message and content block types**

In `packages/shared/src/protocol.ts`, change `ChatServerMessage` members to include `AgentEventMeta` through intersections. Use this exact shape:

```ts
export type ChatServerMessage =
  | ({ type: 'session_ready'; session_key: string; cwd: string; permission_mode: PermissionMode; resumed?: string | null; busy?: boolean } & AgentEventMeta)
  | ({ type: 'assistant'; model?: string; content: ContentBlock[]; timestamp?: number; parent_tool_use_id?: string | null } & AgentEventMeta)
  | ({ type: 'user'; content: ContentBlock[]; timestamp?: number; parent_tool_use_id?: string | null } & AgentEventMeta)
  | ({ type: 'system'; subtype?: string; data?: unknown; timestamp?: number } & AgentEventMeta)
  | ({ type: 'result'; subtype?: string; duration_ms?: number; duration_api_ms?: number; is_error: boolean; num_turns?: number; session_id?: string; total_cost_usd?: number; usage?: unknown; timestamp?: number } & AgentEventMeta)
  | ({ type: 'stream_block_start'; index: number; kind: string; parent_tool_use_id?: string | null } & AgentEventMeta)
  | ({ type: 'stream_delta'; index: number; kind: 'text' | 'thinking'; text: string; parent_tool_use_id?: string | null } & AgentEventMeta)
  | ({ type: 'stream_block_stop'; index: number; parent_tool_use_id?: string | null } & AgentEventMeta)
  | ({ type: 'compact_boundary'; trigger: string | null; pre_tokens: number | null; post_tokens: number | null; duration_ms: number | null; timestamp?: number } & AgentEventMeta)
  | ({ type: 'error'; message: string } & AgentEventMeta)
  | { type: 'pong' };
```

Then update tool blocks:

```ts
export type ContentBlock =
  | { type: 'text'; text: string }
  | { type: 'thinking'; text: string }
  | {
      type: 'tool_use';
      id: string;
      name: string;
      input: Record<string, unknown>;
      native_type?: string;
      native_event?: string;
      raw_payload?: unknown;
    }
  | {
      type: 'tool_result';
      tool_use_id: string;
      content: ToolResultContent;
      is_error: boolean;
      native_type?: string;
      native_event?: string;
      raw_payload?: unknown;
    };
```

- [ ] **Step 3: Add `agent` to shared session summary**

In `packages/shared/src/sessions.ts`, import `AgentKind` from `./protocol.js` and add:

```ts
agent: AgentKind;
```

to `SessionSummary`. Keep existing fields unchanged.

- [ ] **Step 4: Verify shared package typecheck**

Run:

```bash
pnpm --filter @pawterm/shared run typecheck
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add packages/shared/src/protocol.ts packages/shared/src/sessions.ts
git commit -m "feat(shared): add agent protocol types"
```

---

## Task 2: Server Agent Provider Interface And Registry

**Files:**
- Create: `server/src/agents/types.ts`
- Create: `server/src/agents/registry.ts`
- Create: `server/src/__tests__/agents-registry.test.ts`
- Modify: `server/src/index.ts`
- Test: `server/src/__tests__/agents-registry.test.ts`

- [ ] **Step 1: Write failing registry tests**

Create `server/src/__tests__/agents-registry.test.ts`:

```ts
import { describe, expect, it } from 'vitest';
import type { AgentInfo } from '@pawterm/shared';
import { AgentRegistry } from '../agents/registry.js';
import type { AgentProvider } from '../agents/types.js';

function fakeProvider(kind: 'claude' | 'codex'): AgentProvider {
  const info: AgentInfo = {
    kind,
    label: kind === 'claude' ? 'Claude Code' : 'Codex',
    status: 'ready',
    defaultRuntime: kind === 'claude'
      ? { agent: 'claude', permission_mode: 'acceptEdits' }
      : { agent: 'codex', sandbox: 'workspace-write', approval_policy: 'on-request' },
    capabilities: {
      streaming: true,
      history: true,
      approvals: true,
      modelSwitch: true,
      runtimeSwitch: true,
      rawEvents: true,
    },
  };
  return {
    kind,
    getInfo: async () => info,
    listSessions: async () => [],
    getSessionMessages: async () => ({ messages: [], has_more: false, total: 0 }),
    startTurn: async () => {
      throw new Error('not used in registry tests');
    },
    interrupt: async () => {},
  };
}

describe('AgentRegistry', () => {
  it('returns the default claude provider when agent is omitted', () => {
    const registry = new AgentRegistry([fakeProvider('claude'), fakeProvider('codex')]);
    expect(registry.resolve(undefined).kind).toBe('claude');
  });

  it('returns the requested provider', () => {
    const registry = new AgentRegistry([fakeProvider('claude'), fakeProvider('codex')]);
    expect(registry.resolve('codex').kind).toBe('codex');
  });

  it('throws a 400-shaped error for an unknown provider', () => {
    const registry = new AgentRegistry([fakeProvider('claude')]);
    expect(() => registry.resolve('missing')).toThrow(/Unknown agent: missing/);
  });

  it('lists provider info in registration order', async () => {
    const registry = new AgentRegistry([fakeProvider('claude'), fakeProvider('codex')]);
    await expect(registry.listInfos()).resolves.toEqual([
      expect.objectContaining({ kind: 'claude' }),
      expect.objectContaining({ kind: 'codex' }),
    ]);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
pnpm --filter @cc/server exec vitest run src/__tests__/agents-registry.test.ts
```

Expected: FAIL because `server/src/agents/registry.ts` does not exist.

- [ ] **Step 3: Create provider interface**

Create `server/src/agents/types.ts`:

```ts
import type {
  AgentInfo,
  AgentKind,
  AgentRuntime,
  ChatServerMessage,
  SessionSummary,
} from '@pawterm/shared';

export interface AgentHistoryPage {
  messages: Array<{
    uuid: string | null;
    parent_uuid: string | null;
    timestamp: number | null;
    message: ChatServerMessage | unknown;
  }>;
  has_more: boolean;
  total: number;
}

export interface AgentRun {
  events: AsyncIterable<unknown>;
  pushUserMessage?(text: string): void;
  setRuntime?(runtime: Partial<AgentRuntime>): Promise<void>;
  interrupt(): Promise<void>;
  close(): void;
}

export interface AgentProvider {
  readonly kind: AgentKind;
  getInfo(): Promise<AgentInfo>;
  listSessions(input: {
    cwd: string;
    limit: number;
    offset: number;
    includeSubdirs: boolean;
  }): Promise<SessionSummary[]>;
  getSessionMessages(input: {
    cwd: string;
    sessionId: string;
    limit: number;
    beforeUuid?: string;
  }): Promise<AgentHistoryPage>;
  startTurn(input: {
    cwd: string;
    sessionId: string;
    text: string;
    runtime: AgentRuntime;
    deviceId: string;
  }): Promise<AgentRun>;
  interrupt(input: { sessionId: string }): Promise<void>;
  setRuntime?(input: {
    sessionId: string;
    runtime: Partial<AgentRuntime>;
  }): Promise<void>;
}

export class UnknownAgentError extends Error {
  readonly statusCode = 400;
  constructor(agent: string) {
    super(`Unknown agent: ${agent}`);
  }
}
```

- [ ] **Step 4: Create registry**

Create `server/src/agents/registry.ts`:

```ts
import type { AgentInfo, AgentKind } from '@pawterm/shared';
import type { AgentProvider } from './types.js';
import { UnknownAgentError } from './types.js';

export class AgentRegistry {
  private readonly providers = new Map<AgentKind, AgentProvider>();

  constructor(providers: AgentProvider[]) {
    for (const provider of providers) {
      this.providers.set(provider.kind, provider);
    }
  }

  resolve(agent: string | undefined | null): AgentProvider {
    const key = (agent ?? 'claude') as AgentKind;
    const provider = this.providers.get(key);
    if (!provider) throw new UnknownAgentError(String(agent));
    return provider;
  }

  async listInfos(): Promise<AgentInfo[]> {
    const infos: AgentInfo[] = [];
    for (const provider of this.providers.values()) {
      infos.push(await provider.getInfo());
    }
    return infos;
  }
}
```

- [ ] **Step 5: Run registry test**

Run:

```bash
pnpm --filter @cc/server exec vitest run src/__tests__/agents-registry.test.ts
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add server/src/agents/types.ts server/src/agents/registry.ts server/src/__tests__/agents-registry.test.ts
git commit -m "feat(server): add agent provider registry"
```

---

## Task 3: Move Claude Serialization Behind Claude Provider Boundary

**Files:**
- Create: `server/src/agents/claude/serialize.ts`
- Modify: `server/src/serialize.ts`
- Modify: `server/src/__tests__/serialize.test.ts`
- Test: `server/src/__tests__/serialize.test.ts`

- [ ] **Step 1: Write failing native metadata tests**

Append to `server/src/__tests__/serialize.test.ts`:

```ts
describe('Claude native tool metadata', () => {
  it('keeps Claude tool_use name unchanged and adds raw payload', () => {
    const raw = {
      type: 'assistant',
      message: {
        model: 'claude-sonnet-4-6',
        content: [
          { type: 'tool_use', id: 'toolu_1', name: 'Bash', input: { command: 'pnpm test' } },
        ],
      },
    };
    const wire = messageToWire(raw);
    expect(wire.content[0]).toMatchObject({
      type: 'tool_use',
      id: 'toolu_1',
      name: 'Bash',
      native_type: 'tool_use',
    });
    expect(wire.content[0].raw_payload).toEqual(raw.message.content[0]);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
pnpm --filter @cc/server exec vitest run src/__tests__/serialize.test.ts
```

Expected: FAIL because `native_type` and `raw_payload` are absent.

- [ ] **Step 3: Move serializer file**

Create `server/src/agents/claude/serialize.ts` by moving the full current contents of `server/src/serialize.ts` into it. Keep the exported function name `messageToWire`.

- [ ] **Step 4: Add Claude metadata in `extractContent`**

In `server/src/agents/claude/serialize.ts`, update the `tool_use` and `tool_result` branches:

```ts
case 'tool_use':
  return {
    type: 'tool_use',
    id: String(b.id ?? ''),
    name: String(b.name ?? ''),
    input: typeof b.input === 'object' && b.input !== null ? b.input : {},
    native_type: 'tool_use',
    native_event: undefined,
    raw_payload: safe(b),
  };
case 'tool_result':
  return {
    type: 'tool_result',
    tool_use_id: String(b.tool_use_id ?? ''),
    content: normalizeToolResultContent(b.content),
    is_error: !!b.is_error,
    native_type: 'tool_result',
    native_event: undefined,
    raw_payload: safe(b),
  };
```

- [ ] **Step 5: Add compatibility re-export**

Replace `server/src/serialize.ts` with:

```ts
export { messageToWire } from './agents/claude/serialize.js';
```

- [ ] **Step 6: Run serializer tests**

Run:

```bash
pnpm --filter @cc/server exec vitest run src/__tests__/serialize.test.ts
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add server/src/agents/claude/serialize.ts server/src/serialize.ts server/src/__tests__/serialize.test.ts
git commit -m "feat(server): preserve claude native tool metadata"
```

---

## Task 4: Move Claude Session And History Into Claude Provider

**Files:**
- Create: `server/src/agents/claude/session.ts`
- Create: `server/src/agents/claude/sessions.ts`
- Create: `server/src/agents/claude/provider.ts`
- Modify: `server/src/session-manager.ts`
- Modify: `server/src/sessions-api.ts`
- Test: `server/src/__tests__/serialize.test.ts`, `server/src/__tests__/event-buffer.test.ts`

- [ ] **Step 1: Move `ChatSession` implementation**

Create `server/src/agents/claude/session.ts` by moving the current `ChatSession` implementation from `server/src/session-manager.ts`. Keep imports local:

```ts
import { query, type Options } from '@anthropic-ai/claude-agent-sdk';
import { execSync } from 'node:child_process';
import type { PermissionMode } from '@pawterm/shared';
import { type AskUserQuestionRegistry, makeAskUserMcpServer } from '../../ask-user-tool.js';
```

Do not change runtime behavior in this step.

- [ ] **Step 2: Add compatibility re-export**

Replace `server/src/session-manager.ts` with:

```ts
export { ChatSession } from './agents/claude/session.js';
```

- [ ] **Step 3: Extract Claude session history helpers**

Create `server/src/agents/claude/sessions.ts` and move these functions and related imports from `server/src/sessions-api.ts`:

- `sanitizePathLocal`
- `localProjectsDir`
- `resolveJsonlPath`
- `isSidechainSession`
- `toSummary`
- Claude list logic from the current `/sessions` route
- Claude message pagination logic from the current `/sessions/:id/messages` route
- Claude raw JSONL history logic from the current `/sessions/:id/raw-history` route
- `renameSession`, `tagSession`, `forkSession`, `deleteSession` calls from the current mutation routes

Export a class:

```ts
import {
  deleteSession,
  forkSession,
  getSessionInfo,
  getSessionMessages,
  listSessions,
  renameSession,
  tagSession,
  type SDKSessionInfo,
  type SessionMessage,
} from '@anthropic-ai/claude-agent-sdk';
import type { SessionSummary } from '@pawterm/shared';
import type { AgentHistoryPage } from '../types.js';

export class ClaudeSessions {
  async list(input: {
    cwd: string;
    limit: number;
    offset: number;
    includeSubdirs: boolean;
    holderFor: (sessionId: string) => string | null;
  }): Promise<SessionSummary[]> {
    const all: SDKSessionInfo[] = [];
    const pageSize = 1000;
    for (let off = 0; ; off += pageSize) {
      const page = await listSessions({ dir: input.cwd, limit: pageSize, offset: off });
      all.push(...page);
      if (page.length < pageSize) break;
    }
    const byCwd = all.filter((s) => {
      const sCwd = s.cwd ?? '';
      if (!sCwd) return false;
      if (sCwd === input.cwd) return true;
      return input.includeSubdirs && sCwd.startsWith(`${input.cwd}/`);
    });
    const page = byCwd.slice(input.offset, input.offset + input.limit);
    const result: SDKSessionInfo[] = [];
    for (const s of page) {
      const jsonlPath = await resolveJsonlPath(s.sessionId, s.cwd ?? input.cwd);
      if (jsonlPath && await isSidechainSession(jsonlPath)) continue;
      result.push(s);
    }
    return result.map((s) => ({
      ...toSummary(s, input.holderFor(s.sessionId)),
      agent: 'claude' as const,
    }));
  }

  async messages(input: {
    cwd: string;
    sessionId: string;
    limit: number;
    beforeUuid?: string;
  }): Promise<AgentHistoryPage> {
    const all: SessionMessage[] = await getSessionMessages(input.sessionId, { dir: input.cwd });
    const total = all.length;
    let upper = total;
    if (input.beforeUuid) {
      const idx = all.findIndex((m) => (m as { uuid?: string }).uuid === input.beforeUuid);
      if (idx > 0) upper = idx;
    }
    const lower = Math.max(0, upper - input.limit);
    const slice = all.slice(lower, upper);
    return {
      messages: slice.map((sm) => {
        const rawTs = (sm as { timestamp?: string | number }).timestamp;
        const ts =
          typeof rawTs === 'string' ? Date.parse(rawTs) :
          typeof rawTs === 'number' ? rawTs :
          null;
        const wire = messageToWire(sm);
        return {
          uuid: (sm as { uuid?: string }).uuid ?? null,
          parent_uuid: (sm as { parent_uuid?: string }).parent_uuid ?? null,
          timestamp: ts,
          message: wire ? { ...wire, agent: 'claude' as const, timestamp: ts ?? undefined } : sm,
        };
      }),
      has_more: lower > 0,
      total,
    };
  }

  async rawHistory(input: {
    cwd: string;
    sessionId: string;
    limit: number;
    beforeUuid?: string;
  }): Promise<AgentHistoryPage> {
    return readClaudeRawHistory(input);
  }

  async rename(input: { cwd: string; sessionId: string; title: string }): Promise<void> {
    await renameSession(input.sessionId, input.title, { dir: input.cwd });
  }

  async tag(input: { cwd: string; sessionId: string; tag: string }): Promise<void> {
    await tagSession(input.sessionId, input.tag, { dir: input.cwd });
  }

  async fork(input: { cwd: string; sessionId: string; title?: string }): Promise<{ session_id: string | null }> {
    const result = await forkSession(input.sessionId, {
      dir: input.cwd,
      ...(input.title ? { title: input.title } : {}),
    });
    return { session_id: result.session_id ?? null };
  }

  async delete(input: { cwd: string; sessionId: string }): Promise<void> {
    await deleteSession(input.sessionId, { dir: input.cwd });
  }
}
```

`readClaudeRawHistory(input)` is the moved body of the current raw-history route. Keep the same JSONL filtering rules and return shape, but stamp each converted wire message with `agent: 'claude'`.

```ts
message: wire ? { ...wire, agent: 'claude' as const, timestamp: ts ?? undefined } : entry
```

- [ ] **Step 4: Create Claude provider**

Create `server/src/agents/claude/provider.ts`:

```ts
import type { AgentInfo, AgentRuntime, ClaudeRuntime } from '@pawterm/shared';
import { ChatSession } from './session.js';
import { ClaudeSessions } from './sessions.js';
import type { AgentProvider, AgentRun } from '../types.js';
import { AskUserQuestionRegistry } from '../../ask-user-tool.js';

export class ClaudeAgentProvider implements AgentProvider {
  readonly kind = 'claude' as const;
  readonly sessions = new ClaudeSessions();

  async getInfo(): Promise<AgentInfo> {
    return {
      kind: 'claude',
      label: 'Claude Code',
      status: 'ready',
      defaultRuntime: { agent: 'claude', permission_mode: 'acceptEdits' },
      capabilities: {
        streaming: true,
        history: true,
        approvals: true,
        modelSwitch: true,
        runtimeSwitch: true,
        rawEvents: true,
      },
    };
  }

  listSessions(input: Parameters<AgentProvider['listSessions']>[0]) {
    return this.sessions.list({
      ...input,
      holderFor: () => null,
    });
  }

  getSessionMessages(input: Parameters<AgentProvider['getSessionMessages']>[0]) {
    return this.sessions.messages(input);
  }

  async startTurn(input: Parameters<AgentProvider['startTurn']>[0]): Promise<AgentRun> {
    const runtime = input.runtime as ClaudeRuntime;
    const askRegistry = new AskUserQuestionRegistry();
    const session = new ChatSession({
      cwd: input.cwd,
      permissionMode: runtime.permission_mode,
      sessionId: input.sessionId,
      model: runtime.model,
      askRegistry,
    });
    session.pushUserMessage(input.text);
    return {
      events: session.start(),
      pushUserMessage: (text) => session.pushUserMessage(text),
      setRuntime: async (next: Partial<AgentRuntime>) => {
        if (next.agent && next.agent !== 'claude') return;
        const claudeNext = next as Partial<ClaudeRuntime>;
        if (claudeNext.model) await session.setModel(claudeNext.model);
        if (claudeNext.permission_mode) await session.setPermissionMode(claudeNext.permission_mode);
      },
      interrupt: () => session.interrupt(),
      close: () => session.close(),
    };
  }

  async interrupt(): Promise<void> {
    // chat-rest keeps active runs and calls AgentRun.interrupt().
  }
}
```

This provider is a stepping stone. `chat-rest.ts` will still own active runs until Task 5.

- [ ] **Step 5: Run existing server tests**

Run:

```bash
pnpm --filter @cc/server exec vitest run src/__tests__/serialize.test.ts src/__tests__/event-buffer.test.ts
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add server/src/agents/claude/session.ts server/src/agents/claude/sessions.ts server/src/agents/claude/provider.ts server/src/session-manager.ts server/src/sessions-api.ts
git commit -m "refactor(server): move claude logic behind provider boundary"
```

---

## Task 5: Agent-Aware Sessions API

**Files:**
- Modify: `server/src/sessions-api.ts`
- Modify: `server/src/index.ts`
- Create: `server/src/__tests__/agents-protocol.test.ts`
- Test: `server/src/__tests__/agents-protocol.test.ts`

- [ ] **Step 1: Write runtime/session helper tests**

Create `server/src/__tests__/agents-protocol.test.ts`:

```ts
import { describe, expect, it } from 'vitest';
import { parseAgentQuery, parseClaudeRuntimeFromBody } from '../agents/http-helpers.js';

describe('agent HTTP helpers', () => {
  it('defaults missing agent query to claude', () => {
    expect(parseAgentQuery(undefined)).toBe('claude');
  });

  it('accepts all for session list only', () => {
    expect(parseAgentQuery('all', { allowAll: true })).toBe('all');
  });

  it('rejects all for single-provider routes', () => {
    expect(() => parseAgentQuery('all')).toThrow(/agent=all is not valid/);
  });

  it('builds a claude runtime from old chat body fields', () => {
    expect(parseClaudeRuntimeFromBody({ model: 'claude-sonnet-4-6', permission_mode: 'plan' })).toEqual({
      agent: 'claude',
      model: 'claude-sonnet-4-6',
      permission_mode: 'plan',
    });
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
pnpm --filter @cc/server exec vitest run src/__tests__/agents-protocol.test.ts
```

Expected: FAIL because `agents/http-helpers.ts` does not exist.

- [ ] **Step 3: Create HTTP helper module**

Create `server/src/agents/http-helpers.ts`:

```ts
import type { AgentKind, ClaudeRuntime, PermissionMode } from '@pawterm/shared';

export type AgentQuery = AgentKind | 'all';

const validAgents = new Set(['claude', 'codex', 'gemini']);

export function parseAgentQuery(
  value: string | undefined,
  opts: { allowAll?: boolean } = {},
): AgentQuery {
  if (!value) return 'claude';
  if (value === 'all') {
    if (opts.allowAll) return 'all';
    throw new Error('agent=all is not valid for this route');
  }
  if (validAgents.has(value)) return value as AgentKind;
  throw new Error(`Unknown agent: ${value}`);
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
```

- [ ] **Step 4: Update `registerSessionsApi` signature**

Change `server/src/sessions-api.ts` export to:

```ts
export async function registerSessionsApi(app: FastifyInstance, deps?: {
  registry?: AgentRegistry;
}): Promise<void> {
```

Inside the function, create:

```ts
const registry = deps?.registry ?? defaultAgentRegistry;
```

`defaultAgentRegistry` will be exported from `agents/registry.ts` after Task 6; until then create a local registry with Claude provider.

- [ ] **Step 5: Add `agent` query dispatch to `/sessions`**

Change the `/sessions` route query type:

```ts
Querystring: { cwd: string; limit?: string; offset?: string; include_subdirs?: string; agent?: string };
```

Then dispatch:

```ts
const agent = parseAgentQuery(req.query.agent, { allowAll: true });
if (agent === 'all') {
  const infos = await registry.listInfos();
  const readyAgents = infos.filter((i) => i.status === 'ready').map((i) => i.kind);
  const pages = await Promise.all(
    readyAgents.map((kind) => registry.resolve(kind).listSessions({
      cwd,
      limit,
      offset,
      includeSubdirs,
    })),
  );
  return pages.flat().sort((a, b) => (b.last_modified ?? 0) - (a.last_modified ?? 0));
}
return registry.resolve(agent).listSessions({ cwd, limit, offset, includeSubdirs });
```

- [ ] **Step 6: Add `agent` query dispatch to history routes**

For `/sessions/:id/messages`, parse `agent` with `allowAll: false` and call:

```ts
return registry.resolve(agent).getSessionMessages({
  cwd,
  sessionId: req.params.id,
  limit,
  beforeUuid,
});
```

For `/sessions/:id/raw-history`, reject non-Claude:

```ts
const agent = parseAgentQuery(req.query.agent);
if (agent !== 'claude') {
  reply.code(400);
  return { error: 'raw-history is only available for claude sessions' };
}
```

- [ ] **Step 7: Run helper tests**

Run:

```bash
pnpm --filter @cc/server exec vitest run src/__tests__/agents-protocol.test.ts
```

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add server/src/agents/http-helpers.ts server/src/sessions-api.ts server/src/index.ts server/src/__tests__/agents-protocol.test.ts
git commit -m "feat(server): dispatch sessions by agent"
```

---

## Task 6: Agent-Aware Chat Runtime Dispatch

**Files:**
- Modify: `server/src/chat-rest.ts`
- Modify: `server/src/index.ts`
- Create: `server/src/__tests__/chat-agent-runtime.test.ts`
- Test: `server/src/__tests__/chat-agent-runtime.test.ts`

- [ ] **Step 1: Write failing chat runtime tests**

Create `server/src/__tests__/chat-agent-runtime.test.ts`:

```ts
import { describe, expect, it } from 'vitest';
import { parseRuntimeFromChatBody } from '../agents/http-helpers.js';

describe('parseRuntimeFromChatBody', () => {
  it('keeps old claude body compatibility', () => {
    expect(parseRuntimeFromChatBody({
      model: 'claude-sonnet-4-6',
      permission_mode: 'acceptEdits',
    })).toEqual({
      agent: 'claude',
      model: 'claude-sonnet-4-6',
      permission_mode: 'acceptEdits',
    });
  });

  it('accepts explicit codex runtime', () => {
    expect(parseRuntimeFromChatBody({
      agent: 'codex',
      runtime: {
        agent: 'codex',
        model: 'gpt-5.4',
        sandbox: 'workspace-write',
        approval_policy: 'on-request',
      },
    })).toEqual({
      agent: 'codex',
      model: 'gpt-5.4',
      sandbox: 'workspace-write',
      approval_policy: 'on-request',
    });
  });

  it('rejects runtime agent mismatch', () => {
    expect(() => parseRuntimeFromChatBody({
      agent: 'codex',
      runtime: { agent: 'claude', permission_mode: 'acceptEdits' },
    })).toThrow(/runtime agent mismatch/);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
pnpm --filter @cc/server exec vitest run src/__tests__/chat-agent-runtime.test.ts
```

Expected: FAIL because `parseRuntimeFromChatBody` is absent.

- [ ] **Step 3: Add runtime parser**

In `server/src/agents/http-helpers.ts`, add:

```ts
import type { AgentRuntime } from '@pawterm/shared';

export function parseRuntimeFromChatBody(body: {
  agent?: string;
  runtime?: AgentRuntime;
  model?: string;
  permission_mode?: PermissionMode;
}): AgentRuntime {
  const agent = parseAgentQuery(body.agent);
  if (body.runtime) {
    if (body.runtime.agent !== agent) {
      throw new Error(`runtime agent mismatch: route=${agent} runtime=${body.runtime.agent}`);
    }
    return body.runtime;
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
```

- [ ] **Step 4: Update `chat-rest.ts` active run key**

Change active run key from bare uuid to an Agent-scoped key:

```ts
function runKey(agent: string, uuid: string): string {
  return `${agent}:${uuid}`;
}
```

Use `const key = runKey(runtime.agent, uuid)` for all `activeRuns` lookups. Keep API body field `uuid` unchanged.

- [ ] **Step 5: Attach Agent metadata to broadcasts**

In `consumeSdk`, accept `agent`:

```ts
async function consumeSdk(agent: AgentKind, uuid: string, entry: RunEntry, log: FastifyInstance['log']): Promise<void>
```

When stamping wire:

```ts
const stamped = {
  ...wire,
  agent,
  session_ref: { agent, id: uuid },
  timestamp: Date.now(),
  uuid: (sdkMsg as any).uuid ?? null,
};
```

For this task, `consumeSdk` still handles Claude SDK messages only.

- [ ] **Step 6: Parse runtime in `/chat/stream`**

In `POST /chat/stream`, replace `const permissionMode = body.permission_mode;` with:

```ts
let runtime: AgentRuntime;
try {
  runtime = parseRuntimeFromChatBody(body);
} catch (err) {
  reply.code(400);
  return { error: (err as Error).message };
}
if (runtime.agent !== 'claude') {
  reply.code(501);
  return { error: `${runtime.agent} chat provider is not wired yet` };
}
```

Then create `ChatSession` using Claude runtime:

```ts
const claudeRuntime = runtime as ClaudeRuntime;
const session = new ChatSession({
  cwd,
  permissionMode: claudeRuntime.permission_mode,
  ...(sessionInfo ? { resume: uuid } : { sessionId: uuid }),
  model: claudeRuntime.model,
  askRegistry,
});
```

- [ ] **Step 7: Add `/chat/runtime` compatibility endpoint**

Add this route:

```ts
app.post<{ Body: { uuid?: string; agent?: AgentKind; runtime?: Partial<AgentRuntime> } }>(
  '/chat/runtime',
  async (req, reply) => {
    const uuid = req.body?.uuid;
    const agent = req.body?.agent ?? 'claude';
    if (!uuid) { reply.code(400); return { error: 'uuid required' }; }
    const entry = activeRuns.get(runKey(agent, uuid));
    if (!entry) { reply.code(404); return { error: 'no active run' }; }
    const runtime = req.body.runtime;
    if (!runtime) { reply.code(400); return { error: 'runtime required' }; }
    if ('model' in runtime && runtime.model) await entry.session.setModel(runtime.model);
    if ('permission_mode' in runtime && runtime.permission_mode) {
      await entry.session.setPermissionMode(runtime.permission_mode as PermissionMode);
    }
    return { ok: true };
  },
);
```

Keep `/chat/model` and `/chat/permission` as Claude compatibility wrappers.

- [ ] **Step 8: Run tests**

Run:

```bash
pnpm --filter @cc/server exec vitest run src/__tests__/chat-agent-runtime.test.ts src/__tests__/agents-protocol.test.ts
```

Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add server/src/chat-rest.ts server/src/agents/http-helpers.ts server/src/__tests__/chat-agent-runtime.test.ts
git commit -m "feat(server): make chat runtime agent-aware"
```

---

## Task 7: `/agents` Endpoint And Default Registry

**Files:**
- Modify: `server/src/agents/registry.ts`
- Create: `server/src/agents/codex/provider.ts`
- Modify: `server/src/index.ts`
- Test: `pnpm --filter @cc/server run typecheck`

- [ ] **Step 1: Add disabled Codex provider shell**

Create `server/src/agents/codex/provider.ts`:

```ts
import type { AgentInfo } from '@pawterm/shared';
import type { AgentProvider } from '../types.js';

export class CodexAgentProvider implements AgentProvider {
  readonly kind = 'codex' as const;

  async getInfo(): Promise<AgentInfo> {
    return {
      kind: 'codex',
      label: 'Codex',
      status: 'disabled',
      statusMessage: 'Codex provider is not connected yet',
      defaultRuntime: {
        agent: 'codex',
        sandbox: 'workspace-write',
        approval_policy: 'on-request',
      },
      capabilities: {
        streaming: true,
        history: true,
        approvals: true,
        modelSwitch: true,
        runtimeSwitch: true,
        rawEvents: true,
      },
    };
  }

  async listSessions() { return []; }
  async getSessionMessages() { return { messages: [], has_more: false, total: 0 }; }
  async startTurn(): Promise<never> { throw new Error('Codex provider is disabled'); }
  async interrupt(): Promise<void> {}
}
```

- [ ] **Step 2: Export default registry**

Update `server/src/agents/registry.ts`:

```ts
import { ClaudeAgentProvider } from './claude/provider.js';
import { CodexAgentProvider } from './codex/provider.js';

export const defaultAgentRegistry = new AgentRegistry([
  new ClaudeAgentProvider(),
  new CodexAgentProvider(),
]);
```

- [ ] **Step 3: Add `/agents` route**

In `server/src/index.ts`, import:

```ts
import type { AgentsResponse } from '@pawterm/shared';
import { defaultAgentRegistry } from './agents/registry.js';
```

Then add before `/models`:

```ts
app.get('/agents', async (): Promise<AgentsResponse> => ({
  agents: await defaultAgentRegistry.listInfos(),
}));
```

- [ ] **Step 4: Wire registry into sessions**

Change:

```ts
await registerSessionsApi(app);
```

to:

```ts
await registerSessionsApi(app, { registry: defaultAgentRegistry });
```

- [ ] **Step 5: Run typecheck**

Run:

```bash
pnpm --filter @cc/server run typecheck
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add server/src/agents/registry.ts server/src/agents/codex/provider.ts server/src/index.ts
git commit -m "feat(server): expose agent registry"
```

---

## Task 8: Codex Serialization With Native Names

**Files:**
- Create: `server/src/agents/codex/serialize.ts`
- Create: `server/src/__tests__/codex-serialize.test.ts`
- Test: `server/src/__tests__/codex-serialize.test.ts`

- [ ] **Step 1: Write failing Codex serializer tests**

Create `server/src/__tests__/codex-serialize.test.ts`:

```ts
import { describe, expect, it } from 'vitest';
import { codexThreadItemToWire } from '../agents/codex/serialize.js';

describe('codexThreadItemToWire', () => {
  it('keeps commandExecution as the native tool name', () => {
    const item = {
      type: 'commandExecution',
      id: 'cmd_1',
      command: 'pnpm test',
      cwd: '/repo',
      status: 'completed',
      aggregatedOutput: 'ok',
      exitCode: 0,
      durationMs: 120,
    };
    const wire = codexThreadItemToWire(item);
    expect(wire).toEqual({
      type: 'assistant',
      content: [
        {
          type: 'tool_use',
          id: 'cmd_1',
          name: 'commandExecution',
          input: { command: 'pnpm test', cwd: '/repo' },
          native_type: 'commandExecution',
          native_event: undefined,
          raw_payload: item,
        },
        {
          type: 'tool_result',
          tool_use_id: 'cmd_1',
          content: 'ok',
          is_error: false,
          native_type: 'commandExecution',
          native_event: undefined,
          raw_payload: item,
        },
      ],
    });
  });

  it('keeps fileChange as the native tool name', () => {
    const item = {
      type: 'fileChange',
      id: 'file_1',
      changes: [{ path: '/repo/a.ts', kind: 'update' }],
      status: 'applied',
    };
    const wire = codexThreadItemToWire(item);
    expect(wire?.content[0]).toMatchObject({
      type: 'tool_use',
      id: 'file_1',
      name: 'fileChange',
      native_type: 'fileChange',
    });
  });

  it('converts agentMessage to assistant text', () => {
    const wire = codexThreadItemToWire({
      type: 'agentMessage',
      id: 'msg_1',
      text: 'hello',
      phase: null,
      memoryCitation: null,
    });
    expect(wire).toEqual({
      type: 'assistant',
      content: [{ type: 'text', text: 'hello' }],
    });
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
pnpm --filter @cc/server exec vitest run src/__tests__/codex-serialize.test.ts
```

Expected: FAIL because serializer does not exist.

- [ ] **Step 3: Implement Codex serializer**

Create `server/src/agents/codex/serialize.ts`:

```ts
import type { ChatServerMessage, ContentBlock } from '@pawterm/shared';

type CodexItem = Record<string, any> & { type?: string; id?: string };

function safeInput(value: unknown): Record<string, unknown> {
  return value && typeof value === 'object' && !Array.isArray(value)
    ? value as Record<string, unknown>
    : {};
}

function toolUse(item: CodexItem, input: Record<string, unknown>): ContentBlock {
  const native = String(item.type ?? 'unknown');
  return {
    type: 'tool_use',
    id: String(item.id ?? native),
    name: native,
    input,
    native_type: native,
    native_event: undefined,
    raw_payload: item,
  };
}

function toolResult(item: CodexItem, content: unknown, isError = false): ContentBlock {
  const native = String(item.type ?? 'unknown');
  return {
    type: 'tool_result',
    tool_use_id: String(item.id ?? native),
    content: content == null ? null : String(content),
    is_error: isError,
    native_type: native,
    native_event: undefined,
    raw_payload: item,
  };
}

export function codexThreadItemToWire(item: CodexItem): ChatServerMessage | null {
  switch (item.type) {
    case 'userMessage':
      return {
        type: 'user',
        content: Array.isArray(item.content)
          ? item.content.map((c: any) => ({ type: 'text', text: String(c.text ?? c.content ?? '') }))
          : [],
      };
    case 'agentMessage':
      return { type: 'assistant', content: [{ type: 'text', text: String(item.text ?? '') }] };
    case 'reasoning':
      return {
        type: 'assistant',
        content: [{
          type: 'thinking',
          text: [...(item.summary ?? []), ...(item.content ?? [])].map(String).join('\n'),
        }],
      };
    case 'plan':
      return {
        type: 'assistant',
        content: [toolUse(item, { text: String(item.text ?? '') })],
      };
    case 'commandExecution':
      return {
        type: 'assistant',
        content: [
          toolUse(item, { command: item.command ?? '', cwd: item.cwd ?? '' }),
          toolResult(item, item.aggregatedOutput ?? '', item.exitCode != null && item.exitCode !== 0),
        ],
      };
    case 'fileChange':
      return {
        type: 'assistant',
        content: [
          toolUse(item, { changes: item.changes ?? [], status: item.status ?? null }),
          toolResult(item, JSON.stringify({ changes: item.changes ?? [], status: item.status ?? null }, null, 2), false),
        ],
      };
    case 'mcpToolCall':
      return {
        type: 'assistant',
        content: [
          toolUse(item, safeInput({ server: item.server, tool: item.tool, arguments: item.arguments })),
          toolResult(item, item.error ? JSON.stringify(item.error, null, 2) : JSON.stringify(item.result ?? null, null, 2), !!item.error),
        ],
      };
    case 'dynamicToolCall':
      return {
        type: 'assistant',
        content: [
          toolUse(item, safeInput({ namespace: item.namespace, tool: item.tool, arguments: item.arguments })),
          toolResult(item, JSON.stringify(item.contentItems ?? null, null, 2), item.success === false),
        ],
      };
    default:
      return null;
  }
}
```

- [ ] **Step 4: Run Codex serializer tests**

Run:

```bash
pnpm --filter @cc/server exec vitest run src/__tests__/codex-serialize.test.ts
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add server/src/agents/codex/serialize.ts server/src/__tests__/codex-serialize.test.ts
git commit -m "feat(server): serialize codex native events"
```

---

## Task 9: Codex App-Server JSON-RPC Client

**Files:**
- Create: `server/src/agents/codex/client.ts`
- Create: `server/src/__tests__/codex-client.test.ts`
- Test: `server/src/__tests__/codex-client.test.ts`

- [ ] **Step 1: Write JSON-RPC client tests**

Create `server/src/__tests__/codex-client.test.ts`:

```ts
import { PassThrough } from 'node:stream';
import { describe, expect, it } from 'vitest';
import { CodexJsonRpcClient } from '../agents/codex/client.js';

describe('CodexJsonRpcClient', () => {
  it('resolves responses by id', async () => {
    const input = new PassThrough();
    const output = new PassThrough();
    const client = new CodexJsonRpcClient({ input, output });
    const promise = client.request('thread/list', { limit: 1 });
    const written = output.read()?.toString() ?? '';
    const request = JSON.parse(written.trim());
    input.write(`${JSON.stringify({ id: request.id, result: { data: [], nextCursor: null, backwardsCursor: null } })}\n`);
    await expect(promise).resolves.toEqual({ data: [], nextCursor: null, backwardsCursor: null });
  });

  it('emits notifications without resolving a request', async () => {
    const input = new PassThrough();
    const output = new PassThrough();
    const client = new CodexJsonRpcClient({ input, output });
    const notifications: unknown[] = [];
    client.onNotification((n) => notifications.push(n));
    input.write(`${JSON.stringify({ method: 'item/agentMessage/delta', params: { delta: 'a' } })}\n`);
    expect(notifications).toEqual([{ method: 'item/agentMessage/delta', params: { delta: 'a' } }]);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
pnpm --filter @cc/server exec vitest run src/__tests__/codex-client.test.ts
```

Expected: FAIL because client does not exist.

- [ ] **Step 3: Implement JSON-RPC client**

Create `server/src/agents/codex/client.ts`:

```ts
import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';
import { createInterface } from 'node:readline';
import type { Readable, Writable } from 'node:stream';

type NotificationHandler = (notification: { method: string; params?: unknown }) => void;

export class CodexJsonRpcClient {
  private nextId = 1;
  private readonly pending = new Map<number, { resolve: (v: unknown) => void; reject: (e: Error) => void }>();
  private readonly notificationHandlers = new Set<NotificationHandler>();

  constructor(private readonly io: { input: Readable; output: Writable }) {
    const rl = createInterface({ input: io.input });
    rl.on('line', (line) => this.handleLine(line));
  }

  request(method: string, params: unknown): Promise<unknown> {
    const id = this.nextId++;
    const payload = { jsonrpc: '2.0', id, method, params };
    this.io.output.write(`${JSON.stringify(payload)}\n`);
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
    });
  }

  onNotification(handler: NotificationHandler): () => void {
    this.notificationHandlers.add(handler);
    return () => this.notificationHandlers.delete(handler);
  }

  private handleLine(line: string): void {
    if (!line.trim()) return;
    const msg = JSON.parse(line);
    if (typeof msg.id === 'number') {
      const pending = this.pending.get(msg.id);
      if (!pending) return;
      this.pending.delete(msg.id);
      if (msg.error) pending.reject(new Error(JSON.stringify(msg.error)));
      else pending.resolve(msg.result);
      return;
    }
    if (msg.method) {
      for (const handler of this.notificationHandlers) handler(msg);
    }
  }
}

export class CodexAppServerProcess {
  private child?: ChildProcessWithoutNullStreams;
  private client?: CodexJsonRpcClient;

  start(): CodexJsonRpcClient {
    if (this.client) return this.client;
    this.child = spawn('codex', ['app-server', '--listen', 'stdio://'], {
      stdio: ['pipe', 'pipe', 'pipe'],
      env: process.env,
    });
    this.child.stderr.on('data', () => {});
    this.client = new CodexJsonRpcClient({
      input: this.child.stdout,
      output: this.child.stdin,
    });
    return this.client;
  }

  stop(): void {
    this.child?.kill('SIGTERM');
    this.child = undefined;
    this.client = undefined;
  }
}
```

- [ ] **Step 4: Run client tests**

Run:

```bash
pnpm --filter @cc/server exec vitest run src/__tests__/codex-client.test.ts
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add server/src/agents/codex/client.ts server/src/__tests__/codex-client.test.ts
git commit -m "feat(server): add codex app-server client"
```

---

## Task 10: Codex Provider Sessions And Turns

**Files:**
- Modify: `server/src/agents/codex/provider.ts`
- Modify: `server/src/chat-rest.ts`
- Test: `pnpm --filter @cc/server run typecheck`

- [ ] **Step 1: Implement Codex provider list/history**

Replace `server/src/agents/codex/provider.ts` with:

```ts
import type { AgentInfo, AgentRuntime, CodexRuntime, SessionSummary } from '@pawterm/shared';
import { CodexAppServerProcess, type CodexJsonRpcClient } from './client.js';
import { codexThreadItemToWire } from './serialize.js';
import type { AgentHistoryPage, AgentProvider, AgentRun } from '../types.js';

export class CodexAgentProvider implements AgentProvider {
  readonly kind = 'codex' as const;
  private readonly appServer = new CodexAppServerProcess();

  private client(): CodexJsonRpcClient {
    return this.appServer.start();
  }

  async getInfo(): Promise<AgentInfo> {
    return {
      kind: 'codex',
      label: 'Codex',
      status: 'ready',
      defaultRuntime: {
        agent: 'codex',
        sandbox: 'workspace-write',
        approval_policy: 'on-request',
      },
      capabilities: {
        streaming: true,
        history: true,
        approvals: true,
        modelSwitch: true,
        runtimeSwitch: true,
        rawEvents: true,
      },
    };
  }

  async listSessions(input: {
    cwd: string;
    limit: number;
    offset: number;
    includeSubdirs: boolean;
  }): Promise<SessionSummary[]> {
    const result = await this.client().request('thread/list', {
      limit: input.limit,
      cursor: input.offset > 0 ? String(input.offset) : null,
      cwd: input.cwd,
    }) as { data?: any[] };
    return (result.data ?? [])
      .filter((thread) => input.includeSubdirs || thread.cwd === input.cwd)
      .map((thread): SessionSummary => ({
        session_id: String(thread.id),
        agent: 'codex',
        summary: thread.preview ?? null,
        title: thread.name ?? null,
        tags: [],
        last_modified: typeof thread.updatedAt === 'number' ? thread.updatedAt * 1000 : null,
        cwd: thread.cwd ?? null,
        num_messages: null,
        total_cost_usd: null,
        holder_device_id: thread.status === 'running' ? 'server' : null,
      }));
  }

  async getSessionMessages(input: {
    cwd: string;
    sessionId: string;
    limit: number;
    beforeUuid?: string;
  }): Promise<AgentHistoryPage> {
    const result = await this.client().request('thread/turns/items/list', {
      threadId: input.sessionId,
      limit: input.limit,
      cursor: input.beforeUuid ?? null,
    }) as { data?: any[]; nextCursor?: string | null };
    const data = result.data ?? [];
    return {
      messages: data.map((item) => ({
        uuid: item.id ?? null,
        parent_uuid: null,
        timestamp: null,
        message: codexThreadItemToWire(item) ?? item,
      })),
      has_more: !!result.nextCursor,
      total: data.length,
    };
  }

  async startTurn(input: {
    cwd: string;
    sessionId: string;
    text: string;
    runtime: AgentRuntime;
    deviceId: string;
  }): Promise<AgentRun> {
    const runtime = input.runtime as CodexRuntime;
    const client = this.client();
    const thread = input.sessionId
      ? await client.request('thread/resume', {
          threadId: input.sessionId,
          cwd: input.cwd,
          model: runtime.model ?? null,
          persistExtendedHistory: false,
        }) as { thread?: { id: string } }
      : await client.request('thread/start', {
          cwd: input.cwd,
          model: runtime.model ?? null,
          sandbox: runtime.sandbox,
          approvalPolicy: runtime.approval_policy,
          experimentalRawEvents: false,
          persistExtendedHistory: false,
        }) as { thread?: { id: string } };
    const threadId = thread.thread?.id ?? input.sessionId;
    await client.request('turn/start', {
      threadId,
      input: [{ type: 'text', text: input.text }],
      model: runtime.model ?? null,
    });
    const events = this.notificationIterable(client, threadId);
    return {
      events,
      interrupt: async () => { await client.request('turn/interrupt', { threadId }); },
      close: () => {},
    };
  }

  async interrupt(input: { sessionId: string }): Promise<void> {
    await this.client().request('turn/interrupt', { threadId: input.sessionId });
  }

  private async *notificationIterable(client: CodexJsonRpcClient, threadId: string): AsyncIterable<unknown> {
    const queue: unknown[] = [];
    let wake: (() => void) | null = null;
    const off = client.onNotification((notification) => {
      const params = notification.params as { threadId?: string; item?: unknown; turn?: { items?: unknown[] } } | undefined;
      if (params?.threadId && params.threadId !== threadId) return;
      queue.push(notification);
      wake?.();
      wake = null;
    });
    try {
      while (true) {
        if (queue.length > 0) {
          yield queue.shift();
          continue;
        }
        await new Promise<void>((resolve) => { wake = resolve; });
      }
    } finally {
      off();
    }
  }
}
```

- [ ] **Step 2: Update `chat-rest.ts` to accept Codex run events**

In `consumeSdk`, rename to `consumeRun` and change the conversion:

```ts
function runMessageToWire(agent: AgentKind, msg: unknown): ReturnType<typeof messageToWire> {
  if (agent === 'claude') return messageToWire(msg);
  if (agent === 'codex') {
    const notification = msg as { method?: string; params?: any };
    const item = notification.params?.item ?? notification.params?.turn?.items?.at?.(-1);
    const wire = item ? codexThreadItemToWire(item) : null;
    return wire ? { ...wire, native_event: notification.method, raw_payload: notification } : null;
  }
  return null;
}
```

For Task 10, keep Claude path working and let Codex path emit item-level events.

- [ ] **Step 3: Remove 501 guard for Codex**

In `/chat/stream`, replace the Task 6 `runtime.agent !== 'claude'` 501 block with provider dispatch:

```ts
const provider = defaultAgentRegistry.resolve(runtime.agent);
```

For Claude, keep existing `ChatSession` path until full active run unification is complete. For Codex, call:

```ts
const run = await provider.startTurn({
  cwd,
  sessionId: uuid,
  text: body.text,
  runtime,
  deviceId,
});
```

Store `run` in `RunEntry` by adding `run?: AgentRun` to the interface. For Codex, `entry.session` can be omitted only after `RunEntry` is changed to:

```ts
interface RunEntry {
  session?: ChatSession;
  run?: AgentRun;
  buffer: EventBuffer;
  askRegistry: AskUserQuestionRegistry;
  graceTimer?: NodeJS.Timeout;
  writers: Set<{ write: (s: string) => void; end: () => void }>;
  resultReceived: boolean;
  holderDeviceId: string;
}
```

Then use `entry.run?.interrupt()` and `entry.run?.close()` where applicable.

- [ ] **Step 4: Run server typecheck**

Run:

```bash
pnpm --filter @cc/server run typecheck
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add server/src/agents/codex/provider.ts server/src/chat-rest.ts
git commit -m "feat(server): wire codex provider turns"
```

---

## Task 11: Flutter Agent API And State

**Files:**
- Create: `app/lib/api/agents_api.dart`
- Create: `app/lib/state/agents_store.dart`
- Modify: `app/lib/api/sessions_api.dart`
- Modify: `app/lib/state/projects_store.dart`
- Verify: `cd app && flutter analyze`

- [ ] **Step 1: Add Agent API models**

Create `app/lib/api/agents_api.dart`:

```dart
import 'dart:convert';

import 'package:http/http.dart' as http;

enum AgentKind {
  claude,
  codex,
  gemini;

  String get wire => name;

  static AgentKind fromWire(String? value) => switch (value) {
        'codex' => AgentKind.codex,
        'gemini' => AgentKind.gemini,
        _ => AgentKind.claude,
      };
}

class AgentCapabilities {
  final bool streaming;
  final bool history;
  final bool approvals;
  final bool modelSwitch;
  final bool runtimeSwitch;
  final bool rawEvents;

  const AgentCapabilities({
    required this.streaming,
    required this.history,
    required this.approvals,
    required this.modelSwitch,
    required this.runtimeSwitch,
    required this.rawEvents,
  });

  factory AgentCapabilities.fromJson(Map<String, dynamic> json) => AgentCapabilities(
        streaming: json['streaming'] as bool? ?? false,
        history: json['history'] as bool? ?? false,
        approvals: json['approvals'] as bool? ?? false,
        modelSwitch: json['modelSwitch'] as bool? ?? false,
        runtimeSwitch: json['runtimeSwitch'] as bool? ?? false,
        rawEvents: json['rawEvents'] as bool? ?? false,
      );
}

class AgentInfo {
  final AgentKind kind;
  final String label;
  final String status;
  final String? statusMessage;
  final Map<String, dynamic> defaultRuntime;
  final AgentCapabilities capabilities;

  const AgentInfo({
    required this.kind,
    required this.label,
    required this.status,
    this.statusMessage,
    required this.defaultRuntime,
    required this.capabilities,
  });

  factory AgentInfo.fromJson(Map<String, dynamic> json) => AgentInfo(
        kind: AgentKind.fromWire(json['kind'] as String?),
        label: json['label'] as String? ?? 'Agent',
        status: json['status'] as String? ?? 'disabled',
        statusMessage: json['statusMessage'] as String?,
        defaultRuntime: Map<String, dynamic>.from(json['defaultRuntime'] ?? {}),
        capabilities: AgentCapabilities.fromJson(Map<String, dynamic>.from(json['capabilities'] ?? {})),
      );
}

class AgentsApi {
  final String baseUrl;
  final String? token;
  AgentsApi(this.baseUrl, {this.token});

  Map<String, String> get _auth =>
      token != null ? {'Authorization': 'Bearer $token'} : const {};

  Future<List<AgentInfo>> list() async {
    final resp = await http.get(Uri.parse('$baseUrl/agents'), headers: _auth);
    if (resp.statusCode != 200) {
      throw Exception('agents HTTP ${resp.statusCode}: ${resp.body}');
    }
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    final list = (body['agents'] as List? ?? const []);
    return list.map((e) => AgentInfo.fromJson(Map<String, dynamic>.from(e))).toList();
  }
}
```

- [ ] **Step 2: Add Agent store**

Create `app/lib/state/agents_store.dart`:

```dart
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/agents_api.dart';
import 'server_config.dart';

final agentsProvider = FutureProvider<List<AgentInfo>>((ref) async {
  final conn = ref.watch(activeConnectionProvider);
  if (conn == null) return [];
  return AgentsApi(conn.httpBase, token: conn.token).list();
});

final projectDefaultAgentProvider =
    StateNotifierProvider<ProjectDefaultAgentNotifier, Map<String, AgentKind>>(
  (ref) => ProjectDefaultAgentNotifier(),
);

class ProjectDefaultAgentNotifier extends StateNotifier<Map<String, AgentKind>> {
  ProjectDefaultAgentNotifier() : super(const {}) {
    _load();
  }

  static const _key = 'project_default_agents_v1';

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return;
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    state = decoded.map((k, v) => MapEntry(k, AgentKind.fromWire(v as String?)));
  }

  Future<void> setDefault(String cwd, AgentKind agent) async {
    state = {...state, cwd: agent};
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(state.map((k, v) => MapEntry(k, v.wire))));
  }

  AgentKind forProject(String cwd) => state[cwd] ?? AgentKind.claude;
}
```

- [ ] **Step 3: Extend `SessionSummary`**

In `app/lib/api/sessions_api.dart`, import `agents_api.dart` and add:

```dart
final AgentKind agent;
```

to constructor and `fromJson`:

```dart
agent: AgentKind.fromWire(json['agent'] as String?),
```

Update `displayTitle` fallback to Chinese:

```dart
String get displayTitle => title ?? summary ?? '(未命名)';
```

- [ ] **Step 4: Add session list agent filter**

Change `SessionsApi.list` signature:

```dart
Future<List<SessionSummary>> list(String cwd, {int limit = 50, String agent = 'all'}) async {
```

and include `'agent': agent` in query.

- [ ] **Step 5: Extend `CurrentSession`**

In `app/lib/state/projects_store.dart`, import `agents_api.dart` and add fields:

```dart
final AgentKind agent;
final Map<String, dynamic> runtime;
```

Constructor:

```dart
this.agent = AgentKind.claude,
this.runtime = const {'agent': 'claude', 'permission_mode': 'acceptEdits'},
```

`copyWith` adds:

```dart
AgentKind? agent,
Map<String, dynamic>? runtime,
```

and passes them through.

- [ ] **Step 6: Run analyzer**

Run:

```bash
cd app && flutter analyze
```

Expected: PASS or only pre-existing warnings unrelated to these files. Any new error in changed files must be fixed before commit.

- [ ] **Step 7: Commit**

```bash
git add app/lib/api/agents_api.dart app/lib/state/agents_store.dart app/lib/api/sessions_api.dart app/lib/state/projects_store.dart
git commit -m "feat(app): add agent api and state"
```

---

## Task 12: Flutter Project Agent Picker UI

**Files:**
- Create: `app/lib/widgets/agent_badge.dart`
- Create: `app/lib/widgets/agent_picker_sheet.dart`
- Modify: `app/lib/screens/project_picker_screen.dart`
- Test: `cd app && flutter analyze`

- [ ] **Step 1: Create Agent badge**

Create `app/lib/widgets/agent_badge.dart`:

```dart
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
```

- [ ] **Step 2: Create Agent picker sheet**

Create `app/lib/widgets/agent_picker_sheet.dart`:

```dart
import 'package:flutter/material.dart';

import '../api/agents_api.dart';
import '../theme.dart';
import 'agent_badge.dart';

class AgentPickerSheet extends StatelessWidget {
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
            Text('选择 Agent', style: TextStyle(color: t.text, fontSize: 17, fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            for (final agent in agents)
              _AgentOption(
                info: agent,
                selected: agent.kind == selected,
                onTap: agent.status == 'ready' ? () => onSelected(agent.kind) : null,
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

  const _AgentOption({required this.info, required this.selected, required this.onTap});

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
                    Text(info.label, style: TextStyle(color: t.text, fontWeight: FontWeight.w700, fontSize: 14)),
                    const SizedBox(height: 4),
                    Text(info.statusMessage ?? desc, style: TextStyle(color: t.textMuted, fontSize: 12, height: 1.35)),
                  ],
                ),
              ),
              if (selected) Icon(Icons.check_rounded, size: 18, color: t.accent),
            ],
          ),
        ),
      ),
    );
  }
}
```

- [ ] **Step 3: Add project page current Agent card**

In `app/lib/screens/project_picker_screen.dart`, import:

```dart
import '../api/agents_api.dart';
import '../state/agents_store.dart';
import '../widgets/agent_badge.dart';
import '../widgets/agent_picker_sheet.dart';
```

Inside the expanded project tile UI, add an Agent card above session rows. Use existing `_expanded` project path to determine visibility:

```dart
final defaultAgent = ref.watch(projectDefaultAgentProvider)[project.path] ?? AgentKind.claude;
```

Card tap:

```dart
void _showAgentPicker(BuildContext context, Project project) {
  final agentsAsync = ref.read(agentsProvider);
  agentsAsync.whenData((agents) {
    final selected = ref.read(projectDefaultAgentProvider.notifier).forProject(project.path);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => AgentPickerSheet(
        agents: agents.isEmpty
            ? [
                AgentInfo(
                  kind: AgentKind.claude,
                  label: 'Claude Code',
                  status: 'ready',
                  defaultRuntime: const {'agent': 'claude', 'permission_mode': 'acceptEdits'},
                  capabilities: const AgentCapabilities(
                    streaming: true,
                    history: true,
                    approvals: true,
                    modelSwitch: true,
                    runtimeSwitch: true,
                    rawEvents: true,
                  ),
                ),
              ]
            : agents,
        selected: selected,
        onSelected: (agent) async {
          await ref.read(projectDefaultAgentProvider.notifier).setDefault(project.path, agent);
          if (context.mounted) Navigator.of(context).pop();
          ref.invalidate(sessionsProvider(project.path));
        },
      ),
    );
  });
}
```

- [ ] **Step 4: Add session filter UI**

Add local state in `_ProjectPickerScreenState`:

```dart
final Map<String, AgentKind?> _agentFilters = {};
```

When loading sessions, pass selected filter to the provider in Task 13. Until Task 13, keep list unfiltered and only render segmented buttons.

- [ ] **Step 5: Run analyzer**

Run:

```bash
cd app && flutter analyze
```

Expected: PASS or only pre-existing warnings unrelated to changed files.

- [ ] **Step 6: Commit**

```bash
git add app/lib/widgets/agent_badge.dart app/lib/widgets/agent_picker_sheet.dart app/lib/screens/project_picker_screen.dart
git commit -m "feat(app): add project agent picker"
```

---

## Task 13: Flutter Chat Agent Runtime And Native Tool Names

**Files:**
- Create: `app/lib/screens/tabs/chat_agent_bar.dart`
- Modify: `app/lib/api/chat_api.dart`
- Modify: `app/lib/api/protocol.dart`
- Modify: `app/lib/screens/tabs/chat_tab.dart`
- Modify: `app/lib/widgets/tool_call_card.dart`
- Test: `cd app && flutter analyze`

- [ ] **Step 1: Extend content blocks with raw metadata**

In `app/lib/api/protocol.dart`, update `ToolUseBlock`:

```dart
final String? nativeType;
final String? nativeEvent;
final Map<String, dynamic>? rawPayload;
```

Constructor and parser:

```dart
nativeType: json['native_type'] as String?,
nativeEvent: json['native_event'] as String?,
rawPayload: json['raw_payload'] is Map ? Map<String, dynamic>.from(json['raw_payload']) : null,
```

Do the same for `ToolResultBlock`.

- [ ] **Step 2: Update Chat API stream body**

In `app/lib/api/chat_api.dart`, import `agents_api.dart` and add parameters to `stream`:

```dart
AgentKind agent = AgentKind.claude,
Map<String, dynamic>? runtime,
```

Add to JSON body:

```dart
'agent': agent.wire,
if (runtime != null) 'runtime': runtime,
```

Add:

```dart
Future<void> runtime(String uuid, AgentKind agent, Map<String, dynamic> runtime) async {
  final resp = await http.post(
    Uri.parse('$httpBase/chat/runtime'),
    headers: {'Content-Type': 'application/json', ..._auth},
    body: jsonEncode({'uuid': uuid, 'agent': agent.wire, 'runtime': runtime}),
  );
  if (resp.statusCode != 200) throw ChatApiException(resp.statusCode, resp.body);
}
```

- [ ] **Step 3: Create Chat Agent bar**

Create `app/lib/screens/tabs/chat_agent_bar.dart`:

```dart
import 'package:flutter/material.dart';

import '../../api/agents_api.dart';
import '../../theme.dart';
import '../../widgets/agent_badge.dart';

class ChatAgentBar extends StatelessWidget {
  final AgentKind agent;
  final Map<String, dynamic> runtime;
  final VoidCallback? onTap;

  const ChatAgentBar({super.key, required this.agent, required this.runtime, this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final title = switch (agent) {
      AgentKind.claude => 'Claude Code',
      AgentKind.codex => 'Codex',
      AgentKind.gemini => 'Gemini CLI',
    };
    final subtitle = switch (agent) {
      AgentKind.claude => '${runtime['model'] ?? '默认模型'} · ${runtime['permission_mode'] ?? 'acceptEdits'}',
      AgentKind.codex => '${runtime['model'] ?? '默认模型'} · ${runtime['sandbox'] ?? 'workspace-write'} · ${runtime['approval_policy'] ?? 'on-request'}',
      AgentKind.gemini => '${runtime['model'] ?? '默认模型'} · 未配置',
    };
    return InkWell(
      onTap: onTap,
      child: Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: t.surface,
          border: Border(bottom: BorderSide(color: t.borderSubt, width: 0.5)),
        ),
        child: Row(
          children: [
            AgentBadge(agent: agent, compact: true),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: TextStyle(color: t.text, fontSize: 12, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: t.textDim, fontSize: 10)),
                ],
              ),
            ),
            Icon(Icons.tune_rounded, size: 16, color: t.textDim),
          ],
        ),
      ),
    );
  }
}
```

- [ ] **Step 4: Wire ChatTab stream call**

In `chat_tab.dart`, read:

```dart
final current = ref.watch(currentSessionProvider);
```

When calling `ChatApi.stream`, pass:

```dart
agent: current?.agent ?? AgentKind.claude,
runtime: current?.runtime,
```

Insert `ChatAgentBar` above the message list, inside Chat tab layout, using current session.

- [ ] **Step 5: Preserve native tool card title**

In `app/lib/widgets/tool_call_card.dart`, ensure title uses:

```dart
Text(
  toolUse.name,
  style: TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w600,
    color: t.text,
  ),
)
```

Remove `_displayName(...)` from the title path. Keep `_displayName` only if another non-title summary path still needs it.

- [ ] **Step 6: Add raw payload foldout**

In `_ToolCallCardState`, add:

```dart
bool _showRawPayload = false;
```

Inside expanded content after Output, add:

```dart
if (toolUse.rawPayload != null || result?.rawPayload != null) ...[
  const SizedBox(height: 10),
  InkWell(
    onTap: () => setState(() => _showRawPayload = !_showRawPayload),
    child: Row(
      children: [
        _SectionLabel('原始事件', t),
        const Spacer(),
        Icon(_showRawPayload ? Icons.expand_less : Icons.expand_more, size: 14, color: t.textDim),
      ],
    ),
  ),
  if (_showRawPayload) ...[
    const SizedBox(height: 4),
    _JsonPayloadBlock(value: {
      if (toolUse.rawPayload != null) 'tool_use': toolUse.rawPayload,
      if (result?.rawPayload != null) 'tool_result': result!.rawPayload,
    }),
  ],
]
```

Add `_JsonPayloadBlock`:

```dart
class _JsonPayloadBlock extends StatelessWidget {
  final Object value;
  const _JsonPayloadBlock({required this.value});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    const encoder = JsonEncoder.withIndent('  ');
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: t.bg,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: t.borderSubt, width: 0.5),
      ),
      child: SelectableText(
        encoder.convert(value),
        style: TextStyle(fontFamily: 'monospace', fontSize: 11, color: t.textMuted, height: 1.5),
      ),
    );
  }
}
```

`tool_call_card.dart` already imports `dart:convert`, so no new import is needed.

- [ ] **Step 7: Run analyzer**

Run:

```bash
cd app && flutter analyze
```

Expected: PASS or only pre-existing warnings unrelated to changed files.

- [ ] **Step 8: Commit**

```bash
git add app/lib/screens/tabs/chat_agent_bar.dart app/lib/api/chat_api.dart app/lib/api/protocol.dart app/lib/screens/tabs/chat_tab.dart app/lib/widgets/tool_call_card.dart
git commit -m "feat(app): show agent runtime and native tool names"
```

---

## Task 14: End-To-End Server Verification

**Files:**
- No source changes unless tests reveal a regression.
- Verify: server tests, server typecheck, root typecheck.

- [ ] **Step 1: Run focused server tests**

Run:

```bash
pnpm --filter @cc/server exec vitest run \
  src/__tests__/agents-registry.test.ts \
  src/__tests__/agents-protocol.test.ts \
  src/__tests__/chat-agent-runtime.test.ts \
  src/__tests__/codex-serialize.test.ts \
  src/__tests__/codex-client.test.ts \
  src/__tests__/serialize.test.ts
```

Expected: PASS.

- [ ] **Step 2: Run all server tests**

Run:

```bash
pnpm --filter @cc/server test
```

Expected: PASS.

- [ ] **Step 3: Run TypeScript typecheck**

Run:

```bash
pnpm typecheck
```

Expected: PASS.

- [ ] **Step 4: Fix regressions one at a time**

If a test fails, use `superpowers:systematic-debugging` before changing code. Commit each fix separately with a message naming the broken behavior.

- [ ] **Step 5: Commit verification-only fixes**

If fixes were needed:

```bash
git add <changed files>
git commit -m "fix: stabilize multi-agent server integration"
```

If no fixes were needed, do not create an empty commit.

---

## Task 15: End-To-End App Verification

**Files:**
- No source changes unless analyzer/manual smoke reveals a regression.
- Verify: Flutter analyzer and manual smoke.

- [ ] **Step 1: Run Flutter analyzer**

Run:

```bash
cd app && flutter analyze
```

Expected: PASS or only pre-existing warnings. New errors in changed files must be fixed.

- [ ] **Step 2: Run Flutter tests if present**

Run:

```bash
cd app && flutter test
```

Expected: PASS if test suite exists. If the app has no tests configured, record the exact output in the final implementation summary.

- [ ] **Step 3: Manual smoke with existing Claude flow**

Run the dev server:

```bash
pnpm dev:server
```

Then use the App to verify:

- Existing Claude project opens.
- Existing Claude sessions list includes `agent: claude` data but UI still behaves normally.
- New Claude chat sends a message.
- Claude `Bash` card title is exactly `Bash`.
- Claude `TodoWrite` card title/behavior remains existing behavior.

- [ ] **Step 4: Manual smoke with Codex visibility**

With a local Codex login available, verify:

- `/agents` returns Codex.
- Project page can set Codex as default Agent.
- New chat sheet shows Codex runtime summary.
- Codex chat can start a turn.
- Codex command card title is exactly `commandExecution`.
- Codex file card title is exactly `fileChange`.
- Raw event foldout shows JSON.

- [ ] **Step 5: Commit verification fixes**

If fixes were needed:

```bash
git add <changed files>
git commit -m "fix: stabilize multi-agent app integration"
```

If no fixes were needed, do not create an empty commit.

---

## Final Review Checklist

- [ ] `Bash` remains `Bash` in Claude Chat.
- [ ] `commandExecution` remains `commandExecution` in Codex Chat.
- [ ] Tool card titles do not add `Claude ·` or `Codex ·`.
- [ ] Session summaries include `agent`.
- [ ] Existing clients without `agent` still default to Claude.
- [ ] Codex code lives under `server/src/agents/codex/`.
- [ ] Claude code lives under `server/src/agents/claude/`.
- [ ] App Agent UI follows the approved HTML prototype.
- [ ] Server tests pass.
- [ ] App analyzer passes.
