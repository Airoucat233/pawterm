# Claude 权限模式对齐 Claude Code CLI 实施方案

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 pawterm 的 Claude 权限处理与 Claude Code CLI / Agent SDK 0.3.179 的语义对齐——支持全部 6 个 permission mode，并在 SDK 真正请求权限决策时弹出可交互的审批卡（而不是无脑放行）。

**Architecture:** SDK 在 `query()` 里通过 host 提供的 `canUseTool` 回调来下发"需要审批"的请求（`can_use_tool` control_request）。SDK 已在上游完成所有 mode 相关的过滤/分类（allow/deny 规则、安全工具自动放行、acceptEdits 自动接受编辑、auto 模式分类器、dontAsk 自动拒绝），**只有真正需要用户拍板的工具调用才会进入我们的 `canUseTool`**。因此 host 的职责在 default / acceptEdits / auto 三种模式下是一致的：被调到 = 该问用户了 → 挂起 + 发审批请求 wire + 等 App 回传 → resolve allow/deny。复用现有 `AskUserQuestionRegistry` 的"挂起 Promise→发消息→等 /chat/answer→resolve"模式，新建一个能 allow/deny 的 `ToolPermissionRegistry`。

**Tech Stack:** TypeScript（server，Fastify + @anthropic-ai/claude-agent-sdk 0.3.179，vitest）、共享 wire 协议（packages/shared，TS）、Flutter/Dart（app，Riverpod，手动同步协议）。

## Global Constraints

- **三端协议同步**：任何 `packages/shared/src/protocol.ts` 改动必须同步迁移 server（`chat-rest.ts`/`session.ts`/`serialize.ts`）、app（`app/lib/api/protocol.dart`，手动同步无 codegen）。Web 端 chat 仍走 WS，本方案不涉及 Claude 审批，可暂不动；若改了公共 union 需保证 web 端 typecheck 不挂。
- **SDK 版本**：以 `@anthropic-ai/claude-agent-sdk@0.3.179` 的 `sdk.d.ts` 为准（repo node_modules 已是 0.3.179）。`PermissionMode = 'default' | 'acceptEdits' | 'bypassPermissions' | 'plan' | 'dontAsk' | 'auto'`（sdk.d.ts:2055）。`PermissionResult` 只有 `allow`（`updatedInput?` 可选）和 `deny`（`message` 必填）两种 behavior（sdk.d.ts:2077-2089）；**没有 `ask`**——"ask" 是 SDK 调你的 canUseTool 这件事本身。
- **HTTP 规范**：新增接口只能 `GET`/`POST`，URL path 不带占位符参数，标识符放 query/body。审批决定走 `POST /chat/tool-permission`。
- **不碰 Codex / Gemini**：本方案只动 Claude 路径。Codex 审批卡（`codex_approval_card.dart`）只作为视觉脚手架参考，不复用它的 wire 形状（要对齐的是 CLI 不是 Codex）。
- **per-session 隔离**：审批请求 / 待审批状态必须按 session（runtime）隔离，遵循刚修过的"全局 provider 串页"教训——审批状态进 `_ChatSessionRuntime`，不进全局单例。
- **不主动重启测试服 / 不发布 / 不 push**：验证用 `pnpm dev:server` + `flutter analyze`；改动 server 后如需让当前会话生效再单独和用户确认。

---

## File Structure

**Server（新建/修改）**
- Create `server/src/tool-permission.ts` — `ToolPermissionRegistry`（挂起 canUseTool，按 App 决定 resolve allow/deny）。
- Modify `server/src/agents/claude/session.ts` — 注入 registry；重写 `canUseTool`；新增 `answerToolPermission()`；mode 透传无需改（已直传）。
- Modify `server/src/agents/claude/provider.ts` — 构造并注入 `ToolPermissionRegistry`；把"待审批请求需要广播"的 hook 接到 SSE 广播。
- Modify `server/src/chat-rest.ts` — 新增 `POST /chat/tool-permission` 端点；在工具审批请求产生时广播 `tool_permission_request` SSE 事件。
- Modify `server/src/agents/claude/serialize.ts` —（可选，末task）路由 SDK auto-deny system 事件成 wire `tool_auto_denied`。

**共享协议**
- Modify `packages/shared/src/protocol.ts` — widen `PermissionMode` 到 6 值；新增 `ToolPermissionRequest` wire 消息 + `ToolPermissionDecision` body 契约（+ 可选 `ToolAutoDenied`）。

