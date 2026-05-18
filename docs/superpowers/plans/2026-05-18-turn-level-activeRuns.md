# Turn-Level activeRuns Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把服务端从"跨多轮长连接 session"改为"每条消息一个独立 turn"，用 Claude UUID 作为唯一标识，消除随机 server session ID；同时新增 raw-history 接口（绕过 SDK 读完整 jsonl）和对话框顶部 UUID 显示。

**Architecture:**
- 服务端 `activeRuns Map<claudeUUID, RunEntry>` 仅在 turn 存活期间有值，turn 结束 + grace 超时后清空，两次 turn 之间服务端零状态。
- Flutter 侧生成 UUID（新建会话）或沿用 `currentSession.resumeId`（resume 已有会话），存入 SharedPreferences；SSE URL 直接使用 `GET /chat/:uuid/events`。
- `raw-history` 直接读 jsonl 文件，返回 compact_boundary 之前的历史消息，分页格式与现有 `/sessions/:id/messages` 相同。

**Tech Stack:** TypeScript/Fastify (server), Dart/Flutter (app), @anthropic-ai/claude-agent-sdk, shared_preferences ^2.3.2, uuid ^4.5.3

---

## File Map

| 文件 | 改动 | 主要内容 |
|---|---|---|
| `server/src/chat-rest.ts` | 大改（原地重写） | activeRuns、新 API、grace 时机、status 接口 |
| `server/src/session-manager.ts` | 小改 | 新增 `sessionId?` constructor 选项 |
| `server/src/sessions-api.ts` | 小改 | 新增 `GET /sessions/:uuid/raw-history` |
| `app/lib/api/chat_api.dart` | 重写 | 新 API 形状（turn/status，去掉 start/message） |
| `app/lib/screens/tabs/chat_tab.dart` | 中等改 | UUID 作为 key、持久化、SSE 连接时机、UUID 显示 |
| `app/lib/state/projects_store.dart` | 无改 | resumeId 语义已是 Claude UUID，不需要改 |

---

## Task 1: session-manager.ts — 新增 sessionId 选项

**Files:**
- Modify: `server/src/session-manager.ts`

- [ ] **Step 1: 在构造参数中加 `sessionId?`，并传给 SDK**

在 `ChatSession` constructor 和 `start()` 里加 `sessionId` 支持：

```typescript
// constructor opts interface (add field):
constructor(opts: {
  cwd: string;
  permissionMode: PermissionMode;
  resume?: string;
  sessionId?: string;   // ← new: for new sessions where client provides UUID
  model?: string;
  askRegistry: AskUserQuestionRegistry;
}) {
  this.cwd = opts.cwd;
  this.permissionMode = opts.permissionMode;
  this.resume = opts.resume;
  this.sessionId = opts.sessionId;   // ← store it
  this.model = opts.model;
  this.askRegistry = opts.askRegistry;
}
```

在 `start()` 里，`resume` 和 `sessionId` 互斥传给 SDK：

```typescript
start(): AsyncIterableIterator<any> {
  const bypassing = this.permissionMode === 'bypassPermissions';
  const options: Options = {
    cwd: this.cwd,
    permissionMode: this.permissionMode,
    includePartialMessages: true,
    forwardSubagentText: true,
    mcpServers: {
      'ask-user-question': makeAskUserMcpServer(this.askRegistry),
    },
    ...(bypassing ? { allowDangerouslySkipPermissions: true } : {}),
    // resume takes priority; sessionId is for brand-new sessions only
    ...(this.resume
      ? { resume: this.resume }
      : this.sessionId
        ? { sessionId: this.sessionId }
        : {}),
    ...(this.model ? { model: this.model } : {}),
  };
  this.iter = query({ prompt: this.inputGen.call(this), options });
  return this.iter as unknown as AsyncIterableIterator<any>;
}
```

Also add `readonly sessionId?: string;` as a class field alongside the existing `readonly resume?: string;`.

- [ ] **Step 2: Build check**

```bash
cd /Users/airoucat/workspace/shulex/claude-companion/server
npm run build 2>&1 | tail -20
```

Expected: 0 errors.

- [ ] **Step 3: Commit**

