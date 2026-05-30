# Multi-Agent Provider 架构设计

> 状态：approved by user (2026-05-22)
> 范围：Server + Shared Protocol + Flutter App。Web 管理面板跟随基础协议做最小兼容，不作为首要体验面。
> 交互原型：`docs/superpowers/mockups/multi-agent-mobile-demo.html`

## 背景

PawTerm 当前以 Claude Code 为核心：server 通过 `@anthropic-ai/claude-agent-sdk` 驱动会话，App 展示 Claude 会话、工具卡片、终端和文件浏览。下一步需要接入 Codex，并为未来 Gemini CLI、Aider、本地 Agent 等预留扩展空间。

这个功能不能通过简单替换 `claude` 命令实现。Claude、Codex、Gemini 的会话 ID、历史格式、权限模型、运行参数和事件流都不同。设计目标是让这些差异在 Server 端形成清晰模块边界，在 App 端形成直觉一致的交互。

## 用户心智模型

产品交互固定为：

```text
Connection -> Project -> Agent -> Session -> Turn
```

- **Connection**：连接到一台运行 PawTerm server 的开发机。
- **Project**：选择开发机上的一个白名单项目。
- **Agent**：选择谁来处理这个项目，如 Claude Code、Codex、Gemini CLI。
- **Session**：某个 Agent 在该项目里的会话。
- **Turn**：一次用户输入和 Agent 响应。

Agent 是一等对象，不是模型选择器。用户在项目页选择默认 Agent，新会话默认使用项目 Agent；已有会话保持创建时的 Agent，不允许在会话内原地切换到另一个 Agent。

## 非目标

- 不把 Claude 历史迁移成 Codex 历史。
- 不在同一 Session 内混用多个 Agent。
- 不做跨 Agent 上下文自动转换。未来可以做 "Fork with Codex"，但它是新会话语义。
- 不把所有 Provider 的模型塞进同一个全局模型列表。
- 不隐藏或重命名 Agent 的原生工具/事件名称。

## App 交互设计

### 项目页

项目页显示当前项目默认 Agent：

```text
claude-companion
/workspace/shulex/claude-companion

当前 Agent
[ Codex ]
  GPT-5.4 · workspace-write · 高风险命令前询问

会话
[全部] [Claude] [Codex]
```

点击当前 Agent 打开 Agent 选择 bottom sheet。这个入口在项目页，而不是设置页，因为用户的实际决策是"这个项目派谁来干活"。

### Agent 选择器

Agent 选择器展示所有可用或已知 Agent：

- Claude Code：显示登录/可用状态、默认模型、Claude 权限模式摘要。
- Codex：显示登录/可用状态、默认模型、sandbox/approval 摘要。
- Gemini CLI：如果未实现，显示"稍后"或"未配置"，作为扩展位置。

选择某个 Agent 后，可以设为本项目默认。这个选择只影响新会话，不改变已有会话。

### 新会话

点击"新会话"后先确认 Agent，再显示该 Agent 的运行参数：

- Claude Code：`model`、`permission_mode`。
- Codex：`model`、`reasoning_effort`、`sandbox`、`approval_policy`。
- Gemini：未来由 Gemini provider capabilities 决定。

模型和权限归属于 Agent，不做全局模型列表。

### Chat 页

Chat 页顶部显示当前会话 Agent 和运行参数：

```text
Codex · GPT-5.4
workspace-write · 按需审批
```

Chat 页不提供"切换 Agent"按钮。更多菜单里可以有：

- 修改当前 Agent 支持的运行参数。
- 未来添加"用另一个 Agent 重新开始"或"Fork with Codex"。

### 工具卡片命名规则

PawTerm **复用渲染组件，但不抽象掉 Agent 的原生命名**。

在 Claude Chat 中，工具卡片标题显示 Claude 原生名称：

```text
Bash
Edit
Read
TodoWrite
mcp__ask-user-question__AskUserQuestion
```

在 Codex Chat 中，工具卡片标题显示 Codex 原生定义：

```text
commandExecution
fileChange
mcpToolCall
dynamicToolCall
plan
reasoning
```

不加 `Claude ·` / `Codex ·` 前缀，因为 Chat 页已经处在对应 Agent 上下文里。也不把它们统一改名为"命令"、"文件变更"等通用标题。

实现上可以复用 renderer：

- Claude `Bash` 和 Codex `commandExecution` 都使用命令输出布局。
- Claude `Edit` 和 Codex `fileChange` 都使用文件变更布局。
- Claude `TodoWrite` 和 Codex `plan` 可以使用各自专门布局或共享列表布局。

但是卡片标题和可展开原始 payload 必须保持 Agent 原生语义。

