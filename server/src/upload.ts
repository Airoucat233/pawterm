import type { FastifyInstance, FastifyRequest, FastifyReply } from 'fastify';
import { mkdir, writeFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';

import { isPathAllowed } from './config.js';

const MAX_FILE_BYTES = 25 * 1024 * 1024; // 25 MB

/**
 * Sanitize a filename so it stays a single path segment.
 * - drop path separators
 * - keep ASCII letters / digits / . - _ ; replace others with _
 * - collapse repeats; trim leading dots (no hidden files)
 */
function sanitize(name: string): string {
  const base = name.replace(/[/\\]/g, '');
  let out = '';
  for (const ch of base) {
    out += /[A-Za-z0-9._\-]/.test(ch) ? ch : '_';
  }
  out = out.replace(/_+/g, '_').replace(/^\.+/, '');
  return out || 'file';
}

function timestamp(): string {
  const d = new Date();
  const pad = (n: number, w = 2) => String(n).padStart(w, '0');
  return (
    `${d.getFullYear()}${pad(d.getMonth() + 1)}${pad(d.getDate())}-` +
    `${pad(d.getHours())}${pad(d.getMinutes())}${pad(d.getSeconds())}-` +
    `${pad(d.getMilliseconds(), 3)}`
  );
}

export async function registerUpload(app: FastifyInstance): Promise<void> {
  app.post('/upload', async (req: FastifyRequest, reply: FastifyReply) => {
    const cwd = (req.query as { cwd?: string }).cwd;
    if (!cwd) {
      reply.code(400);
      return { error: 'cwd required' };
    }
    const abs = resolve(cwd);
    if (!isPathAllowed(abs)) {
      reply.code(403);
      return { error: 'cwd not allowed' };
    }

    const part = await req.file({ limits: { fileSize: MAX_FILE_BYTES } });
    if (!part) {
      reply.code(400);
      return { error: 'no file' };
    }

    const buf = await part.toBuffer();
    if (part.file.truncated) {
      reply.code(413);
      return { error: `file exceeds ${MAX_FILE_BYTES} bytes` };
    }

    const dir = join(abs, '.claude', 'attachments');
    await mkdir(dir, { recursive: true });
    const filename = `${timestamp()}-${sanitize(part.filename)}`;
    const dest = join(dir, filename);
    await writeFile(dest, buf);

    return { path: dest, size: buf.length };
  });
}
