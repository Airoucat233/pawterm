import { readFileSync, existsSync, mkdirSync, writeFileSync } from 'node:fs';
import { writeFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import { basename, dirname, resolve, relative } from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomBytes, randomUUID } from 'node:crypto';

import type { Project, PermissionMode } from '@pawterm/shared';
import { hashAdminPassword } from './admin-password.js';

const __dirname = dirname(fileURLToPath(import.meta.url));

const DEFAULT_CONFIG_DIR = resolve(homedir(), '.config', 'pawterm');
const DEFAULT_CONFIG_PATH = resolve(DEFAULT_CONFIG_DIR, 'config.json');

export type LogFormat = 'pretty' | 'json';

export interface StoredDevice {
  deviceId: string;
  name: string;
  deviceToken: string;
  pairedAt: number;
  lastSeen: number | null;
}

export interface RawProjectConfig {
  name?: string;
  path: string;
}

export interface RawStoredDeviceConfig {
  device_id: string;
  name: string;
  device_token: string;
  paired_at: number;
  last_seen: number | null;
}

/** JSON shape stored in config.json. Keys use snake_case on disk. */
export interface RawServerConfig {
  host?: string;
  port?: number;
  projects?: RawProjectConfig[];
  log_level?: string;
  log_format?: LogFormat;
  log_file?: string | null;
  /** Admin pairing token. Generated automatically when omitted. */
  token?: string;
  /** Optional password gate for older/manual connection flows. */
  password?: string;
  /** Hashed admin password, written as `scrypt$<salt>$<hash>`. */
  admin_password_hash?: string;
  admin_password_set_at?: number;
  /** Stable server identity. Generated automatically when omitted. */
  server_id?: string;
  paired_devices?: RawStoredDeviceConfig[];
}

export interface ServerSettings {
  host: string;
  port: number;
  projects: Project[];
  logLevel: string;
  logFormat: LogFormat;
  logFile: string | null;
  /** Renamed from token; old config.json key "token" still accepted on read */
  adminToken: string;
  serverId: string;
  pairedDevices: StoredDevice[];
  adminPasswordHash?: string;
  adminPasswordSetAt?: number;
  /** Legacy plaintext config key; accepted on read but never written. */
  password?: string;
}

function expandHome(p: string): string {
  if (p.startsWith('~/')) return resolve(homedir(), p.slice(2));
  if (p === '~') return homedir();
  return resolve(p);
}

const ACTIVE_CONFIG_PTR = resolve(DEFAULT_CONFIG_DIR, 'active-config');
const CONFIG_ENV = 'PAWTERM_CONFIG';

function resolveConfigPath(): string {
  if (process.env[CONFIG_ENV]) return process.env[CONFIG_ENV];
  if (existsSync(ACTIVE_CONFIG_PTR)) {
    const ptr = readFileSync(ACTIVE_CONFIG_PTR, 'utf-8').trim();
    if (ptr) return resolve(ptr.replace(/^~/, homedir()));
  }
  return DEFAULT_CONFIG_PATH;
}

export const configPath = resolveConfigPath();

export let isFirstRun = false;

function loadConfig(): ServerSettings {
  if (!existsSync(configPath)) {
    const adminToken = 'sk-' + randomBytes(16).toString('hex');
    const serverId = randomUUID();
    const defaultConfig: Required<Pick<RawServerConfig, 'host' | 'port' | 'projects' | 'token' | 'server_id' | 'paired_devices'>> = {
      host: '0.0.0.0',
      port: 8765,
      projects: [],
      token: adminToken,
      server_id: serverId,
      paired_devices: [],
    };
    try {
      isFirstRun = true;
      mkdirSync(DEFAULT_CONFIG_DIR, { recursive: true });
      writeFileSync(configPath, JSON.stringify(defaultConfig, null, 2));
      console.info(`[config] Created default config at ${configPath}`);
      console.info(`[config] Edit it to add your project paths, then restart.`);
    } catch { /* ignore write errors (e.g. read-only fs) */ }
    const defaultLogFormat: LogFormat = 'pretty';
    return {
      host: defaultConfig.host,
      port: defaultConfig.port,
      projects: [],
      logLevel: process.env.PAWTERM_LOG_LEVEL ?? process.env.CC_LOG_LEVEL ?? 'info',
      logFormat: (process.env.PAWTERM_LOG_FORMAT ?? process.env.CC_LOG_FORMAT ?? defaultLogFormat) as LogFormat,
      logFile: (() => { const p = process.env.PAWTERM_LOG_FILE; return p ? expandHome(p) : null; })(),
      adminToken,
      serverId,
      pairedDevices: [],
    };
  }

  const raw = JSON.parse(readFileSync(configPath, 'utf-8')) as RawServerConfig;

  let adminToken = raw.token as string | undefined;
  let needsWrite = false;

  if (!adminToken) {
    adminToken = 'sk-' + randomBytes(16).toString('hex');
    needsWrite = true;
  }

  let serverId = raw.server_id;
  if (!serverId) {
    serverId = randomUUID();
    needsWrite = true;
  }

  if (needsWrite) {
    const updated: Record<string, unknown> = { ...raw, token: adminToken, server_id: serverId };
    writeFileSync(configPath, JSON.stringify(updated, null, 2));
  }

  const defaultLogFormat: LogFormat = 'pretty';

  const pairedDevices: StoredDevice[] = (raw.paired_devices ?? []).map((d) => ({
    deviceId: d.device_id,
    name: d.name,
    deviceToken: d.device_token,
    pairedAt: d.paired_at,
    lastSeen: d.last_seen,
  }));

  return {
    host: raw.host ?? '0.0.0.0',
    port: raw.port ?? 8765,
    projects: (raw.projects ?? []).map((p) => {
      const path = expandHome(p.path);
      return { name: p.name?.trim() || basename(path) || path, path };
    }),
    // env var > config.json > default
    logLevel: process.env.PAWTERM_LOG_LEVEL ?? process.env.CC_LOG_LEVEL ?? raw.log_level ?? 'info',
    logFormat: (process.env.PAWTERM_LOG_FORMAT ?? process.env.CC_LOG_FORMAT ?? raw.log_format ?? defaultLogFormat) as LogFormat,
    logFile: (() => { const p = process.env.PAWTERM_LOG_FILE ?? raw.log_file; return p ? expandHome(p) : null; })(),
    adminToken,
    serverId,
    pairedDevices,
    adminPasswordHash: raw.admin_password_hash,
    adminPasswordSetAt: raw.admin_password_set_at,
    password: raw.password as string | undefined,
  };
}