**App（修改/新建）**
- Modify `app/lib/state/prefs.dart` — `CcPermissionMode` 加 `auto`、`dontAsk`。
- Modify `app/lib/api/protocol.dart` — 同步 6 值；新增 `ToolPermissionRequestMsg`。
- Modify `app/lib/api/chat_api.dart` — 新增 `toolPermission(uuid, requestId, decision, {dontAskAgain})`。
- Create `app/lib/widgets/tool_permission_card.dart` — Claude 工具审批卡（CLI 风格文案）。
- Modify `app/lib/screens/tabs/chat_tab.dart` — runtime 加 pending-approval 状态；`_handleWireMessage` 处理 `tool_permission_request`；权限 picker 加 auto/dontAsk 行；渲染审批卡。
- Modify `app/lib/widgets/message_view.dart` — 在 Claude 工具 tool_use 处插入审批卡渲染点（如需）。

---

## Task 1: Spike — 实测每个 mode 下 canUseTool 的真实触发行为

**为什么先做**：方案的正确性依赖一个假设——"SDK 已在上游过滤，只有需要用户拍板的工具才进 canUseTool"。这必须**实测确认**，否则可能出现 default 模式下连 Read/Grep 都弹卡（过度打扰）或某些危险工具反而不弹。本 task 不写产品代码，只做一次性测量，结论可能微调 Task 4/8。

**Files:**
- Modify（临时）: `server/src/agents/claude/session.ts:116-124`（canUseTool 内加日志，测完回退）

**Interfaces:**
- Produces: 一份「mode × 工具 → 是否进 canUseTool + opts 字段实测值」表，供 Task 4 决定卡片要展示哪些字段、Task 8 决定哪些工具走审批。

- [ ] **Step 1: 在 canUseTool 顶部加临时日志**

```typescript
canUseTool: async (toolName, input, opts) => {
  // TEMP spike logging — remove after Task 1
  console.error('[canUseTool]', JSON.stringify({
    mode: this.permissionMode,
    toolName,
    title: (opts as any).title,
    displayName: (opts as any).displayName,
    description: (opts as any).description,
    decisionReason: (opts as any).decisionReason,
    decisionReasonType: (opts as any).decision_reason_type,
    classifierApprovable: (opts as any).classifier_approvable,
    hasSuggestions: Array.isArray((opts as any).suggestions),
  }));
  if (toolName === 'AskUserQuestion') {
    return this.askRegistry.register('native', opts.toolUseID, input as Record<string, unknown>);
  }
  return { behavior: 'allow' as const, updatedInput: input as Record<string, unknown> };
},
```

- [ ] **Step 2: 跑 dev server，分别在 default / acceptEdits / auto / dontAsk 下发起会话**

Run: `pnpm dev:server`（另开 app 或用 curl 触发一次会让 Claude 跑 Read + Bash + Write 的请求，每个 mode 各一次）
观察 server 日志里 `[canUseTool]` 输出。

- [ ] **Step 3: 记录结论到 plan 注释**

确认这些事实并写进本 task 下方（实测后填）：
- default 下：Read/Grep/Glob 是否**不进** canUseTool（期望：不进，SDK 自动放行）？Bash/Write/Edit 是否进？
- acceptEdits 下：Edit/Write 是否**不进**（SDK 自动接受）？Bash 是否进？
- auto 下：哪些进（期望：仅分类器升级的，如危险 Bash / safetyCheck）？`classifier_approvable` 字段是否出现？
- opts 上 `title`/`displayName`/`description` 实际有没有值（决定卡片用哪个做标题）。

- [ ] **Step 4: 回退临时日志**

```bash
git checkout server/src/agents/claude/session.ts   # 仅当未混入其它改动；否则手动删日志
```

- [ ] **Step 5: 不提交（spike 无产物代码）**

> **实测结论（填）：** _________________________________________________

---

## Task 2: 共享协议 — widen PermissionMode + 审批 wire 类型

**Files:**
- Modify: `packages/shared/src/protocol.ts`
- Test: `server/src/__tests__/protocol-permission.test.ts`（新建，纯类型/常量断言）

**Interfaces:**
- Produces:
  - `PermissionMode = 'default' | 'acceptEdits' | 'bypassPermissions' | 'plan' | 'dontAsk' | 'auto'`
  - wire 消息 `ToolPermissionRequest { type:'tool_permission_request'; requestId:string; toolName:string; input:Record<string,unknown>; title?:string; displayName?:string; description?:string; reasonType?:string; safetyManual?:boolean }`
  - body 契约 `ToolPermissionDecisionBody { uuid:string; requestId:string; decision:'allow'|'deny'; dontAskAgain?:boolean }`
  - 加入 `ChatServerMessage` union。

- [ ] **Step 1: 写失败测试（断言常量/类型边界）**