```bash
cd /Users/airoucat/workspace/shulex/claude-companion
git add server/src/session-manager.ts
git commit -m "feat(session-manager): add sessionId option for client-provided UUID on new sessions"
```

---

## Task 2: chat-rest.ts — 重写为 turn-level activeRuns

**Files:**
- Modify: `server/src/chat-rest.ts`

这是改动最大的一步。完整替换文件内容。

- [ ] **Step 1: 替换 chat-rest.ts**

用下面内容完整替换（保留所有现有功能，但重构为 turn-level）：

```typescript
import type { FastifyInstance } from 'fastify';
import { resolve } from 'node:path';
import { getSessionInfo } from '@anthropic-ai/claude-agent-sdk';

import type { AnswerQuestionRequest, PermissionMode } from '@cc/shared';

import { isPathAllowed, settings } from './config.js';
import { AskUserQuestionRegistry } from './ask-user-tool.js';
import { EventBuffer } from './event-buffer.js';
import { findHolder } from './holder-detect.js';
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

function startGrace(uuid: string, entry: RunEntry): void {
  if (entry.graceTimer) return;
  entry.graceTimer = setTimeout(() => {
    closeRun(uuid);
  }, GRACE_MS);
}

function closeRun(uuid: string): void {
  const entry = activeRuns.get(uuid);
  if (!entry) return;
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

async function consumeSdk(uuid: string, entry: RunEntry): Promise<void> {
  try {
    const iter = entry.session.start();
    for await (const sdkMsg of iter) {
      const wire = messageToWire(sdkMsg);
      if (wire) {
        const stamped = { ...wire, timestamp: Date.now() };
        maybeSetPendingToolUseId(wire, entry.askRegistry);
        broadcast(entry, (wire as { type: string }).type, stamped);
        // When result arrives: mark it and start grace timer.
        // The run stays in activeRuns during grace so reconnects can replay.
        if ((wire as { type: string }).type === 'result') {
          entry.resultReceived = true;
          startGrace(uuid, entry);
        }
      }
    }
  } catch (err) {
    broadcast(entry, 'error', { type: 'error', message: (err as Error).message });
    entry.resultReceived = true;
    startGrace(uuid, entry);
  } finally {
    // If consumeSdk ends without a result (e.g. session.close() called before
    // SDK emitted result), make sure grace starts so we don't leak the entry.
    if (!entry.resultReceived) {
      entry.resultReceived = true;
      startGrace(uuid, entry);
    }
  }
}

export async function registerChatRest(app: FastifyInstance): Promise<void> {
  /**
   * Start a new turn. Creates a fresh RunEntry for the given Claude UUID.
   *
   * Body: { cwd, text, model?, permission_mode? }
   *
   * - If uuid already has an active run → 409
   * - If session exists on disk (getSessionInfo finds it) → resume: uuid
   * - If not → sessionId: uuid  (new session with client-provided UUID)
   */
  app.post<{
    Params: { uuid: string };
    Body: { cwd?: string; text?: string; model?: string; permission_mode?: PermissionMode };
  }>(
    '/chat/:uuid/turn',
    async (req, reply) => {
      const { uuid } = req.params;
      const body = req.body ?? {};

      if (!body.cwd) { reply.code(400); return { error: 'cwd required' }; }
      if (!body.text) { reply.code(400); return { error: 'text required' }; }

      const cwd = resolve(body.cwd);
      if (!isPathAllowed(cwd)) { reply.code(403); return { error: `Project not allowed: ${cwd}` }; }

      if (activeRuns.has(uuid)) {
        reply.code(409);
        return { error: 'turn already active for this session' };
      }

      const permissionMode = body.permission_mode ?? settings.permissionMode;

      // Determine whether to resume or create new.
      const existing = await getSessionInfo(uuid, { dir: cwd });
      const askRegistry = new AskUserQuestionRegistry();
      const session = new ChatSession({
        cwd,
        permissionMode,
        ...(existing ? { resume: uuid } : { sessionId: uuid }),
        model: body.model,
        askRegistry,
      });

      const entry: RunEntry = {
        session,
        buffer: new EventBuffer(2000),   // larger buffer for long runs
        askRegistry,
        writers: new Set(),
        resultReceived: false,
      };
      activeRuns.set(uuid, entry);

      // Push the user message then start consuming.
      session.pushUserMessage(body.text);
      consumeSdk(uuid, entry).catch(() => {});

      return { ok: true };
    },
  );

  app.get<{ Params: { uuid: string }; Querystring: { lastEventId?: string } }>(
    '/chat/:uuid/events',
    (req, reply) => {
      const { uuid } = req.params;
      const entry = activeRuns.get(uuid);
      if (!entry) { reply.code(404); return reply.send({ error: 'no active turn' }); }

      const lastIdHeader = (req.headers['last-event-id'] as string | undefined) ?? req.query.lastEventId;
      const lastId = lastIdHeader ? parseInt(lastIdHeader, 10) : 0;
      if (lastId > 0) {
        const probe = entry.buffer.since(lastId);
        if (probe === null) { reply.code(412); return reply.send({ error: 'event gap, please reload' }); }
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

      // Replay missed events.
      if (lastId > 0) {
        const replay = entry.buffer.since(lastId) ?? [];
        for (const e of replay) {
          writer.write(`id: ${e.id}\nevent: ${e.type}\ndata: ${JSON.stringify(e.data)}\n\n`);
        }
      } else if (lastId === 0 && entry.buffer.newestId > 0) {
        // New subscriber: replay all buffered events from this turn.
        const all = entry.buffer.since(0) ?? [];
        for (const e of all) {
          writer.write(`id: ${e.id}\nevent: ${e.type}\ndata: ${JSON.stringify(e.data)}\n\n`);
        }
      }

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
        // NOTE: disconnecting does NOT trigger grace. Grace only starts on result.
      });

      return reply;
    },
  );

  /**
   * GET /chat/:uuid/status —叠加三信号判断 turn 状态。
   * 'live'    → activeRuns 里有，SSE 可用
   * 'done'    → grace 期内（result 已到达）或无活跃 run
   * 'unknown' → 无活跃 run 且无法判断
   */
  app.get<{ Params: { uuid: string }; Querystring: { cwd?: string } }>(
    '/chat/:uuid/status',
    async (req) => {
      const { uuid } = req.params;
      const entry = activeRuns.get(uuid);
      if (entry) {
        return { state: entry.resultReceived ? 'done' : 'live' };
      }
      // Check PID holder as secondary signal.
      const holder = await findHolder(uuid).catch(() => null);
      if (holder) {
        return { state: 'running', holder };
      }
      return { state: 'unknown' };
    },
  );

  app.post<{ Params: { uuid: string } }>('/chat/:uuid/interrupt', async (req, reply) => {
    const entry = activeRuns.get(req.params.uuid);
    if (!entry) { reply.code(404); return { error: 'no active turn' }; }
    await entry.session.interrupt();
    return { ok: true };
  });

  app.post<{ Params: { uuid: string }; Body: { model: string } }>(
    '/chat/:uuid/set-model',
    async (req, reply) => {
      const entry = activeRuns.get(req.params.uuid);
      if (!entry) { reply.code(404); return { error: 'no active turn' }; }
      await entry.session.setModel(req.body.model);
      return { ok: true };
    },
  );

  app.post<{ Params: { uuid: string }; Body: { mode: PermissionMode } }>(
    '/chat/:uuid/set-permission-mode',
    async (req, reply) => {
      const entry = activeRuns.get(req.params.uuid);
      if (!entry) { reply.code(404); return { error: 'no active turn' }; }
      await entry.session.setPermissionMode(req.body.mode);
      return { ok: true };
    },
  );

  app.post<{ Params: { uuid: string }; Body: AnswerQuestionRequest }>(
    '/chat/:uuid/answer-question',
    async (req, reply) => {
      const entry = activeRuns.get(req.params.uuid);
      if (!entry) { reply.code(404); return { error: 'no active turn' }; }
      const ok = entry.session.answerQuestion(
        req.body.tool_use_id,
        req.body.answers,
        req.body.annotations,
      );
      if (!ok) {
        app.log.warn({ toolUseId: req.body.tool_use_id }, 'answer_question: no pending tool');
      }
      return { ok };
    },
  );

  app.delete<{ Params: { uuid: string } }>('/chat/:uuid', async (req) => {
    closeRun(req.params.uuid);
    return { ok: true };
  });
}

/** Exported for AskUserQuestion wiring. */
export function getRunEntry(uuid: string): RunEntry | undefined {
  return activeRuns.get(uuid);
}

/**
 * @deprecated Use getRunEntry. Kept for backward compat with ask-user-tool.ts
 * which may reference getSessionEntry.
 */
export const getSessionEntry = getRunEntry;
```

