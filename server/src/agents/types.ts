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
