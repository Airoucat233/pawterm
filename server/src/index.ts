import cors from '@fastify/cors';
import multipart from '@fastify/multipart';
import websocketPlugin from '@fastify/websocket';
import Fastify, { type FastifyReply, type FastifyRequest } from 'fastify';
import { createReadStream, existsSync, readFileSync } from 'node:fs';
import { mkdir, readdir, stat } from 'node:fs/promises';
import { hostname, homedir } from 'node:os';
import { basename, dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import QRCode from 'qrcode';

const __dirname = dirname(fileURLToPath(import.meta.url));

import type { AgentsResponse, HealthResponse, Project, PairedDevice, ModelsResponse, ModelInfo, ModelProvider } from '@pawterm/shared';

import { AdminAccessManager } from './admin-auth.js';
import { verifyAdminPassword } from './admin-password.js';
import { defaultAgentRegistry } from './agents/registry.js';
import { registerChatRest } from './chat-rest.js';
import { settings, addProject, removeProject, isPathAllowed, ProjectExistsError, configPath, setPassword, clearPassword, isFirstRun, persistPairedDevices, persistAdminAccessTokens } from './config.js';
import { adminEventBus } from './event-bus.js';
import { buildLoggerOptions, SILENT_PATHS } from './logger.js';
import { startMdns } from './mdns.js';
import { createNetworkAddressService, type AdvertisedAddress } from './network-address.js';
import { pairingManager } from './pair.js';
import { registerSessionsApi } from './sessions-api.js';
import { registerUpload } from './upload.js';
import { handleShellSocket } from './ws-shell.js';

declare const __SERVER_VERSION__: string;
const VERSION: string = typeof __SERVER_VERSION__ !== 'undefined' ? __SERVER_VERSION__ : (() => {
  try { return JSON.parse(readFileSync(join(__dirname, '..', 'package.json'), 'utf8')).version ?? 'dev'; }
  catch { return 'dev'; }
})();

const adminAccessManager = new AdminAccessManager({
  initialAccessTokens: settings.adminAccessTokens,
});

// Extract a short human label from a model ID, falling back to the provided default.
// e.g. "global.anthropic.claude-sonnet-4-6" → "Sonnet 4.6"
//      "anthropic.claude-opus-4-7-20260101" → "Opus 4.7"
function _modelLabel(id: string, fallback: string): string {
  const m = id.match(/claude-(opus|sonnet|haiku)[-.](\d+[-.]?\d*)/i);
  if (m) return `${m[1].charAt(0).toUpperCase()}${m[1].slice(1)} ${m[2].replace(/-/g, '.')}`;
  return fallback;
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
    console.log('  show            Show password status / token');
    process.exit(0);
  }
  if (action === 'show') {
    if (settings.adminPasswordHash || settings.password) {
      console.log(`Password : set (${settings.adminPasswordHash ? 'hashed' : 'legacy plaintext'})`);
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
  const app = Fastify({ logger: buildLoggerOptions(), disableRequestLogging: true });
  let stopMdns: (() => void) | null = null;
  const mdnsOptions = () => ({
    port: settings.port,
    serverId: settings.serverId,
    hostname: hostname(),
    version: VERSION,
    getPairingState: () => pairingManager.getState(),
  });
  const formatAddress = (address: AdvertisedAddress | null): string =>
    address ? `${address.address} (${address.name})` : 'none';
  const restartMdns = (reason: string): void => {
    if (!stopMdns) return;
    try {
      stopMdns();
      stopMdns = startMdns(mdnsOptions());
      app.log.info(`mDNS advertisement restarted: ${reason}`);
    } catch (err) {
      app.log.warn({ err }, `Failed to restart mDNS advertisement: ${reason}`);
    }
  };
  const networkAddressService = createNetworkAddressService({
    onChange: (current, previous) => {
      app.log.info(
        `LAN address changed: ${formatAddress(previous)} -> ${formatAddress(current)}`,
      );
      restartMdns('LAN address changed');
    },
  });
  const advertisedHost = () => networkAddressService.getCurrent()?.address ?? 'localhost';
  const unsubscribePairRequestLog = adminEventBus.subscribe((event) => {
    if (event.type !== 'pair_request') return;
    app.log.info(
      [
        '',
        '┌─ Pairing request',
        `│  device : ${event.deviceName}`,
        `│  ip     : ${event.ip}`,
        `│  approve: http://${advertisedHost()}:${settings.port}/admin`,
        '│  PIN    : run `cd server && PAWTERM_CONFIG=$(pwd)/config.json pnpm exec tsx src/index.ts pair`',
        '└─ waiting for approval',
      ].join('\n'),
    );
  });

  await app.register(cors, { origin: true });
  await app.register(websocketPlugin);
  await app.register(multipart, { limits: { fileSize: 25 * 1024 * 1024 } });

  // Request/response logging (manual, so we can suppress noisy paths and control format)
  const BODY_LIMIT = 512;
  const truncate = (s: string) =>
    s.length <= BODY_LIMIT ? s : `${s.slice(0, BODY_LIMIT)} …(+${s.length - BODY_LIMIT} bytes)`;
  const redactUrl = (url: string) =>
    url.replace(/([?&]admin_login_code=)[^&\s]+/g, '$1<redacted>');
  const redactSecrets = (text: string) =>
    text
      .replace(/("(?:admin_login_code|admin_access_token|access_token|deviceToken|device_token|token)"\s*:\s*")[^"]+/g, '$1<redacted>')
      .replace(/("(?:password|admin_password)"\s*:\s*")[^"]+/g, '$1<redacted>')
      .replace(/(Bearer\s+)(?:sk|aat|alc|dt)-[0-9a-f]+/g, '$1<redacted>');

  app.addHook('preHandler', async (req) => {
    const path = req.url.split('?')[0];
    if (SILENT_PATHS.has(path)) return;
    const body = req.body != null ? ` ${redactSecrets(truncate(JSON.stringify(req.body)))}` : '';
    req.log.info(`→ ${req.method} ${redactUrl(req.url)}${body}`);
  });

  app.addHook('onSend', async (req, reply, payload) => {
    const path = req.url.split('?')[0];
    if (SILENT_PATHS.has(path)) return payload;
    const ms = Math.round(reply.elapsedTime);
    const isStream = typeof (payload as { pipe?: unknown })?.pipe === 'function';
    const bodyStr = (!isStream && typeof payload === 'string')
      ? ` ${redactSecrets(truncate(payload))}`
      : '';
    req.log.info(`← ${reply.statusCode} ${req.method} ${redactUrl(req.url)}  ${ms}ms${bodyStr}`);
    return payload;
  });

  // Auth middleware.
  // Frontend routes/static files are public. API routes live under /api, except
  // /health which remains a root LAN/discovery probe.
  app.addHook('onRequest', async (req, reply) => {
    const url = req.url.split('?')[0];
    if (
      url === '/health' ||
      (!url.startsWith('/api/') && url !== '/ws/shell') ||
      url === '/ws/shell' ||
      url === '/api/pair/start' ||
      url === '/api/pair/request' ||
      url === '/api/pair/qr-claim' ||
      url === '/api/admin/access-token' ||
      url.startsWith('/api/pair/poll/')
    ) {
      return;
    }

    const auth = req.headers['authorization'];
    const token = typeof auth === 'string' && auth.startsWith('Bearer ') ? auth.slice(7) : null;

    const isPasswordAdmin =
      !!token &&
      (
        verifyAdminPassword(token, settings.adminPasswordHash) ||
        (!!settings.password && token === settings.password)
      );
    const isRootAdmin = token === settings.adminToken || isPasswordAdmin;
    const isAdmin = isRootAdmin || (!!token && adminAccessManager.isAdminAccessToken(token));
    const matchedDevice = token
      ? settings.pairedDevices.find((d) => d.deviceToken === token)
      : undefined;

    if (!isAdmin && !matchedDevice) {
      reply.code(401).send({ error: 'unauthorized' });
      return;
    }

    // Admin-only routes
    if (url === '/api/admin/login-codes' && !isRootAdmin) {
      reply.code(403).send({ error: 'root admin token required' });
      return;
    }

    if (url.startsWith('/api/admin/') && !isAdmin) {
      reply.code(403).send({ error: 'admin access token required' });
      return;
    }

    // Async update lastSeen for matched device (non-blocking)
    if (matchedDevice) {
      matchedDevice.lastSeen = Date.now();
      persistPairedDevices().catch(() => { /* ignore */ });
    }
  });

  // REST: health (no auth)
  const healthHandler = async (): Promise<HealthResponse> => {
    const advertisedAddress = networkAddressService.getCurrent();
    return {
      status: 'ok',
      version: VERSION,
      hostname: hostname(),
      serverId: settings.serverId,
      pairingOpen: pairingManager.getState() === 'open',
      advertisedAddress: advertisedAddress
        ? { name: advertisedAddress.name, address: advertisedAddress.address }
        : undefined,
    };
  };
  app.get('/health', healthHandler);

  await app.register(async (api) => {

  const agentsHandler = async (): Promise<AgentsResponse> => ({
    agents: await defaultAgentRegistry.listInfos(),
  });
  api.get('/agents', agentsHandler);

  // REST: models — reads ~/.claude/settings.json to detect provider + available models
  api.get('/models', async (): Promise<ModelsResponse> => {
    const claudeSettings = (() => {
      try {
        return JSON.parse(readFileSync(join(homedir(), '.claude', 'settings.json'), 'utf-8'));
      } catch { return {}; }
    })();
    const env: Record<string, string> = claudeSettings.env ?? {};

    const provider: ModelProvider =
      env['CLAUDE_CODE_USE_BEDROCK'] === '1' ? 'bedrock' :
      env['CLAUDE_CODE_USE_VERTEX'] === '1' ? 'vertex' :
      env['ANTHROPIC_BASE_URL'] && !env['ANTHROPIC_BASE_URL'].includes('anthropic.com') ? 'unknown' :
      'anthropic';

    const sonnet = env['ANTHROPIC_DEFAULT_SONNET_MODEL'] ?? env['ANTHROPIC_MODEL'] ?? 'claude-sonnet-4-6';
    const opus   = env['ANTHROPIC_DEFAULT_OPUS_MODEL']   ?? 'claude-opus-4-7';
    const haiku  = env['ANTHROPIC_DEFAULT_HAIKU_MODEL']  ?? 'claude-haiku-4-5';
    const current = env['ANTHROPIC_MODEL'] ?? sonnet;

    const models: ModelInfo[] = [
      { id: sonnet, label: _modelLabel(sonnet, 'Sonnet'), tier: 'fast' },
      { id: opus,   label: _modelLabel(opus,   'Opus'),   tier: 'powerful' },
      { id: haiku,  label: _modelLabel(haiku,  'Haiku'),  tier: 'cheap' },
    ];

    return { provider, current, models };
  });

  // REST: projects list
  const projectsHandler = async (): Promise<Project[]> => settings.projects;
  api.get('/projects', projectsHandler);

  // REST: add project. name is optional; defaults to basename(path).
  api.post<{ Body: { name?: string; path: string } }>('/projects', async (req, reply) => {
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
  api.delete<{ Querystring: { path?: string } }>('/projects', async (req, reply) => {
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
  api.get<{ Querystring: { path?: string } }>('/browse', async (req): Promise<{ dirs: string[] }> => {
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
  api.post<{ Body: { parent: string; name: string } }>('/browse/mkdir', async (req, reply) => {
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
  api.get<{ Querystring: { path?: string } }>('/fs/ls', async (req, reply) => {
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
  api.get<{ Querystring: { path?: string; max_bytes?: string } }>('/fs/cat', async (req, reply) => {
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

  api.get<{ Querystring: { path?: string } }>('/fs/download', async (req, reply) => {
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
  await registerSessionsApi(api, { registry: defaultAgentRegistry });

  // REST + SSE: chat
  await registerChatRest(api);

  // REST: upload (chat attachments)
  await registerUpload(api);

  // ============ Admin access endpoints ============

  // POST /api/admin/login-codes — root admin token/password required.
  // Used by local trusted entry points (CLI / Mac app) to open Web Admin
  // without placing the root admin token in the browser URL.
  const createAdminLoginCodeHandler = async () => {
    const login = adminAccessManager.createLoginCode();
    return {
      admin_login_code: login.loginCode,
      expires_at: login.expiresAt,
    };
  };
  api.post('/admin/login-codes', createAdminLoginCodeHandler);

  // POST /api/admin/access-token — public exchange endpoint; the one-time
  // admin_login_code is the credential and is consumed whether exchange succeeds.
  const exchangeAdminAccessTokenHandler = async (
    req: FastifyRequest<{ Body: { admin_login_code?: string } }>,
    reply: FastifyReply,
  ) => {
    const code = req.body?.admin_login_code;
    if (!code) {
      reply.code(400);
      return { error: 'admin_login_code required' };
    }
    const access = adminAccessManager.redeemLoginCode(code);
    if (!access) {
      reply.code(403);
      return { error: 'invalid or expired admin_login_code' };
    }
    await persistAdminAccessTokens(adminAccessManager.snapshotAccessTokens());
    return {
      admin_access_token: access.accessToken,
      expires_at: access.expiresAt,
    };
  };
  api.post<{ Body: { admin_login_code?: string } }>('/admin/access-token', exchangeAdminAccessTokenHandler);

  // POST /api/admin/access-token/renew — admin access token required.
  // Rotates the Bearer token before expiry; the old token is revoked.
  const renewAdminAccessTokenHandler = async (req: FastifyRequest, reply: FastifyReply) => {
    const auth = req.headers['authorization'];
    const token = typeof auth === 'string' && auth.startsWith('Bearer ') ? auth.slice(7) : null;
    if (!token) {
      reply.code(401);
      return { error: 'admin access token required' };
    }
    const access = adminAccessManager.renewAccessToken(token);
    if (!access) {
      await persistAdminAccessTokens(adminAccessManager.snapshotAccessTokens());
      reply.code(403);
      return { error: 'admin access token expired' };
    }
    await persistAdminAccessTokens(adminAccessManager.snapshotAccessTokens());
    return {
      admin_access_token: access.accessToken,
      expires_at: access.expiresAt,
    };
  };
  api.post('/admin/access-token/renew', renewAdminAccessTokenHandler);

  // POST /api/admin/password — admin auth required.
  const setAdminPasswordHandler = async (
    req: FastifyRequest<{ Body: { password?: string } }>,
    reply: FastifyReply,
  ) => {
    const password = req.body?.password ?? '';
    if (!isValidPassword(password)) {
      reply.code(400);
      return { error: 'Password must be >=8 characters and contain both letters and digits.' };
    }
    await setPassword(password);
    return { ok: true, admin_password_set_at: settings.adminPasswordSetAt ?? Date.now() };
  };
  api.post<{ Body: { password?: string } }>('/admin/password', setAdminPasswordHandler);

  const clearAdminPasswordHandler = async () => {
    await clearPassword();
    return { ok: true };
  };
  api.delete('/admin/password', clearAdminPasswordHandler);

  // ============ Pairing endpoints ============

  // POST /api/admin/pair-window — adminToken required (checked by middleware)
  const openPairWindowHandler = async () => {
    const result = pairingManager.openWindow();
    return result;
  };
  api.post('/admin/pair-window', openPairWindowHandler);

  // POST /api/pair/start — no auth; PIN is the out-of-band credential
  api.post<{ Body: { deviceId: string; deviceName: string; pin: string } }>(
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

  // POST /api/pair/qr-claim — no auth; claim code (from QR) is the credential
  api.post<{ Body: { deviceId: string; deviceName: string; claim: string } }>(
    '/pair/qr-claim',
    async (req, reply) => {
      const { deviceId, deviceName, claim } = req.body ?? {};
      if (!deviceId || !deviceName || !claim) {
        reply.code(400);
        return { error: 'missing fields' };
      }
      const ok = pairingManager.consumeQrClaim(claim);
      if (!ok) {
        reply.code(403);
        return { error: 'invalid or expired claim' };
      }
      const result = await pairingManager.issueDeviceTokenAndNotify(deviceId, deviceName);
      return result;
    },
  );

  // GET /api/admin/devices — list paired devices (no deviceToken in response)
  const listAdminDevicesHandler = async (): Promise<PairedDevice[]> => {
    return settings.pairedDevices.map((d) => ({
      deviceId: d.deviceId,
      name: d.name,
      pairedAt: d.pairedAt,
      lastSeen: d.lastSeen,
    }));
  };
  api.get('/admin/devices', listAdminDevicesHandler);

  // DELETE /api/admin/devices/:id — revoke a device
  const revokeAdminDeviceHandler = async (
    req: FastifyRequest<{ Params: { id: string } }>,
    reply: FastifyReply,
  ) => {
    const { id } = req.params;
    const revoked = await pairingManager.revokeDevice(id);
    if (!revoked) {
      reply.code(404);
      return { error: 'device not found' };
    }
    return { revoked: true };
  };
  api.delete<{ Params: { id: string } }>('/admin/devices/:id', revokeAdminDeviceHandler);

  // ==========================================
  // ======== Slice 8: Web Admin APIs =========

  // GET /api/admin/qr — adminToken required.
  // 生成一次性 QR claim code，5min 过期，扫码端用 POST /api/pair/qr-claim 兑换 deviceToken。
  const adminQrHandler = async () => {
    const { code, expiresAt } = pairingManager.createQrClaim();
    const content = `pawterm://${advertisedHost()}:${settings.port}?claim=${code}`;
    const svg = await QRCode.toString(content, { type: 'svg' });
    return { content, svg, expiresAt };
  };
  api.get('/admin/qr', adminQrHandler);

  // POST /api/pair/request — no auth
  api.post<{ Body: { deviceId: string; deviceName: string } }>(
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
        pollUrl: `/api/pair/poll/${requestId}`,
      };
    },
  );

  // GET /api/pair/poll/:requestId — no auth, long-poll (up to 30s)
  api.get<{ Params: { requestId: string } }>(
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

  // POST /api/admin/pair-approve — adminToken required
  const approvePairHandler = async (
    req: FastifyRequest<{ Body: { requestId: string } }>,
    reply: FastifyReply,
  ) => {
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
  };
  api.post<{ Body: { requestId: string } }>('/admin/pair-approve', approvePairHandler);

  // POST /api/admin/pair-deny — adminToken required
  const denyPairHandler = async (
    req: FastifyRequest<{ Body: { requestId: string } }>,
    reply: FastifyReply,
  ) => {
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
  };
  api.post<{ Body: { requestId: string } }>('/admin/pair-deny', denyPairHandler);

  // GET /api/admin/events — SSE stream; admin auth via Bearer header.
  const adminEventsHandler = async (req: FastifyRequest, reply: FastifyReply) => {
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
  };
  api.get('/admin/events', adminEventsHandler);

  }, { prefix: '/api' });

  // WebSocket: shell
  app.get('/ws/shell', { websocket: true }, (socket, req) => {
    handleShellSocket(socket, req);
  });

  app.get('/', async (_req, reply) => {
    reply.redirect('/admin');
  });

  // GET /admin — serve built web admin SPA; fallback placeholder when not built.
  const packagedWebDist = resolve(__dirname, '..', 'dist-web');
  const repoWebDist = resolve(__dirname, '..', '..', 'web', 'dist');
  const webDist = existsSync(packagedWebDist) ? packagedWebDist : repoWebDist;
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

  const serveIndex = async (reply: import('fastify').FastifyReply) => {
    if (existsSync(resolve(webDist, 'index.html'))) {
      await serveStatic('index.html', reply);
      return;
    }
    reply
      .header('Content-Type', 'text/html; charset=utf-8')
      .send(
        '<!DOCTYPE html><html><head><meta charset="utf-8"><title>PawTerm Web Admin</title></head>' +
        '<body style="font-family:monospace;padding:2rem;background:#111;color:#eee">' +
        '<h2>PawTerm Web Admin</h2>' +
        '<p>Web admin not built yet — run <code>pnpm --filter @pawterm/web build</code>.</p>' +
        '</body></html>',
      );
  };

  app.get('/admin', async (_req, reply) => serveIndex(reply));
  app.get<{ Params: { '*': string } }>('/admin/*', async (_req, reply) => serveIndex(reply));
  // Vite emits hashed filenames under /assets/.
  app.get<{ Params: { '*': string } }>('/assets/*', (req, reply) => serveStatic(join('assets', req.params['*']), reply));

  // ==========================================

  await app.listen({ host: settings.host, port: settings.port });
  networkAddressService.start();

  const advertisedAddress = networkAddressService.getCurrent();
  const lanIp = advertisedHost();
  app.log.info(
    [
      '',
      `┌─ PawTerm Server v${VERSION}`,
      `│  node     : ${process.version}`,
      `│  listen   : http://${settings.host}:${settings.port}`,
      `│  web admin: http://${lanIp}:${settings.port}/admin`,
      `│  address  : ${formatAddress(advertisedAddress)}`,
      `│  config   : ${configPath}`,
      `│  serverId : ${settings.serverId}`,
      `│  log      : ${settings.logFormat} / ${settings.logLevel}${settings.logFile ? ` → ${settings.logFile}` : ''}`,
      `│  projects :`,
      ...settings.projects.map((p) => `│    • ${p.name}  (${p.path})`),
      ...(settings.projects.length === 0 ? ['│    (none)'] : []),
      `└─ ready`,
    ].join('\n'),
  );

  // Start mDNS advertisement
  stopMdns = startMdns(mdnsOptions());

  // Cleanup on shutdown
  const shutdown = async () => {
    console.log('\n[pawterm] shutting down…');
    unsubscribePairRequestLog();
    networkAddressService.stop();
    stopMdns?.();
    try { await app.close(); } catch {}
    console.log('[pawterm] bye');
    process.exit(0);
  };
  process.once('SIGTERM', () => { void shutdown(); });
  process.once('SIGINT',  () => { void shutdown(); });
}

const SERVICE_CMDS = new Set(['install', 'uninstall', 'start', 'stop', 'restart', 'status', 'logs', 'update', 'use', 'help']);
const subcommand = process.argv[2];

if (subcommand === '--version' || subcommand === '-v') {
  console.log(`pawterm-server ${VERSION}`);
  process.exit(0);
} else if (subcommand === 'password') {
  await runPasswordCommand();
} else if (subcommand === 'admin') {
  const { runAdminCli } = await import('./admin-cli.js');
  await runAdminCli();
} else if (subcommand === 'pair') {
  const { runPairCli } = await import('./pair-cli.js');
  await runPairCli();
} else if (subcommand && SERVICE_CMDS.has(subcommand)) {
  const { runServiceCommand } = await import('./service.js');
  runServiceCommand(subcommand, process.argv.slice(3));
} else {
  if (isFirstRun && process.stdin.isTTY && process.stdout.isTTY) await firstRunSetup();
  main().catch((err) => {
    console.error(err);
    process.exit(1);
  });
}
