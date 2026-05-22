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