```typescript
// server/src/__tests__/protocol-permission.test.ts
import { describe, it, expect } from 'vitest';
import { PERMISSION_MODES } from '@pawterm/shared';

describe('permission protocol', () => {
  it('exposes all six SDK permission modes', () => {
    expect(PERMISSION_MODES).toEqual([
      'default', 'acceptEdits', 'plan', 'auto', 'dontAsk', 'bypassPermissions',
    ]);
  });
});
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd server && pnpm exec vitest run src/__tests__/protocol-permission.test.ts`
Expected: FAIL（`PERMISSION_MODES` 未导出）

- [ ] **Step 3: 在 protocol.ts 实现类型与常量**

```typescript
// packages/shared/src/protocol.ts
export const PERMISSION_MODES = [
  'default', 'acceptEdits', 'plan', 'auto', 'dontAsk', 'bypassPermissions',
] as const;
export type PermissionMode = typeof PERMISSION_MODES[number];

export interface ToolPermissionRequest {
  type: 'tool_permission_request';
  requestId: string;              // = SDK toolUseID
  toolName: string;
  input: Record<string, unknown>;
  title?: string;                 // opts.title: "Claude wants to run …"
  displayName?: string;           // opts.displayName: "Run command"
  description?: string;           // opts.description: 权限范围说明
  reasonType?: string;            // decision_reason_type
  safetyManual?: boolean;         // classifier_approvable === false → 需人工
}

export interface ToolPermissionDecisionBody {
  uuid: string;
  requestId: string;
  decision: 'allow' | 'deny';
  dontAskAgain?: boolean;         // CLI 的 "Yes, and don't ask again"
}
```
并把 `ToolPermissionRequest` 加进 `ChatServerMessage` union（找到现有 union，追加成员）。若原 `permission_mode` 字段引用旧的窄类型，替换为新的 `PermissionMode`。

- [ ] **Step 4: 跑测试 + 全量 typecheck**

Run: `cd server && pnpm exec vitest run src/__tests__/protocol-permission.test.ts && cd .. && pnpm typecheck`
Expected: PASS；typecheck 无新错误（若 web/server 有对 `permission_mode` 的穷举 switch，补 default 分支）。

- [ ] **Step 5: Commit**

```bash
git add packages/shared/src/protocol.ts server/src/__tests__/protocol-permission.test.ts
git commit -m "shared: widen PermissionMode to 6 SDK values + tool_permission wire types"
```

---

## Task 3: Server — ToolPermissionRegistry（可 allow/deny 的挂起器）

**Files:**
- Create: `server/src/tool-permission.ts`
- Test: `server/src/__tests__/tool-permission.test.ts`

**Interfaces:**
- Consumes: 无（独立）。
- Produces:
  - `class ToolPermissionRegistry`
    - `register(toolUseId: string, originalInput: Record<string,unknown>): Promise<SdkPermissionResult>`
    - `answer(toolUseId: string, decision: 'allow'|'deny', opts?: { dontAskAgain?: boolean; toolName?: string }): boolean`
    - `rejectAll(reason: string): void`
  - 类型 `SdkPermissionResult = { behavior:'allow'; updatedInput:Record<string,unknown>; updatedPermissions?: unknown[] } | { behavior:'deny'; message:string }`

- [ ] **Step 1: 写失败测试**

```typescript
// server/src/__tests__/tool-permission.test.ts
import { describe, it, expect } from 'vitest';
import { ToolPermissionRegistry } from '../tool-permission.js';

describe('ToolPermissionRegistry', () => {
  it('resolves allow with original input echoed as updatedInput', async () => {
    const reg = new ToolPermissionRegistry({ timeoutMs: 1000 });
    const p = reg.register('t1', { command: 'ls' });
    expect(reg.answer('t1', 'allow')).toBe(true);
    await expect(p).resolves.toEqual({ behavior: 'allow', updatedInput: { command: 'ls' } });
  });

  it('resolves deny with a message', async () => {
    const reg = new ToolPermissionRegistry({ timeoutMs: 1000 });
    const p = reg.register('t2', { command: 'rm -rf /' });
    expect(reg.answer('t2', 'deny')).toBe(true);
    await expect(p).resolves.toEqual({ behavior: 'deny', message: expect.stringContaining('denied') });
  });

  it('attaches a session allow rule when dontAskAgain', async () => {
    const reg = new ToolPermissionRegistry({ timeoutMs: 1000 });
    const p = reg.register('t3', { command: 'ls' });
    reg.answer('t3', 'allow', { dontAskAgain: true, toolName: 'Bash' });
    const r = await p as any;
    expect(r.behavior).toBe('allow');
    expect(Array.isArray(r.updatedPermissions)).toBe(true);
  });

  it('answer on unknown id returns false', () => {
    const reg = new ToolPermissionRegistry({ timeoutMs: 1000 });
    expect(reg.answer('nope', 'allow')).toBe(false);
  });
});
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd server && pnpm exec vitest run src/__tests__/tool-permission.test.ts`
Expected: FAIL（模块不存在）

