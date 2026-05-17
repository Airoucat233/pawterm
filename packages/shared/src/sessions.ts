/** REST schema for session management endpoints. */

export interface Project {
  name: string;
  path: string;
}

export interface SessionSummary {
  session_id: string;
  summary?: string | null;
  title?: string | null;
  tags: string[];
  last_modified?: number | null;
  cwd?: string | null;
  num_messages?: number | null;
  total_cost_usd?: number | null;
}

export interface HealthResponse {
  status: 'ok';
  version: string;
  hostname: string;
}

/** 一条 session 当前的持有者：某个活着的 claude CLI 进程。 */
export interface SessionHolder {
  pid: number;
  cwd: string;
  startedAt: number;
  kind?: string;
}

export interface SessionHolderResponse {
  holder: SessionHolder | null;
}