- [ ] **Step 2: Build check**

```bash
cd /Users/airoucat/workspace/shulex/claude-companion/server
npm run build 2>&1 | tail -30
```

Expected: 0 errors. If `ask-user-tool.ts` imports `getSessionEntry`, it still works via the alias.

- [ ] **Step 3: Verify ask-user-tool.ts still compiles**

```bash
grep -n "getSessionEntry\|getRunEntry" server/src/ask-user-tool.ts
```

If it imports `getSessionEntry`, no change needed. If it uses `SessionEntry` type, update to `RunEntry`.

- [ ] **Step 4: Commit**

```bash
cd /Users/airoucat/workspace/shulex/claude-companion
git add server/src/chat-rest.ts
git commit -m "feat(chat-rest): turn-level activeRuns — UUID key, grace on result, status endpoint"
```

---

## Task 3: sessions-api.ts — 新增 raw-history 接口

**Files:**
- Modify: `server/src/sessions-api.ts`

- [ ] **Step 1: 在文件顶部加 node:fs 和 path 导入**

在现有 imports 后加：

```typescript
import { createReadStream } from 'node:fs';
import { readFile, access } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join } from 'node:path';
```

- [ ] **Step 2: 加辅助函数（放在 `requirePath` 函数之前）**

```typescript
/** Mirrors claude-code's sanitizePath: replace non-alphanumeric chars with '-'. */
function sanitizePathLocal(p: string): string {
  return p.replace(/[^a-zA-Z0-9]/g, '-');
}

function localProjectsDir(): string {
  return join(homedir(), '.claude', 'projects');
}

/**
 * Resolve jsonl path for a session. Only handles the common case (short paths).
 * Falls back to scanning the projects dir if exact match not found.
 */
async function resolveJsonlPath(uuid: string, cwd: string): Promise<string | null> {
  const exact = join(localProjectsDir(), sanitizePathLocal(cwd), `${uuid}.jsonl`);
  try {
    await access(exact);
    return exact;
  } catch {
    // Fall back: scan all dirs under ~/.claude/projects for prefix match.
    const prefix = sanitizePathLocal(cwd).slice(0, 200);
    const { readdir } = await import('node:fs/promises');
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
```

