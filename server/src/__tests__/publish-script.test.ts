import { mkdtempSync, mkdirSync, copyFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { describe, expect, test } from 'vitest';

function makePublishRepo(version: string) {
  const repo = mkdtempSync(join(tmpdir(), 'pawterm-publish-'));
  const scriptsDir = join(repo, 'server', 'scripts');
  mkdirSync(scriptsDir, { recursive: true });
  copyFileSync(join(process.cwd(), 'scripts', 'publish.sh'), join(scriptsDir, 'publish.sh'));
  writeFileSync(
    join(repo, 'server', 'package.json'),
    `${JSON.stringify({ name: 'pawterm-server', version }, null, 2)}\n`,
  );

  expect(spawnSync('git', ['init', '-b', 'main'], { cwd: repo, encoding: 'utf8' }).status).toBe(0);
  expect(spawnSync('git', ['config', 'user.email', 'test@example.com'], { cwd: repo, encoding: 'utf8' }).status).toBe(0);
  expect(spawnSync('git', ['config', 'user.name', 'Test User'], { cwd: repo, encoding: 'utf8' }).status).toBe(0);
  expect(spawnSync('git', ['add', '.'], { cwd: repo, encoding: 'utf8' }).status).toBe(0);
  expect(spawnSync('git', ['commit', '-m', 'init'], { cwd: repo, encoding: 'utf8' }).status).toBe(0);
  return repo;
}

describe('server publish script', () => {
  test('stable release menu handles a current prerelease version', () => {
    const repo = makePublishRepo('0.6.5-prerelease.1');
    const result = spawnSync('zsh', ['server/scripts/publish.sh'], {
      cwd: repo,
      input: 'q\n',
      encoding: 'utf8',
    });

    expect(result.stderr).toBe('');
    expect(result.status).toBe(0);
    expect(result.stdout).toContain('current:');
    expect(result.stdout).toContain('0.6.5-prerelease.1');
    expect(result.stdout).toContain('1)  stable   0.6.5');
    expect(result.stdout).toContain('2)  patch    0.6.6');
    expect(result.stdout).toContain('aborted.');
  });
});
