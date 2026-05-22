import { beforeEach, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => ({
  getSessionInfo: vi.fn(),
  sessionOpts: [] as Array<Record<string, unknown>>,
}));

vi.mock('@anthropic-ai/claude-agent-sdk', () => ({
  deleteSession: vi.fn(),
  forkSession: vi.fn(),
  getSessionInfo: mocks.getSessionInfo,
  getSessionMessages: vi.fn(),
  listSessions: vi.fn(),
  renameSession: vi.fn(),
  tagSession: vi.fn(),
}));

vi.mock('../agents/claude/session.js', () => ({
  ChatSession: class {
    constructor(opts: Record<string, unknown>) {
      mocks.sessionOpts.push(opts);
    }

    pushUserMessage() {}

    start() {
      return (async function* () {})();
    }

    async setModel() {}

    async setPermissionMode() {}

    async interrupt() {}

    close() {}
  },
}));

describe('ClaudeAgentProvider', () => {
  beforeEach(() => {
    mocks.getSessionInfo.mockReset();
    mocks.sessionOpts.length = 0;
  });

  it('resumes an existing Claude session', async () => {
    mocks.getSessionInfo.mockResolvedValue({ sessionId: 'session-1' });
    const { ClaudeAgentProvider } = await import('../agents/claude/provider.js');

    const provider = new ClaudeAgentProvider();
    await provider.startTurn({
      cwd: '/repo',
      sessionId: 'session-1',
      text: 'continue',
      runtime: { agent: 'claude', permission_mode: 'acceptEdits' },
      deviceId: 'phone',
    });

    expect(mocks.getSessionInfo).toHaveBeenCalledWith('session-1', { dir: '/repo' });
    expect(mocks.sessionOpts[0]).toMatchObject({
      cwd: '/repo',
      permissionMode: 'acceptEdits',
      resume: 'session-1',
    });
    expect(mocks.sessionOpts[0]).not.toHaveProperty('sessionId');
  });

  it('starts a new Claude session when no history exists', async () => {
    mocks.getSessionInfo.mockResolvedValue(null);
    const { ClaudeAgentProvider } = await import('../agents/claude/provider.js');

    const provider = new ClaudeAgentProvider();
    await provider.startTurn({
      cwd: '/repo',
      sessionId: 'session-2',
      text: 'start',
      runtime: { agent: 'claude', permission_mode: 'plan' },
      deviceId: 'phone',
    });

    expect(mocks.sessionOpts[0]).toMatchObject({
      cwd: '/repo',
      permissionMode: 'plan',
      sessionId: 'session-2',
    });
    expect(mocks.sessionOpts[0]).not.toHaveProperty('resume');
  });
});
