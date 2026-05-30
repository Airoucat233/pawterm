#!/usr/bin/env node
const { mkdtempSync, readdirSync, readFileSync, rmSync } = require('node:fs');
const { tmpdir } = require('node:os');
const { join, resolve } = require('node:path');
const { pathToFileURL } = require('node:url');
const { spawnSync } = require('node:child_process');

const serverDir = resolve(__dirname, '..');
const distDir = resolve(serverDir, 'dist');
const nodeBin = process.execPath;

function fail(message, detail = '') {
  console.error(`✗ ${message}`);
  if (detail) console.error(detail);
  process.exit(1);
}

function run(args, opts = {}) {
  const result = spawnSync(args[0], args.slice(1), {
    cwd: serverDir,
    encoding: 'utf8',
    timeout: opts.timeout ?? 10_000,
    env: { ...process.env, ...(opts.env ?? {}) },
  });
  if (result.error) fail(`${args.join(' ')} failed`, result.error.stack ?? String(result.error));
  if (result.status !== 0) {
    fail(
      `${args.join(' ')} exited ${result.status}`,
      `${result.stdout ?? ''}${result.stderr ?? ''}`.trim(),
    );
  }
  return result;
}

async function main() {
  const indexPath = resolve(distDir, 'index.js');
  const indexSource = readFileSync(indexPath, 'utf8');
  if (indexSource.includes('import { Bonjour } from "bonjour-service"')) {
    fail('dist/index.js contains a fragile named import from bonjour-service');
  }

  const version = run([nodeBin, indexPath, '--version']);
  if (!version.stdout.includes('pawterm-server')) {
    fail('dist --version did not print the package version', version.stdout);
  }

  const help = run([nodeBin, indexPath, 'help']);
  if (!help.stdout.includes('Usage: pawterm-server')) {
    fail('dist help did not print CLI usage', help.stdout);
  }

  for (const file of readdirSync(distDir)) {
    if (!file.endsWith('.js') || file === 'index.js') continue;
    await import(pathToFileURL(resolve(distDir, file)).href);
  }

  const packCache = mkdtempSync(join(tmpdir(), 'pawterm-npm-cache-'));
  try {
    const pack = run(['npm', 'pack', '--dry-run', '--json'], {
      env: { npm_config_cache: packCache },
    });
    const info = JSON.parse(pack.stdout)[0];
    const paths = new Set((info.files ?? []).map((f) => f.path));
    for (const required of ['package.json', 'dist/index.js', 'dist-web/index.html']) {
      if (!paths.has(required)) fail(`npm package is missing ${required}`);
    }
  } finally {
    rmSync(packCache, { recursive: true, force: true });
  }

  console.log('✓ packaged server smoke ok');
}

main().catch((err) => fail('packaged smoke failed', err.stack ?? String(err)));
