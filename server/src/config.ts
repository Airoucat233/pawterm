import { readFileSync, existsSync, mkdirSync, writeFileSync } from 'node:fs';
import { writeFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import { basename, dirname, resolve, relative } from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomBytes } from 'node:crypto';

import type { Project, PermissionMode } from '@pawterm/shared';

const __dirname = dirname(fileURLToPath(import.meta.url));

const DEFAULT_CONFIG_DIR = resolve(homedir(), '.config', 'pawterm');
const DEFAULT_CONFIG_PATH = resolve(DEFAULT_CONFIG_DIR, 'config.json');

export type LogFormat = 'pretty' | 'json';

export interface ServerSettings {
  host: string;
  port: number;
  permissionMode: PermissionMode;
  projects: Project[];
  logLevel: string;
  logFormat: LogFormat;
  logFile: string | null;
  token: string;
}

function expandHome(p: string): string {
  if (p.startsWith('~/')) return resolve(homedir(), p.slice(2));
  if (p === '~') return homedir();
  return resolve(p);
}

export const configPath = process.env.PAWTERM_CONFIG ?? process.env.CC_CONFIG ?? DEFAULT_CONFIG_PATH;

function loadConfig(): ServerSettings {
  if (!existsSync(configPath)) {
    const token = 'sk-' + randomBytes(16).toString('hex');
    const defaultConfig = {
      host: '0.0.0.0',
      port: 8765,
      permission_mode: 'bypassPermissions',
      projects: [] as Array<{ name: string; path: string }>,
      token,
    };
    try {
      mkdirSync(DEFAULT_CONFIG_DIR, { recursive: true });
      writeFileSync(configPath, JSON.stringify(defaultConfig, null, 2));
      console.info(`[config] Created default config at ${configPath}`);
      console.info(`[config] Edit it to add your project paths, then restart.`);
    } catch { /* ignore write errors (e.g. read-only fs) */ }
    const defaultLogFormat: LogFormat = 'pretty';
    return {
      host: defaultConfig.host,
      port: defaultConfig.port,
      permissionMode: 'bypassPermissions',
      projects: [],
      logLevel: process.env.PAWTERM_LOG_LEVEL ?? process.env.CC_LOG_LEVEL ?? 'info',
      logFormat: (process.env.PAWTERM_LOG_FORMAT ?? process.env.CC_LOG_FORMAT ?? defaultLogFormat) as LogFormat,
      logFile: (() => { const p = process.env.PAWTERM_LOG_FILE; return p ? expandHome(p) : null; })(),
      token,
    };
  }

  const raw = JSON.parse(readFileSync(configPath, 'utf-8')) as {
    host?: string;
    port?: number;
    permission_mode?: PermissionMode;
    projects?: Array<{ name?: string; path: string }>;
    log_level?: string;
    log_format?: LogFormat;
    log_file?: string;
    token?: string;
  };

  let token = raw.token as string | undefined;
  if (!token) {
    token = 'sk-' + randomBytes(16).toString('hex');
    const updated: Record<string, unknown> = { ...raw, token };
    writeFileSync(configPath, JSON.stringify(updated, null, 2));
  }

  const defaultLogFormat: LogFormat = 'pretty';

  return {
    host: raw.host ?? '0.0.0.0',
    port: raw.port ?? 8765,
    permissionMode: raw.permission_mode ?? 'bypassPermissions',
    projects: (raw.projects ?? []).map((p) => {
      const path = expandHome(p.path);
      return { name: p.name?.trim() || basename(path) || path, path };
    }),
    // env var > config.json > default
    logLevel: process.env.PAWTERM_LOG_LEVEL ?? process.env.CC_LOG_LEVEL ?? raw.log_level ?? 'info',
    logFormat: (process.env.PAWTERM_LOG_FORMAT ?? process.env.CC_LOG_FORMAT ?? raw.log_format ?? defaultLogFormat) as LogFormat,
    logFile: (() => { const p = process.env.PAWTERM_LOG_FILE ?? raw.log_file; return p ? expandHome(p) : null; })(),
    token,
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
  const current: Record<string, unknown> = existsSync(configPath)
    ? (JSON.parse(readFileSync(configPath, 'utf-8')) as Record<string, unknown>)
    : { host: settings.host, port: settings.port };
  current['projects'] = settings.projects.map((p) => ({ name: p.name, path: p.path }));
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
