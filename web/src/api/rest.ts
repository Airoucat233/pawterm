import type { AnswerQuestionRequest, HealthResponse, Project, SessionSummary } from '@pawterm/shared';

const BASE = '/api';

async function get<T>(path: string): Promise<T> {
  const r = await fetch(`${BASE}${path}`);
  if (!r.ok) throw new Error(`${r.status}: ${await r.text()}`);
  return r.json();
}

async function post<T>(path: string, body?: unknown): Promise<T> {
  const r = await fetch(`${BASE}${path}`, {
    method: 'POST',
    ...(body !== undefined
      ? { headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) }
      : {}),
  });
  if (!r.ok) throw new Error(`${r.status}: ${await r.text()}`);
  return r.json();
}

async function del<T>(path: string): Promise<T> {
  const r = await fetch(`${BASE}${path}`, { method: 'DELETE' });
  if (!r.ok) throw new Error(`${r.status}: ${await r.text()}`);
  return r.json();
}

export const api = {
  health: () => get<HealthResponse>('/health'),
  projects: () => get<Project[]>('/projects'),
  listSessions: (cwd: string) => get<SessionSummary[]>(`/sessions?cwd=${encodeURIComponent(cwd)}`),
  renameSession: (id: string, cwd: string, title: string) =>
    post<{ ok: boolean }>(
      `/sessions/${id}/rename?cwd=${encodeURIComponent(cwd)}&title=${encodeURIComponent(title)}`,
    ),
  tagSession: (id: string, cwd: string, tag: string) =>
    post<{ ok: boolean }>(
      `/sessions/${id}/tag?cwd=${encodeURIComponent(cwd)}&tag=${encodeURIComponent(tag)}`,
    ),
  forkSession: (id: string, cwd: string) =>
    post<{ session_id: string | null }>(`/sessions/${id}/fork?cwd=${encodeURIComponent(cwd)}`),
  deleteSession: (id: string, cwd: string) =>
    del<{ ok: boolean }>(`/sessions/${id}?cwd=${encodeURIComponent(cwd)}`),
  answerQuestion: (req: AnswerQuestionRequest) =>
    post<{ ok: boolean }>('/chat/answer', req),
};