- [ ] **Step 3: 实现 registry**

```typescript
// server/src/tool-permission.ts
export type SdkPermissionResult =
  | { behavior: 'allow'; updatedInput: Record<string, unknown>; updatedPermissions?: unknown[] }
  | { behavior: 'deny'; message: string };

type Pending = {
  resolve: (r: SdkPermissionResult) => void;
  reject: (e: Error) => void;
  timer: ReturnType<typeof setTimeout>;
  originalInput: Record<string, unknown>;
};

const DEFAULT_TIMEOUT_MS = 30 * 60 * 1000;

export class ToolPermissionRegistry {
  private pending = new Map<string, Pending>();
  private readonly timeoutMs: number;
  constructor(opts: { timeoutMs?: number } = {}) {
    this.timeoutMs = opts.timeoutMs ?? DEFAULT_TIMEOUT_MS;
  }

  register(toolUseId: string, originalInput: Record<string, unknown>): Promise<SdkPermissionResult> {
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        if (this.pending.delete(toolUseId)) {
          // 超时按拒绝处理，避免无限挂起 SDK
          resolve({ behavior: 'deny', message: 'Permission request timed out (no answer in 30 minutes)' });
        }
      }, this.timeoutMs);
      this.pending.set(toolUseId, { resolve, reject, timer, originalInput });
    });
  }

  answer(toolUseId: string, decision: 'allow' | 'deny', opts: { dontAskAgain?: boolean; toolName?: string } = {}): boolean {
    const entry = this.pending.get(toolUseId);
    if (!entry) return false;
    clearTimeout(entry.timer);
    this.pending.delete(toolUseId);
    if (decision === 'deny') {
      entry.resolve({ behavior: 'deny', message: 'Tool call denied by user' });
      return true;
    }
    const result: SdkPermissionResult = { behavior: 'allow', updatedInput: entry.originalInput };
    if (opts.dontAskAgain && opts.toolName) {
      // CLI "don't ask again"：给本 session 加一条 allow 规则
      result.updatedPermissions = [{
        type: 'addRules',
        rules: [{ toolName: opts.toolName }],
        behavior: 'allow',
        destination: 'session',
      }];
    }
    entry.resolve(result);
    return true;
  }

  rejectAll(reason: string): void {
    for (const [, p] of this.pending) {
      clearTimeout(p.timer);
      p.resolve({ behavior: 'deny', message: reason });
    }
    this.pending.clear();
  }
}
```

> 注：`updatedPermissions` 的精确结构以 Task 1 spike + sdk.d.ts `PermissionUpdate`（2096-2123）为准；若 `destination:'session'` 或 rule 形状不被接受，退化为不带规则的纯 allow（功能不丢，只是每次都问）。

- [ ] **Step 4: 跑测试确认通过**

Run: `cd server && pnpm exec vitest run src/__tests__/tool-permission.test.ts`
Expected: PASS（4 个用例）

- [ ] **Step 5: Commit**

```bash
git add server/src/tool-permission.ts server/src/__tests__/tool-permission.test.ts
git commit -m "server: add ToolPermissionRegistry (allow/deny suspend for canUseTool)"
```

---

## Task 4: Server — 重写 canUseTool + 广播请求 + 决定端点

**Files:**
- Modify: `server/src/agents/claude/session.ts`（canUseTool；注入 registry；新增 `answerToolPermission` + 暴露"待广播请求"回调）
- Modify: `server/src/agents/claude/provider.ts`（构造 registry，接广播）
- Modify: `server/src/chat-rest.ts`（`POST /chat/tool-permission` + 广播 `tool_permission_request` SSE）
- Test: `server/src/__tests__/session-permission.test.ts`（对 canUseTool 决策分支做单元测试，mock registry + 一个 onRequest spy）

**Interfaces:**
- Consumes: `ToolPermissionRegistry`（Task 3）、`ToolPermissionRequest`（Task 2）。
- Produces:
  - session 上 `answerToolPermission(toolUseId, decision, opts)`，转调 registry.answer。
  - session 构造参数新增 `onToolPermissionRequest?: (req: ToolPermissionRequest) => void`（由 chat-rest 注入，用于广播 SSE）。

- [ ] **Step 1: 写失败测试（canUseTool 分支）**

