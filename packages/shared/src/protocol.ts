/**
 * Wire protocol between server and clients (Flutter app, Web admin).
 * Stable contract — any change needs migration in both client codebases.
 */

// ============== Common ==============

export type PermissionMode = 'default' | 'acceptEdits' | 'plan' | 'bypassPermissions';

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

export interface AgentSessionRef {
  agent: AgentKind;
  id: string;
}

export interface ClaudeRuntime {
  agent: 'claude';
  model?: string;
  permission_mode: PermissionMode;
  /**
   * 扩展推理（thinking）配置。可选，未指定时 SDK 自行决定默认（Opus 4.6+ 默认 adaptive）。
   *   - adaptive: Claude 自行决定何时/多少 thinking（Opus 4.6+）
   *   - enabled: 固定 token 预算（旧模型）
   *   - disabled: 完全关闭 extended thinking
   * 字段命名与 SDK ThinkingConfig 保持一致，方便服务端透传。
   */
  thinking?: ThinkingConfig;
}

export type ThinkingConfig =
  | { type: 'adaptive'; display?: 'summarized' | 'omitted' }
  | { type: 'enabled'; budget_tokens?: number; display?: 'summarized' | 'omitted' }
  | { type: 'disabled' };

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

export type AgentRuntime = ClaudeRuntime | CodexRuntime | GeminiRuntime;

export interface AgentInfo {
  kind: AgentKind;
  label: string;
  status: AgentStatus;
  statusMessage?: string;
  defaultRuntime: AgentRuntime;
  capabilities: AgentCapabilities;
}

export interface AgentsResponse {
  agents: AgentInfo[];
}

export interface SessionRuntimeRecord {
  agent: AgentKind;
  cwd: string;
  sessionId: string;
  runtime: AgentRuntime;
  updatedAt: number;
}

export interface AgentEventMeta {
  agent?: AgentKind;
  session_ref?: AgentSessionRef;
  native_type?: string;
  native_name?: string;
  native_event?: string;
  raw_payload?: unknown;
}

// ============== Health ==============

export interface HealthResponse {
  status: string;
  version: string;
  hostname: string;
  serverId?: string;
  pairingOpen?: boolean;
  advertisedAddress?: {
    name: string;
    address: string;
  };
}

// ============== Pairing ==============

// POST /api/admin/pair-window — requires adminToken
export interface PairWindowRequest {}
export interface PairWindowResponse { pin: string; expiresAt: number }

// POST /api/pair/start — no auth; PIN is the out-of-band credential
export interface PairStartRequest { deviceId: string; deviceName: string; pin: string }
export type PairStartResponse =
  | { ok: true; deviceToken: string; serverId: string }
  | { ok: false; error: 'bad_pin' | 'pairing_closed' | 'rate_limited' };

// POST /api/pair/qr-claim — no auth; QR claim is the credential
export interface PairQrClaimRequest { deviceId: string; deviceName: string }
export interface PairQrClaimResponse { deviceToken: string; serverId: string }

// GET /api/admin/devices — list; DELETE /api/admin/devices/:id — revoke; requires admin auth
export interface PairedDevice {
  deviceId: string;
  name: string;
  pairedAt: number;  // epoch ms
  lastSeen: number | null;
}

export interface AdminLoginCodeResponse { admin_login_code: string; expires_at: number }
export interface AdminAccessTokenResponse { admin_access_token: string; expires_at: number }
export interface AdminPasswordRequest { password: string }

// GET /api/admin/qr — requires admin auth
export interface QrResponse { content: string; svg: string; expiresAt?: number }

// POST /api/pair/request — no auth
export interface PairRequestRequest { deviceId: string; deviceName: string }
export interface PairRequestResponse { requestId: string; pollUrl: string }

// GET /api/pair/poll/:requestId — no auth, long-poll
export type PairPollResponse =
  | { status: 'pending' }
  | { status: 'approved'; deviceToken: string; serverId: string }
  | { status: 'denied' | 'expired' };

