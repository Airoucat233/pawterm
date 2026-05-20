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

import type { SessionSummary } from '@pawterm/shared';

import { isPathAllowed } from './config.js';
import { messageToWire } from './serialize.js';
import { findAllHolders } from './holder-detect.js';
import { getActiveRunHolder } from './chat-rest.js';

import { readFile, access, readdir, open } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join } from 'node:path';

/** Mirrors claude-code's sanitizePath: replace non-alphanumeric chars with '-'. */
function sanitizePathLocal(p: string): string {
  return p.replace(/[^a-zA-Z0-9]/g, '-');
}

function localProjectsDir(): string {
  return join(homedir(), '.claude', 'projects');
}

/**
 * Resolve jsonl path for a session. Tries exact match first, then prefix scan.
 */
async function resolveJsonlPath(uuid: string, cwd: string): Promise<string | null> {
  const exact = join(localProjectsDir(), sanitizePathLocal(cwd), `${uuid}.jsonl`);
  try {
    await access(exact);
    return exact;
  } catch {
    // Fall back: scan all dirs under ~/.claude/projects for prefix match.
    const prefix = sanitizePathLocal(cwd).slice(0, 200);
    let entries: string[];
    try {
      entries = await readdir(localProjectsDir());
    } catch {
      return null;
    }
    for (const name of entries) {
      if (name === sanitizePathLocal(cwd) || name.startsWith(prefix + '-')) {
        const candidate = join(localProjectsDir(), name, `${uuid}.jsonl`);
        try {
          await access(candidate);
          return candidate;
        } catch {
          continue;
        }
      }
    }
    return null;
  }
}

// Mirror the SDK's LITE_READ_BUF_SIZE (sessionStoragePortable.ts).
const LITE_READ_BUF_SIZE = 65536;

/**
 * Read the first 64KB of a session jsonl (same as the SDK's head read) and
 * check whether any line contains `"isSidechain":true`.
 *
 * The SDK itself only checks the very first line, but sessions that start with
 * queue-operation entries can have isSidechain on a later line. Reading the
 * full head catches those. String-match (not JSON.parse) mirrors the SDK.
 */
async function isSidechainSession(filePath: string): Promise<boolean> {
  let fd: Awaited<ReturnType<typeof open>> | undefined;
  try {
    fd = await open(filePath, 'r');
    const buf = Buffer.allocUnsafe(LITE_READ_BUF_SIZE);
    const { bytesRead } = await fd.read(buf, 0, LITE_READ_BUF_SIZE, 0);
    const head = buf.subarray(0, bytesRead).toString('utf-8');
    return head.includes('"isSidechain":true') || head.includes('"isSidechain": true');
  } catch {
    return false;
  } finally {
    await fd?.close().catch(() => {});
  }
}

function requirePath(cwd: string | undefined): string {
  if (!cwd) throw new Error('missing cwd');
  if (!isPathAllowed(cwd)) throw new Error(`Path not allowed: ${cwd}`);
  return cwd;
}

function toSummary(s: SDKSessionInfo, holderDeviceId: string | null = null): SessionSummary {
  return {
    session_id: s.sessionId,
    summary: s.summary ?? s.firstPrompt ?? null,
    title: s.customTitle ?? null,
    tags: s.tag ? [s.tag] : [],
    last_modified: s.lastModified ?? null,
    cwd: s.cwd ?? null,
    num_messages: null,
    total_cost_usd: null,
    holder_device_id: holderDeviceId,
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
    const byCwd = all.filter((s) => {
      const sCwd = s.cwd ?? '';
      if (!sCwd) return false;
      if (sCwd === cwd) return true;
      if (includeSubdirs && sCwd.startsWith(cwd + '/')) return true;
      return false;
    });
    // Filter out sidechain (sub-agent) sessions that leaked through SDK's first-line-only check.
    const page = byCwd.slice(offset, offset + limit);
    const result: SDKSessionInfo[] = [];
    for (const s of page) {
      const jsonlPath = await resolveJsonlPath(s.sessionId, s.cwd ?? cwd);
      if (jsonlPath && await isSidechainSession(jsonlPath)) continue;
      result.push(s);
    }
    // 一次性扫描 ~/.claude/sessions/ 获取所有 PC CLI 持有者。
    // 优先用 activeRun 的 holderDeviceId（移动端持有），其次才看 pid.json（PC CLI）。
    const allHolders = await findAllHolders();
    return result.map((s) => {
      const activeHolder = getActiveRunHolder(s.sessionId);
      if (activeHolder) return toSummary(s, activeHolder);
      if (allHolders.has(s.sessionId)) return toSummary(s, 'server');
      return toSummary(s, null);
    });
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
    Querystring: { cwd: string; limit?: string; before_uuid?: string };
  }>('/sessions/:id/raw-history', async (req, reply) => {
    const cwd = requirePath(req.query.cwd);
    const uuid = req.params.id;
    const limit = req.query.limit ? Math.max(1, Math.min(500, Number(req.query.limit))) : 50;
    const beforeUuid = req.query.before_uuid;

    const filePath = await resolveJsonlPath(uuid, cwd);
    if (!filePath) {
      reply.code(404);
      return { error: 'session file not found' };
    }

    const raw = await readFile(filePath, 'utf-8');
    const lines = raw.split('\n').filter((l) => l.trim().length > 0);

    type RawEntry = {
      uuid?: string;
      parent_uuid?: string;
      timestamp?: string | number;
      message?: unknown;
      isSidechain?: boolean;
      isMeta?: boolean;
      type?: string;
      [k: string]: unknown;
    };

    const parsed: Array<{ uuid: string | null; parent_uuid: string | null; timestamp: number | null; message: unknown }> = [];
    for (const line of lines) {
      let entry: RawEntry;
      try {
        entry = JSON.parse(line) as RawEntry;
      } catch {
        continue;
      }
      // Skip sidechain, meta-injections (isMeta=true, e.g. skill content), and non-conversation entries.
      if (entry.isSidechain) continue;
      if ((entry as any).isMeta) continue;
      const t = entry.type;
      if (t !== 'user' && t !== 'assistant' && t !== 'result') continue;
      // Skip user messages that are only tool_results (no human text).
      if (t === 'user') {
        const msg = entry.message as { content?: unknown } | undefined;
        const content = msg?.content;
        if (Array.isArray(content) && content.every((b: { type?: string }) => b.type === 'tool_result')) continue;
      }

      const rawTs = entry.timestamp;
      const ts =
        typeof rawTs === 'string' ? Date.parse(rawTs) :
        typeof rawTs === 'number' ? rawTs :
        null;

      const wire = messageToWire(entry);
      parsed.push({
        uuid: entry.uuid ?? null,
        parent_uuid: entry.parent_uuid ?? null,
        timestamp: ts,
        message: wire ? { ...wire, timestamp: ts ?? undefined } : entry,
      });
    }

    const total = parsed.length;
    let upper = total;
    if (beforeUuid) {
      const idx = parsed.findIndex((m) => m.uuid === beforeUuid);
      if (idx > 0) upper = idx;
    }
    const lower = Math.max(0, upper - limit);
    const slice = parsed.slice(lower, upper);

    return { messages: slice, has_more: lower > 0, total };
  });
}
