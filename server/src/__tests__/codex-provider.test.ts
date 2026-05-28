import { describe, expect, it } from 'vitest';
import { CodexAgentProvider } from '../agents/codex/provider.js';

type RequestCall = { method: string; params: unknown };

class FakeCodexClient {
  readonly requests: RequestCall[] = [];
  readonly handlers = new Set<(notification: { method: string; params?: unknown }) => void>();
  readonly closeHandlers = new Set<() => void>();
  handlersAtTurnStart = 0;

  async request(method: string, params: unknown): Promise<unknown> {
    this.requests.push({ method, params });
    if (method === 'thread/list') {
      return {
        data: [
          { id: 'in-root', cwd: '/repo', preview: 'root', updatedAt: 10 },
          { id: 'nested', cwd: '/repo/pkg', preview: 'nested', updatedAt: 9 },
          { id: 'other', cwd: '/other', preview: 'other', updatedAt: 8 },
        ],
      };
    }
    if (method === 'thread/read') {
      return {
        thread: {
          turns: [
            {
              id: 'turn-1',
              completedAt: 10,
              items: [{ type: 'agentMessage', id: 'msg_1', text: 'hello' }],
            },
          ],
        },
      };
    }
    if (method === 'thread/resume') throw new Error('not found');
    if (method === 'thread/start') return { thread: { id: 'new-thread' } };
    if (method === 'turn/start') {
      this.handlersAtTurnStart = this.handlers.size;
      return { turn: { id: 'turn-1' } };
    }
    return {};
  }

  onNotification(handler: (notification: { method: string; params?: unknown }) => void): () => void {
    this.handlers.add(handler);
    return () => this.handlers.delete(handler);
  }

  onClose(handler: () => void): () => void {
    this.closeHandlers.add(handler);
    return () => this.closeHandlers.delete(handler);
  }
}

function providerWith(client: FakeCodexClient): CodexAgentProvider {
  return new CodexAgentProvider({ start: () => client } as any);
}

describe('CodexAgentProvider', () => {
  it('filters sessions by cwd and subdir setting', async () => {
    const client = new FakeCodexClient();
    const provider = providerWith(client);

    await expect(provider.listSessions({
      cwd: '/repo',
      limit: 20,
      offset: 0,
      includeSubdirs: false,
    })).resolves.toEqual([
      expect.objectContaining({ agent: 'codex', session_id: 'in-root' }),
    ]);

    await expect(provider.listSessions({
      cwd: '/repo',
      limit: 20,
      offset: 0,
      includeSubdirs: true,
    })).resolves.toEqual([
      expect.objectContaining({ session_id: 'in-root' }),
      expect.objectContaining({ session_id: 'nested' }),
    ]);
  });

  it('stamps history messages with codex agent metadata', async () => {
    const client = new FakeCodexClient();
    const provider = providerWith(client);

    const page = await provider.getSessionMessages({
      cwd: '/repo',
      sessionId: 'thread-1',
      limit: 10,
    });

    expect(page.messages[0]?.message).toMatchObject({
      type: 'assistant',
      agent: 'codex',
      session_ref: { agent: 'codex', id: 'thread-1' },
      content: [{ type: 'text', text: 'hello' }],
    });
  });

  it('subscribes to notifications before starting a turn', async () => {
    const client = new FakeCodexClient();
    const provider = providerWith(client);

    const run = await provider.startTurn({
      cwd: '/repo',
      sessionId: 'maybe-new-thread',
      text: 'hello',
      runtime: { agent: 'codex', sandbox: 'workspace-write', approval_policy: 'on-request' },
      deviceId: 'phone',
    });

    expect(client.requests.map((call) => call.method)).toEqual([
      'thread/resume',
      'thread/start',
      'turn/start',
    ]);
    expect(client.handlersAtTurnStart).toBe(1);
    expect(run.sessionId).toBe('new-thread');
  });

  it('interrupts the active turn with threadId and turnId', async () => {
    const client = new FakeCodexClient();
    const provider = providerWith(client);

    const run = await provider.startTurn({
      cwd: '/repo',
      sessionId: 'thread-1',
      text: 'hello',
      runtime: { agent: 'codex', sandbox: 'workspace-write', approval_policy: 'on-request' },
      deviceId: 'phone',
    });
    await run.interrupt();

    expect(client.requests.at(-1)).toEqual({
      method: 'turn/interrupt',
      params: { threadId: 'new-thread', turnId: 'turn-1' },
    });
  });
});