- [ ] **Step 3: 在 `registerSessionsApi` 末尾（deleteSession 之后）加 raw-history 路由**

```typescript
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

    // Parse lines into wire messages (same logic as serialize.ts but for jsonl entries).
    type RawEntry = {
      uuid?: string;
      parent_uuid?: string;
      timestamp?: string | number;
      message?: unknown;
      isSidechain?: boolean;
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
      // Skip sidechain, metadata-only, and non-conversation entries.
      if (entry.isSidechain) continue;
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
```

- [ ] **Step 4: Build check**

```bash
cd /Users/airoucat/workspace/shulex/claude-companion/server
npm run build 2>&1 | tail -20
```

Expected: 0 errors.

- [ ] **Step 5: Quick smoke test — curl**

```bash
# Get a real session UUID and cwd from your system first:
SESSION_UUID=$(ls ~/.claude/projects/-Users-airoucat-workspace-shulex-claude-companion/*.jsonl | head -1 | xargs basename | sed 's/\.jsonl//')
curl -s "http://localhost:8765/sessions/$SESSION_UUID/raw-history?cwd=/Users/airoucat/workspace/shulex/claude-companion&limit=3" | python3 -m json.tool | head -30
```

Expected: JSON with `messages`, `has_more`, `total`.

- [ ] **Step 6: Commit**

```bash
cd /Users/airoucat/workspace/shulex/claude-companion
git add server/src/sessions-api.ts
git commit -m "feat(sessions-api): add raw-history endpoint — reads full jsonl bypassing SDK compact filter"
```

