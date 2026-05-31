import type { AgentInfo, CodexRuntime, SessionSummary } from '@pawterm/shared';
import { CodexAppServerProcess, type CodexJsonRpcClient, type CodexServerRequest } from './client.js';
import { codexThreadItemToWire } from './serialize.js';
import type { AgentHistoryPage, AgentProvider, AgentRun } from '../types.js';

type CodexTurn = {
  id?: string;
  items?: any[];
  status?: string;
  completedAt?: number | null;
  durationMs?: number | null;
};

export class CodexAgentProvider implements AgentProvider<'codex'> {
  readonly kind = 'codex' as const;

  constructor(private readonly appServer = new CodexAppServerProcess()) {}

  private async client(): Promise<CodexJsonRpcClient> {
    const appServer = this.appServer as CodexAppServerProcess & {
      startInitialized?: () => Promise<CodexJsonRpcClient>;
    };
    return appServer.startInitialized ? appServer.startInitialized() : appServer.start();
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
    const client = await this.client();
    const result = await client.request('thread/list', {
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
    const client = await this.client();
    const result = await client.request('thread/read', {
      threadId: input.sessionId,
      includeTurns: true,
    }) as { thread?: { turns?: CodexTurn[] } };
    const all = (result.thread?.turns ?? [])
      .flatMap((turn) => (turn.items ?? []).map((item) => ({ turn, item })))
      .filter(({ item }) => !!codexThreadItemToWire(item));
    const beforeIndex = input.beforeUuid
      ? all.findIndex(({ item }) => item.id === input.beforeUuid)
      : -1;
    const end = beforeIndex >= 0 ? beforeIndex : all.length;
    const start = Math.max(0, end - input.limit);
    const data = all.slice(start, end);
    return {
      messages: data.map(({ turn, item }) => ({
        uuid: item.id ?? null,
        parent_uuid: null,
        timestamp: typeof turn.completedAt === 'number' ? turn.completedAt * 1000 : null,
        message: (() => {
          const wire = codexThreadItemToWire(item);
          return wire
            ? { ...wire, agent: 'codex' as const, session_ref: { agent: 'codex' as const, id: input.sessionId } }
            : item;
        })(),
      })),
      has_more: start > 0,
      total: all.length,
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
    const client = await this.client();
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
          sandbox: runtime.sandbox,
          approvalPolicy: runtime.approval_policy,
          persistExtendedHistory: false,
        }).catch(() => startThread()) as { thread?: { id: string } }
      : await startThread();
    const threadId = thread.thread?.id ?? input.sessionId;
    const stream = this.createNotificationStream(client, threadId);
    const started = await client.request('turn/start', {
      threadId,
      input: [{ type: 'text', text: input.text }],
      model: runtime.model ?? null,
    }).catch((err) => {
      stream.close();
      throw err;
    }) as { turn?: { id?: string } };
    const turnId = started.turn?.id;
    return {
      sessionId: threadId,
      events: stream.events,
      interrupt: async () => {
        if (!turnId) return;
        await client.request('turn/interrupt', { threadId, turnId });
      },
      answerApproval: async (requestId, decision) => {
        stream.answerApproval(requestId, decision);
      },
      close: stream.close,
    };
  }

  async interrupt(input: { sessionId: string }): Promise<void> {
    // Codex app-server requires a turnId for interruption. Active turns are
    // interrupted through the AgentRun closure returned by startTurn().
  }

  private createNotificationStream(client: CodexJsonRpcClient, threadId: string): {
    events: AsyncIterable<unknown>;
    answerApproval: (requestId: string, decision: 'accept' | 'acceptForSession' | 'decline' | 'cancel') => void;
    close: () => void;
  } {
    const queue: unknown[] = [];
    const pendingApprovals = new Map<string, CodexServerRequest>();
    let wake: (() => void) | null = null;
    let closed = false;
    let closeAfterDrain = false;
    let offClose: (() => void) | null = null;
    let offRequest: (() => void) | null = null;
    const off = client.onNotification((notification) => {
      if (closed) return;
      const params = notification.params as { threadId?: string; item?: unknown; turn?: { items?: unknown[] } } | undefined;
      if (params?.threadId && params.threadId !== threadId) return;
      queue.push(notification);
      if (notification.method === 'turn/completed' || notification.method === 'error') {
        closeAfterDrain = true;
      }
      wake?.();
      wake = null;
    });
    offRequest = client.onRequest((request) => {
      if (closed) return;
      if (!isApprovalRequest(request.method)) {
        client.reject(request.id, -32601, `Unhandled Codex app-server request: ${request.method}`);
        return;
      }
      const params = request.params as { threadId?: string } | undefined;
      if (params?.threadId && params.threadId !== threadId) return;
      const requestId = String(request.id);
      pendingApprovals.set(requestId, request);
      queue.push({ id: requestId, method: request.method, params: request.params });
      wake?.();
      wake = null;
    });

    const close = () => {
      if (closed) return;
      closed = true;
      off();
      offRequest?.();
      offClose?.();
      wake?.();
      wake = null;
    };
    offClose = client.onClose(close);

    async function* events() {
      try {
        while (true) {
          if (queue.length > 0) {
            yield queue.shift();
            if (closeAfterDrain && queue.length === 0) break;
            continue;
          }
          if (closed || closeAfterDrain) break;
          await new Promise<void>((resolve) => { wake = resolve; });
        }
      } finally {
        close();
      }
    }

    const answerApproval = (requestId: string, decision: 'accept' | 'acceptForSession' | 'decline' | 'cancel') => {
      const request = pendingApprovals.get(requestId);
      if (!request) throw new Error(`No pending Codex approval request: ${requestId}`);
      pendingApprovals.delete(requestId);
      client.respond(request.id, approvalResponse(request, decision));
      queue.push({
        method: 'serverRequest/resolved',
        params: { threadId, requestId, decision },
      });
      wake?.();
      wake = null;
    };

    return { events: events(), answerApproval, close };
  }
}

function isApprovalRequest(method: string): boolean {
  return method === 'item/commandExecution/requestApproval' ||
    method === 'item/fileChange/requestApproval' ||
    method === 'item/permissions/requestApproval';
}

function approvalResponse(
  request: CodexServerRequest,
  decision: 'accept' | 'acceptForSession' | 'decline' | 'cancel',
): unknown {
  if (request.method === 'item/permissions/requestApproval') {
    if (decision === 'accept' || decision === 'acceptForSession') {
      const permissions = (request.params as { permissions?: unknown } | undefined)?.permissions;
      return {
        permissions: normalizeGrantedPermissions(permissions),
        scope: decision === 'acceptForSession' ? 'session' : 'turn',
        strictAutoReview: false,
      };
    }
    return { permissions: {}, scope: 'turn', strictAutoReview: false };
  }
  return { decision };
}

function normalizeGrantedPermissions(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return {};
  const input = value as Record<string, unknown>;
  const out: Record<string, unknown> = {};
  if (input.network && typeof input.network === 'object') out.network = input.network;
  if (input.fileSystem && typeof input.fileSystem === 'object') out.fileSystem = input.fileSystem;
  return out;
}