```typescript
// server/src/__tests__/session-permission.test.ts
import { describe, it, expect, vi } from 'vitest';
import { buildCanUseTool } from '../agents/claude/session.js'; // 抽出的纯函数，见 Step 3

describe('buildCanUseTool', () => {
  it('AskUserQuestion 仍走 askRegistry', async () => {
    const ask = { register: vi.fn().mockResolvedValue({ behavior: 'allow', updatedInput: {} }) };
    const tool = { register: vi.fn() };
    const onReq = vi.fn();
    const fn = buildCanUseTool({ askRegistry: ask as any, toolRegistry: tool as any, onRequest: onReq, getMode: () => 'default' });
    await fn('AskUserQuestion', { questions: [] }, { toolUseID: 'a1' } as any);
    expect(ask.register).toHaveBeenCalled();
    expect(tool.register).not.toHaveBeenCalled();
  });

  it('普通工具 → 广播请求并挂起 toolRegistry', async () => {
    const ask = { register: vi.fn() };
    const tool = { register: vi.fn().mockResolvedValue({ behavior: 'allow', updatedInput: { command: 'ls' } }) };
    const onReq = vi.fn();
    const fn = buildCanUseTool({ askRegistry: ask as any, toolRegistry: tool as any, onRequest: onReq, getMode: () => 'default' });
    const r = await fn('Bash', { command: 'ls' }, { toolUseID: 'b1', title: 'Run ls' } as any);
    expect(onReq).toHaveBeenCalledWith(expect.objectContaining({ type: 'tool_permission_request', requestId: 'b1', toolName: 'Bash' }));
    expect(tool.register).toHaveBeenCalledWith('b1', { command: 'ls' });
    expect(r).toEqual({ behavior: 'allow', updatedInput: { command: 'ls' } });
  });
});
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd server && pnpm exec vitest run src/__tests__/session-permission.test.ts`
Expected: FAIL（`buildCanUseTool` 未导出）

- [ ] **Step 3: 把 canUseTool 抽成纯函数并改写**

在 `session.ts` 抽出可测的工厂（替换原 116-124 内联实现）：

```typescript
// session.ts
import type { ToolPermissionRequest } from '@pawterm/shared';
import { ToolPermissionRegistry } from '../../tool-permission.js';

export function buildCanUseTool(deps: {
  askRegistry: AskUserQuestionRegistry;
  toolRegistry: ToolPermissionRegistry;
  onRequest: (req: ToolPermissionRequest) => void;
  getMode: () => string;
}) {
  return async (toolName: string, input: Record<string, unknown>, opts: any) => {
    if (toolName === 'AskUserQuestion') {
      return deps.askRegistry.register('native', opts.toolUseID, input);
    }
    // 走到这里 = SDK 上游没自动决定，需要用户拍板（default/acceptEdits/auto 升级）。
    const req: ToolPermissionRequest = {
      type: 'tool_permission_request',
      requestId: opts.toolUseID,
      toolName,
      input,
      title: opts.title,
      displayName: opts.displayName,
      description: opts.description,
      reasonType: opts.decision_reason_type,
      safetyManual: opts.classifier_approvable === false,
    };
    deps.onRequest(req);                       // 广播给 App（chat-rest 注入）
    return deps.toolRegistry.register(opts.toolUseID, input);
  };
}
```
在 session 类里：构造 `this.toolRegistry = new ToolPermissionRegistry()`；`options.canUseTool = buildCanUseTool({ askRegistry: this.askRegistry, toolRegistry: this.toolRegistry, onRequest: this.onToolPermissionRequest, getMode: () => this.permissionMode })`；新增 `answerToolPermission(id, decision, opts) { return this.toolRegistry.answer(id, decision, opts); }`；并在会话结束/中断处调用 `this.toolRegistry.rejectAll('session ended')`（与现有 askRegistry 清理同位置）。`onToolPermissionRequest` 由构造参数传入。

> bypass：仍由 `...(bypassing ? { allowDangerouslySkipPermissions:true } : {})` 处理——bypass 下 SDK 不调 canUseTool，本逻辑天然不触发。plan：SDK 不执行工具，也不触发。dontAsk/auto-deny：SDK 不调 canUseTool（自动拒），见 Task 8 末的 auto-deny 渲染（可选）。

- [ ] **Step 4: provider.ts 注入 onRequest 广播**

在 `provider.ts` 构造 session 时，把"广播一条 SSE 事件"的函数作为 `onToolPermissionRequest` 传入。广播复用现有把 wire 消息推到该 session SSE 流的通道（与 assistant 消息同一条 per-session SSE）。具体函数名以现有广播实现为准（grep 现有 `broadcast`/`emit`/SSE push）。

- [ ] **Step 5: chat-rest.ts 新增决定端点**