---

## Task 4: app/lib/api/chat_api.dart — 按新 API 形状重写

**Files:**
- Modify: `app/lib/api/chat_api.dart`

- [ ] **Step 1: 完整替换 chat_api.dart**

```dart
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Turn state reported by GET /chat/:uuid/status
enum TurnState { live, done, running, unknown }

class TurnStatus {
  final TurnState state;
  TurnStatus(this.state);
  factory TurnStatus.fromJson(Map<String, dynamic> j) {
    final s = j['state'] as String? ?? 'unknown';
    return TurnStatus(switch (s) {
      'live' => TurnState.live,
      'done' => TurnState.done,
      'running' => TurnState.running,
      _ => TurnState.unknown,
    });
  }
}

class ChatApiException implements Exception {
  final int status;
  final String message;
  ChatApiException(this.status, this.message);
  @override
  String toString() => 'ChatApiException($status): $message';
}

/// REST 客户端：与 chat-rest.ts 一一对应。
/// SSE 事件流是另一条 socket（见 SseClient），不在此类中处理。
class ChatApi {
  final String httpBase;
  ChatApi(this.httpBase);

  /// Start a new turn: send first message, optionally specifying model/permission.
  /// [uuid] is the Claude session UUID (client-generated for new sessions, or
  /// the existing resumeId for existing sessions).
  Future<void> turn({
    required String uuid,
    required String cwd,
    required String text,
    String? model,
    String? permissionMode,
  }) async {
    final resp = await http.post(
      Uri.parse('$httpBase/chat/$uuid/turn'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'cwd': cwd,
        'text': text,
        if (model != null) 'model': model,
        if (permissionMode != null) 'permission_mode': permissionMode,
      }),
    );
    if (resp.statusCode == 409) {
      throw ChatApiException(409, 'turn already active');
    }
    if (resp.statusCode != 200) {
      throw ChatApiException(resp.statusCode, resp.body);
    }
  }

  Future<TurnStatus> status(String uuid) async {
    final resp = await http
        .get(Uri.parse('$httpBase/chat/$uuid/status'))
        .timeout(const Duration(seconds: 4));
    if (resp.statusCode != 200) return TurnStatus(TurnState.unknown);
    return TurnStatus.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  Future<void> answerQuestion(
    String uuid,
    String toolUseId,
    Map<String, String> answers,
    Map<String, Map<String, String>>? annotations,
  ) async {
    final resp = await http.post(
      Uri.parse('$httpBase/chat/$uuid/answer-question'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'tool_use_id': toolUseId,
        'answers': answers,
        if (annotations != null) 'annotations': annotations,
      }),
    );
    if (resp.statusCode != 200) {
      throw ChatApiException(resp.statusCode, resp.body);
    }
  }

  Future<void> interrupt(String uuid) async {
    await http.post(Uri.parse('$httpBase/chat/$uuid/interrupt'));
  }

  Future<void> setModel(String uuid, String model) async {
    await http.post(
      Uri.parse('$httpBase/chat/$uuid/set-model'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'model': model}),
    );
  }

  Future<void> setPermissionMode(String uuid, String mode) async {
    await http.post(
      Uri.parse('$httpBase/chat/$uuid/set-permission-mode'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'mode': mode}),
    );
  }

  Future<void> close(String uuid) async {
    await http.delete(Uri.parse('$httpBase/chat/$uuid'));
  }
}
```

- [ ] **Step 2: Verify Flutter still compiles (check import sites)**

```bash
grep -rn "ChatStartResponse\|chatApi\.start\|\.sendMessage\b" \
  /Users/airoucat/workspace/shulex/claude-companion/app/lib --include="*.dart"
```

Expected: only `chat_tab.dart` references them → those will be fixed in Task 5.

- [ ] **Step 3: Commit**

```bash
cd /Users/airoucat/workspace/shulex/claude-companion
git add app/lib/api/chat_api.dart
git commit -m "feat(chat_api): rewrite to turn-level API — turn()/status(), drop start()/sendMessage()"
```

---

## Task 5: chat_tab.dart — UUID 作为 key、持久化、新连接流程、UUID 显示

**Files:**
- Modify: `app/lib/screens/tabs/chat_tab.dart`

