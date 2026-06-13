import { mkdtemp, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import Fastify from 'fastify';
import { describe, expect, it, vi } from 'vitest';

import { registerSessionFilesApi } from '../session-files-api.js';
import { SessionFilesStore } from '../session-files-store.js';

vi.mock('../config.js', () => ({
  configPath: join(tmpdir(), 'pawterm-test-config.json'),
  isPathAllowed: vi.fn((path: string) => path.includes('allowed-project')),
}));

async function appWithStore() {
  const dir = await mkdtemp(join(tmpdir(), 'pawterm-session-files-'));
  const store = new SessionFilesStore(join(dir, 'session-files.json'));
  const app = Fastify({ logger: false });
  await registerSessionFilesApi(app, { store });
  return { app };
}

describe('session files API', () => {
  it('adds, lists, deduplicates, and removes session file refs', async () => {
    const { app } = await appWithStore();
    const dir = await mkdtemp(join(tmpdir(), 'allowed-project-'));
    const filePath = join(dir, 'preview.html');
    await writeFile(filePath, '<html></html>', 'utf8');

    const add = await app.inject({
      method: 'POST',
      url: '/session-files',
      payload: {
        action: 'add',
        sessionId: 'session-a',
        payload: { path: filePath, cwd: dir },
      },
    });
    expect(add.statusCode).toBe(200);
    const added = add.json().file;
    expect(added).toMatchObject({
      sessionId: 'session-a',
      path: filePath,
      name: 'preview.html',
    });

    const duplicate = await app.inject({
      method: 'POST',
      url: '/session-files',
      payload: {
        action: 'add',
        sessionId: 'session-a',
        payload: { path: filePath, cwd: dir },
      },
    });
    expect(duplicate.statusCode).toBe(200);
    expect(duplicate.json().file.id).toBe(added.id);

    const list = await app.inject({
      method: 'GET',
      url: '/session-files?sessionId=session-a',
    });
    expect(list.statusCode).toBe(200);
    expect(list.json().files).toHaveLength(1);

    const remove = await app.inject({
      method: 'POST',
      url: '/session-files',
      payload: { action: 'remove', sessionId: 'session-a', id: added.id },
    });
    expect(remove.statusCode).toBe(200);
    expect(remove.json()).toEqual({ ok: true });

    await app.close();
  });

  it('rejects files outside allowed projects', async () => {
    const { app } = await appWithStore();
    const outside = join(tmpdir(), 'outside.html');

    const resp = await app.inject({
      method: 'POST',
      url: '/session-files',
      payload: {
        action: 'add',
        sessionId: 'session-a',
        payload: { path: outside },
      },
    });

    expect(resp.statusCode).toBe(403);
    await app.close();
  });
});
