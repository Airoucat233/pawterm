/**
 * admin-cli.ts — implements `pawterm-server admin`
 *
 * Reads the local root admin token, asks the running server for a short-lived
 * admin_login_code, then opens Web Admin without exposing the root token.
 */

import { spawn } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { homedir, platform } from 'node:os';
import { resolve } from 'node:path';

const CONFIG_DIR = resolve(homedir(), '.config', 'pawterm');
const DEFAULT_CONFIG_PATH = resolve(CONFIG_DIR, 'config.json');
const ACTIVE_CONFIG_PTR = resolve(CONFIG_DIR, 'active-config');

const configPath = (() => {
  if (process.env.PAWTERM_CONFIG) return process.env.PAWTERM_CONFIG;
  if (existsSync(ACTIVE_CONFIG_PTR)) {
    const ptr = readFileSync(ACTIVE_CONFIG_PTR, 'utf-8').trim();
    if (ptr) return resolve(ptr.replace(/^~/, homedir()));
  }
  return DEFAULT_CONFIG_PATH;
})();

interface RawConfig {
  token?: string;
  port?: number;
  host?: string;
}

function readConfig(): { adminToken: string; port: number; host: string } {
  if (!existsSync(configPath)) {
    console.error(`[admin] Config not found at ${configPath}. Is pawterm-server installed?`);
    process.exit(1);
  }
  const raw = JSON.parse(readFileSync(configPath, 'utf-8')) as RawConfig;
  if (!raw.token) {
    console.error('[admin] No token found in config. Please check your config file.');
    process.exit(1);
  }
  const rawHost = raw.host ?? '127.0.0.1';
  return {
    adminToken: raw.token,
    port: raw.port ?? 8765,
    host: rawHost === '0.0.0.0' ? '127.0.0.1' : rawHost,
  };
}

function openBrowser(url: string): boolean {
  const command =
    platform() === 'darwin' ? 'open' :
    platform() === 'win32' ? 'cmd' :
    'xdg-open';
  const args = platform() === 'win32' ? ['/c', 'start', '', url] : [url];
  const proc = spawn(command, args, {
    detached: true,
    stdio: 'ignore',
  });
  proc.unref();
  return !proc.killed;
}

export async function runAdminCli(): Promise<void> {
  const { adminToken, port, host } = readConfig();
  const base = `http://${host}:${port}`;

  let loginCode: string;
  try {
    const res = await fetch(`${base}/admin/login-codes`, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${adminToken}`,
        'Content-Type': 'application/json',
      },
      body: '{}',
    });
    const data = await res.json() as { admin_login_code?: string; error?: string };
    if (!res.ok || !data.admin_login_code) {
      console.error(`[admin] Server error: ${JSON.stringify(data)}`);
      process.exit(1);
    }
    loginCode = data.admin_login_code;
  } catch (err) {
    console.error('[admin] Could not reach pawterm server. Is it running?');
    console.error(String(err));
    process.exit(1);
  }

  const url = `${base}/admin?admin_login_code=${encodeURIComponent(loginCode)}`;
  if (process.argv.includes('--print-url')) {
    console.log(url);
    return;
  }

  if (!openBrowser(url)) {
    console.log(url);
    return;
  }
  console.log(`[admin] Opened ${base}/admin`);
}
