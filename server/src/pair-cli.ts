/**
 * pair-cli.ts — implements `pawterm-server pair`
 *
 * Reads config to get adminToken + port + host, calls POST /admin/pair-window,
 * displays the PIN in a box, polls /admin/devices until a new device appears,
 * then exits.
 */

import { readFileSync, existsSync } from 'node:fs';
import { homedir } from 'node:os';
import { resolve } from 'node:path';

const DEFAULT_CONFIG_PATH = resolve(homedir(), '.config', 'pawterm', 'config.json');
const configPath = process.env.PAWTERM_CONFIG ?? process.env.CC_CONFIG ?? DEFAULT_CONFIG_PATH;

interface RawConfig {
  token?: string;
  port?: number;
  host?: string;
}

function readConfig(): { adminToken: string; port: number; host: string } {
  if (!existsSync(configPath)) {
    console.error(`[pair] Config not found at ${configPath}. Is pawterm-server installed?`);
    process.exit(1);
  }
  const raw = JSON.parse(readFileSync(configPath, 'utf-8')) as RawConfig;
  const adminToken = raw.token;
  if (!adminToken) {
    console.error('[pair] No token found in config. Please check your config file.');
    process.exit(1);
  }
  const port = raw.port ?? 8765;
  // If host is 0.0.0.0 (listen on all), connect to localhost
  const rawHost = raw.host ?? '127.0.0.1';
  const host = rawHost === '0.0.0.0' ? '127.0.0.1' : rawHost;
  return { adminToken, port, host };
}

function printPinBox(pin: string): void {
  const digits = pin.split('').join(' ');
  console.log('');
  console.log('  Enter this PIN on your phone:');
  console.log('');
  console.log('      ┌────────────────┐');
  console.log(`      │   ${digits} │`);
  console.log('      └────────────────┘');
  console.log('');
  console.log('  Waiting for device... (Ctrl+C to cancel)');
}

async function fetchJson<T>(
  url: string,
  opts: RequestInit = {},
): Promise<{ ok: boolean; status: number; data: T }> {
  const res = await fetch(url, opts);
  const data = (await res.json()) as T;
  return { ok: res.ok, status: res.status, data };
}

export async function runPairCli(): Promise<void> {
  const { adminToken, port, host } = readConfig();
  const base = `http://${host}:${port}`;
  const headers = {
    Authorization: `Bearer ${adminToken}`,
    'Content-Type': 'application/json',
  };

  console.log('');
  process.stdout.write('▶ requesting pairing window from local pawterm server...\n');

  let pin: string;
  let expiresAt: number;

  try {
    const result = await fetchJson<{ pin?: string; expiresAt?: number; error?: string }>(
      `${base}/admin/pair-window`,
      { method: 'POST', headers, body: '{}' },
    );
    if (!result.ok || !result.data.pin) {
      console.error(`[pair] Server error: ${JSON.stringify(result.data)}`);
      process.exit(1);
    }
    pin = result.data.pin!;
    expiresAt = result.data.expiresAt!;
  } catch (err) {
    console.error('[pair] Could not reach pawterm server. Is it running?');
    console.error(String(err));
    process.exit(1);
  }

  const minutesLeft = Math.ceil((expiresAt - Date.now()) / 60_000);
  console.log(`✓ window open for ${minutesLeft} minutes`);
  printPinBox(pin);

  // Snapshot current devices before pairing so we can detect new ones
  let knownDeviceIds = new Set<string>();
  try {
    const devResult = await fetchJson<Array<{ deviceId: string }>>(
      `${base}/admin/devices`,
      { headers },
    );
    if (devResult.ok) {
      knownDeviceIds = new Set(devResult.data.map((d) => d.deviceId));
    }
  } catch {
    // Non-fatal; if we can't list devices now, we'll detect all on next poll
  }

  // Poll until new device appears or window expires
  const pollInterval = setInterval(async () => {
    if (Date.now() > expiresAt) {
      console.log('\n✗ pairing window expired. Run `pawterm-server pair` again.');
      clearInterval(pollInterval);
      process.exit(0);
    }

    try {
      const devResult = await fetchJson<Array<{ deviceId: string; name: string }>>(
        `${base}/admin/devices`,
        { headers },
      );
      if (!devResult.ok) return;
      const newDevice = devResult.data.find((d) => !knownDeviceIds.has(d.deviceId));
      if (newDevice) {
        console.log(`\n✓ paired: ${newDevice.name}`);
        clearInterval(pollInterval);
        process.exit(0);
      }
    } catch {
      // Transient error; keep polling
    }
  }, 2000);

  // Ctrl+C handler
  process.on('SIGINT', () => {
    clearInterval(pollInterval);
    console.log('\n[pair] Cancelled. The server pairing window remains open until it expires.');
    process.exit(0);
  });
}
