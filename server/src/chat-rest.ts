import type { FastifyInstance } from 'fastify';
import { resolve } from 'node:path';
import { getSessionInfo } from '@anthropic-ai/claude-agent-sdk';

import type { AnswerQuestionRequest, PermissionMode } from '@pawterm/shared';

import { isPathAllowed, settings } from './config.js';
import { AskUserQuestionRegistry } from './ask-user-tool.js';
import { EventBuffer } from './event-buffer.js';
import { findHolder, killHolder } from './holder-detect.js';
import { messageToWire } from './serialize.js';
import { ChatSession } from './session-manager.js';

interface RunEntry {
  session: ChatSession;
  buffer: EventBuffer;
  askRegistry: AskUserQuestionRegistry;
  /** Grace timer: starts when result arrives, clears run after GRACE_MS. */
  graceTimer?: NodeJS.Timeout;
  writers: Set<{ write: (s: string) => void; end: () => void }>;
  /** True once a result event has been emitted for this turn. */
  resultReceived: boolean;
}

/** Key = Claude UUID (same as jsonl filename). Only present during an active turn. */
const activeRuns = new Map<string, RunEntry>();
const GRACE_MS = 60_000;
const HEARTBEAT_MS = 15_000;

function broadcast(entry: RunEntry, type: string, data: unknown): void {
  const ev = entry.buffer.push(type, data);
  const payload = `id: ${ev.id}\nevent: ${type}\ndata: ${JSON.stringify(data)}\n\n`;
  for (const w of [...entry.writers]) {
    try {
      w.write(payload);
    } catch {
      entry.writers.delete(w);
    }
  }
}

function cancelGrace(entry: RunEntry): void {
  if (entry.graceTimer) {
    clearTimeout(entry.graceTimer);
    entry.graceTimer = undefined;
  }
}

function startGrace(uuid: string, entry: RunEntry, log?: FastifyInstance['log']): void {
  if (entry.graceTimer) return;
  log?.info({ uuid, graceMs: GRACE_MS }, 'run: grace started');
  entry.graceTimer = setTimeout(() => {
    closeRun(uuid, log);
  }, GRACE_MS);
}

function closeRun(uuid: string, log?: FastifyInstance['log']): void {
  const entry = activeRuns.get(uuid);
  if (!entry) return;
  log?.info({ uuid }, 'run: closing (grace expired)');
  cancelGrace(entry);
  entry.askRegistry.rejectAll('run closed');
  // Interrupt first so the SDK subprocess actually stops, then close input gen.
  entry.session.interrupt().finally(() => {
    entry.session.close();
  });
  for (const w of entry.writers) {
    try { w.end(); } catch { /* */ }
  }
  activeRuns.delete(uuid);
}

const ASK_TOOL_NAME = 'mcp__ask-user-question__AskUserQuestion';

function maybeSetPendingToolUseId(wire: ReturnType<typeof messageToWire>, registry: AskUserQuestionRegistry): void {
  if (!wire || wire.type !== 'assistant') return;
  const content = (wire as { content?: unknown[] }).content;
  if (!Array.isArray(content)) return;
  for (const block of content) {
    if (
      block && typeof block === 'object' &&
      (block as { type?: string }).type === 'tool_use' &&
      (block as { name?: string }).name === ASK_TOOL_NAME
    ) {
      registry.pendingToolUseId = (block as { id?: string }).id ?? null;
      return;
    }
  }
}

async function consumeSdk(uuid: string, entry: RunEntry, log: FastifyInstance['log']): Promise<void> {
  try {
    const iter = entry.session.start();
    for await (const sdkMsg of iter) {
      const wire = messageToWire(sdkMsg);
      if (wire) {
        const stamped = { ...wire, timestamp: Date.now(), uuid: (sdkMsg as any).uuid ?? null };
        maybeSetPendingToolUseId(wire, entry.askRegistry);
        broadcast(entry, (wire as { type: string }).type, stamped);
        if ((wire as { type: string }).type === 'result') {
          log.info({ uuid }, 'run: result received, starting grace');
          entry.resultReceived = true;
          startGrace(uuid, entry, log);
        }
      }
    }
    log.info({ uuid }, 'run: SDK iterator exhausted');
  } catch (err) {
    log.error({ uuid, err: (err as Error).message }, 'run: SDK error');
    broadcast(entry, 'error', { type: 'error', message: (err as Error).message });
    entry.resultReceived = true;
    startGrace(uuid, entry, log);
  } finally {
    if (!entry.resultReceived) {
      entry.resultReceived = true;
      startGrace(uuid, entry, log);
    }
  }
}

