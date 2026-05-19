import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { mkdirSync, writeFileSync, rmSync, existsSync, readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { tmpdir } from 'node:os';
import { randomUUID } from 'node:crypto';

/**
 * Tests for config persistence logic — serverId generation and reuse.
 * We test the raw JSON manipulation logic rather than the module singleton,
 * since the singleton is evaluated once at import time.
 */

function makeTestDir(): { dir: string; configPath: string } {
  const dir = resolve(tmpdir(), `pawterm-test-${Date.now()}-${Math.random().toString(36).slice(2)}`);
  mkdirSync(dir, { recursive: true });
  return { dir, configPath: resolve(dir, 'config.json') };
}

function writeConfig(configPath: string, data: Record<string, unknown>): void {
  writeFileSync(configPath, JSON.stringify(data, null, 2));
}

function readConfig(configPath: string): Record<string, unknown> {
  return JSON.parse(readFileSync(configPath, 'utf-8')) as Record<string, unknown>;
}

/**
 * Simulates what loadConfig does: read config, generate server_id if missing, write back.
 * Returns { serverId, adminToken }.
 */
function simulateLoad(configPath: string): { serverId: string; adminToken: string } {
  const { randomBytes } = require('node:crypto') as typeof import('node:crypto');

  const raw = readConfig(configPath);
  let adminToken = raw['token'] as string | undefined;
  let serverId = raw['server_id'] as string | undefined;
  let needsWrite = false;

  if (!adminToken) {
    adminToken = 'sk-' + randomBytes(16).toString('hex');
    needsWrite = true;
  }
  if (!serverId) {
    serverId = randomUUID();
    needsWrite = true;
  }
  if (needsWrite) {
    writeConfig(configPath, { ...raw, token: adminToken, server_id: serverId });
  }

  return { serverId, adminToken };
}

describe('config — serverId persistence', () => {
  const testDirs: string[] = [];

  afterEach(() => {
    for (const dir of testDirs) {
      if (existsSync(dir)) rmSync(dir, { recursive: true, force: true });
    }
    testDirs.length = 0;
  });

  function newTestDir() {
    const result = makeTestDir();
    testDirs.push(result.dir);
    return result;
  }

  it('generates a valid UUID v4 for serverId on first startup', () => {
    const { configPath } = newTestDir();
    // Write minimal config without server_id
    writeConfig(configPath, { host: '0.0.0.0', port: 8765, token: 'sk-test' });

    const { serverId } = simulateLoad(configPath);

    const uuidRegex = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
    expect(uuidRegex.test(serverId)).toBe(true);
  });

  it('persists serverId to config.json', () => {
    const { configPath } = newTestDir();
    writeConfig(configPath, { host: '0.0.0.0', port: 8765, token: 'sk-test' });

    const { serverId } = simulateLoad(configPath);

    const saved = readConfig(configPath);
    expect(saved['server_id']).toBe(serverId);
  });

  it('reuses existing serverId on second startup', () => {
    const { configPath } = newTestDir();
    const existingServerId = randomUUID();
    writeConfig(configPath, {
      host: '0.0.0.0',
      port: 8765,
      token: 'sk-test',
      server_id: existingServerId,
    });

    const { serverId: firstLoad } = simulateLoad(configPath);
    const { serverId: secondLoad } = simulateLoad(configPath);

    expect(firstLoad).toBe(existingServerId);
    expect(secondLoad).toBe(existingServerId);
  });

  it('does not overwrite config when server_id already present', () => {
    const { configPath } = newTestDir();
    const existingServerId = randomUUID();
    const original = {
      host: '0.0.0.0',
      port: 8765,
      token: 'sk-existing',
      server_id: existingServerId,
      projects: [{ name: 'test', path: '/tmp/test' }],
    };
    writeConfig(configPath, original);

    simulateLoad(configPath);

    const saved = readConfig(configPath);
    // All original fields preserved
    expect(saved['server_id']).toBe(existingServerId);
    expect(saved['token']).toBe('sk-existing');
    expect(saved['projects']).toEqual(original.projects);
  });

  it('generates adminToken when config lacks token field', () => {
    const { configPath } = newTestDir();
    writeConfig(configPath, { host: '0.0.0.0', port: 8765 });

    const { adminToken } = simulateLoad(configPath);

    expect(adminToken).toMatch(/^sk-[0-9a-f]{32}$/);
    const saved = readConfig(configPath);
    expect(saved['token']).toBe(adminToken);
  });

  it('two different servers get different serverIds', () => {
    const test1 = newTestDir();
    const test2 = newTestDir();
    writeConfig(test1.configPath, { token: 'sk-1' });
    writeConfig(test2.configPath, { token: 'sk-2' });

    const { serverId: id1 } = simulateLoad(test1.configPath);
    const { serverId: id2 } = simulateLoad(test2.configPath);

    expect(id1).not.toBe(id2);
  });
});
