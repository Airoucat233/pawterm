import {
  deleteSession,
  forkSession,
  getSessionMessages,
  listSessions,
  renameSession,
  tagSession,
  type SDKSessionInfo,
  type SessionMessage,
} from '@anthropic-ai/claude-agent-sdk';
import type { SessionSummary } from '@pawterm/shared';

import { readFile, access, readdir, open } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join } from 'node:path';

import type { AgentHistoryPage } from '../types.js';
import { messageToWire } from './serialize.js';

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

function toSummary(s: SDKSessionInfo, holderDeviceId: string | null = null): SessionSummary {
  return {
    agent: 'claude',
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

function timestampOf(input: { timestamp?: string | number }): number | null {
  const rawTs = input.timestamp;
  return typeof rawTs === 'string' ? Date.parse(rawTs) :
    typeof rawTs === 'number' ? rawTs :
    null;
}

function withClaudeAgent(wire: any, timestamp: number | null): any {
  return { ...wire, agent: 'claude' as const, timestamp: timestamp ?? undefined };
}

async function readClaudeRawHistory(input: {
  cwd: string;
  sessionId: string;
  limit: number;
  beforeUuid?: string;
}): Promise<AgentHistoryPage> {
  const filePath = await resolveJsonlPath(input.sessionId, input.cwd);
  if (!filePath) {
    const error = new Error('session file not found');
    (error as Error & { statusCode?: number }).statusCode = 404;
    throw error;
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

  const parsed: AgentHistoryPage['messages'] = [];
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

    const ts = timestampOf(entry);
    const wire = messageToWire(entry);
    parsed.push({
      uuid: entry.uuid ?? null,
      parent_uuid: entry.parent_uuid ?? null,
      timestamp: ts,
      message: wire ? withClaudeAgent(wire, ts) : entry,
    });
  }

  const total = parsed.length;
  let upper = total;
  if (input.beforeUuid) {
    const idx = parsed.findIndex((m) => m.uuid === input.beforeUuid);
    if (idx > 0) upper = idx;
  }
  const lower = Math.max(0, upper - input.limit);
  const slice = parsed.slice(lower, upper);

  return { messages: slice, has_more: lower > 0, total };
}

export class ClaudeSessions {
  async list(input: {
    cwd: string;
    limit: number;
    offset: number;
    includeSubdirs: boolean;
    holderFor: (sessionId: string) => string | null;
  }): Promise<SessionSummary[]> {
    // SDK 的 listSessions 是全局返回 + dir 过滤"松散"，且单次有 1000 条隐含上限。
    // 这里循环 offset 拉满，避免重度用户的老 session 被切掉。
    const all: SDKSessionInfo[] = [];
    const pageSize = 1000;
    for (let off = 0; ; off += pageSize) {
      const page = await listSessions({ dir: input.cwd, limit: pageSize, offset: off });
      all.push(...page);
      if (page.length < pageSize) break;
    }
    const byCwd = all.filter((s) => {
      const sCwd = s.cwd ?? '';
      if (!sCwd) return false;
      if (sCwd === input.cwd) return true;
      if (input.includeSubdirs && sCwd.startsWith(input.cwd + '/')) return true;
      return false;
    });
    // Filter out sidechain (sub-agent) sessions that leaked through SDK's first-line-only check.
    const page = byCwd.slice(input.offset, input.offset + input.limit);
    const result: SDKSessionInfo[] = [];
    for (const s of page) {
      const jsonlPath = await resolveJsonlPath(s.sessionId, s.cwd ?? input.cwd);
      if (jsonlPath && await isSidechainSession(jsonlPath)) continue;
      result.push(s);
    }
    return result.map((s) => toSummary(s, input.holderFor(s.sessionId)));
  }

  async messages(input: {
    cwd: string;
    sessionId: string;
    limit: number;
    beforeUuid?: string;
  }): Promise<AgentHistoryPage> {
    const all: SessionMessage[] = await getSessionMessages(input.sessionId, { dir: input.cwd });
    const total = all.length;

    let upper = total; // exclusive
    if (input.beforeUuid) {
      const idx = all.findIndex((m) => (m as { uuid?: string }).uuid === input.beforeUuid);
      if (idx > 0) upper = idx;
    }
    const lower = Math.max(0, upper - input.limit);
    const slice = all.slice(lower, upper);

    return {
      messages: slice.map((sm) => {
        const ts = timestampOf(sm as { timestamp?: string | number });
        const wire = messageToWire(sm);
        return {
          uuid: (sm as { uuid?: string }).uuid ?? null,
          parent_uuid: (sm as { parent_uuid?: string }).parent_uuid ?? null,
          timestamp: ts,
          message: wire ? withClaudeAgent(wire, ts) : sm,
        };
      }),
      has_more: lower > 0,
      total,
    };
  }

  async rawHistory(input: {
    cwd: string;
    sessionId: string;
    limit: number;
    beforeUuid?: string;
  }): Promise<AgentHistoryPage> {
    return readClaudeRawHistory(input);
  }

  async rename(input: { cwd: string; sessionId: string; title: string }): Promise<void> {
    await renameSession(input.sessionId, input.title, { dir: input.cwd });
  }

  async tag(input: { cwd: string; sessionId: string; tag: string }): Promise<void> {
    await tagSession(input.sessionId, input.tag, { dir: input.cwd });
  }

  async fork(input: { cwd: string; sessionId: string; title?: string }): Promise<{ session_id: string | null }> {
    const result = await forkSession(input.sessionId, {
      dir: input.cwd,
      ...(input.title ? { title: input.title } : {}),
    });
    const forked = result as { sessionId?: string; session_id?: string };
    return { session_id: forked.sessionId ?? forked.session_id ?? null };
  }

  async delete(input: { cwd: string; sessionId: string }): Promise<void> {
    await deleteSession(input.sessionId, { dir: input.cwd });
  }
}
