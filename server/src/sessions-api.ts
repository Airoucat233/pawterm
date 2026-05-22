import {
  getSessionInfo,
} from '@anthropic-ai/claude-agent-sdk';
import type { FastifyInstance } from 'fastify';

import { isPathAllowed } from './config.js';
import { findAllHolders } from './holder-detect.js';
import { getActiveRunHolder } from './chat-rest.js';
import { AgentRegistry } from './agents/registry.js';
import { ClaudeAgentProvider } from './agents/claude/provider.js';
import { ClaudeSessions } from './agents/claude/sessions.js';
import { parseAgentQuery } from './agents/http-helpers.js';

function requirePath(cwd: string | undefined): string {
  if (!cwd) throw new Error('missing cwd');
  if (!isPathAllowed(cwd)) throw new Error(`Path not allowed: ${cwd}`);
  return cwd;
}

export async function registerSessionsApi(app: FastifyInstance, deps?: {
  registry?: AgentRegistry;
}): Promise<void> {
  const claudeSessions = new ClaudeSessions();
  const registry = deps?.registry ?? new AgentRegistry([
    new ClaudeAgentProvider({
      sessionHolderFor: async () => {
        // 一次性扫描 ~/.claude/sessions/ 获取所有 PC CLI 持有者。
        // 优先用 activeRun 的 holderDeviceId（移动端持有），其次才看 pid.json（PC CLI）。
        const allHolders = await findAllHolders();
        return (sessionId) => {
          const activeHolder = getActiveRunHolder(sessionId);
          if (activeHolder) return activeHolder;
          if (allHolders.has(sessionId)) return 'server';
          return null;
        };
      },
    }),
  ]);

  /**
   * List sessions for a given working directory.
   * The SDK returns all sessions globally (the `dir` filter is loose), so we
   * filter strictly to sessions whose cwd matches the requested path.
   */
  app.get<{
    Querystring: { cwd: string; limit?: string; offset?: string; include_subdirs?: string; agent?: string };
  }>('/sessions', async (req) => {
    const cwd = requirePath(req.query.cwd);
    const limit = req.query.limit ? Number(req.query.limit) : 200;
    const offset = req.query.offset ? Number(req.query.offset) : 0;
    const includeSubdirs = req.query.include_subdirs === 'true';
    const agent = parseAgentQuery(req.query.agent, { allowAll: true });

    if (agent === 'all') {
      const infos = await registry.listInfos();
      const readyAgents = infos.filter((i) => i.status === 'ready').map((i) => i.kind);
      const candidateLimit = offset + limit;
      const pages = await Promise.all(
        readyAgents.map((kind) => registry.resolve(kind).listSessions({
          cwd,
          limit: candidateLimit,
          offset: 0,
          includeSubdirs,
        })),
      );
      return pages
        .flat()
        .sort((a, b) => (b.last_modified ?? 0) - (a.last_modified ?? 0))
        .slice(offset, offset + limit);
    }

    return registry.resolve(agent).listSessions({ cwd, limit, offset, includeSubdirs });
  });

  app.get<{ Params: { id: string }; Querystring: { cwd: string } }>(
    '/sessions/:id',
    async (req, reply) => {
      const cwd = requirePath(req.query.cwd);
      const info = await getSessionInfo(req.params.id, { dir: cwd });
      if (!info) {
        reply.code(404);
        return { detail: 'Session not found' };
      }
      return info;
    },
  );

  /**
   * Paginated session messages — reverse-infinite-scroll friendly.
   *
   *   GET /sessions/:id/messages?cwd=...&limit=50
   *     → 最后 50 条（首屏），按 chronological order 升序。
   *
   *   GET /sessions/:id/messages?cwd=...&limit=50&before_uuid=<uuid>
   *     → 找到该 uuid 在完整链中的位置，取它**前面**的 50 条。
   *
   * 响应：
   *   { messages: [...], has_more: boolean, total: number }
   *
   * SDK 的 getSessionMessages(offset/limit) 是从开头算 offset，
   * 而我们需要"最近 N 条"语义；最稳妥的方式是先一次读全（JSONL parse 快、
   * 本地磁盘），再在内存里 slice。1000 条以内毫秒级。
   */
  app.get<{
    Params: { id: string };
    Querystring: { cwd: string; limit?: string; before_uuid?: string; agent?: string };
  }>('/sessions/:id/messages', async (req) => {
    const cwd = requirePath(req.query.cwd);
    const limit = req.query.limit ? Math.max(1, Math.min(500, Number(req.query.limit))) : 50;
    const beforeUuid = req.query.before_uuid;
    const agent = parseAgentQuery(req.query.agent);

    return registry.resolve(agent).getSessionMessages({ cwd, sessionId: req.params.id, limit, beforeUuid });
  });

  app.post<{
    Params: { id: string };
    Querystring: { cwd: string; title: string };
  }>('/sessions/:id/rename', async (req) => {
    const cwd = requirePath(req.query.cwd);
    await claudeSessions.rename({ cwd, sessionId: req.params.id, title: req.query.title });
    return { ok: true };
  });

  app.post<{
    Params: { id: string };
    Querystring: { cwd: string; tag: string };
  }>('/sessions/:id/tag', async (req) => {
    const cwd = requirePath(req.query.cwd);
    await claudeSessions.tag({ cwd, sessionId: req.params.id, tag: req.query.tag });
    return { ok: true };
  });

  app.post<{
    Params: { id: string };
    Querystring: { cwd: string; title?: string };
  }>('/sessions/:id/fork', async (req) => {
    const cwd = requirePath(req.query.cwd);
    return claudeSessions.fork({ cwd, sessionId: req.params.id, title: req.query.title });
  });

  app.delete<{ Params: { id: string }; Querystring: { cwd: string } }>(
    '/sessions/:id',
    async (req) => {
      const cwd = requirePath(req.query.cwd);
      await claudeSessions.delete({ cwd, sessionId: req.params.id });
      return { ok: true };
    },
  );

  /**
   * GET /sessions/:uuid/raw-history — Read full jsonl directly, bypassing SDK.
   * Returns all messages including pre-compact history.
   *
   * Query: cwd (required), limit (default 50), before_uuid (cursor for older pages)
   *
   * Response: same shape as /sessions/:id/messages
   * { messages: [...], has_more: boolean, total: number }
   */
  app.get<{
    Params: { id: string };
    Querystring: { cwd: string; limit?: string; before_uuid?: string; agent?: string };
  }>('/sessions/:id/raw-history', async (req, reply) => {
    const cwd = requirePath(req.query.cwd);
    const limit = req.query.limit ? Math.max(1, Math.min(500, Number(req.query.limit))) : 50;
    const beforeUuid = req.query.before_uuid;
    const agent = parseAgentQuery(req.query.agent);

    if (agent !== 'claude') {
      reply.code(400);
      return { error: 'raw-history is only available for claude sessions' };
    }

    try {
      return await claudeSessions.rawHistory({ cwd, sessionId: req.params.id, limit, beforeUuid });
    } catch (err) {
      if ((err as { statusCode?: number }).statusCode !== 404) throw err;
      reply.code(404);
      return { error: 'session file not found' };
    }
  });
}
