import type { FastifyInstance, FastifyReply } from 'fastify';
import { dirname, join } from 'node:path';

import { configPath } from './config.js';
import { IdeasStore, type IdeaStatus } from './ideas-store.js';

type IdeasAction = 'create' | 'update' | 'archive' | 'unarchive' | 'delete';

type IdeasBody = {
  action?: IdeasAction;
  id?: string;
  payload?: {
    text?: string;
  };
};

export async function registerIdeasApi(
  app: FastifyInstance,
  opts: { store?: IdeasStore } = {},
) {
  const store = opts.store ?? new IdeasStore(join(dirname(configPath), 'ideas.json'));

  app.get<{ Querystring: { status?: string } }>('/ideas', async (req, reply) => {
    const status = parseStatus(req.query.status, reply);
    if (!status) return;
    return { ideas: await store.list(status) };
  });

  app.post<{ Body: IdeasBody }>('/ideas', async (req, reply) => {
    const body = req.body ?? {};
    try {
      switch (body.action) {
        case 'create':
          return { idea: await store.create(body.payload?.text ?? '') };
        case 'update': {
          const id = requireId(body.id, reply);
          if (!id) return;
          const idea = await store.update(id, body.payload?.text ?? '');
          if (!idea) return notFound(reply);
          return { idea };
        }
        case 'archive':
        case 'unarchive': {
          const id = requireId(body.id, reply);
          if (!id) return;
          const idea = await store.setStatus(
            id,
            body.action === 'archive' ? 'archived' : 'active',
          );
          if (!idea) return notFound(reply);
          return { idea };
        }
        case 'delete': {
          const id = requireId(body.id, reply);
          if (!id) return;
          const ok = await store.delete(id);
          if (!ok) return notFound(reply);
          return { ok: true };
        }
        default:
          reply.code(400);
          return { error: 'invalid action' };
      }
    } catch (err) {
      reply.code(400);
      return { error: (err as Error).message };
    }
  });
}

function parseStatus(raw: string | undefined, reply: FastifyReply): IdeaStatus | 'all' | null {
  const status = raw ?? 'active';
  if (status === 'active' || status === 'archived' || status === 'all') return status;
  reply.code(400);
  return null;
}

function requireId(id: string | undefined, reply: FastifyReply): string | null {
  if (id && id.trim()) return id;
  reply.code(400);
  return null;
}

function notFound(reply: FastifyReply) {
  reply.code(404);
  return { error: 'not found' };
}