export const settings = loadConfig();

export class ProjectExistsError extends Error {
  constructor(public readonly path: string) {
    super(`Project at ${path} already exists`);
    this.name = 'ProjectExistsError';
  }
}

export async function addProject(name: string | undefined, rawPath: string): Promise<Project> {
  const path = expandHome(rawPath);
  if (settings.projects.some((p) => p.path === path)) {
    throw new ProjectExistsError(path);
  }
  const finalName = name?.trim() || basename(path) || path;
  const project: Project = { name: finalName, path };
  settings.projects.push(project);
  await persistProjects();
  return project;
}

/** Remove a project entry from config only. Does NOT touch ~/.claude/projects sessions. */
export async function removeProject(rawPath: string): Promise<boolean> {
  const path = expandHome(rawPath);
  const before = settings.projects.length;
  settings.projects = settings.projects.filter((p) => p.path !== path);
  if (settings.projects.length === before) return false;
  await persistProjects();
  return true;
}

async function persistProjects(): Promise<void> {
  await writeConfigPreserving((c) => {
    c['projects'] = settings.projects.map((p) => ({ name: p.name, path: p.path }));
  });
}

export async function setPassword(password: string): Promise<void> {
  const hash = hashAdminPassword(password);
  const setAt = Date.now();
  await writeConfigPreserving((c) => {
    c['admin_password_hash'] = hash;
    c['admin_password_set_at'] = setAt;
    delete c['password'];
  });
  (settings as any).adminPasswordHash = hash;
  (settings as any).adminPasswordSetAt = setAt;
  (settings as any).password = undefined;
}

export async function clearPassword(): Promise<void> {
  await writeConfigPreserving((c) => {
    delete c['admin_password_hash'];
    delete c['admin_password_set_at'];
    delete c['password'];
  });
  (settings as any).adminPasswordHash = undefined;
  (settings as any).adminPasswordSetAt = undefined;
  (settings as any).password = undefined;
}

export async function persistPairedDevices(): Promise<void> {
  await writeConfigPreserving((c) => {
    c['paired_devices'] = settings.pairedDevices.map((d) => ({
      device_id: d.deviceId,
      name: d.name,
      device_token: d.deviceToken,
      paired_at: d.pairedAt,
      last_seen: d.lastSeen,
    }));
  });
}

/**
 * 读盘 → 修改 → 写盘，磁盘异常（不存在 / 空文件 / JSON 损坏）时回退到 `{}` 并
 * 用内存中的 `settings` 重建 token / server_id / host / port 等关键字段，
 * 防止一次 writeFile 半成品状态把整份配置带崩。
 *
 * NB: 这里没加跨调用的串行保护，若并发 persist 仍可能丢更新；那是另一个修。
 */
async function writeConfigPreserving(
  mutator: (current: Record<string, unknown>) => void,
): Promise<void> {
  let current: Record<string, unknown> = {};
  if (existsSync(configPath)) {
    try {
      const text = readFileSync(configPath, 'utf-8').trim();
      if (text) current = JSON.parse(text) as Record<string, unknown>;
    } catch {
      // 文件被写到一半 / 被外部破坏 —— 用 settings 重建，下面会补关键字段。
      current = {};
    }
  }
  if (current['host'] === undefined) current['host'] = settings.host;
  if (current['port'] === undefined) current['port'] = settings.port;
  if (current['token'] === undefined) current['token'] = settings.adminToken;
  if (current['server_id'] === undefined) current['server_id'] = settings.serverId;
  mutator(current);
  await writeFile(configPath, JSON.stringify(current, null, 2));
}

/** Returns true if `target` is inside any whitelisted project root. */
export function isPathAllowed(target: string): boolean {
  const t = resolve(target);
  for (const p of settings.projects) {
    const root = resolve(p.path);
    const rel = relative(root, t);
    if (rel === '' || (!rel.startsWith('..') && !resolve(rel).startsWith('..'))) {
      return true;
    }
  }
  return false;
}
