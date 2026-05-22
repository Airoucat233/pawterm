import type { FastifyInstance } from 'fastify';
import { resolve } from 'node:path';
import { getSessionInfo } from '@anthropic-ai/claude-agent-sdk';

import type { AgentKind, AgentRuntime, AnswerQuestionRequest, ClaudeRuntime, PermissionMode } from '@pawterm/shared';

import { isPathAllowed, settings } from './config.js';
import { AskUserQuestionRegistry } from './ask-user-tool.js';
import { EventBuffer } from './event-buffer.js';
import { findHolder, killHolder } from './holder-detect.js';
import { messageToWire } from './serialize.js';
import { ChatSession } from './session-manager.js';
import { defaultAgentRegistry } from './agents/registry.js';
import { parseRuntimeFromChatBody, parseRuntimePatchForAgent } from './agents/http-helpers.js';
import { codexThreadItemToWire } from './agents/codex/serialize.js';
import type { AgentRun } from './agents/types.js';

interface RunEntry {
  agent: AgentKind;
  uuid: string;
  sessionId: string;
  session?: ChatSession;
  run?: AgentRun;
  buffer: EventBuffer;
  askRegistry: AskUserQuestionRegistry;
  /** Grace timer: starts when result arrives, clears run after GRACE_MS. */
  graceTimer?: NodeJS.Timeout;
  writers: Set<{ write: (s: string) => void; end: () => void }>;
  /** True once a result event has been emitted for this turn. */
  resultReceived: boolean;
  /** Device id of the client currently streaming this run. Cleared when grace starts. */
  holderDeviceId: string;
}

/** Key = `${agent}:${uuid}`. Only present during an active turn. */
const activeRuns = new Map<string, RunEntry>();
const sessionAliases = new Map<string, string>();
const GRACE_MS = 60_000;
const HEARTBEAT_MS = 15_000;

function runKey(agent: string, uuid: string): string {
  return `${agent}:${uuid}`;
}

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

function startGrace(key: string, entry: RunEntry, log?: FastifyInstance['log']): void {
  if (entry.graceTimer) return;
  log?.info({ uuid: entry.uuid, agent: entry.agent, graceMs: GRACE_MS }, 'run: grace started');
  // Clear holderDeviceId so sessions list no longer shows this session as "in use".
  entry.holderDeviceId = '';
  entry.graceTimer = setTimeout(() => {
    closeRun(key, log);
  }, GRACE_MS);
}

