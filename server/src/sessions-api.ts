import {
  deleteSession,
  forkSession,
  getSessionInfo,
  getSessionMessages,
  listSessions,
  renameSession,
  tagSession,
  type SDKSessionInfo,
  type SessionMessage,
} from '@anthropic-ai/claude-agent-sdk';
import type { FastifyInstance } from 'fastify';

import type { SessionSummary } from '@cc/shared';

import { isPathAllowed } from './config.js';
import { findHolder } from './holder-detect.js';
import { messageToWire } from './serialize.js';

function requirePath(cwd: string | undefined): string {
  if (!cwd) throw new Error('missing cwd');
  if (!isPathAllowed(cwd)) throw new Error(`Path not allowed: ${cwd}`);
  return cwd;
}

function toSummary(s: SDKSessionInfo): SessionSummary {
  return {
    session_id: s.sessionId,
    summary: s.summary ?? s.firstPrompt ?? null,
    title: s.customTitle ?? null,
    tags: s.tag ? [s.tag] : [],
    last_modified: s.lastModified ?? null,
    cwd: s.cwd ?? null,
    num_messages: null,
    total_cost_usd: null,
  };
}

export async function registerSessionsApi(app: FastifyInstance): Promise<void> {
  /**
   * List sessions for a given working directory.
   * The SDK returns all sessions globally (the `dir` filter is loose), so we
   * filter strictly to sessions whose cwd matches the requested path.
   */
  app.get<{
    Querystring: { cwd: string; limit?: string; offset?: string; include_subdirs?: string };
  }>('/sessions', async (req) => {
    const cwd = requirePath(req.query.cwd);
    const limit = req.query.limit ? Number(req.query.limit) : 200;
    const offset = req.query.offset ? Number(req.query.offset) : 0;
    const includeSubdirs = req.query.include_subdirs === 'true';

    // SDK 的 listSessions 是全局返回 + dir 过滤"松散"，且单次有 1000 条隐含上限。
    // 这里循环 offset 拉满，避免重度用户的老 session 被切掉。
    const all: SDKSessionInfo[] = [];
    const pageSize = 1000;
    for (let off = 0; ; off += pageSize) {
      const page = await listSessions({ dir: cwd, limit: pageSize, offset: off });
      all.push(...page);
      if (page.length < pageSize) break;
    }
    const filtered = all.filter((s) => {
      const sCwd = s.cwd ?? '';
      if (!sCwd) return false;
      if (sCwd === cwd) return true;
      if (includeSubdirs && sCwd.startsWith(cwd + '/')) return true;
      return false;
    });
    return filtered.slice(offset, offset + limit).map(toSummary);
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
   * 检测 sessionId 是否正被某个 claude CLI 进程持有。
   * 返回 { holder } —— 命中时 holder 是 { pid, cwd, startedAt, kind }，否则 null。
   * 客户端在 resume 前先调一次，命中则提示用户「接管 / 只读」二选一。
   *
   * 没有 cwd 校验：持有者本身可能在别的目录里跑（用户走错路径开了 claude）；
   * 不带 cwd 也能查得到，便于做"误开"提示。
   */
  app.get<{ Params: { id: string } }>('/sessions/:id/holder', async (req) => {
    const holder = await findHolder(req.params.id);
    return { holder };
  });

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
    Querystring: { cwd: string; limit?: string; before_uuid?: string };
  }>('/sessions/:id/messages', async (req) => {
    const cwd = requirePath(req.query.cwd);
    const limit = req.query.limit ? Math.max(1, Math.min(500, Number(req.query.limit))) : 50;
    const beforeUuid = req.query.before_uuid;

    const all: SessionMessage[] = await getSessionMessages(req.params.id, { dir: cwd });
    const total = all.length;

    let upper = total; // exclusive
    if (beforeUuid) {
      const idx = all.findIndex((m) => (m as { uuid?: string }).uuid === beforeUuid);
      if (idx > 0) upper = idx;
    }
    const lower = Math.max(0, upper - limit);
    const slice = all.slice(lower, upper);

    return {
      messages: slice.map((sm) => {
        const rawTs = (sm as { timestamp?: string | number }).timestamp;
        const ts =
          typeof rawTs === 'string' ? Date.parse(rawTs) :
          typeof rawTs === 'number' ? rawTs :
          null;
        const wire = messageToWire(sm);
        return {
          uuid: (sm as { uuid?: string }).uuid ?? null,
          parent_uuid: (sm as { parent_uuid?: string }).parent_uuid ?? null,
          timestamp: ts,
          message: wire ? { ...wire, timestamp: ts ?? undefined } : sm,
        };
      }),
      has_more: lower > 0,
      total,
    };
  });

  app.post<{
    Params: { id: string };
    Querystring: { cwd: string; title: string };
  }>('/sessions/:id/rename', async (req) => {
    const cwd = requirePath(req.query.cwd);
    await renameSession(req.params.id, req.query.title, { dir: cwd });
    return { ok: true };
  });

  app.post<{
    Params: { id: string };
    Querystring: { cwd: string; tag: string };
  }>('/sessions/:id/tag', async (req) => {
    const cwd = requirePath(req.query.cwd);
    await tagSession(req.params.id, req.query.tag, { dir: cwd });
    return { ok: true };
  });

  app.post<{
    Params: { id: string };
    Querystring: { cwd: string; title?: string };
  }>('/sessions/:id/fork', async (req) => {
    const cwd = requirePath(req.query.cwd);
    const result = await forkSession(req.params.id, {
      dir: cwd,
      ...(req.query.title ? { title: req.query.title } : {}),
    });
    return result;
  });

  app.delete<{ Params: { id: string }; Querystring: { cwd: string } }>(
    '/sessions/:id',
    async (req) => {
      const cwd = requirePath(req.query.cwd);
      await deleteSession(req.params.id, { dir: cwd });
      return { ok: true };
    },
  );
}
