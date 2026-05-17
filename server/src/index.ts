import cors from '@fastify/cors';
import websocketPlugin from '@fastify/websocket';
import Fastify from 'fastify';
import { createReadStream } from 'node:fs';
import { mkdir, readdir, stat } from 'node:fs/promises';
import { hostname, homedir } from 'node:os';
import { basename, join, resolve } from 'node:path';

import type { HealthResponse, Project } from '@cc/shared';

import { settings, addProject, removeProject, isPathAllowed, ProjectExistsError } from './config.js';
import { buildLoggerOptions } from './logger.js';
import { registerSessionsApi } from './sessions-api.js';
import { handleChatSocket } from './ws-chat.js';
import { handleShellSocket } from './ws-shell.js';

const VERSION = '0.2.0';

async function main(): Promise<void> {
  const app = Fastify({ logger: buildLoggerOptions() });

  await app.register(cors, { origin: true });
  await app.register(websocketPlugin);

  // REST: health
  app.get('/health', async (): Promise<HealthResponse> => ({ status: 'ok', version: VERSION, hostname: hostname() }));

  // REST: projects list
  app.get('/projects', async (): Promise<Project[]> => settings.projects);

  // REST: add project. name is optional; defaults to basename(path).
  app.post<{ Body: { name?: string; path: string } }>('/projects', async (req, reply) => {
    const { name, path: p } = req.body ?? {};
    if (!p) {
      reply.code(400);
      return { error: 'path required' };
    }
    try {
      return await addProject(name, p);
    } catch (err) {
      if (err instanceof ProjectExistsError) {
        reply.code(409);
        return { error: 'duplicate', path: err.path, message: '该目录已在项目列表中' };
      }
      throw err;
    }
  });

  // REST: remove project (config only — never touches ~/.claude/projects sessions).
  app.delete<{ Querystring: { path?: string } }>('/projects', async (req, reply) => {
    const p = req.query.path;
    if (!p) {
      reply.code(400);
      return { error: 'path required' };
    }
    const removed = await removeProject(p);
    if (!removed) reply.code(404);
    return { removed };
  });

  // REST: browse server filesystem (directories only)
  app.get<{ Querystring: { path?: string } }>('/browse', async (req): Promise<{ dirs: string[] }> => {
    const p = req.query.path;
    const abs = p ? resolve(p.replace(/^~/, homedir())) : homedir();
    try {
      const entries = await readdir(abs, { withFileTypes: true });
      const dirs = entries
        .filter((e) => e.isDirectory() && !e.name.startsWith('.'))
        .map((e) => `${abs}/${e.name}`)
        .sort();
      return { dirs };
    } catch {
      return { dirs: [] };
    }
  });

  // REST: create a new subdirectory under `parent`.
  app.post<{ Body: { parent: string; name: string } }>('/browse/mkdir', async (req, reply) => {
    const { parent, name } = req.body ?? {};
    if (!parent || !name) {
      reply.code(400);
      return { error: 'parent and name required' };
    }
    const safeName = name.replace(/[\/\\]/g, '').trim();
    if (!safeName || safeName === '.' || safeName === '..') {
      reply.code(400);
      return { error: 'invalid name' };
    }
    const abs = resolve(parent.replace(/^~/, homedir()), safeName);
    try {
      await mkdir(abs);
      return { path: abs };
    } catch (err) {
      const e = err as NodeJS.ErrnoException;
      if (e.code === 'EEXIST') {
        reply.code(409);
        return { error: 'exists', path: abs };
      }
      reply.code(500);
      return { error: e.message };
    }
  });

  // REST: filesystem — list and download files under whitelisted project roots.
  // Both endpoints accept absolute paths and reject anything outside isPathAllowed().
  app.get<{ Querystring: { path?: string } }>('/fs/ls', async (req, reply) => {
    const p = req.query.path;
    if (!p) { reply.code(400); return { error: 'path required' }; }
    const abs = resolve(p.replace(/^~/, homedir()));
    if (!isPathAllowed(abs)) { reply.code(403); return { error: 'path not allowed', path: abs }; }
    try {
      const entries = await readdir(abs, { withFileTypes: true });
      const items = await Promise.all(entries.map(async (e) => {
        if (e.name.startsWith('.')) return null;
        const fp = join(abs, e.name);
        try {
          const st = await stat(fp);
          return {
            name: e.name,
            path: fp,
            isDir: e.isDirectory(),
            sizeBytes: st.size,
            modifiedMs: Math.floor(st.mtimeMs),
          };
        } catch {
          return null;
        }
      }));
      type Entry = NonNullable<(typeof items)[number]>;
      const visible: Entry[] = items.filter((x): x is Entry => x !== null);
      visible.sort((a, b) => {
        if (a.isDir !== b.isDir) return a.isDir ? -1 : 1;
        return a.name.localeCompare(b.name);
      });
      return { path: abs, entries: visible };
    } catch (err) {
      reply.code(500);
      return { error: (err as Error).message };
    }
  });

  app.get<{ Querystring: { path?: string } }>('/fs/download', async (req, reply) => {
    const p = req.query.path;
    if (!p) { reply.code(400); return { error: 'path required' }; }
    const abs = resolve(p.replace(/^~/, homedir()));
    if (!isPathAllowed(abs)) { reply.code(403); return { error: 'path not allowed' }; }
    try {
      const st = await stat(abs);
      if (!st.isFile()) { reply.code(400); return { error: 'not a file' }; }
      const filename = basename(abs);
      reply
        .header('Content-Type', 'application/octet-stream')
        .header('Content-Length', String(st.size))
        .header(
          'Content-Disposition',
          `attachment; filename*=UTF-8''${encodeURIComponent(filename)}`,
        );
      return reply.send(createReadStream(abs));
    } catch (err) {
      const e = err as NodeJS.ErrnoException;
      if (e.code === 'ENOENT') { reply.code(404); return { error: 'not found' }; }
      reply.code(500);
      return { error: e.message };
    }
  });

  // REST: sessions
  await registerSessionsApi(app);

  // WebSocket: chat
  app.get('/ws/session', { websocket: true }, (socket, req) => {
    handleChatSocket(socket, req);
  });

  // WebSocket: shell
  app.get('/ws/shell', { websocket: true }, (socket, req) => {
    handleShellSocket(socket, req);
  });

  await app.listen({ host: settings.host, port: settings.port });
  app.log.info(`Claude Companion server v${VERSION} on http://${settings.host}:${settings.port}`);
  app.log.info(`Projects: ${settings.projects.map((p) => p.name).join(', ') || '(none)'}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