```typescript
// chat-rest.ts —— 仿照 616-637 的 /chat/permission
app.post('/chat/tool-permission', async (req, reply) => {
  const { uuid, requestId, decision, dontAskAgain } = (req.body ?? {}) as ToolPermissionDecisionBody;
  if (!uuid || !requestId || (decision !== 'allow' && decision !== 'deny')) {
    reply.code(400); return { error: 'uuid, requestId, decision(allow|deny) required' };
  }
  const entry = activeRuns.get(runKey('claude', uuid));
  if (!entry?.session?.answerToolPermission) { reply.code(400); return { error: 'no active claude run' }; }
  const ok = entry.session.answerToolPermission(requestId, decision, { dontAskAgain, /* toolName 见下 */ });
  return { ok };
});
```
`toolName` 在 answer 时需要（用于 dontAskAgain 规则）。两种取法：(a) registry 在 register 时把 toolName 一并存（推荐，改 Task 3 register 签名加 toolName）；(b) request body 带回 toolName。**选 (a)**：回 Task 3 给 `register(toolUseId, originalInput, toolName)` 存上，`answer` 内部自取，端点就不必传 toolName。

- [ ] **Step 6: 跑 server 测试 + typecheck**

Run: `cd server && pnpm exec vitest run && pnpm typecheck`
Expected: 新旧测试全 PASS；typecheck 干净。

- [ ] **Step 7: Commit**

```bash
git add server/src/agents/claude/session.ts server/src/agents/claude/provider.ts server/src/chat-rest.ts server/src/__tests__/session-permission.test.ts
git commit -m "server: canUseTool surfaces interactive approval via ToolPermissionRegistry + /chat/tool-permission"
```

---

## Task 5: App 协议 + API — 6 模式 + 审批 wire/decision

**Files:**
- Modify: `app/lib/state/prefs.dart`（CcPermissionMode 加 auto/dontAsk）
- Modify: `app/lib/api/protocol.dart`（ToolPermissionRequestMsg + fromJson 路由）
- Modify: `app/lib/api/chat_api.dart`（toolPermission 端点）

**Interfaces:**
- Produces:
  - `CcPermissionMode { defaultMode, acceptEdits, plan, auto, dontAsk, bypass }`，`.wire` 对应 SDK 值。
  - `class ToolPermissionRequestMsg extends IncomingMessage { requestId, toolName, input, title?, displayName?, description?, reasonType?, safetyManual? }`
  - `ChatApi.toolPermission(uuid, requestId, decision, {dontAskAgain})`

- [ ] **Step 1: prefs.dart 扩枚举**

```dart
enum CcPermissionMode {
  defaultMode('default'),
  acceptEdits('acceptEdits'),
  plan('plan'),
  auto('auto'),
  dontAsk('dontAsk'),
  bypass('bypassPermissions');
  final String wire;
  const CcPermissionMode(this.wire);
  static CcPermissionMode fromWire(String? w) =>
      CcPermissionMode.values.firstWhere((m) => m.wire == w, orElse: () => CcPermissionMode.defaultMode);
}
```

- [ ] **Step 2: protocol.dart 新增消息类型 + 路由**

```dart
class ToolPermissionRequestMsg extends IncomingMessage {
  final String requestId;
  final String toolName;
  final Map<String, dynamic> input;
  final String? title;
  final String? displayName;
  final String? description;
  final String? reasonType;
  final bool safetyManual;
  ToolPermissionRequestMsg({
    required this.requestId, required this.toolName, required this.input,
    this.title, this.displayName, this.description, this.reasonType, this.safetyManual = false,
  });
  factory ToolPermissionRequestMsg.fromJson(Map<String, dynamic> j) => ToolPermissionRequestMsg(
    requestId: j['requestId'] as String,
    toolName: j['toolName'] as String,
    input: Map<String, dynamic>.from(j['input'] ?? const {}),
    title: j['title'] as String?,
    displayName: j['displayName'] as String?,
    description: j['description'] as String?,
    reasonType: j['reasonType'] as String?,
    safetyManual: j['safetyManual'] as bool? ?? false,
  );
}
```
在 `IncomingMessage.fromJson` 的 `switch (type)` 增加 `case 'tool_permission_request': return ToolPermissionRequestMsg.fromJson(json);`

- [ ] **Step 3: chat_api.dart 新端点**

```dart
Future<void> toolPermission(String uuid, String requestId, String decision, {bool dontAskAgain = false}) async {
  final resp = await http.post(
    Uri.parse('$_apiBase/chat/tool-permission'),
    headers: {'Content-Type': 'application/json', ..._auth},
    body: jsonEncode({'uuid': uuid, 'requestId': requestId, 'decision': decision, if (dontAskAgain) 'dontAskAgain': true}),
  );
  if (resp.statusCode != 200) throw Exception('tool-permission HTTP ${resp.statusCode}: ${resp.body}');
}
```

- [ ] **Step 4: 分析**

Run: `cd app && flutter analyze lib/state/prefs.dart lib/api/protocol.dart lib/api/chat_api.dart`
Expected: No issues found.（注意：扩了枚举后，所有对 CcPermissionMode 的穷举 switch 会报缺分支——Task 6 一并补；本步若报这些 switch 错误属预期，Task 6 修。）

- [ ] **Step 5: Commit**

