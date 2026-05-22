import Fastify from 'fastify';
import { describe, expect, it, vi } from 'vitest';
import type { AgentInfo, AgentKind, SessionSummary } from '@pawterm/shared';

import { AgentRegistry } from '../agents/registry.js';
import type { AgentProvider } from '../agents/types.js';
import { registerSessionsApi } from '../sessions-api.js';

vi.mock('../config.js', () => ({
  isPathAllowed: vi.fn(() => true),
}));

function summary(agent: AgentKind, id: string, lastModified: number): SessionSummary {
  return {
    agent,
    session_id: id,
    summary: null,
    title: null,
    tags: [],
    last_modified: lastModified,
    cwd: '/repo',
    num_messages: null,
    total_cost_usd: null,
    holder_device_id: null,
  };
}

function fakeProvider(
  kind: 'claude' | 'codex',
  sessions: SessionSummary[],
  calls: Array<{ kind: AgentKind; limit: number; offset: number }>,
  failList = false,
): AgentProvider {
  const info: AgentInfo = {
    kind,
    label: kind,
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
    listSessions: async ({ limit, offset }) => {
      calls.push({ kind, limit, offset });
      if (failList) throw new Error(`${kind} unavailable`);
      return sessions.slice(offset, offset + limit);
    },
    getSessionMessages: async () => ({ messages: [], has_more: false, total: 0 }),
    startTurn: async () => {
      throw new Error('not used in sessions-api tests');
    },
    interrupt: async () => {},
  };
}

describe('sessions API agent dispatch', () => {
  it('globally sorts and paginates agent=all results', async () => {
    const calls: Array<{ kind: AgentKind; limit: number; offset: number }> = [];
    const registry = new AgentRegistry([
      fakeProvider('claude', [
        summary('claude', 'claude-100', 100),
        summary('claude', 'claude-70', 70),
        summary('claude', 'claude-10', 10),
      ], calls),
      fakeProvider('codex', [
        summary('codex', 'codex-90', 90),
        summary('codex', 'codex-80', 80),
        summary('codex', 'codex-20', 20),
      ], calls),
    ]);
    const app = Fastify({ logger: false });
    await registerSessionsApi(app, { registry });

    const response = await app.inject({
      method: 'GET',
      url: '/sessions?cwd=/repo&agent=all&limit=2&offset=1',
    });

    expect(response.statusCode).toBe(200);
    expect(response.json()).toEqual([
      expect.objectContaining({ agent: 'codex', session_id: 'codex-90' }),
      expect.objectContaining({ agent: 'codex', session_id: 'codex-80' }),
    ]);
    expect(calls).toEqual([
      { kind: 'claude', limit: 3, offset: 0 },
      { kind: 'codex', limit: 3, offset: 0 },
    ]);

    await app.close();
  });

  it('keeps agent=all usable when one provider fails to list sessions', async () => {
    const calls: Array<{ kind: AgentKind; limit: number; offset: number }> = [];
    const registry = new AgentRegistry([
      fakeProvider('claude', [summary('claude', 'claude-100', 100)], calls),
      fakeProvider('codex', [], calls, true),
    ]);
    const app = Fastify({ logger: false });
    await registerSessionsApi(app, { registry });

    const response = await app.inject({
      method: 'GET',
      url: '/sessions?cwd=/repo&agent=all&limit=10',
    });

    expect(response.statusCode).toBe(200);
    expect(response.json()).toEqual([
      expect.objectContaining({ agent: 'claude', session_id: 'claude-100' }),
    ]);

    await app.close();
  });
});