export async function registerChatRest(app: FastifyInstance): Promise<void> {
  /**
   * POST /chat/stream — send a message and start streaming the response.
   *
   * Body: { uuid, cwd, text, model?, permission_mode? }
   * Returns: { ok: true } — actual events come via GET /chat/events?uuid=
   *
   * 409 if a run is already active for this uuid.
   */
  app.post<{
    Body: { uuid?: string; cwd?: string; text?: string; model?: string; permission_mode?: PermissionMode };
  }>(
    '/chat/stream',
    async (req, reply) => {
      const body = req.body ?? {};
      const uuid = body.uuid;

      if (!uuid) { reply.code(400); return { error: 'uuid required' }; }
      if (!body.cwd) { reply.code(400); return { error: 'cwd required' }; }
      if (!body.text) { reply.code(400); return { error: 'text required' }; }

      const cwd = resolve(body.cwd);
      if (!isPathAllowed(cwd)) { reply.code(403); return { error: `Project not allowed: ${cwd}` }; }

      if (activeRuns.has(uuid)) {
        const existing = activeRuns.get(uuid)!;
        if (existing.resultReceived) {
          // Grace period — previous turn finished, new turn arriving. Reuse the
          // SDK session (inputGen is still waiting) with a fresh event buffer.
          req.log.info({ uuid }, 'run: new turn during grace, cancelling grace');
          cancelGrace(existing);
          existing.resultReceived = false;
          existing.buffer = new EventBuffer(2000);
          existing.session.pushUserMessage(body.text);
          return { ok: true };
        }
        req.log.warn({ uuid }, 'run: 409 — run still active (not in grace)');
        reply.code(409);
        return { error: 'run already active for this session' };
      }

      const permissionMode = body.permission_mode ?? settings.permissionMode;

      const sessionInfo = await getSessionInfo(uuid, { dir: cwd });
      const askRegistry = new AskUserQuestionRegistry();
      const session = new ChatSession({
        cwd,
        permissionMode,
        ...(sessionInfo ? { resume: uuid } : { sessionId: uuid }),
        model: body.model,
        askRegistry,
      });

      const entry: RunEntry = {
        session,
        buffer: new EventBuffer(2000),
        askRegistry,
        writers: new Set(),
        resultReceived: false,
      };
      activeRuns.set(uuid, entry);
      req.log.info({ uuid, cwd, resume: !!sessionInfo }, 'run: created');

      session.pushUserMessage(body.text);
      consumeSdk(uuid, entry, req.log).catch(() => {});

      return { ok: true };
    },
  );

  /**
   * GET /chat/events?uuid=&lastEventId= — subscribe to (or reconnect to) an active run's SSE stream.
   *
   * 404 if no active run for uuid.
   * 412 if lastEventId is too old (event gap).
   */
  app.get<{ Querystring: { uuid?: string; lastEventId?: string } }>(
    '/chat/events',
    (req, reply) => {
      const uuid = req.query.uuid;
      if (!uuid) { reply.code(400); return reply.send({ error: 'uuid required' }); }

      const entry = activeRuns.get(uuid);
      if (!entry) {
        req.log.warn({ uuid }, 'sse: 404 no active run');
        reply.code(404); return reply.send({ error: 'no active run' });
      }

      const lastIdHeader = (req.headers['last-event-id'] as string | undefined) ?? req.query.lastEventId;
      const lastId = lastIdHeader ? parseInt(lastIdHeader, 10) : 0;
      if (lastId > 0) {
        const probe = entry.buffer.since(lastId);
        if (probe === null) {
          req.log.warn({ uuid, lastId }, 'sse: 412 event gap');
          reply.code(412); return reply.send({ error: 'event gap, please reload' });
        }
      }

      reply.hijack();
      reply.raw.setHeader('Content-Type', 'text/event-stream');
      reply.raw.setHeader('Cache-Control', 'no-cache');
      reply.raw.setHeader('Connection', 'keep-alive');
      reply.raw.flushHeaders();

      const writer = {
        write: (s: string) => reply.raw.write(s),
        end: () => reply.raw.end(),
      };
      entry.writers.add(writer);

      let replayCount = 0;
      if (lastId > 0) {
        const replay = entry.buffer.since(lastId) ?? [];
        replayCount = replay.length;
        for (const e of replay) {
          writer.write(`id: ${e.id}\nevent: ${e.type}\ndata: ${JSON.stringify(e.data)}\n\n`);
        }
      } else if (lastId === 0 && entry.buffer.newestId > 0) {
        const all = entry.buffer.since(0) ?? [];
        replayCount = all.length;
        for (const e of all) {
          writer.write(`id: ${e.id}\nevent: ${e.type}\ndata: ${JSON.stringify(e.data)}\n\n`);
        }
      }
      req.log.info({ uuid, lastId, replayCount, writers: entry.writers.size }, 'sse: client connected');

      const heartbeat = setInterval(() => {
        try {
          writer.write(`: heartbeat\n\n`);
        } catch {
          entry.writers.delete(writer);
          clearInterval(heartbeat);
        }
      }, HEARTBEAT_MS);

      req.raw.on('close', () => {
        clearInterval(heartbeat);
        entry.writers.delete(writer);
        req.log.info({ uuid, writers: entry.writers.size }, 'sse: client disconnected');
      });

      return reply;
    },
  );

  /**
   * GET /chat/status?uuid= — three-signal run state.
   * 'live'    → run active, result not yet received
   * 'done'    → run in grace period (result received, not yet cleaned up)
   * 'running' → no activeRun but PID holder found (another process holds session)
   * 'unknown' → no activeRun and no holder
   */
  app.get<{ Querystring: { uuid?: string } }>(
    '/chat/status',
    async (req, reply) => {
      const uuid = req.query.uuid;
      if (!uuid) { reply.code(400); return { error: 'uuid required' }; }

      const entry = activeRuns.get(uuid);
      if (entry) {
        return { state: entry.resultReceived ? 'done' : 'live' };
      }
      const holder = await findHolder(uuid).catch(() => null);
      if (holder) {
        return { state: 'running', holder };
      }
      return { state: 'unknown' };
    },
  );

  /** POST /chat/interrupt — interrupt the active run for a session. */
  app.post<{ Body: { uuid?: string } }>('/chat/interrupt', async (req, reply) => {
    const uuid = req.body?.uuid;
    if (!uuid) { reply.code(400); return { error: 'uuid required' }; }
    const entry = activeRuns.get(uuid);
    if (!entry) { reply.code(404); return { error: 'no active run' }; }
    await entry.session.interrupt();
    return { ok: true };
  });

  /** POST /chat/model — change model mid-run. */
  app.post<{ Body: { uuid?: string; model?: string } }>(
    '/chat/model',
    async (req, reply) => {
      const { uuid, model } = req.body ?? {};
      if (!uuid) { reply.code(400); return { error: 'uuid required' }; }
      if (!model) { reply.code(400); return { error: 'model required' }; }
      const entry = activeRuns.get(uuid);
      if (!entry) { reply.code(404); return { error: 'no active run' }; }
      await entry.session.setModel(model);
      return { ok: true };
    },
  );

  /** POST /chat/permission — change permission mode mid-run. */
  app.post<{ Body: { uuid?: string; mode?: PermissionMode } }>(
    '/chat/permission',
    async (req, reply) => {
      const { uuid, mode } = req.body ?? {};
      if (!uuid) { reply.code(400); return { error: 'uuid required' }; }
      if (!mode) { reply.code(400); return { error: 'mode required' }; }
      const entry = activeRuns.get(uuid);
      if (!entry) { reply.code(404); return { error: 'no active run' }; }
      await entry.session.setPermissionMode(mode);
      return { ok: true };
    },
  );

  /**
   * POST /chat/takeover — kill the holder process for a session so this client can take over.
   * Returns 200 { ok: true } if the holder is gone (or was already gone).
   * Returns 409 if the holder could not be stopped within 3 s.
   */
  app.post<{ Body: { uuid?: string } }>('/chat/takeover', async (req, reply) => {
    const uuid = req.body?.uuid;
    if (!uuid) { reply.code(400); return { error: 'uuid required' }; }
    const holder = await findHolder(uuid);
    if (!holder) return { ok: true };
    const killed = await killHolder(holder.pid);
    if (!killed) { reply.code(409); return { error: 'could not stop holder process' }; }
    return { ok: true };
  });

  /**
   * GET /chat/context-usage?uuid= — query context window usage for an active run.
   *
   * Returns the full SDKControlGetContextUsageResponse:
   *   { categories, totalTokens, maxTokens, percentage, model, memoryFiles, mcpTools, ... }
   *
   * 404 if no active run for uuid.
   * 503 if the SDK call fails (e.g. session not yet started).
   */
  app.get<{ Querystring: { uuid?: string } }>(
    '/chat/context-usage',
    async (req, reply) => {
      const uuid = req.query.uuid;
      if (!uuid) { reply.code(400); return { error: 'uuid required' }; }
      const entry = activeRuns.get(uuid);
      if (!entry) { reply.code(404); return { error: 'no active run' }; }
      try {
        const usage = await entry.session.getContextUsage();
        return usage;
      } catch (err) {
        req.log.warn({ uuid, err: (err as Error).message }, 'context-usage: failed');
        reply.code(503);
        return { error: (err as Error).message };
      }
    },
  );

  /** POST /chat/answer — answer a pending AskUserQuestion tool call. */
  app.post<{ Body: AnswerQuestionRequest }>(
    '/chat/answer',
    async (req, reply) => {
      const uuid = req.body?.uuid;
      if (!uuid) { reply.code(400); return { error: 'uuid required' }; }
      const entry = activeRuns.get(uuid);
      if (!entry) { reply.code(404); return { error: 'no active run' }; }
      const ok = entry.session.answerQuestion(
        req.body.tool_use_id,
        req.body.answers,
        req.body.annotations,
      );
      if (!ok) {
        app.log.warn({ toolUseId: req.body.tool_use_id }, 'answer: no pending tool');
      }
      return { ok };
    },
  );
}

/** Exported for AskUserQuestion wiring. */
export function getRunEntry(uuid: string): RunEntry | undefined {
  return activeRuns.get(uuid);
}

/** @deprecated Use getRunEntry. */
export const getSessionEntry = getRunEntry;