function closeRun(key: string, log?: FastifyInstance['log']): void {
  const entry = activeRuns.get(key);
  if (!entry) return;
  log?.info({ uuid: entry.uuid, agent: entry.agent }, 'run: closing (grace expired)');
  cancelGrace(entry);
  entry.askRegistry.rejectAll('run closed');
  // Interrupt first so the SDK subprocess actually stops, then close input gen.
  if (entry.session) {
    entry.session.interrupt().finally(() => {
      entry.session?.close();
    });
  }
  if (entry.run) {
    entry.run.interrupt().catch(() => {}).finally(() => {
      entry.run?.close();
    });
  }
  for (const w of entry.writers) {
    try { w.end(); } catch { /* */ }
  }
  activeRuns.delete(key);
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

function runMessagesToWire(agent: AgentKind, msg: unknown): Array<ReturnType<typeof messageToWire>> {
  if (agent === 'claude') return [messageToWire(msg)];
  if (agent === 'codex') {
    const notification = msg as { method?: string; params?: any };
    const items = Array.isArray(notification.params?.turn?.items)
      ? notification.params.turn.items
      : notification.params?.item
        ? [notification.params.item]
        : [];
    return items
      .map((item: unknown) => {
        const wire = codexThreadItemToWire(item as Record<string, unknown>);
        return wire ? { ...wire, native_event: notification.method, raw_payload: notification } : null;
      })
      .filter(Boolean);
  }
  return [];
}

async function consumeRun(agent: AgentKind, key: string, uuid: string, entry: RunEntry, log: FastifyInstance['log']): Promise<void> {
  try {
    const iter = entry.run?.events ?? entry.session?.start();
    if (!iter) throw new Error('run has no event source');
    for await (const sdkMsg of iter) {
      const wires = runMessagesToWire(agent, sdkMsg);
      for (const wire of wires) {
        if (!wire) continue;
        const stamped = {
          ...wire,
          agent,
          session_ref: { agent, id: entry.sessionId },
          timestamp: Date.now(),
          uuid: (sdkMsg as any).uuid ?? null,
        };
        maybeSetPendingToolUseId(wire, entry.askRegistry);
        broadcast(entry, (wire as { type: string }).type, stamped);
        if ((wire as { type: string }).type === 'result') {
          log.info({ uuid, agent }, 'run: result received, starting grace');
          entry.resultReceived = true;
          startGrace(key, entry, log);
        }
      }
    }
    log.info({ uuid, agent }, 'run: SDK iterator exhausted');
  } catch (err) {
    log.error({ uuid, agent, err: (err as Error).message }, 'run: SDK error');
    broadcast(entry, 'error', { type: 'error', agent, session_ref: { agent, id: entry.sessionId }, message: (err as Error).message });
    entry.resultReceived = true;
    startGrace(key, entry, log);
  } finally {
    if (!entry.resultReceived) {
      entry.resultReceived = true;
      startGrace(key, entry, log);
    }
  }
}

/**
 * Returns the holderDeviceId for a given uuid if there is an active (non-grace) run.
 * Used by sessions-api to annotate session summaries.
 */
export function getActiveRunHolder(uuid: string): string | null {
  const entry = activeRuns.get(runKey('claude', uuid));
  if (!entry || !entry.holderDeviceId) return null;
  return entry.holderDeviceId;
}

export async function registerChatRest(app: FastifyInstance): Promise<void> {
  /**
   * POST /chat/stream — send a message and start streaming the response.
   *
   * Body: { uuid, cwd, text, permission_mode, model? }
   * Returns: { ok: true } — actual events come via GET /chat/events?uuid=
   *
   * 409 if a run is already active for this uuid.
   */
  app.post<{
    Body: {
      uuid?: string;
      cwd?: string;
      text?: string;
      agent?: string;
      runtime?: AgentRuntime;
      model?: string;
      permission_mode?: PermissionMode;
      device_id?: string;
    };
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

      const deviceId = body.device_id ?? 'unknown';
      let runtime: AgentRuntime;
      try {
        runtime = parseRuntimeFromChatBody(body);
      } catch (err) {
        reply.code(400);
        return { error: (err as Error).message };
      }
      const key = runKey(runtime.agent, uuid);
      const provider = defaultAgentRegistry.resolve(runtime.agent);
      const providerSessionId = sessionAliases.get(key) ?? uuid;

      if (activeRuns.has(key)) {
        const existing = activeRuns.get(key)!;
        if (existing.resultReceived) {
          // Grace period — previous turn finished, new turn arriving. Reuse the
          // SDK session (inputGen is still waiting) with a fresh event buffer.
          req.log.info({ uuid, agent: runtime.agent }, 'run: new turn during grace, cancelling grace');
          cancelGrace(existing);
          existing.resultReceived = false;
          existing.holderDeviceId = deviceId;
          existing.buffer = new EventBuffer(2000);
          if (existing.session) {
            existing.session.pushUserMessage(body.text);
            return { ok: true };
          }
          if (existing.run?.pushUserMessage) {
            existing.run.pushUserMessage(body.text);
            return { ok: true };
          }
          closeRun(key, req.log);
        } else {
          req.log.warn({ uuid, agent: runtime.agent }, 'run: 409 — run still active (not in grace)');
          reply.code(409);
          return { error: 'run already active for this session' };
        }
      }

      if (runtime.agent === 'claude') {
        const sessionInfo = await getSessionInfo(uuid, { dir: cwd });
        const askRegistry = new AskUserQuestionRegistry();
        const claudeRuntime = runtime as ClaudeRuntime;
        const session = new ChatSession({
          cwd,
          permissionMode: claudeRuntime.permission_mode,
          ...(sessionInfo ? { resume: uuid } : { sessionId: uuid }),
          model: claudeRuntime.model,
          askRegistry,
        });

        const entry: RunEntry = {
          agent: runtime.agent,
          uuid,
          sessionId: uuid,
          session,
          buffer: new EventBuffer(2000),
          askRegistry,
          writers: new Set(),
          resultReceived: false,
          holderDeviceId: deviceId,
        };
        activeRuns.set(key, entry);
        req.log.info({ uuid, agent: runtime.agent, cwd, resume: !!sessionInfo }, 'run: created');

        session.pushUserMessage(body.text);
        consumeRun(runtime.agent, key, uuid, entry, req.log).catch(() => {});

        return { ok: true };
      }

      const run = await provider.startTurn({
        cwd,
        sessionId: providerSessionId,
        text: body.text,
        runtime: runtime as never,
        deviceId,
      });
      const actualSessionId = run.sessionId ?? providerSessionId;
      sessionAliases.set(key, actualSessionId);
      const entry: RunEntry = {
        agent: runtime.agent,
        uuid,
        sessionId: actualSessionId,
        run,
        buffer: new EventBuffer(2000),
        askRegistry: new AskUserQuestionRegistry(),
        writers: new Set(),
        resultReceived: false,
        holderDeviceId: deviceId,
      };
      activeRuns.set(key, entry);
      req.log.info({ uuid, agent: runtime.agent, cwd }, 'run: created');
      consumeRun(runtime.agent, key, uuid, entry, req.log).catch(() => {});
      return { ok: true };
    },
  );

  /**
   * GET /chat/events?uuid=&lastEventId= — subscribe to (or reconnect to) an active run's SSE stream.
   *
   * 404 if no active run for uuid.
   * 412 if lastEventId is too old (event gap).
   */
  app.get<{ Querystring: { uuid?: string; agent?: AgentKind; lastEventId?: string } }>(
    '/chat/events',
    (req, reply) => {
      const uuid = req.query.uuid;
      if (!uuid) { reply.code(400); return reply.send({ error: 'uuid required' }); }
      const agent = req.query.agent ?? 'claude';

      const entry = activeRuns.get(runKey(agent, uuid));
      if (!entry) {
        req.log.warn({ uuid, agent }, 'sse: 404 no active run');
        reply.code(404); return reply.send({ error: 'no active run' });
      }

      const lastIdHeader = (req.headers['last-event-id'] as string | undefined) ?? req.query.lastEventId;
      const lastId = lastIdHeader ? parseInt(lastIdHeader, 10) : 0;
      if (lastId > 0) {
        const probe = entry.buffer.since(lastId);
        if (probe === null) {
          req.log.warn({ uuid, agent, lastId }, 'sse: 412 event gap');
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
      req.log.info({ uuid, agent, lastId, replayCount, writers: entry.writers.size }, 'sse: client connected');

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
        req.log.info({ uuid, agent, writers: entry.writers.size }, 'sse: client disconnected');
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
  app.get<{ Querystring: { uuid?: string; agent?: AgentKind } }>(
    '/chat/status',
    async (req, reply) => {
      const uuid = req.query.uuid;
      if (!uuid) { reply.code(400); return { error: 'uuid required' }; }
      const agent = req.query.agent ?? 'claude';

      const entry = activeRuns.get(runKey(agent, uuid));
      if (entry) {
        return { state: entry.resultReceived ? 'done' : 'live' };
      }
      if (agent !== 'claude') return { state: 'unknown' };
      const holder = await findHolder(uuid).catch(() => null);
      if (holder) {
        return { state: 'running', holder };
      }
      return { state: 'unknown' };
    },
  );

  /** POST /chat/interrupt — interrupt the active run for a session. */
  app.post<{ Body: { uuid?: string; agent?: AgentKind } }>('/chat/interrupt', async (req, reply) => {
    const uuid = req.body?.uuid;
    const agent = req.body?.agent ?? 'claude';
    if (!uuid) { reply.code(400); return { error: 'uuid required' }; }
    const entry = activeRuns.get(runKey(agent, uuid));
    if (!entry) { reply.code(404); return { error: 'no active run' }; }
    await (entry.run?.interrupt() ?? entry.session?.interrupt());
    return { ok: true };
  });

  app.post<{ Body: { uuid?: string; agent?: AgentKind; runtime?: Partial<AgentRuntime> } }>(
    '/chat/runtime',
    async (req, reply) => {
      const uuid = req.body?.uuid;
      if (!uuid) { reply.code(400); return { error: 'uuid required' }; }
      let parsed: ReturnType<typeof parseRuntimePatchForAgent>;
      try {
        parsed = parseRuntimePatchForAgent(req.body?.agent, req.body?.runtime);
      } catch (err) {
        reply.code(400);
        return { error: (err as Error).message };
      }
      const { agent, patch: runtime } = parsed;
      const entry = activeRuns.get(runKey(agent, uuid));
      if (!entry) { reply.code(404); return { error: 'no active run' }; }
      if (entry.run?.setRuntime) {
        await entry.run.setRuntime(runtime);
        return { ok: true };
      }
      if (!entry.session) { reply.code(400); return { error: 'runtime switch is not supported for this run' }; }
      if ('model' in runtime && runtime.model) await entry.session.setModel(runtime.model);
      if ('permission_mode' in runtime && runtime.permission_mode) {
        await entry.session.setPermissionMode(runtime.permission_mode);
      }
      return { ok: true };
    },
  );

  /** POST /chat/model — change model mid-run. */
  app.post<{ Body: { uuid?: string; model?: string } }>(
    '/chat/model',
    async (req, reply) => {
      const { uuid, model } = req.body ?? {};
      if (!uuid) { reply.code(400); return { error: 'uuid required' }; }
      if (!model) { reply.code(400); return { error: 'model required' }; }
      const entry = activeRuns.get(runKey('claude', uuid));
      if (!entry) { reply.code(404); return { error: 'no active run' }; }
      if (!entry.session) { reply.code(400); return { error: 'model switch is only available for claude sessions' }; }
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
      const entry = activeRuns.get(runKey('claude', uuid));
      if (!entry) { reply.code(404); return { error: 'no active run' }; }
      if (!entry.session) { reply.code(400); return { error: 'permission switch is only available for claude sessions' }; }
      await entry.session.setPermissionMode(mode);
      return { ok: true };
    },
  );

  /**
   * POST /chat/takeover — take over a session from another holder.
   *
   * If there is an active run (mobile device holding it): interrupt the run and
   * transfer holderDeviceId to the requesting device.
   * If only a pid.json holder (PC CLI): send SIGTERM and wait.
   *
   * Returns 200 { ok: true } if the session is now free to use.
   * Returns 409 if the holder could not be stopped within 3 s.
   */
  app.post<{ Body: { uuid?: string; device_id?: string } }>('/chat/takeover', async (req, reply) => {
    const uuid = req.body?.uuid;
    const deviceId = req.body?.device_id ?? 'unknown';
    if (!uuid) { reply.code(400); return { error: 'uuid required' }; }

    // Case 1: active run held by another mobile device → interrupt + transfer ownership
    const entry = activeRuns.get(runKey('claude', uuid));
    if (entry && entry.holderDeviceId && entry.holderDeviceId !== deviceId) {
      await (entry.run?.interrupt() ?? entry.session?.interrupt());
      entry.holderDeviceId = deviceId;
      entry.resultReceived = false;
      entry.buffer = new EventBuffer(2000);
      return { ok: true };
    }

    // Case 2: PC CLI holding via pid.json → SIGTERM
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
      const entry = activeRuns.get(runKey('claude', uuid));
      if (!entry) { reply.code(404); return { error: 'no active run' }; }
      if (!entry.session) { reply.code(400); return { error: 'context usage is only available for claude sessions' }; }
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
      const entry = activeRuns.get(runKey('claude', uuid));
      if (!entry) { reply.code(404); return { error: 'no active run' }; }
      if (!entry.session) { reply.code(400); return { error: 'answers are only available for claude sessions' }; }
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
  return activeRuns.get(runKey('claude', uuid));
}

/** @deprecated Use getRunEntry. */
export const getSessionEntry = getRunEntry;
