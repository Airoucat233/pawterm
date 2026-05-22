import { getSessionInfo } from '@anthropic-ai/claude-agent-sdk';
import type { AgentInfo, AgentRuntime, ClaudeRuntime } from '@pawterm/shared';

import { AskUserQuestionRegistry } from '../../ask-user-tool.js';
import type { AgentProvider, AgentRun } from '../types.js';
import { ChatSession } from './session.js';
import { ClaudeSessions } from './sessions.js';

export class ClaudeAgentProvider implements AgentProvider<'claude'> {
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

  listSessions(input: Parameters<AgentProvider<'claude'>['listSessions']>[0]) {
    return this.sessions.list({
      ...input,
      holderFor: () => null,
    });
  }

  getSessionMessages(input: Parameters<AgentProvider<'claude'>['getSessionMessages']>[0]) {
    return this.sessions.messages(input);
  }

  async startTurn(input: Parameters<AgentProvider<'claude'>['startTurn']>[0]): Promise<AgentRun> {
    const runtime = input.runtime;
    const askRegistry = new AskUserQuestionRegistry();
    const sessionInfo = await getSessionInfo(input.sessionId, { dir: input.cwd });
    const session = new ChatSession({
      cwd: input.cwd,
      permissionMode: runtime.permission_mode,
      ...(sessionInfo ? { resume: input.sessionId } : { sessionId: input.sessionId }),
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
