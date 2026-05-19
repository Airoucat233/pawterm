/**
 * Wire protocol between server and clients (Flutter app, Web admin).
 * Stable contract — any change needs migration in both client codebases.
 */

// ============== Common ==============

export type PermissionMode = 'default' | 'acceptEdits' | 'plan' | 'bypassPermissions';

// ============== Health ==============

export interface HealthResponse {
  status: string;
  version: string;
  hostname: string;
  serverId?: string;
  pairingOpen?: boolean;
}

// ============== Pairing ==============

// POST /admin/pair-window — requires adminToken
export interface PairWindowRequest {}
export interface PairWindowResponse { pin: string; expiresAt: number }

// POST /pair/start — no auth; PIN is the out-of-band credential
export interface PairStartRequest { deviceId: string; deviceName: string; pin: string }
export type PairStartResponse =
  | { ok: true; deviceToken: string; serverId: string }
  | { ok: false; error: 'bad_pin' | 'pairing_closed' | 'rate_limited' };

// POST /pair/qr-claim — requires adminToken
export interface PairQrClaimRequest { deviceId: string; deviceName: string }
export interface PairQrClaimResponse { deviceToken: string; serverId: string }

// GET /admin/devices — list; DELETE /admin/devices/:id — revoke; requires adminToken
export interface PairedDevice {
  deviceId: string;
  name: string;
  pairedAt: number;  // epoch ms
  lastSeen: number | null;
}

// GET /admin/qr — requires adminToken
export interface QrResponse { content: string; svg: string }

// POST /pair/request — no auth
export interface PairRequestRequest { deviceId: string; deviceName: string }
export interface PairRequestResponse { requestId: string; pollUrl: string }

// GET /pair/poll/:requestId — no auth, long-poll
export type PairPollResponse =
  | { status: 'pending' }
  | { status: 'approved'; deviceToken: string; serverId: string }
  | { status: 'denied' | 'expired' };

// GET /admin/events — SSE stream, requires adminToken
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

/** Available Claude models the client can pick. Keep in sync with App + Web. */
export const KNOWN_MODELS = [
  { id: 'claude-sonnet-4-6', label: 'Sonnet 4.6', tier: 'fast' },
  { id: 'claude-opus-4-7', label: 'Opus 4.7', tier: 'powerful' },
  { id: 'claude-haiku-4-5', label: 'Haiku 4.5', tier: 'cheap' },
] as const;

export type ChatServerMessage =
  | { type: 'session_ready'; session_key: string; cwd: string; permission_mode: PermissionMode; resumed?: string | null; busy?: boolean }
  | { type: 'assistant'; model?: string; content: ContentBlock[]; timestamp?: number }
  | { type: 'user'; content: ContentBlock[]; timestamp?: number }
  | { type: 'system'; subtype?: string; data?: unknown; timestamp?: number }
  | { type: 'result'; subtype?: string; duration_ms?: number; duration_api_ms?: number; is_error: boolean; num_turns?: number; session_id?: string; total_cost_usd?: number; usage?: unknown; timestamp?: number }
  | { type: 'stream_block_start'; index: number; kind: string }
  | { type: 'stream_delta'; index: number; kind: 'text' | 'thinking'; text: string }
  | { type: 'stream_block_stop'; index: number }
  | { type: 'compact_boundary'; trigger: string | null; pre_tokens: number | null; post_tokens: number | null; duration_ms: number | null; timestamp?: number }
  | { type: 'error'; message: string }
  | { type: 'pong' };

export type ContentBlock =
  | { type: 'text'; text: string }
  | { type: 'thinking'; text: string }
  | { type: 'tool_use'; id: string; name: string; input: Record<string, unknown> }
  | { type: 'tool_result'; tool_use_id: string; content: ToolResultContent; is_error: boolean };

export type ToolResultContent =
  | string
  | Array<{ type: 'text'; text: string } | { type: string; [k: string]: unknown }>
  | null;

// ============== Chat REST: POST /chat/answer ==============

/** POST /chat/answer 请求 body */
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
