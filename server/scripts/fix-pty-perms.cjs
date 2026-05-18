#!/usr/bin/env node
// pnpm 解包 tarball 时偶尔会丢掉可执行位，导致 node-pty 的 spawn-helper
// 被 posix_spawnp 调用时报 EACCES（"posix_spawnp failed"）。这里在 postinstall
// 阶段把所有平台 prebuilds 下的 spawn-helper 重新 chmod +x。
//
// 不在 Linux 上（非 darwin/linux）静默跳过。

const fs = require('node:fs');
const path = require('node:path');

function findPtyRoot() {
  // 同时支持 npm 平铺布局和 pnpm 的 .pnpm/<pkg>/node_modules/<pkg> 布局
  try {
    return path.dirname(require.resolve('node-pty/package.json'));
  } catch {
    return null;
  }
}

function chmodExecRecursive(dir) {
  if (!fs.existsSync(dir)) return;
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      chmodExecRecursive(p);
    } else if (entry.name === 'spawn-helper') {
      try {
        fs.chmodSync(p, 0o755);
        console.log(`[fix-pty-perms] chmod +x ${p}`);
      } catch (e) {
        console.warn(`[fix-pty-perms] failed to chmod ${p}: ${e.message}`);
      }
    }
  }
}

const pkg = JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'package.json'), 'utf-8'));
console.log(`\n✓ pawterm-server@${pkg.version} installed\n`);

const root = findPtyRoot();
if (!root) {
  process.exit(0);
}

const prebuilds = path.join(root, 'prebuilds');
chmodExecRecursive(prebuilds);
