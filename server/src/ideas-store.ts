import { randomUUID } from 'node:crypto';
import { existsSync } from 'node:fs';
import { mkdir, readFile, rename, writeFile } from 'node:fs/promises';
import { dirname } from 'node:path';

export type IdeaStatus = 'active' | 'archived';

export type Idea = {
  id: string;
  text: string;
  status: IdeaStatus;
  createdAt: number;
  updatedAt: number;
};

type IdeasFile = {
  ideas?: Idea[];
};

export class IdeasStore {
  constructor(private readonly filePath: string) {}

  async list(status: IdeaStatus | 'all' = 'active'): Promise<Idea[]> {
    const ideas = await this.readAll();
    return ideas
      .filter((idea) => status === 'all' || idea.status === status)
      .sort((a, b) => b.updatedAt - a.updatedAt);
  }

  async create(text: string): Promise<Idea> {
    const cleaned = cleanText(text);
    const now = Date.now();
    const idea: Idea = {
      id: randomUUID(),
      text: cleaned,
      status: 'active',
      createdAt: now,
      updatedAt: now,
    };
    const ideas = await this.readAll();
    ideas.push(idea);
    await this.writeAll(ideas);
    return idea;
  }

  async update(id: string, text: string): Promise<Idea | null> {
    const cleaned = cleanText(text);
    const ideas = await this.readAll();
    const idea = ideas.find((item) => item.id === id);
    if (!idea) return null;
    idea.text = cleaned;
    idea.updatedAt = Date.now();
    await this.writeAll(ideas);
    return idea;
  }

  async setStatus(id: string, status: IdeaStatus): Promise<Idea | null> {
    const ideas = await this.readAll();
    const idea = ideas.find((item) => item.id === id);
    if (!idea) return null;
    idea.status = status;
    idea.updatedAt = Date.now();
    await this.writeAll(ideas);
    return idea;
  }

  async delete(id: string): Promise<boolean> {
    const ideas = await this.readAll();
    const next = ideas.filter((item) => item.id !== id);
    if (next.length === ideas.length) return false;
    await this.writeAll(next);
    return true;
  }

  private async readAll(): Promise<Idea[]> {
    if (!existsSync(this.filePath)) return [];
    const raw = await readFile(this.filePath, 'utf8');
    const parsed = JSON.parse(raw) as IdeasFile;
    return Array.isArray(parsed.ideas) ? parsed.ideas.filter(isIdea) : [];
  }

  private async writeAll(ideas: Idea[]): Promise<void> {
    await mkdir(dirname(this.filePath), { recursive: true });
    const tmp = `${this.filePath}.${process.pid}.tmp`;
    await writeFile(tmp, `${JSON.stringify({ ideas }, null, 2)}\n`, 'utf8');
    await rename(tmp, this.filePath);
  }
}

function cleanText(text: string): string {
  const cleaned = text.trim();
  if (!cleaned) throw new Error('text required');
  if (cleaned.length > 4000) throw new Error('text too long');
  return cleaned;
}

function isIdea(value: unknown): value is Idea {
  if (!value || typeof value !== 'object') return false;
  const item = value as Partial<Idea>;
  return typeof item.id === 'string' &&
    typeof item.text === 'string' &&
    (item.status === 'active' || item.status === 'archived') &&
    typeof item.createdAt === 'number' &&
    typeof item.updatedAt === 'number';
}
