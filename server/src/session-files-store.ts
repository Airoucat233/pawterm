import { randomUUID } from 'node:crypto';
import { existsSync } from 'node:fs';
import { mkdir, readFile, rename, writeFile } from 'node:fs/promises';
import { basename, dirname } from 'node:path';

export type SessionFile = {
  id: string;
  sessionId: string;
  path: string;
  cwd?: string;
  name: string;
  sourceMessageId?: string;
  createdAt: number;
  updatedAt: number;
};

type SessionFilesFile = {
  files?: SessionFile[];
};

export class SessionFilesStore {
  constructor(private readonly filePath: string) {}

  async list(sessionId: string): Promise<SessionFile[]> {
    const files = await this.readAll();
    return files
      .filter((file) => file.sessionId === sessionId)
      .sort((a, b) => b.updatedAt - a.updatedAt);
  }

  async add(input: {
    sessionId: string;
    path: string;
    cwd?: string;
    sourceMessageId?: string;
  }): Promise<SessionFile> {
    if (!input.sessionId.trim()) throw new Error('sessionId required');
    if (!input.path.trim()) throw new Error('path required');
    const files = await this.readAll();
    const existing = files.find(
      (file) => file.sessionId === input.sessionId && file.path === input.path,
    );
    const now = Date.now();
    if (existing) {
      existing.cwd = input.cwd ?? existing.cwd;
      existing.sourceMessageId = input.sourceMessageId ?? existing.sourceMessageId;
      existing.updatedAt = now;
      await this.writeAll(files);
      return existing;
    }
    const file: SessionFile = {
      id: randomUUID(),
      sessionId: input.sessionId,
      path: input.path,
      cwd: input.cwd,
      name: basename(input.path),
      sourceMessageId: input.sourceMessageId,
      createdAt: now,
      updatedAt: now,
    };
    files.push(file);
    await this.writeAll(files);
    return file;
  }

  async remove(sessionId: string, id: string): Promise<boolean> {
    const files = await this.readAll();
    const next = files.filter((file) => file.sessionId !== sessionId || file.id !== id);
    if (next.length === files.length) return false;
    await this.writeAll(next);
    return true;
  }

  private async readAll(): Promise<SessionFile[]> {
    if (!existsSync(this.filePath)) return [];
    const raw = await readFile(this.filePath, 'utf8');
    const parsed = JSON.parse(raw) as SessionFilesFile;
    return Array.isArray(parsed.files) ? parsed.files.filter(isSessionFile) : [];
  }

  private async writeAll(files: SessionFile[]): Promise<void> {
    await mkdir(dirname(this.filePath), { recursive: true });
    const tmp = `${this.filePath}.${process.pid}.tmp`;
    await writeFile(tmp, `${JSON.stringify({ files }, null, 2)}\n`, 'utf8');
    await rename(tmp, this.filePath);
  }
}

function isSessionFile(value: unknown): value is SessionFile {
  if (!value || typeof value !== 'object') return false;
  const item = value as Partial<SessionFile>;
  return typeof item.id === 'string' &&
    typeof item.sessionId === 'string' &&
    typeof item.path === 'string' &&
    typeof item.name === 'string' &&
    typeof item.createdAt === 'number' &&
    typeof item.updatedAt === 'number';
}
