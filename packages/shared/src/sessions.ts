/** REST schema for session management endpoints. */

import type { AgentKind } from './protocol.js';

export interface Project {
  name: string;
  path: string;
}

export interface SessionSummary {
  agent: AgentKind;
  session_id: string;
  summary?: string | null;
  title?: string | null;
  tags: string[];
  last_modified?: number | null;
  cwd?: string | null;
  num_messages?: number | null;
  total_cost_usd?: number | null;
  /**
   * 当前持有该 session 的设备 id。
   *   null / undefined  → 空闲
   *   "server"          → PC 端 claude CLI 占用（无 activeRun）
   *   其他字符串        → 某台移动设备通过 app 正在 streaming
   */
  holder_device_id?: string | null;
}
