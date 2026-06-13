import { mkdtemp } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import Fastify from 'fastify';
import { describe, expect, it } from 'vitest';

import { registerIdeasApi } from '../ideas-api.js';
import { IdeasStore } from '../ideas-store.js';

async function appWithStore() {
  const dir = await mkdtemp(join(tmpdir(), 'pawterm-ideas-'));
  const store = new IdeasStore(join(dir, 'ideas.json'));
  const app = Fastify({ logger: false });
  await registerIdeasApi(app, { store });
  return { app, store };
}

describe('ideas API', () => {
  it('creates, updates, archives, unarchives, and deletes ideas through GET/POST endpoints', async () => {
    const { app } = await appWithStore();

    const create = await app.inject({
      method: 'POST',
      url: '/ideas',
      payload: { action: 'create', payload: { text: '记录一个灵感' } },
    });
    expect(create.statusCode).toBe(200);
    const created = create.json();
    expect(created.idea).toMatchObject({ text: '记录一个灵感', status: 'active' });

    const update = await app.inject({
      method: 'POST',
      url: '/ideas',
      payload: {
        action: 'update',
        id: created.idea.id,
        payload: { text: '更新后的灵感' },
      },
    });
    expect(update.statusCode).toBe(200);
    expect(update.json().idea).toMatchObject({ text: '更新后的灵感', status: 'active' });

    const archive = await app.inject({
      method: 'POST',
      url: '/ideas',
      payload: { action: 'archive', id: created.idea.id },
    });
    expect(archive.statusCode).toBe(200);
    expect(archive.json().idea).toMatchObject({ status: 'archived' });

    const archivedList = await app.inject({ method: 'GET', url: '/ideas?status=archived' });
    expect(archivedList.statusCode).toBe(200);
    expect(archivedList.json().ideas).toHaveLength(1);

    const unarchive = await app.inject({
      method: 'POST',
      url: '/ideas',
      payload: { action: 'unarchive', id: created.idea.id },
    });
    expect(unarchive.statusCode).toBe(200);
    expect(unarchive.json().idea).toMatchObject({ status: 'active' });

    const remove = await app.inject({
      method: 'POST',
      url: '/ideas',
      payload: { action: 'delete', id: created.idea.id },
    });
    expect(remove.statusCode).toBe(200);
    expect(remove.json()).toEqual({ ok: true });

    const activeList = await app.inject({ method: 'GET', url: '/ideas' });
    expect(activeList.statusCode).toBe(200);
    expect(activeList.json().ideas).toEqual([]);

    await app.close();
  });

  it('persists ideas to disk', async () => {
    const dir = await mkdtemp(join(tmpdir(), 'pawterm-ideas-'));
    const file = join(dir, 'ideas.json');
    const first = new IdeasStore(file);
    const idea = await first.create('持久化灵感');

    const second = new IdeasStore(file);
    expect(await second.list('all')).toEqual([
      expect.objectContaining({ id: idea.id, text: '持久化灵感' }),
    ]);
  });
});
