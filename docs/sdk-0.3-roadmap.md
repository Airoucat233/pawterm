# @anthropic-ai/claude-agent-sdk 0.3.x 新 feature 路线图

> SDK 升级到 0.3.179 之后值得后续接入的能力清单，按"性价比/落地难度"分级。
> 升级 commit 见 `feature/upgrade-sdk-0.3`。

---

## 评估口径

- ROI = (用户能感知的价值) / (改动量 × 风险)
- 落地难度按"server / app / 三端协议"分别打标。
- 优先级：⭐⭐⭐ 立刻有感、⭐⭐ 值得排期、⭐ 等需求出现再做。

---

## ⭐⭐⭐ 立刻有感

### 1. `SDKRateLimitInfo` / `SDKRateLimitEvent` — 显示限流状态

**价值**：长会话经常撞 5h/24h 限流。用户在 app 端看不到额度状态，被卡了才知道。

**做法**：
- server `chat-rest.ts` 把 `SDKRateLimitEvent` 转成 wire 消息（新 `rate_limit_info` 类型）。
- 协议层加 `RateLimitInfo { window_used, window_reset_at, ... }`。
- app composer 上方加个静默标签，临近上限（>80%）变橙、超限变红 + 时间倒计时。

**改动量**：server 一处 hook（小），protocol 加类型（小），app 加一个常驻 chip（中）。

### 2. `SDKStatusMessage` / `SDKSessionStateChangedMessage` — 启动 / 索引 / 暖机状态

**价值**：SDK 启动有几秒"warming up"窗口（读 jsonl、构建上下文）。现在 app 在这段时间显示"已就绪"但实际发不出去，UX 体感是"卡了"。

**做法**：在 SessionReady 之外新增 `session_status: 'warming' | 'indexing' | 'ready'` 维度，app 用 spinner overlay 区分。

**改动量**：server 加事件转发（小），protocol 改 SessionReady 或新加 SessionStatus（中），app 改 status bar（中）。

---

## ⭐⭐ 值得排期

### 3. `BackgroundTaskSummary` + `SDKTaskStartedMessage` / `SDKTaskProgressMessage` / `SDKTaskCompletedMessage` — 后台任务可视化

**价值**：Claude Code 2.1 加了"后台任务"概念（长跑的 build、test、deploy 等），SDK 暴露了进度事件。companion 可以做个"后台任务"面板，从 app 监控开发机上跑了什么。

**做法**：新加 `/tasks` REST + SSE，server 维护 task store；app 加 BottomNav 第 4 个 tab 或 Chat tab 上方的可折叠面板。

**改动量**：架构级——server 加 store + endpoint，protocol 加 task 类型组，app 新 tab。大。

**风险**：需要先理清 SDK 的 task lifecycle 跟我们 session 持有者的关系（同一个 session 可以并发多个 task 吗？task 中断该不该挡 session 关闭？）。

### 4. `SDKThinkingTokensMessage` + `ThinkingConfig` (Adaptive/Disabled/Enabled) — Thinking 控制

**价值**：现在 thinking 块靠手动 stream_delta(kind='thinking') 累积。0.3.x 暴露 `ThinkingAdaptive` 模式 + 显式 token 数。可以做到：
- 用户在 picker 旁加个 thinking 开关（off / adaptive / on）
- 显示当前 turn 用了多少 thinking tokens（用 SDKThinkingTokensMessage）

**做法**：runtime 加 `thinking` 字段（沿用现有 runtime 分发链路），display 时 surface 数据。

**改动量**：runtime schema 改（中），server SDK 调用参数加（小），app picker 改（中）。

### 5. `SDKToolProgressMessage` / `SDKToolUseSummaryMessage` — 工具执行进度

**价值**：现在 Bash 跑 30s 没任何反馈，用户不知道是不是卡住。新 SDK 给了 tool_progress 事件（"Bash: still running, 12s elapsed..."）。

**做法**：tool_call_card 内嵌一个进度行，订阅同一 tool_use_id 的 progress 事件。

**改动量**：protocol 加 type（小），app tool_call_card 改（中）。

### 6. `MessageDisplay` hook — 拦截 / 改写 AI 输出

**价值**：能在 SDK 把 assistant 消息丢给 client 之前改一手。可以做：
- 自动 redact 敏感信息（API key、token）
- 给特定模式加 emoji / 标签

**做法**：server 注册 hook，按规则匹配 → 改写 content blocks。

**改动量**：小 hook + 规则配置（中）。属于"产品定位"决定要不要做。

---

## ⭐ 等需求出现再做

### 7. `SessionCronSummary` + 定时会话 — 自动唤起

SDK 支持给 session 挂 cron schedule。companion 可以做"每天上班前帮我跑一遍 PR 检查"这类周期任务。需求驱动，没明确需求不做。

### 8. `WarmQuery` — 预热查询

低延迟首响应。当前网络是 LAN，延迟问题不突出，优先级低。

### 9. `UserDialogRequest` / `UserDialogResult` — 阻塞式弹窗

SDK 可以请求 client 弹窗收输入（区别于 elicitation 的非阻塞）。能用在 git commit message 这类"必须用户输入" 场景。需求驱动。

### 10. `SDKModelRefusalFallbackMessage` — 模型拒答时切换

当 primary 模型拒答（policy refusal），SDK 会发这个事件。可以提示用户"刚才换到了 fallback 模型"。需要 SDK 的 fallbackModel 配置先接通。

### 11. `SandboxSettings` / `SandboxFilesystemConfig` / `SandboxNetworkConfig` — 沙箱细粒度配置

目前我们只暴露 Codex 的 `sandbox: workspace-write/read-only`。0.3.x 把 sandbox 细化到文件系统 + 网络两个维度。如果产品想做"按目录、按域名"的精细控制，可以接。

### 12. `filterEscalatingDefaultMode` 工具函数

权限模式从 acceptEdits 升 bypassPermissions 的过滤工具。我们当前 permission flow 没用到 escalation 模式，先 mark。

---

## 不推荐接入

- `InMemorySessionStore`、`SessionStore` —— 我们靠 jsonl on-disk，不要在内存里再造一份。
- `createSdkMcpServer` —— 我们不做 MCP server，passthrough 即可。
- `tool` helper —— 我们不内嵌 SDK 自定义工具，全部走 Claude Code 原生工具集。

---

## 升级注意

0.3.179 实测对当前 server 代码 drop-in 兼容（typecheck + 145 tests 全过）。但要注意：

1. `HOOK_EVENTS` 多了 `MessageDisplay`，如果有 hook 系统遍历所有事件名，需要兼容新成员。
2. `Settings` 类型加了 `availableModels` / `enforceAvailableModels` / `modelOverrides` / `fallbackModel` / `disableBundledSkills` / `skillOverrides` 字段。我们不用就忽略。
3. 0.3.x 的 model alias 多了 `'fable'`（和 sonnet/opus/haiku 并列）。`KNOWN_MODELS` 里已经加了 `claude-fable-5` 占位。
