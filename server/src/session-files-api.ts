import type { FastifyInstance, FastifyReply } from 'fastify';
import { dirname, join, resolve } from 'node:path';
import { homedir } from 'node:os';

import { configPath, isPathAllowed } from './config.js';
import { SessionFilesStore } from './session-files-store.js';

type Body = {
  action?: 'add' | 'remove';
  sessionId?: string;
  id?: string;
  payload?: {
    path?: string;
    cwd?: string;
    sourceMessageId?: string;
  };
};

export async function registerSessionFilesApi(
  app: FastifyInstance,
  opts: { store?: SessionFilesStore } = {},
) {
  const store = opts.store ?? new SessionFilesStore(join(dirname(configPath), 'session-files.json'));

  app.get<{ Querystring: { sessionId?: string } }>('/session-files', async (req, reply) => {
    const sessionId = requireValue(req.query.sessionId, 'sessionId', reply);
    if (!sessionId) return;
    return { files: await store.list(sessionId) };
  });

  app.post<{ Body: Body }>('/session-files', async (req, reply) => {
    const body = req.body ?? {};
    switch (body.action) {
      case 'add': {
        const sessionId = requireValue(body.sessionId, 'sessionId', reply);
        const path = requireValue(body.payload?.path, 'path', reply);
        if (!sessionId || !path) return;
        const abs = resolve(path.replace(/^~/, homedir()));
        if (!isPathAllowed(abs)) {
          reply.code(403);
          return { error: 'path not allowed' };
        }
        return {
          file: await store.add({
            sessionId,
            path: abs,
            cwd: body.payload?.cwd,
            sourceMessageId: body.payload?.sourceMessageId,
          }),
        };
      }
      case 'remove': {
        const sessionId = requireValue(body.sessionId, 'sessionId', reply);
        const id = requireValue(body.id, 'id', reply);
        if (!sessionId || !id) return;
        const ok = await store.remove(sessionId, id);
        if (!ok) {
          reply.code(404);
          return { error: 'not found' };
        }
        return { ok: true };
      }
      default:
        reply.code(400);
        return { error: 'invalid action' };
    }
  });
}

function requireValue(value: string | undefined, name: string, reply: FastifyReply): string | null {
  if (value && value.trim()) return value;
  reply.code(400);
  return null;
}