这是改动最复杂的步骤，分为几个子步骤逐个进行。

### 5a — imports 和 state 字段

- [ ] **Step 1: 在 imports 区加 SharedPreferences 和 uuid**

在 `chat_tab.dart` 顶部现有 imports 后加：

```dart
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
```

- [ ] **Step 2: 修改 `_ChatTabState` 的 `_sessionId` 语义**

`_sessionId` 现在就是 Claude UUID（不再是服务端随机串）。没有语义变化，只是来源变了。在 `_ChatTabState` 的字段声明处，**在 `_sessionId` 旁边加注释**：

```dart
/// Claude session UUID. For new sessions: client-generated and persisted.
/// For resumed sessions: equals currentSession.resumeId.
String? _sessionId;
```

### 5b — SharedPreferences 持久化辅助方法

- [ ] **Step 3: 在 `_ChatTabState` 里加两个私有方法（放在 `_ensureConnected` 之前）**

```dart
static const _kLastUuidKey = 'chat_last_uuid';

Future<void> _persistUuid(String uuid) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_kLastUuidKey, uuid);
}

Future<String?> _loadPersistedUuid() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getString(_kLastUuidKey);
}
```

### 5c — `_openSseSession` 改为 turn-based

- [ ] **Step 4: 完全替换 `_openSseSession` 方法**

原方法调用了 `api.start()` 获取 server session ID。新方法：用 Claude UUID，调 `turn()` 发送消息。

但有一个问题：原来 `_openSseSession` 是在 `_ensureConnected` 里调用的，当时**还没有用户消息**。新的 `turn()` 需要消息文本。

解决方案：把 `_openSseSession` 改名为 `_connectToSession`（仅建立 SSE 连接），把 turn 的发送移到 `_sendNow` 里。

```dart
/// 建立到已有活跃 run 的 SSE 连接，或者仅做历史加载然后等用户输入。
/// 注意：turn 本身由 [_sendNow] 触发，不在此方法里。
Future<void> _connectToSession(String httpBase, CurrentSession session) async {
  // 有 resumeId → 先加载历史
  if (session.resumeId != null) {
    _loadHistory(httpBase, session.cwd, session.resumeId!);
  }

  final uuid = session.resumeId ?? const Uuid().v4();
  _sessionId = uuid;

  // 持久化 UUID（新建会话时尤其重要）
  unawaited(_persistUuid(uuid));

  final api = ChatApi(httpBase);
  _chatApi = api;

  // 检查是否有活跃 turn（服务端正在运行）。
  // 有 → 立刻连接 SSE 接收输出（可能是另一终端或上次未结束的 turn）。
  // 没有 → 只加载历史，等用户发消息再触发 turn。
  TurnStatus turnStatus;
  try {
    turnStatus = await api.status(uuid);
  } catch (_) {
    turnStatus = TurnStatus(TurnState.unknown);
  }

  if (!mounted) return;

  setState(() {
    _attempting = false;
    _error = null;
  });

  if (turnStatus.state == TurnState.live) {
    // 已有活跃 turn（比如从另一个终端/app 实例恢复）→ 连接 SSE 接收输出
    setState(() {
      _connected = true;
      _busy = true;
      _busyStartedAt ??= DateTime.now();
    });
    _subscribeSse(httpBase, uuid);
  } else {
    // 空闲 → 标记为 connected（可以发消息），历史已在加载
    setState(() => _connected = true);
  }
}
```

- [ ] **Step 5: 加 `_subscribeSse` 私有方法**

```dart
void _subscribeSse(String httpBase, String uuid) {
  final sseUrl = Uri.parse('$httpBase/chat/$uuid/events');
  final sse = SseClient(url: sseUrl);
  _sseClient = sse;
  sse.events.listen(_onSseEvent);
  unawaited(sse.connect());
}
```

### 5d — `_sendNow` 改为发 turn

- [ ] **Step 6: 修改 `_sendNow`**

原来是 `_chatApi!.sendMessage(_sessionId!, text)`。  
新逻辑：`_chatApi!.turn(uuid, cwd, text)` + 连接 SSE（如果尚未连接）。

找到 `_sendNow` 方法，替换其中的网络调用部分：

