#!/usr/bin/env node

const { spawn, spawnSync } = require('node:child_process');
const { resolve } = require('node:path');

const ROOT = resolve(__dirname, '..');
const SERVER_DIR = resolve(ROOT, 'server');
const WEB_DIR = resolve(ROOT, 'web');

function listProcesses() {
  const result = spawnSync('ps', ['-axo', 'pid=,ppid=,command='], {
    encoding: 'utf8',
  });
  if (result.status !== 0) return [];
  return result.stdout
    .split(/\r?\n/)
    .map((line) => {
      const match = line.match(/^\s*(\d+)\s+(\d+)\s+(.+)$/);
      if (!match) return null;
      return {
        pid: Number(match[1]),
        ppid: Number(match[2]),
        command: match[3],
      };
    })
    .filter(Boolean);
}

function isRepoDevProcess(proc) {
  const command = proc.command;
  if (proc.pid === process.pid || proc.ppid === process.pid) return false;
  if (!command.includes(ROOT)) return false;
  return (
    command.includes('scripts/dev.cjs') ||
    (command.includes(SERVER_DIR) &&
      command.includes('tsx') &&
      command.includes('src/index.ts')) ||
    (command.includes(WEB_DIR) && command.includes('vite'))
  );
}

function matchedDevProcesses() {
  const ownParent = process.ppid;
  return listProcesses()
    .filter((proc) => proc.pid !== ownParent)
    .filter(isRepoDevProcess);
}

function signalAll(processes, signal) {
  for (const proc of processes) {
    try {
      process.kill(proc.pid, signal);
      console.log(`[pawterm dev] ${signal} pid=${proc.pid} ${proc.command}`);
    } catch {
      // Process already exited.
    }
  }
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function stopDevProcesses() {
  const first = matchedDevProcesses();
  if (first.length === 0) {
    console.log('[pawterm dev] No running dev processes found.');
    return;
  }

  signalAll(first, 'SIGTERM');
  await sleep(900);

  const remaining = matchedDevProcesses();
  if (remaining.length > 0) signalAll(remaining, 'SIGKILL');
}

function startDev() {
  const child = spawn('pnpm', ['run', 'dev'], {
    cwd: ROOT,
    env: process.env,
    stdio: 'inherit',
    shell: false,
  });
  child.on('exit', (code, signal) => {
    process.exit(signal ? 1 : (code ?? 0));
  });
}

(async () => {
  await stopDevProcesses();
  startDev();
})().catch((err) => {
  console.error(`[pawterm dev] restart failed: ${err.message}`);
  process.exit(1);
});