```bash
git add app/lib/state/prefs.dart app/lib/api/protocol.dart app/lib/api/chat_api.dart
git commit -m "app: 6 permission modes + tool_permission wire/decision API"
```

---

## Task 6: App — 权限 picker 补 auto / dontAsk（CLI 文案）

**Files:**
- Modify: `app/lib/screens/tabs/chat_tab.dart`（`_runtimePermissionPage` 选项列表 4787-4811 一带：label/description/icon/color 三处 switch 补全 6 值）

**Interfaces:**
- Consumes: `CcPermissionMode`（Task 5）。

- [ ] **Step 1: 补全选项文案（对齐 CLI 语义）**

在权限选项定义处加入两项，并保证 label/description/icon/color 的 switch 覆盖全部 6 值：

```dart
// 6 项顺序：default, acceptEdits, plan, auto, dontAsk, bypass
// 文案对齐 Claude Code CLI：
// default     '默认'        '危险操作前询问（对齐 Claude Code 默认）'
// acceptEdits 'Accept Edits' '自动接受文件编辑，其它危险操作仍询问'
// plan        'Plan'        '只规划不执行，产出计划后再确认'
// auto        'Auto'        '模型分类器自动批准/拒绝，必要时才询问'
// dontAsk     "Don't Ask"   '不弹询问；未预先批准的工具直接拒绝'
// bypass      'Bypass'      '跳过所有权限检查，完整访问'
```
图标/颜色给 auto（如 `Icons.auto_awesome` + accent）、dontAsk（如 `Icons.block` + textDim）补上，消除 Step 4/Task5 的穷举 switch 报错。

- [ ] **Step 2: 分析**

Run: `cd app && flutter analyze lib`
Expected: No issues found.（所有 CcPermissionMode switch 现已全覆盖）

- [ ] **Step 3: Commit**

```bash
git add app/lib/screens/tabs/chat_tab.dart
git commit -m "app: permission picker adds Auto and Don't Ask modes (CLI-aligned copy)"
```

---

## Task 7: App — Claude 工具审批卡 + per-session 待审批状态 + 回传

**Files:**
- Create: `app/lib/widgets/tool_permission_card.dart`
- Modify: `app/lib/screens/tabs/chat_tab.dart`（`_ChatSessionRuntime` 加 `pendingToolPermissions`；`_handleWireMessage` 处理 `ToolPermissionRequestMsg`；渲染卡 + 回传；resolve 后移除）

**Interfaces:**
- Consumes: `ToolPermissionRequestMsg`、`ChatApi.toolPermission`。
- Produces: 审批卡 `ToolPermissionCard(req, onDecide: (decision, dontAskAgain) {...})`。

- [ ] **Step 1: 审批卡 widget（CLI 风格：Allow / Allow & don't ask again / Deny）**

```dart
// tool_permission_card.dart —— 视觉脚手架可参考 codex_approval_card.dart，但选项对齐 CLI
class ToolPermissionCard extends StatelessWidget {
  final ToolPermissionRequestMsg req;
  final void Function(String decision, bool dontAskAgain) onDecide;
  const ToolPermissionCard({super.key, required this.req, required this.onDecide});
  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final title = req.title ?? '${req.displayName ?? req.toolName} 需要确认';
    // 标题 + 危险标记(req.safetyManual) + input 摘要(command/path) + 三个按钮
    // 按钮：允许 / 允许且不再询问该工具 / 拒绝
    // onTap → onDecide('allow', false) / onDecide('allow', true) / onDecide('deny', false)
    return Card( /* ... 用 t 配色，safetyManual 时标红 ... */ );
  }
}
```

- [ ] **Step 2: runtime 加 per-session 待审批 map**

在 `_ChatSessionRuntime`（chat_tab.dart:87-135）加：
```dart
final Map<String, ToolPermissionRequestMsg> pendingToolPermissions = {};
```
（**进 runtime、不进全局 provider**——遵守 per-session 隔离约束。）

- [ ] **Step 3: _handleWireMessage 处理请求 + 渲染 + 回传**

在 `_handleWireMessage` 的分支链加：
```dart
} else if (msg is ToolPermissionRequestMsg) {
  // 进当前事件 runtime 的待审批表（_runtime 已被 _onSseEvent 设为 eventRuntime）
  _runtime.pendingToolPermissions[msg.requestId] = msg;
  // 不进 _messages；由专门的 pending 区或内联卡渲染
}
```
在 build 的消息流末尾/输入框上方，遍历 `_runtime.pendingToolPermissions.values` 渲染 `ToolPermissionCard`，onDecide：
```dart
onDecide: (decision, dontAskAgain) {
  final uuid = _sessionId; final api = _chatApi;
  if (uuid != null && api != null) {
    unawaited(api.toolPermission(uuid, req.requestId, decision, dontAskAgain: dontAskAgain)
      .catchError((e) { /* top toast 报错 */ }));
  }
  setState(() => _runtime.pendingToolPermissions.remove(req.requestId));
}
```

