import type { AgentInfo } from '@pawterm/shared';
import type { AgentProvider } from '../types.js';

export class CodexAgentProvider implements AgentProvider<'codex'> {
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

  async listSessions() {
    return [];
  }

  async getSessionMessages() {
    return { messages: [], has_more: false, total: 0 };
  }

  async startTurn(): Promise<never> {
    throw new Error('Codex provider is disabled');
  }

  async interrupt(): Promise<void> {}
}