```dart
void _sendNow(String text) {
  setState(() {
    _messages.add(LocalUserInput(text));
    _busy = true;
    _busyStartedAt = DateTime.now();
    _mode = CcStreamMode.requesting;
    _currentBlockKind = null;
    _thoughtSeconds = null;
    _thoughtForTimer?.cancel();
  });

  final uuid = _sessionId;
  final config = ref.read(activeConnectionProvider);
  final session = ref.read(currentSessionProvider);
  if (uuid != null && _chatApi != null && config != null && session != null) {
    final model = ref.read(currentModelProvider);
    final permMode = ref.read(permissionModeProvider);
    unawaited(_chatApi!.turn(
      uuid: uuid,
      cwd: session.cwd,
      text: text,
      model: model.id,
      permissionMode: permMode.wire,
    ).then((_) {
      // Turn started — connect SSE if not already connected.
      if (mounted && _sseClient == null) {
        _subscribeSse(config.httpBase, uuid);
      }
    }).catchError((e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '$e';
        });
      }
    }));
  }
  _scrollToEnd(force: true);
}
```

### 5e — `_ensureConnected` 调用更新

- [ ] **Step 7: 在 `_ensureConnected` 里把 `_openSseSession` → `_connectToSession`**

找到以下两处调用：

```dart
    if (session.resumeId != null) {
      _resumeWithHolderCheck(config.httpBase, session);
    } else {
      _openSseSession(config.httpBase, session);
    }
```

改为：

```dart
    if (session.resumeId != null) {
      _resumeWithHolderCheck(config.httpBase, session);
    } else {
      _connectToSession(config.httpBase, session);
    }
```

也把 `_resumeWithHolderCheck` 里的 `_openSseSession` 调用：

```dart
      _openSseSession(httpBase, session);
```

改为：

```dart
      _connectToSession(httpBase, session);
```

### 5f — `dispose` 和 `_manualReconnect` 清理

- [ ] **Step 8: 更新 dispose 里的 close 调用**

原来：

```dart
    if (_sessionId != null && _chatApi != null) {
      unawaited(_chatApi!.close(_sessionId!));
    }
```

这行可以保留，语义正确（仍然 close 活跃 turn）。

`_manualReconnect` 不需要改，它已经正确地清空 `_sessionId`、`_sseClient`、`_chatApi`。

### 5g — ResultMsg 处理：SSE 断开（可选，优化体验）

- [ ] **Step 9: 在 `_handleWireMessage` 里 ResultMsg 到达后断开 SSE**

在现有的 `} else if (msg is ResultMsg) {` 块里，在设置 `_busy = false` 之后，加：

```dart
        // Turn finished — server will close SSE after grace; we can also
        // proactively disconnect to free resources.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            unawaited(_sseClient?.close() ?? Future.value());
            setState(() => _sseClient = null);
          }
        });
```

### 5h — UUID 显示在 `_StatusRow`

- [ ] **Step 10: 修改 `_StatusRow` 加 uuid 参数**

在 `_StatusRow` 的 `const _StatusRow({...})` 里加 `this.uuid`:

```dart
class _StatusRow extends StatelessWidget {
  final bool connected;
  final bool busy;
  final String? error;
  final String? uuid;        // ← new
  final VoidCallback onReconnect;
  const _StatusRow({
    required this.connected,
    required this.busy,
    required this.error,
    required this.onReconnect,
    this.uuid,               // ← new
  });
```

在 `build` 方法的 `Row` 里，在 `const Spacer()` 之前加 UUID chip：

```dart
          if (uuid != null) ...[
            GestureDetector(
              onTap: () {
                Clipboard.setData(ClipboardData(text: uuid!));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('UUID copied'), duration: Duration(seconds: 1)),
                );
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                margin: const EdgeInsets.only(right: 6),
                decoration: BoxDecoration(
                  color: t.surfaceHi,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: t.border, width: 0.5),
                ),
                child: Text(
                  uuid!.length >= 8 ? uuid!.substring(0, 8) : uuid!,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 10,
                    color: t.textDim,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            ),
          ],
```

- [ ] **Step 11: 在 `build` 方法里把 `_SessionId` 传给 `_StatusRow`**