## Shared Protocol 设计

### Agent 类型

`packages/shared/src/protocol.ts` 新增：

```ts
export type AgentKind = 'claude' | 'codex' | 'gemini';

export type AgentStatus =
  | 'ready'
  | 'not_installed'
  | 'not_logged_in'
  | 'disabled'
  | 'error';

export interface AgentCapabilities {
  streaming: boolean;
  history: boolean;
  approvals: boolean;
  modelSwitch: boolean;
  runtimeSwitch: boolean;
  rawEvents: boolean;
}

export interface AgentInfo {
  kind: AgentKind;
  label: string;
  status: AgentStatus;
  statusMessage?: string;
  defaultRuntime: AgentRuntime;
  capabilities: AgentCapabilities;
}
```

### Session 引用

裸 `session_id` 不再足够表达来源。新增统一引用：

```ts
export interface AgentSessionRef {
  agent: AgentKind;
  id: string;
}
```

`SessionSummary` 扩展：

```ts
export interface SessionSummary {
  session_id: string;
  agent: AgentKind;
  summary?: string | null;
  title?: string | null;
  tags: string[];
  last_modified?: number | null;
  cwd?: string | null;
  num_messages?: number | null;
  total_cost_usd?: number | null;
  holder_device_id?: string | null;
}
```

保持 `session_id` 字段名，降低 App/Web 迁移成本；新增 `agent` 表示 ID 所属 Provider。

### Runtime

Runtime 使用 discriminated union：

```ts
export type AgentRuntime =
  | ClaudeRuntime
  | CodexRuntime
  | GeminiRuntime;

export interface ClaudeRuntime {
  agent: 'claude';
  model?: string;
  permission_mode: PermissionMode;
}

export interface CodexRuntime {
  agent: 'codex';
  model?: string;
  reasoning_effort?: 'low' | 'medium' | 'high' | 'xhigh';
  sandbox: 'read-only' | 'workspace-write' | 'danger-full-access';
  approval_policy: 'untrusted' | 'on-request' | 'never';
}

export interface GeminiRuntime {
  agent: 'gemini';
  model?: string;
  approval_policy?: string;
}
```

Claude 的 `PermissionMode` 保留原定义。Codex 不复用 `PermissionMode`，因为 Codex 的 sandbox 和 approval 是两个独立维度。

### Chat 事件

现有 `ChatServerMessage` 增加可选 Agent metadata：

```ts
export interface AgentEventMeta {
  agent: AgentKind;
  session_ref?: AgentSessionRef;
  native_type?: string;
  native_name?: string;
  native_event?: string;
  raw_payload?: unknown;
}
```

对已有 wire message 采用交叉扩展：

```ts
export type AgentChatServerMessage = ChatServerMessage & AgentEventMeta;
```

工具内容块扩展：

```ts
export type ContentBlock =
  | { type: 'text'; text: string }
  | { type: 'thinking'; text: string }
  | {
      type: 'tool_use';
      id: string;
      name: string;              // UI 标题：Agent 原生命名
      input: Record<string, unknown>;
      native_type?: string;
      native_event?: string;
      raw_payload?: unknown;
    }
  | {
      type: 'tool_result';
      tool_use_id: string;
      content: ToolResultContent;
      is_error: boolean;
      native_type?: string;
      native_event?: string;
      raw_payload?: unknown;
    };
```

`name` 必须保持 Agent 原生名称，例如 Claude `Bash` 或 Codex `commandExecution`。

## Server 架构

新增目录：

```text
server/src/agents/
  types.ts
  registry.ts
  claude/
    provider.ts
    session.ts
    serialize.ts
    sessions.ts
  codex/
    provider.ts
    client.ts
    serialize.ts
    sessions.ts
```

### Provider 接口

```ts
export interface AgentProvider {
  readonly kind: AgentKind;

  getInfo(): Promise<AgentInfo>;

  listSessions(input: {
    cwd: string;
    limit: number;
    offset: number;
    includeSubdirs: boolean;
  }): Promise<SessionSummary[]>;

  getSessionMessages(input: {
    cwd: string;
    sessionId: string;
    limit: number;
    beforeUuid?: string;
  }): Promise<{
    messages: Array<{
      uuid: string | null;
      parent_uuid: string | null;
      timestamp: number | null;
      message: AgentChatServerMessage | unknown;
    }>;
    has_more: boolean;
    total: number;
  }>;

  startTurn(input: {
    cwd: string;
    sessionId: string;
    text: string;
    runtime: AgentRuntime;
    deviceId: string;
  }): Promise<AgentRun>;

  interrupt(input: { sessionId: string }): Promise<void>;

  setRuntime?(input: {
    sessionId: string;
    runtime: Partial<AgentRuntime>;
  }): Promise<void>;
}
```

