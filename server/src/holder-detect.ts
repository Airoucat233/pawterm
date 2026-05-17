import { readdir, readFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join } from 'node:path';

/**
 * Claude CLI 在 ~/.claude/sessions/<pid>.json 写自己的运行态。
 * 文件内容来自 claude-code 源码 src/utils/concurrentSessions.ts:registerSession()：
 *   { pid, sessionId, cwd, startedAt, kind, ... }
 * 进程退出时通过 registerCleanup 删除自己的文件。
 *
 * 我们在 resume 之前调用 findHolder()，避免和一个正在持有该 session 的 CLI 终端
 * 同时写同一份 jsonl。
 */
export interface SessionHolder {
  pid: number;
  cwd: string;
  startedAt: number;
  kind?: string;
}

function sessionsDir(): string {
  return join(homedir(), '.claude', 'sessions');
}

/** 用 kill(pid, 0) 检查进程是否还活着。 */
function isProcessRunning(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (e) {
    const err = e as NodeJS.ErrnoException;
    // EPERM = 存在但没权限发信号（仍算活），ESRCH = 不存在
    return err.code === 'EPERM';
  }
}

/** 返回该 sessionId 当前的持有者（活进程）；没有则 null。 */
export async function findHolder(sessionId: string): Promise<SessionHolder | null> {
  let files: string[];
  try {
    files = await readdir(sessionsDir());
  } catch {
    return null;
  }

  for (const file of files) {
    if (!/^\d+\.json$/.test(file)) continue;
    const pid = parseInt(file.slice(0, -5), 10);
    let raw: string;
    try {
      raw = await readFile(join(sessionsDir(), file), 'utf-8');
    } catch {
      continue;
    }
    let parsed: { sessionId?: string; cwd?: string; startedAt?: number; kind?: string };
    try {
      parsed = JSON.parse(raw);
    } catch {
      continue;
    }
    if (parsed.sessionId !== sessionId) continue;
    if (!isProcessRunning(pid)) continue;
    return {
      pid,
      cwd: parsed.cwd ?? '',
      startedAt: parsed.startedAt ?? 0,
      kind: parsed.kind,
    };
  }
  return null;
}
