import { readdir, stat } from 'node:fs/promises';
import { join } from 'node:path';

export type FsEntry = {
  name: string;
  path: string;
  isDir: boolean;
  sizeBytes: number;
  modifiedMs: number;
};

export async function listFsEntries(abs: string): Promise<FsEntry[]> {
  const entries = await readdir(abs, { withFileTypes: true });
  const items = await Promise.all(
    entries.map(async (entry) => {
      const fp = join(abs, entry.name);
      try {
        const st = await stat(fp);
        return {
          name: entry.name,
          path: fp,
          isDir: entry.isDirectory(),
          sizeBytes: st.size,
          modifiedMs: Math.floor(st.mtimeMs),
        };
      } catch {
        return null;
      }
    }),
  );
  const visible = items.filter((item): item is FsEntry => item !== null);
  visible.sort((a, b) => {
    if (a.isDir !== b.isDir) return a.isDir ? -1 : 1;
    return a.name.localeCompare(b.name);
  });
  return visible;
}