找到：

```dart
          _StatusRow(
            connected: _connected,
            busy: _busy,
            error: _error,
            onReconnect: _manualReconnect,
          ),
```

改为：

```dart
          _StatusRow(
            connected: _connected,
            busy: _busy,
            error: _error,
            uuid: _sessionId,
            onReconnect: _manualReconnect,
          ),
```

- [ ] **Step 12: Flutter analyze**

```bash
cd /Users/airoucat/workspace/shulex/claude-companion/app
flutter analyze --no-pub 2>&1 | grep -E "error|warning" | head -30
```

Expected: 0 errors. Warnings about unused imports are ok to fix.

- [ ] **Step 13: Commit**

```bash
cd /Users/airoucat/workspace/shulex/claude-companion
git add app/lib/screens/tabs/chat_tab.dart app/lib/api/chat_api.dart
git commit -m "feat(chat): turn-level UUID session — client UUID, SharedPrefs persistence, UUID chip display"
```

---

## Task 6: 端到端验证

- [ ] **Step 1: 启动服务端**

```bash
cd /Users/airoucat/workspace/shulex/claude-companion/server
npm run dev
```

- [ ] **Step 2: 测试新建会话 turn**

```bash
# 生成一个 UUID
NEW_UUID=$(python3 -c "import uuid; print(uuid.uuid4())")
echo "UUID: $NEW_UUID"

# 开始一个 turn
curl -s -X POST http://localhost:8765/chat/$NEW_UUID/turn \
  -H "Content-Type: application/json" \
  -d "{\"cwd\":\"/Users/airoucat/workspace/shulex/claude-companion\",\"text\":\"say hello\"}" | python3 -m json.tool
```

Expected: `{"ok": true}`

- [ ] **Step 3: 订阅 SSE 并看输出**

```bash
curl -N http://localhost:8765/chat/$NEW_UUID/events 2>/dev/null | head -40
```

Expected: SSE events including stream_delta, result.

- [ ] **Step 4: 测试 status 接口**

```bash
curl -s http://localhost:8765/chat/$NEW_UUID/status | python3 -m json.tool
```

Expected: `{"state": "live"}` while running, `{"state": "done"}` after result.

- [ ] **Step 5: 测试 raw-history**

```bash
# 用上面的 $NEW_UUID (after turn completes):
curl -s "http://localhost:8765/sessions/$NEW_UUID/raw-history?cwd=/Users/airoucat/workspace/shulex/claude-companion&limit=10" | python3 -m json.tool | head -40
```

Expected: `messages`, `has_more`, `total`.

- [ ] **Step 6: 409 重复 turn 测试**

```bash
# 在前一个 turn 还 running 时:
curl -s -X POST http://localhost:8765/chat/$NEW_UUID/turn \
  -H "Content-Type: application/json" \
  -d "{\"cwd\":\"/Users/airoucat/workspace/shulex/claude-companion\",\"text\":\"hello again\"}"
```

Expected: `{"error": "turn already active for this session"}` with HTTP 409.

- [ ] **Step 7: App smoke test on device/simulator**

启动 Flutter app → 选择项目 → 点一个已有 session → 确认：
1. 顶部 UUID chip 显示（8 位缩略）
2. 点击 UUID chip → snackbar "UUID copied"
3. 发送一条消息 → spinner 出现 → 收到回复

- [ ] **Step 8: Final commit (if any fixes)**

```bash
cd /Users/airoucat/workspace/shulex/claude-companion
git add -p
git commit -m "fix: address issues found during e2e verification"
```

---

## 已知限制与后续工作

1. **raw-history 不支持 sidechain 内容**：subagent 消息（`isSidechain: true`）被过滤掉，与现有行为一致。
2. **setModel/setPermissionMode 在无活跃 turn 时返回 404**：新模型下这些操作只在 turn 期间有意义，符合预期。
3. **app 暂未使用 raw-history**：raw-history 接口已就绪，但 chat_tab 尚未接入"查看完整历史"入口，这是下一期的工作。
4. **`GET /chat/:uuid/status` 的 `running` 状态**（PID holder 但无活跃 run）目前 Flutter 不处理，直接显示历史。下一期可以加轮询。