`AgentRun` 由 provider 内部消费原生事件，并向 `chat-rest.ts` 提供统一 async iterable 或 callback。

### Registry

`registry.ts` 持有 provider map：

```ts
const providers: Record<AgentKind, AgentProvider> = {
  claude: new ClaudeAgentProvider(),
  codex: new CodexAgentProvider(),
  gemini: new DisabledAgentProvider('gemini'),
};
```

所有 REST endpoint 先解析 `agent`，再分发到 provider。`agent` 缺省为 `claude`，保持旧客户端兼容。

### Claude Provider

Claude provider 从现有文件迁移：

- `session-manager.ts` -> `agents/claude/session.ts`
- `serialize.ts` -> `agents/claude/serialize.ts`
- `sessions-api.ts` 中 Claude 专用读 `~/.claude/projects` 的逻辑 -> `agents/claude/sessions.ts`

迁移后行为保持不变：

- 使用 `@anthropic-ai/claude-agent-sdk`。
- 保持 `permission_mode`。
- 保持 `AskUserQuestion` MCP/native 逻辑。
- 保持 Claude jsonl/raw-history 行为。
- 工具卡片名称继续来自 Claude `tool_use.name`。

### Codex Provider

Codex provider 通过 `codex app-server` 协议接入，不跑裸 TUI：

- Server 在本机启动或连接 Codex app-server。
- PawTerm 不把 Codex app-server 直接暴露到 LAN。
- PawTerm 负责认证、项目白名单和移动端协议。

`codex/client.ts` 负责：

- 启动/连接 `codex app-server --listen unix://...`。
- 实现 JSON-RPC request/response。
- 订阅 Codex notifications。
- 将 server requests（审批、用户输入）桥接到 PawTerm 的审批 API。

Codex 关键方法：

- 新会话：`thread/start` 后 `turn/start`。
- 续会话：`thread/resume` 后 `turn/start`。
- 历史列表：`thread/list`。
- 历史消息：`thread/turns/items/list`。
- 中断：`turn/interrupt`。

Codex serialization：

| Codex ThreadItem / Notification | PawTerm wire | UI 标题 |
|---|---|---|
| `agentMessage` | assistant text | 不作为工具卡 |
| `reasoning` | thinking / tool-like block | `reasoning` |
| `plan` | assistant/tool block | `plan` |
| `commandExecution` | tool_use/tool_result pair | `commandExecution` |
| `fileChange` | tool_use/tool_result pair | `fileChange` |
| `mcpToolCall` | tool_use/tool_result pair | `mcpToolCall` |
| `dynamicToolCall` | tool_use/tool_result pair | `dynamicToolCall` |
| approval request | tool_use/question-like event | 原生 request method 或 item type |

`name` 使用上表 UI 标题，保持 Codex 原生命名。

## REST API 变更

### Agents

新增：

```text
GET /agents
```

返回：

```ts
{ agents: AgentInfo[] }
```

### Sessions

改造：

```text
GET /sessions?cwd=...&agent=all|claude|codex
GET /sessions/:id/messages?cwd=...&agent=claude|codex
GET /sessions/:id/raw-history?cwd=...&agent=claude
```

`raw-history` 初期只对 Claude 开放；Codex 历史通过 app-server 的 thread item API。

### Chat

`POST /chat/stream` body 增加：

```ts
{
  agent?: AgentKind;       // 缺省 claude
  runtime?: AgentRuntime;  // 新字段，旧 permission_mode/model 仍兼容 claude
}
```

旧字段兼容：

- `permission_mode` + `model` + 无 `agent` -> Claude runtime。
- `agent: 'claude'` 时仍接受旧字段。
- `agent: 'codex'` 必须使用 Codex runtime，缺省值由 server config 或 provider default 填充。

`POST /chat/model` 和 `POST /chat/permission` 后续收敛为：

```text
POST /chat/runtime
```

旧 endpoint 保留给 Claude 兼容。

## Flutter App 架构

新增：

```text
app/lib/api/agents_api.dart
app/lib/state/agents_store.dart
app/lib/widgets/agent_badge.dart
app/lib/widgets/agent_picker_sheet.dart
app/lib/screens/tabs/chat_agent_bar.dart
```

### State

新增 `AgentKind`、`AgentInfo`、`AgentRuntime` Dart 类型，手动同步 shared protocol。

`CurrentSession` 扩展：

```dart
class CurrentSession {
  final String cwd;
  final String label;
  final AgentKind agent;
  final String? sessionId;
  final AgentRuntime runtime;
}
```

