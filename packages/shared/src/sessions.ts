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
  /** 若该 session 当前被某个 claude CLI 进程持有，此字段包含进程信息。null 表示无持有者。 */
  holder?: SessionHolder | null;
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
