#!/usr/bin/env node

const { cpSync, existsSync, rmSync } = require('node:fs');
const { resolve } = require('node:path');

const serverRoot = resolve(__dirname, '..');
const repoRoot = resolve(serverRoot, '..');
const webDist = resolve(repoRoot, 'web', 'dist');
const target = resolve(serverRoot, 'dist-web');

if (!existsSync(webDist)) {
  console.error('[copy-web-dist] Missing web/dist. Run `pnpm --filter @pawterm/web run build` first.');
  process.exit(1);
}

rmSync(target, { recursive: true, force: true });
cpSync(webDist, target, { recursive: true });
console.log(`[copy-web-dist] ${webDist} -> ${target}`);