项目默认 Agent 存在本地 prefs：

```dart
Map<String, AgentKind> projectDefaultAgents; // key = cwd
```

如果没有设置，默认 `claude`，保证旧行为。

### ProjectPickerScreen

改造项目展开内容：

- 顶部显示当前 Agent card。
- 点击打开 `AgentPickerSheet`。
- 会话列表支持 `All / Claude / Codex` 筛选。
- session tile 显示 Agent badge，但 tile 主标题仍显示会话标题。

### New Chat Flow

点击新会话：

1. 使用项目默认 Agent。
2. 弹出新会话 sheet，展示 Agent 和运行参数。
3. 可以临时"换一个 Agent"。
4. 确认后进入 Chat。

### ChatTab

Chat 顶部新增 `ChatAgentBar`：

- 显示当前 Agent 原生 runtime 摘要。
- 点击打开当前 Agent runtime sheet。
- 不提供切换 Agent。

发送消息时，`ChatApi.startStream` 带上 `agent` 和 `runtime`。

### ToolCallCard

`ToolCallCard` 的标题规则：

```dart
final title = block.name;
```

不要根据 `agent` 翻译或替换 title。

新增 renderer 选择逻辑：

```dart
ToolRenderer rendererFor(ContentBlock block, AgentKind agent) {
  switch (agent) {
    case AgentKind.claude:
      return claudeRendererFor(block.name);
    case AgentKind.codex:
      return codexRendererFor(block.name);
    case AgentKind.gemini:
      return genericJsonRenderer;
  }
}
```

Renderer 可以共享布局，但不能改标题。

卡片详情区增加"原始事件"折叠块，显示 `raw_payload` pretty JSON。默认折叠。

## Web 管理面板

Web 先做最小兼容：

- SessionSummary 识别 `agent`。
- Chat stream 请求默认 `agent: 'claude'`。
- 多 Agent UI 不作为首轮目标。

如果 Web 遇到 Codex session，可显示 badge 并允许只读历史；完整交互优先在 App 端完成。

## 测试策略

### Server

新增单元测试：

- `agents/registry`：缺省 agent 为 Claude，未知 agent 返回 400。
- Claude provider：迁移后 `messageToWire` 保持原测试通过。
- Codex serializer：`commandExecution` 输出 `name: 'commandExecution'`，不改成 `Command`。
- Codex serializer：`fileChange` 输出 `name: 'fileChange'`。
- Sessions API：`agent=all` 合并 Claude/Codex 并保留 `agent` 字段。
- Chat stream：旧 body 无 agent 时仍走 Claude。

### App

Widget tests：

- ProjectPicker 显示当前 Agent card。
- AgentPickerSheet 能设置项目默认 Agent。
- Session tile 显示 Agent badge。
- ToolCallCard 在 Claude `Bash` 时标题为 `Bash`。
- ToolCallCard 在 Codex `commandExecution` 时标题为 `commandExecution`。
- 原始事件折叠块默认关闭，点击后显示 pretty JSON。

### 手动验收

1. 旧 Claude 会话列表和聊天不回归。
2. 项目页能选择 Codex 作为默认 Agent。
3. 新 Codex 会话能发送 prompt，收到 streaming 文本。
4. Codex 命令执行卡片标题为 `commandExecution`。
5. Claude 命令卡片标题仍为 `Bash`。
6. Codex 审批请求能在手机端选择允许/拒绝。
7. 会话列表 `All / Claude / Codex` 筛选正确。

## 风险与边界

- Codex app-server 是 experimental，协议可能变。缓解：Codex 相关代码隔离在 `agents/codex/`，并通过生成类型或快照测试保护 serializer。
- Claude 和 Codex 的历史分页语义不同。缓解：Provider 接口只暴露 PawTerm 需要的分页形状，内部自行适配。
- Raw payload 可能很大。缓解：App 默认折叠，Server 可对 raw JSON 做大小上限，超限时保留摘要和截断标记。
- 多 Agent runtime 字段复杂。缓解：runtime 使用 discriminated union，不做字符串 map 大杂烩。

## 实施顺序

1. Shared protocol 加 Agent 类型、runtime、session agent 字段。
2. Server 引入 `AgentProvider` 接口和 registry。
3. 将现有 Claude 逻辑迁入 `ClaudeAgentProvider`，确保测试不变。
4. App 加 Agent 状态、项目默认 Agent、Agent picker 和 session badge。
5. ToolCallCard 支持按 Agent 选择 renderer，并保留原生命名。
6. 接 Codex app-server client。
7. 实现 Codex sessions/history/stream/approval。
8. 完整联调和回归。