- [ ] **Step 4: 分析**

Run: `cd app && flutter analyze lib`
Expected: No issues found.

- [ ] **Step 5: 手动联调（dev server）**

Run: `pnpm dev:server`，App 连上，权限切到 default，发一个会触发 Bash 的请求。
Expected: App 弹审批卡；点"允许"→工具执行继续；点"拒绝"→Claude 收到 deny 继续；点"允许且不再询问"→后续同工具不再弹（session 内）。

- [ ] **Step 6: Commit**

```bash
git add app/lib/widgets/tool_permission_card.dart app/lib/screens/tabs/chat_tab.dart
git commit -m "app: interactive Claude tool approval card (per-session, CLI-aligned)"
```

---

## Task 8（可选 / 收尾）：auto-deny 事件渲染 + plan-mode 退出确认

**Files:**
- Modify: `server/src/agents/claude/serialize.ts`（路由 SDK auto-deny system 事件 → wire `tool_auto_denied`）
- Modify: `app/lib/api/protocol.dart` + `chat_tab.dart`（渲染一条"X 被自动拒绝（classifier/dontAsk）"的轻提示）
- （plan-mode）确认 ExitPlanMode 现状，必要时加"计划就绪，确认执行？"卡

**说明**：sdk.d.ts:3795 描述了 auto-deny 事件（auto 分类器/dontAsk/deny 规则导致的无交互拒绝）。为完全忠实 CLI，应让用户看到"为什么这个工具没跑"。本 task 优先级低于 1-7，可作为后续。plan 模式的 ExitPlanMode 审批 UI 同理，先 Task 1 spike 时观察 plan 模式行为再决定是否纳入。

- [ ] Step 1: 先确认现状（serialize 是否已透传该 system subtype；App 是否已渲染 ExitPlanMode），再决定是否实现。
- [ ] Step 2-N: 按确认结果补充（本 task 待 1-7 完成、用户确认后再细化）。

---

## Self-Review

**1. Spec coverage：**
- 6 个 mode 全支持 → Task 2（类型）+ Task 5（Dart 枚举）+ Task 6（picker）✓
- default/acceptEdits/auto 弹真实审批（完全忠实 CLI）→ Task 4（canUseTool 改造）+ Task 7（卡）✓
- auto 分类器是 SDK 内部、host 不实现 → Architecture 已说明，Task 4 只在被调到时弹 ✓
- dontAsk → Task 5/6 透传；auto-deny 可见性 → Task 8（可选）
- "don't ask again"（CLI 的 scope）→ Task 3 updatedPermissions + Task 7 按钮 ✓
- per-session 隔离（不重蹈串页覆辙）→ Task 7 Step 2 进 runtime ✓
- 不碰 Codex/Gemini、HTTP 只 GET/POST 无占位符 → 端点 `POST /chat/tool-permission` ✓

**2. Placeholder scan：** Task 1 是 spike（按定义无产物代码）；Task 8 明确标记为"待确认后细化"的可选收尾，非占位符遗漏。其余任务均含真实代码。

**3. Type consistency：**
- `requestId` = SDK `toolUseID` 全链路一致（server req.requestId / 端点 requestId / Dart requestId）✓
- registry `register(toolUseId, originalInput, toolName)`（Task 4 Step 5 决定把 toolName 并入 register）——**需回填 Task 3 的 register 签名**：实现时把 Task 3 的 `register(toolUseId, originalInput)` 改为 `register(toolUseId, originalInput, toolName)` 并在 `answer` 内自取 toolName，去掉 answer 的 `opts.toolName` 依赖。Task 3 测试相应调整。
- `decision: 'allow'|'deny'` 在 server 端点 / registry.answer / Dart API 三处一致 ✓

---

## 已知风险 / 待 spike 验证

1. **canUseTool 触发面**（Task 1）：若 default 模式下 SDK 也对 Read/Grep 调 canUseTool，则需在 `buildCanUseTool` 里对一组"安全只读工具"直接 allow，避免过度打扰——这会偏离"纯被动"设计，Task 1 实测后定。
2. **updatedPermissions 形状**：session 级 allow 规则若 SDK 不接受，dontAskAgain 退化为"每次问"（功能不丢）。
3. **auto 模式**：能否仅靠 `permissionMode:'auto'` 让 SDK 内部分类器工作、且升级时正确回调我们的 canUseTool——Task 1 用 auto 模式实测确认。
4. **运行时改 mode**：现有 `setPermissionMode` 走 `iter.setPermissionMode`；切到/切出 plan、auto 是否即时生效需联调。
