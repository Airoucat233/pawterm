import type { AgentInfo, CodexRuntime, SessionSummary } from '@pawterm/shared';
import { CodexAppServerProcess, type CodexJsonRpcClient } from './client.js';
import { codexThreadItemToWire } from './serialize.js';
import type { AgentHistoryPage, AgentProvider, AgentRun } from '../types.js';

export class CodexAgentProvider implements AgentProvider<'codex'> {
  readonly kind = 'codex' as const;

  constructor(private readonly appServer = new CodexAppServerProcess()) {}

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
      .filter((thread) => {
        const cwd = thread.cwd ?? '';
        if (cwd === input.cwd) return true;
        return input.includeSubdirs && cwd.startsWith(`${input.cwd}/`);
      })
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
        message: (() => {
          const wire = codexThreadItemToWire(item);
          return wire
            ? { ...wire, agent: 'codex' as const, session_ref: { agent: 'codex' as const, id: input.sessionId } }
            : item;
        })(),
      })),
      has_more: !!result.nextCursor,
      total: data.length,
    };
  }

  async startTurn(input: {
    cwd: string;
    sessionId: string;
    text: string;
    runtime: CodexRuntime;
    deviceId: string;
  }): Promise<AgentRun> {
    const runtime = input.runtime;
    const client = this.client();
    const startThread = () => client.request('thread/start', {
      cwd: input.cwd,
      model: runtime.model ?? null,
      sandbox: runtime.sandbox,
      approvalPolicy: runtime.approval_policy,
      experimentalRawEvents: false,
      persistExtendedHistory: false,
    }) as Promise<{ thread?: { id: string } }>;
    const thread = input.sessionId
      ? await client.request('thread/resume', {
          threadId: input.sessionId,
          cwd: input.cwd,
          model: runtime.model ?? null,
          persistExtendedHistory: false,
        }).catch(() => startThread()) as { thread?: { id: string } }
      : await startThread();
    const threadId = thread.thread?.id ?? input.sessionId;
    const stream = this.createNotificationStream(client, threadId);
    await client.request('turn/start', {
      threadId,
      input: [{ type: 'text', text: input.text }],
      model: runtime.model ?? null,
    }).catch((err) => {
      stream.close();
      throw err;
    });
    return {
      sessionId: threadId,
      events: stream.events,
      interrupt: async () => { await client.request('turn/interrupt', { threadId }); },
      close: stream.close,
    };
  }

  async interrupt(input: { sessionId: string }): Promise<void> {
    await this.client().request('turn/interrupt', { threadId: input.sessionId });
  }

  private createNotificationStream(client: CodexJsonRpcClient, threadId: string): {
    events: AsyncIterable<unknown>;
    close: () => void;
  } {
    const queue: unknown[] = [];
    let wake: (() => void) | null = null;
    let closed = false;
    let offClose: (() => void) | null = null;
    const off = client.onNotification((notification) => {
      if (closed) return;
      const params = notification.params as { threadId?: string; item?: unknown; turn?: { items?: unknown[] } } | undefined;
      if (params?.threadId && params.threadId !== threadId) return;
      queue.push(notification);
      wake?.();
      wake = null;
    });

    const close = () => {
      if (closed) return;
      closed = true;
      off();
      offClose?.();
      wake?.();
      wake = null;
    };
    offClose = client.onClose(close);

    async function* events() {
      try {
        while (!closed) {
          if (queue.length > 0) {
            yield queue.shift();
            continue;
          }
          await new Promise<void>((resolve) => { wake = resolve; });
        }
      } finally {
        close();
      }
    }

    return { events: events(), close };
  }
}
