import cors from '@fastify/cors';
import multipart from '@fastify/multipart';
import websocketPlugin from '@fastify/websocket';
import Fastify from 'fastify';
import { createReadStream } from 'node:fs';
import { mkdir, readdir, stat } from 'node:fs/promises';
import { hostname, homedir, networkInterfaces } from 'node:os';
import { basename, dirname, join, resolve } from 'node:path';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import qrcode from 'qrcode-terminal';
import QRCode from 'qrcode';

const __dirname = dirname(fileURLToPath(import.meta.url));

import type { HealthResponse, Project, PairedDevice } from '@pawterm/shared';

import { registerChatRest } from './chat-rest.js';
import { settings, addProject, removeProject, isPathAllowed, ProjectExistsError, configPath, setPassword, clearPassword, isFirstRun, persistPairedDevices } from './config.js';
import { adminEventBus } from './event-bus.js';
import { buildLoggerOptions } from './logger.js';
import { startMdns } from './mdns.js';
import { pairingManager } from './pair.js';
import { registerSessionsApi } from './sessions-api.js';
import { registerUpload } from './upload.js';
import { handleShellSocket } from './ws-shell.js';

declare const __SERVER_VERSION__: string;
const VERSION: string = typeof __SERVER_VERSION__ !== 'undefined' ? __SERVER_VERSION__ : 'dev';

function getLanIp(): string {
  const ifaces = networkInterfaces();
  for (const name of Object.keys(ifaces)) {
    for (const iface of (ifaces[name] ?? [])) {
      if (!iface.internal && iface.family === 'IPv4') return iface.address;
    }
  }
  return 'localhost';
}

function isValidPassword(pw: string): boolean {
  return pw.length >= 8 && /[a-zA-Z]/.test(pw) && /[0-9]/.test(pw);
}

async function promptPassword(prompt: string): Promise<string> {
  if (!process.stdin.isTTY) {
    // Non-interactive: read single line from stdin
    return new Promise((resolve) => {
      const chunks: string[] = [];
      process.stdin.setEncoding('utf8');
      process.stdin.once('data', (d) => { resolve(String(d).trim()); });
    });
  }
  process.stdout.write(prompt);
  return new Promise((resolve) => {
    let input = '';
    process.stdin.setRawMode(true);
    process.stdin.resume();
    process.stdin.setEncoding('utf8');
    const onData = (char: string) => {
      if (char === '\n' || char === '\r' || char === '') {
        process.stdin.setRawMode(false);
        process.stdin.pause();
        process.stdin.removeListener('data', onData);
        process.stdout.write('\n');
        resolve(input);
      } else if (char === '') {
        process.stdin.setRawMode(false);
        process.stdin.pause();
        process.stdin.removeListener('data', onData);
        process.stdout.write('\n');
        process.exit(0);
      } else if (char === '' || char === '\b') {
        if (input.length > 0) {
          input = input.slice(0, -1);
          process.stdout.write('\b \b');
        }
      } else {
        input += char;
        process.stdout.write('*');
      }
    };
    process.stdin.on('data', onData);
  });
}

async function runPasswordCommand(): Promise<void> {
  const action = process.argv[3];
  if (!action || !['set', 'clear', 'show'].includes(action)) {
    console.log('Usage: pawterm-server password <set|clear|show>');
    console.log('  set [password]  Set a memorable password (prompts if omitted)');
    console.log('  clear           Remove the password');
    console.log('  show            Show the current password / token');
    process.exit(0);
  }
  if (action === 'show') {
    if (settings.password) {
      console.log(`Password : ${settings.password}`);
    } else {
      console.log('No password set. Auth uses the random token only.');
    }
    console.log(`Token    : ${settings.adminToken}`);
    process.exit(0);
  }
  if (action === 'clear') {
    await clearPassword();
    console.log('Password cleared.');
    process.exit(0);
  }
  if (action === 'set') {
    let pw = process.argv[4] ?? '';
    if (!pw) pw = await promptPassword('New password: ');
    if (!pw) { console.error('No password provided.'); process.exit(1); }
    if (!isValidPassword(pw)) {
      console.error('Password must be ≥8 characters and contain both letters and digits.');
      process.exit(1);
    }
    await setPassword(pw);
    console.log('Password set.');
    process.exit(0);
  }
}