// GET /api/admin/events — SSE stream, requires admin Bearer auth
export type AdminEvent =
  | { type: 'pair_request'; requestId: string; deviceId: string; deviceName: string; ip: string; createdAt: number }
  | { type: 'device_paired'; deviceId: string; name: string }
  | { type: 'device_revoked'; deviceId: string }
  | { type: 'device_connected'; deviceId: string }
  | { type: 'device_disconnected'; deviceId: string }
  | { type: 'server_status'; pairedDevices: number; activeDevices: number };

// ============== Chat WebSocket: /ws/session (web admin only) ==============
// The Flutter app has migrated to REST + SSE. This union type is kept only for
// the web admin's wsChat.ts until that client is also migrated.

export type ChatClientMessage =
  | { type: 'init'; cwd: string; permission_mode?: PermissionMode; resume?: string; model?: string }
  | { type: 'user_message'; text: string }
  | { type: 'set_model'; model: string }
  | { type: 'set_permission_mode'; mode: PermissionMode }
  | { type: 'interrupt' }
  | { type: 'ping' };

/** Available Claude models the client can pick. Keep in sync with App + Web.
 *
 * NOTE: ID 来源——`@anthropic-ai/claude-code` 2.1.x 二进制里抓到的最新档位。
 * `claude-fable-5` 是 Claude Code 2.1 新增的 coding 专用档位（"fable-mythos"
 * 系列），目前未公开文档，仅在 CLI binary 里曝光；保留 placeholder，
 * 需要服务端 `/models` 实际暴露后客户端才会真正用上。
 */
export const KNOWN_MODELS = [
  { id: 'claude-sonnet-4-6', label: 'Sonnet 4.6', tier: 'fast' },
  { id: 'claude-opus-4-8', label: 'Opus 4.8', tier: 'powerful' },
  { id: 'claude-haiku-4-5', label: 'Haiku 4.5', tier: 'cheap' },
  { id: 'claude-fable-5', label: 'Fable 5', tier: 'coding' },
] as const;

// ============== Models ==============

export type ModelTier = 'fast' | 'powerful' | 'cheap' | 'coding' | 'default';
export type ModelProvider = 'anthropic' | 'bedrock' | 'vertex' | 'openai' | 'unknown';

export interface ModelInfo {
  id: string;
  label: string;
  tier: ModelTier;
  description?: string;
}

export interface ModelsResponse {
  provider: ModelProvider;
  current: string;
  models: ModelInfo[];
}

export type ChatServerMessage =
  | ({ type: 'session_ready'; session_key: string; cwd: string; permission_mode: PermissionMode; resumed?: string | null; busy?: boolean } & AgentEventMeta)
  | ({ type: 'assistant'; model?: string; content: ContentBlock[]; timestamp?: number; parent_tool_use_id?: string | null } & AgentEventMeta)
  | ({ type: 'user'; content: ContentBlock[]; timestamp?: number; parent_tool_use_id?: string | null } & AgentEventMeta)
  | ({ type: 'system'; subtype?: string; data?: unknown; timestamp?: number } & AgentEventMeta)
  | ({ type: 'result'; subtype?: string; duration_ms?: number; duration_api_ms?: number; is_error: boolean; num_turns?: number; session_id?: string; total_cost_usd?: number; usage?: unknown; timestamp?: number } & AgentEventMeta)
  | ({ type: 'stream_block_start'; index: number; kind: string; parent_tool_use_id?: string | null } & AgentEventMeta)
  | ({ type: 'stream_delta'; index: number; kind: 'text' | 'thinking'; text: string; parent_tool_use_id?: string | null } & AgentEventMeta)
  | ({ type: 'stream_block_stop'; index: number; parent_tool_use_id?: string | null } & AgentEventMeta)
  | ({ type: 'compact_boundary'; trigger: string | null; pre_tokens: number | null; post_tokens: number | null; duration_ms: number | null; timestamp?: number } & AgentEventMeta)
  | ({ type: 'rate_limit_info'; info: RateLimitInfo; timestamp?: number } & AgentEventMeta)
  | ({ type: 'session_status'; status: SessionStatus; compact_result?: 'success' | 'failed' | null; compact_error?: string | null; timestamp?: number } & AgentEventMeta)
  | ({ type: 'informational'; content: string; level: InformationalLevel; tool_use_id?: string | null; timestamp?: number } & AgentEventMeta)
  | ({ type: 'tool_progress'; tool_use_id: string; tool_name: string; elapsed_seconds: number; parent_tool_use_id?: string | null; timestamp?: number } & AgentEventMeta)
  | ({ type: 'thinking_tokens'; estimated_tokens: number; estimated_tokens_delta: number; timestamp?: number } & AgentEventMeta)
  | ({ type: 'error'; message: string } & AgentEventMeta)
  | { type: 'pong' };