async function firstRunSetup(): Promise<void> {
  console.log('\n┌─ PawTerm — First-time setup');
  console.log('│  A random token has been generated and saved.');
  console.log('│');
  console.log('│  Tip: Set a memorable password so you can connect from');
  console.log('│  new devices without needing the random token.');
  console.log('│');
  console.log('│  Requirements: ≥8 characters, letters + digits.');
  console.log('└─────────────────────────────────────────────────\n');
  const pw = await promptPassword('Set password (Enter to skip): ');
  if (!pw) {
    console.log('\nSkipped. Set one later: pawterm-server password set\n');
    return;
  }
  if (!isValidPassword(pw)) {
    console.log('\nInvalid (need ≥8 chars with letters and digits). Skipped.');
    console.log('Set one later: pawterm-server password set\n');
    return;
  }
  await setPassword(pw);
  console.log('\nPassword set!\n');
}

async function main(): Promise<void> {
  const app = Fastify({ logger: buildLoggerOptions() });

  await app.register(cors, { origin: true });
  await app.register(websocketPlugin);
  await app.register(multipart, { limits: { fileSize: 25 * 1024 * 1024 } });

  // Auth middleware
  // Skipped: /health (LAN discovery), /ws/shell (WS auth via init message), /pair/start (PIN is the credential)
  app.addHook('onRequest', async (req, reply) => {
    const url = req.url.split('?')[0];
    if (url === '/health' || url === '/ws/shell' || url === '/pair/start' || url === '/pair/request' || url.startsWith('/pair/poll/')) return;

    const auth = req.headers['authorization'];
    // Also accept ?token= query param for SSE connections (EventSource can't set headers)
    const queryToken = (req.query as Record<string, string | undefined>)['token'];
    const token = (typeof auth === 'string' && auth.startsWith('Bearer ') ? auth.slice(7) : null) ?? queryToken ?? null;

    const isAdmin = token === settings.adminToken || (!!settings.password && token === settings.password);
    const matchedDevice = token
      ? settings.pairedDevices.find((d) => d.deviceToken === token)
      : undefined;

    if (!isAdmin && !matchedDevice) {
      reply.code(401).send({ error: 'unauthorized' });
      return;
    }

    // Admin-only routes
    if (url.startsWith('/admin/') && !isAdmin) {
      reply.code(403).send({ error: 'admin token required' });
      return;
    }

    // Async update lastSeen for matched device (non-blocking)
    if (matchedDevice) {
      matchedDevice.lastSeen = Date.now();
      persistPairedDevices().catch(() => { /* ignore */ });
    }
  });

  // REST: health (no auth)
  app.get('/health', async (): Promise<HealthResponse> => ({
    status: 'ok',
    version: VERSION,
    hostname: hostname(),
    serverId: settings.serverId,
    pairingOpen: pairingManager.getState() === 'open',
  }));

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

  /**
   * Read a text file inline for preview. Reject anything that:
   *   - is not a regular file
   *   - is outside the whitelisted project roots
   *   - exceeds [maxBytes] (default 5 MB) — for big files the client should
   *     fall back to /fs/download instead.
   * Returns `{ path, size, text, truncated, binary? }`. If the file looks
   * binary we return `{ binary: true }` without `text` — client decides.
   */
  app.get<{ Querystring: { path?: string; max_bytes?: string } }>('/fs/cat', async (req, reply) => {
    const p = req.query.path;
    if (!p) { reply.code(400); return { error: 'path required' }; }
    const abs = resolve(p.replace(/^~/, homedir()));
    if (!isPathAllowed(abs)) { reply.code(403); return { error: 'path not allowed' }; }
    const maxBytes = Math.min(
      20 * 1024 * 1024,
      Math.max(1024, Number(req.query.max_bytes ?? 5 * 1024 * 1024)),
    );
    try {
      const st = await stat(abs);
      if (!st.isFile()) { reply.code(400); return { error: 'not a file' }; }
      const truncated = st.size > maxBytes;
      const { readFile } = await import('node:fs/promises');
      const buf = truncated
        ? await readFile(abs).then((b) => b.subarray(0, maxBytes))
        : await readFile(abs);
      // 简单嗅探二进制：前 8KB 含 NUL 或大量 < 0x20 非 ASCII 字符
      const head = buf.subarray(0, Math.min(buf.length, 8 * 1024));
      let nul = 0;
      let ctrl = 0;
      for (let i = 0; i < head.length; i++) {
        const c = head[i]!;
        if (c === 0) nul++;
        else if (c < 0x09 || (c > 0x0d && c < 0x20)) ctrl++;
      }
      const binary = nul > 0 || ctrl / Math.max(1, head.length) > 0.05;
      if (binary) {
        return { path: abs, size: st.size, binary: true };
      }
      return {
        path: abs,
        size: st.size,
        truncated,
        text: buf.toString('utf-8'),
      };
    } catch (err) {
      const e = err as NodeJS.ErrnoException;
      if (e.code === 'ENOENT') { reply.code(404); return { error: 'not found' }; }
      reply.code(500);
      return { error: e.message };
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

  // REST + SSE: chat
  await registerChatRest(app);

  // REST: upload (chat attachments)
  await registerUpload(app);

  // WebSocket: shell
  app.get('/ws/shell', { websocket: true }, (socket, req) => {
    handleShellSocket(socket, req);
  });

  // ============ Pairing endpoints ============

  // POST /admin/pair-window — adminToken required (checked by middleware)
  app.post('/admin/pair-window', async (_req, _reply) => {
    const result = pairingManager.openWindow();
    return result;
  });

  // POST /pair/start — no auth; PIN is the out-of-band credential
  app.post<{ Body: { deviceId: string; deviceName: string; pin: string } }>(
    '/pair/start',
    async (req, reply) => {
      const { deviceId, deviceName, pin } = req.body ?? {};
      if (!deviceId || !deviceName || !pin) {
        reply.code(400);
        return { ok: false, error: 'missing fields' };
      }
      const clientIp = req.ip ?? '0.0.0.0';
      const result = await pairingManager.tryRedeemPin(pin, deviceId, deviceName, clientIp);
      if (!result.ok) {
        reply.code(result.error === 'rate_limited' ? 429 : 403);
      }
      return result;
    },
  );

  // POST /pair/qr-claim — adminToken required
  app.post<{ Body: { deviceId: string; deviceName: string } }>(
    '/pair/qr-claim',
    async (req, reply) => {
      const { deviceId, deviceName } = req.body ?? {};
      if (!deviceId || !deviceName) {
        reply.code(400);
        return { error: 'missing fields' };
      }
      const result = await pairingManager.issueDeviceTokenAndNotify(deviceId, deviceName);
      return result;
    },
  );

  // GET /admin/devices — list paired devices (no deviceToken in response)
  app.get('/admin/devices', async (): Promise<PairedDevice[]> => {
    return settings.pairedDevices.map((d) => ({
      deviceId: d.deviceId,
      name: d.name,
      pairedAt: d.pairedAt,
      lastSeen: d.lastSeen,
    }));
  });

  // DELETE /admin/devices/:id — revoke a device
  app.delete<{ Params: { id: string } }>('/admin/devices/:id', async (req, reply) => {
    const { id } = req.params;
    const revoked = await pairingManager.revokeDevice(id);
    if (!revoked) {
      reply.code(404);
      return { error: 'device not found' };
    }
    return { revoked: true };
  });

  // ==========================================
  // ======== Slice 8: Web Admin APIs =========

  // GET /admin/qr — adminToken required
  app.get('/admin/qr', async (_req, _reply) => {
    const lanIp = getLanIp();
    const content = `pawterm://${lanIp}:${settings.port}?token=${settings.adminToken}`;
    const svg = await QRCode.toString(content, { type: 'svg' });
    return { content, svg };
  });

  // POST /pair/request — no auth
  app.post<{ Body: { deviceId: string; deviceName: string } }>(
    '/pair/request',
    async (req, reply) => {
      const { deviceId, deviceName } = req.body ?? {};
      if (!deviceId || !deviceName) {
        reply.code(400);
        return { ok: false, error: 'missing fields' };
      }
      const clientIp = req.ip ?? '0.0.0.0';
      const result = pairingManager.submitRequest(deviceId, deviceName, clientIp);
      if (!result.ok) {
        reply.code(result.error === 'rate_limited' ? 429 : 503);
        return { ok: false, error: result.error };
      }
      const requestId = result.request.requestId;
      return {
        requestId,
        pollUrl: `/pair/poll/${requestId}`,
      };
    },
  );

  // GET /pair/poll/:requestId — no auth, long-poll (up to 30s)
  app.get<{ Params: { requestId: string } }>(
    '/pair/poll/:requestId',
    async (req, reply) => {
      const { requestId } = req.params;
      const req2 = pairingManager.getRequest(requestId);
      if (!req2) {
        reply.code(404);
        return { error: 'not found' };
      }
      const updated = await pairingManager.waitForRequestUpdate(requestId, 30_000);
      if (!updated) {
        reply.code(404);
        return { error: 'not found' };
      }
      if (updated.status === 'approved' && updated.deviceToken) {
        return { status: 'approved', deviceToken: updated.deviceToken, serverId: settings.serverId };
      }
      return { status: updated.status };
    },
  );

  // POST /admin/pair-approve — adminToken required
  app.post<{ Body: { requestId: string } }>(
    '/admin/pair-approve',
    async (req, reply) => {
      const { requestId } = req.body ?? {};
      if (!requestId) {
        reply.code(400);
        return { error: 'requestId required' };
      }
      const result = await pairingManager.approve(requestId);
      if (!result) {
        reply.code(404);
        return { error: 'request not found or not pending' };
      }
      const pairReq = pairingManager.getRequest(requestId)!;
      return { ok: true, deviceId: pairReq.deviceId, name: pairReq.deviceName };
    },
  );

  // POST /admin/pair-deny — adminToken required
  app.post<{ Body: { requestId: string } }>(
    '/admin/pair-deny',
    async (req, reply) => {
      const { requestId } = req.body ?? {};
      if (!requestId) {
        reply.code(400);
        return { error: 'requestId required' };
      }
      const denied = pairingManager.deny(requestId);
      if (!denied) {
        reply.code(404);
        return { error: 'request not found or not pending' };
      }
      return { ok: true };
    },
  );

  // GET /admin/events — SSE stream; adminToken via Bearer header OR ?token= query
  app.get('/admin/events', async (req, reply) => {
    reply
      .raw.writeHead(200, {
        'Content-Type': 'text/event-stream',
        'Cache-Control': 'no-cache',
        'Connection': 'keep-alive',
        'X-Accel-Buffering': 'no',
      });

    const sendEvent = (type: string, data: unknown): void => {
      reply.raw.write(`event: ${type}\ndata: ${JSON.stringify(data)}\n\n`);
    };

    // Initial snapshot
    sendEvent('server_status', {
      type: 'server_status',
      pairedDevices: settings.pairedDevices.length,
      activeDevices: 0,
    });

    // Subscribe to admin events
    const unsubscribe = adminEventBus.subscribe((event) => {
      sendEvent(event.type, event);
    });

    // Keep-alive ping every 20s
    const keepAlive = setInterval(() => {
      reply.raw.write(': keep-alive\n\n');
    }, 20_000);

    // Cleanup on client disconnect
    req.raw.on('close', () => {
      clearInterval(keepAlive);
      unsubscribe();
    });

    // Never resolve — Fastify will manage the raw response
    return reply;
  });

  // GET /admin — serve built web admin SPA; fallback placeholder when not built
  const webDist = resolve(__dirname, '..', '..', 'web', 'dist');
  const contentType = (p: string): string => {
    if (p.endsWith('.js')) return 'application/javascript; charset=utf-8';
    if (p.endsWith('.css')) return 'text/css; charset=utf-8';
    if (p.endsWith('.html')) return 'text/html; charset=utf-8';
    if (p.endsWith('.svg')) return 'image/svg+xml';
    if (p.endsWith('.json')) return 'application/json';
    if (p.endsWith('.woff2')) return 'font/woff2';
    return 'application/octet-stream';
  };
  const serveStatic = async (relPath: string, reply: import('fastify').FastifyReply) => {
    const { readFile } = await import('node:fs/promises');
    const abs = resolve(webDist, relPath);
    if (!abs.startsWith(webDist)) { reply.code(403).send({ error: 'forbidden' }); return; }
    try {
      const buf = await readFile(abs);
      reply.header('Content-Type', contentType(abs)).send(buf);
    } catch {
      reply.code(404).send({ error: 'not found' });
    }
  };

  app.get('/admin', async (_req, reply) => {
    const { existsSync } = await import('node:fs');
    if (existsSync(resolve(webDist, 'admin.html'))) {
      await serveStatic('admin.html', reply);
      return;
    }
    reply
      .header('Content-Type', 'text/html; charset=utf-8')
      .send(
        '<!DOCTYPE html><html><head><meta charset="utf-8"><title>PawTerm Web Admin</title></head>' +
        '<body style="font-family:monospace;padding:2rem;background:#111;color:#eee">' +
        '<h2>🐾 PawTerm Web Admin</h2>' +
        '<p>Web admin not built yet — run <code>pnpm --filter @cc/web build</code>.</p>' +
        '</body></html>',
      );
  });
  // Admin SPA assets (Vite emits hashed filenames under /admin/ and /assets/)
  app.get<{ Params: { '*': string } }>('/admin/*', (req, reply) => serveStatic(join('admin', req.params['*']), reply));
  app.get<{ Params: { '*': string } }>('/assets/*', (req, reply) => serveStatic(join('assets', req.params['*']), reply));

  // ==========================================

  await app.listen({ host: settings.host, port: settings.port });

  app.log.info(
    [
      '',
      `┌─ PawTerm Server v${VERSION}`,
      `│  node     : ${process.version}`,
      `│  listen   : http://${settings.host}:${settings.port}`,
      `│  config   : ${configPath}`,
      `│  serverId : ${settings.serverId}`,
      `│  perm mode: ${settings.permissionMode}`,
      `│  log      : ${settings.logFormat} / ${settings.logLevel}${settings.logFile ? ` → ${settings.logFile}` : ''}`,
      `│  projects :`,
      ...settings.projects.map((p) => `│    • ${p.name}  (${p.path})`),
      ...(settings.projects.length === 0 ? ['│    (none)'] : []),
      `└─ ready`,
    ].join('\n'),
  );

  const lanIp = getLanIp();
  const qrContent = `pawterm://${lanIp}:${settings.port}?token=${settings.adminToken}`;
  app.log.info(`\nScan QR to connect from the app:\n  ${qrContent}\n`);
  await new Promise<void>((resolve) => {
    qrcode.generate(qrContent, { small: true }, (code) => {
      process.stdout.write(code + '\n');
      resolve();
    });
  });

  // Auto-open Web Admin in browser (macOS/Linux only, skip if PAWTERM_NO_OPEN=1)
  if (process.env.PAWTERM_NO_OPEN !== '1') {
    const adminUrl = `http://localhost:${settings.port}/admin?token=${settings.adminToken}`;
    const cmd = process.platform === 'darwin' ? 'open' :
                process.platform === 'linux' ? 'xdg-open' : null;
    if (cmd) {
      try {
        spawn(cmd, [adminUrl], { detached: true, stdio: 'ignore' }).unref();
      } catch {
        // Best-effort: ignore if spawn fails
      }
    }
  }

  // Start mDNS advertisement
  const stopMdns = startMdns({
    port: settings.port,
    serverId: settings.serverId,
    hostname: hostname(),
    version: VERSION,
    getPairingState: () => pairingManager.getState(),
  });

  // Cleanup on shutdown
  const shutdown = () => {
    stopMdns();
    process.exit(0);
  };
  process.once('SIGTERM', shutdown);
  process.once('SIGINT', shutdown);
}

const SERVICE_CMDS = new Set(['install', 'uninstall', 'start', 'stop', 'restart', 'status', 'logs', 'update', 'help']);
const subcommand = process.argv[2];

if (subcommand === '--version' || subcommand === '-v') {
  console.log(`pawterm-server ${VERSION}`);
  process.exit(0);
} else if (subcommand === 'password') {
  await runPasswordCommand();
} else if (subcommand === 'pair') {
  const { runPairCli } = await import('./pair-cli.js');
  await runPairCli();
} else if (subcommand && SERVICE_CMDS.has(subcommand)) {
  const { runServiceCommand } = await import('./service.js');
  runServiceCommand(subcommand);
} else {
  if (isFirstRun) await firstRunSetup();
  main().catch((err) => {
    console.error(err);
    process.exit(1);
  });
}