// ============== Session Status / Informational ==============

/**
 * SDK 当前正在进行的内部操作。null 表示空闲（无内部操作进行中）。
 *   - 'compacting': 正在压缩会话上下文（用户触发 /compact 或自动触发）
 *   - 'requesting': 正在向 Anthropic API 发请求等回包
 * SDK 在状态进入和退出时都会推送（退出时 status=null + 可选的 compact_result）。
 */
export type SessionStatus = 'compacting' | 'requesting' | null;

/**
 * SDK 自发的提示消息级别：
 *   - 'info': 极弱提示（默认隐藏）
 *   - 'notice': 灰色 inactive 渲染
 *   - 'suggestion'/'warning': 显著渲染
 */
export type InformationalLevel = 'info' | 'notice' | 'suggestion' | 'warning';

// ============== Rate Limits ==============

/**
 * Claude.ai 订阅用户的限流信息，SDK 通过 SDKRateLimitEvent 推送。
 * 字段含义同 SDK：
 *   - status: 'allowed' 正常 / 'allowed_warning' 接近阈值 / 'rejected' 已限流
 *   - rate_limit_type: 5h 窗口 / 7d 窗口 / overage（充值额度）
 *   - utilization: 0-1，当前窗口已用比例
 *   - resets_at: 当前窗口重置 unix 毫秒时间戳
 *   - overage_*: 充值额度相关，没开通的话全为 null/undefined
 */
export type RateLimitStatus = 'allowed' | 'allowed_warning' | 'rejected';
export type RateLimitType = 'five_hour' | 'seven_day' | 'seven_day_opus' | 'seven_day_sonnet' | 'overage';

export interface RateLimitInfo {
  status: RateLimitStatus;
  resets_at?: number | null;
  rate_limit_type?: RateLimitType | null;
  utilization?: number | null;
  overage_status?: RateLimitStatus | null;
  overage_resets_at?: number | null;
  is_using_overage?: boolean | null;
  overage_in_use?: boolean | null;
  surpassed_threshold?: number | null;
}

export type ContentBlock =
  | { type: 'text'; text: string }
  | { type: 'thinking'; text: string }
  | {
      type: 'tool_use';
      id: string;
      name: string;
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

export type ToolResultContent =
  | string
  | Array<{ type: 'text'; text: string } | { type: string; [k: string]: unknown }>
  | null;

// ============== Chat REST: POST /api/chat/answer ==============

/** POST /api/chat/answer 请求 body */
export interface AnswerQuestionRequest {
  uuid: string;
  tool_use_id: string;
  answers: Record<string, string>;
  annotations?: Record<string, { preview?: string; notes?: string }>;
}

// ============== Shell WebSocket: /ws/shell ==============

export type ShellClientMessage =
  | { type: 'init'; cwd: string; shell?: string; cols: number; rows: number; token?: string }
  | { type: 'input'; data: string }
  | { type: 'resize'; cols: number; rows: number }
  | { type: 'signal'; signal: 'SIGINT' | 'SIGTERM' | 'SIGKILL' };

export type ShellServerMessage =
  | { type: 'ready' }
  | { type: 'output'; data: string }
  | { type: 'exit'; code: number }
  | { type: 'error'; message: string }
  | { type: 'cwd'; cwd: string };
