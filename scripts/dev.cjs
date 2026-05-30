#!/usr/bin/env node

const { spawn, spawnSync } = require('node:child_process');
const { resolve } = require('node:path');
const readline = require('node:readline');

const PORT = 8765;
const ROOT = resolve(__dirname, '..');
const SERVER_DIR = resolve(ROOT, 'server');
const WEB_DIR = resolve(ROOT, 'web');
const TSX_BIN = resolve(SERVER_DIR, 'node_modules', '.bin', 'tsx');
const VITE_BIN = resolve(WEB_DIR, 'node_modules', '.bin', 'vite');

function listeningPids(port) {
  const result = spawnSync('lsof', ['-nP', `-iTCP:${port}`, '-sTCP:LISTEN'], {
    encoding: 'utf8',
  });
  if (result.status !== 0 || !result.stdout.trim()) return [];
  const lines = result.stdout.trim().split(/\r?\n/).slice(1);
  const seen = new Map();
  for (const line of lines) {
    const cols = line.trim().split(/\s+/);
    const command = cols[0];
    const pid = Number(cols[1]);
    if (pid) seen.set(pid, command);
  }
  return Array.from(seen, ([pid, command]) => ({ pid, command }));
}

function ask(question) {
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  return new Promise((resolve) => {
    rl.question(question, (answer) => {
      rl.close();
      resolve(answer.trim());
    });
  });
}

async function ensurePortFree() {
  const pids = listeningPids(PORT);
  if (pids.length === 0) return;

  console.log(`\n[pawterm dev] Port ${PORT} is already in use:`);
  for (const { pid, command } of pids) {
    console.log(`  - ${command} pid=${pid}`);
  }

  const answer = await ask(`Kill these process(es) and continue? [y/N] `);
  if (!/^(y|yes)$/i.test(answer)) {
    console.log('[pawterm dev] Aborted.');
    process.exit(1);
  }

  for (const { pid } of pids) {
    try {
      process.kill(pid, 'SIGTERM');
    } catch {}
  }

  await new Promise((resolve) => setTimeout(resolve, 900));
  const stillListening = listeningPids(PORT);
  for (const { pid } of stillListening) {
    try {
      process.kill(pid, 'SIGKILL');
    } catch {}
  }
}

function exitIfShutdownComplete() {
  if (!shuttingDown) return;
  if (children.every((child) => child.exitCode != null || child.signalCode != null)) {
    process.exit(0);
  }
}

function run(name, command, args, options = {}) {
  const child = spawn(command, args, {
    cwd: options.cwd ?? ROOT,
    env: { ...process.env, ...(options.env ?? {}) },
    stdio: ['ignore', 'inherit', 'inherit'],
    shell: false,
  });
  child.name = name;
  child.on('exit', (code, signal) => {
    if (shuttingDown) {
      exitIfShutdownComplete();
      return;
    }

    if (signal === 'SIGINT' || signal === 'SIGTERM') {
      shutdown({ killChildren: false });
      return;
    }

    shuttingDown = true;
    for (const other of children) {
      if (other !== child) other.kill('SIGTERM');
    }
    process.exit(signal ? 1 : (code ?? 0));
  });
  children.push(child);
  return child;
}

let shuttingDown = false;
const children = [];

function shutdown({ killChildren = true } = {}) {
  if (shuttingDown) return;
  shuttingDown = true;
  if (killChildren) {
    for (const child of children) {
      if (child.exitCode == null && child.signalCode == null) {
        child.kill('SIGTERM');
      }
    }
  }
  exitIfShutdownComplete();
}

process.on('SIGINT', () => shutdown({ killChildren: false }));
process.on('SIGTERM', () => shutdown({ killChildren: true }));

(async () => {
  await ensurePortFree();
  run('server', TSX_BIN, ['watch', 'src/index.ts'], {
    cwd: SERVER_DIR,
    env: { PAWTERM_CONFIG: resolve(SERVER_DIR, 'config.json') },
  });
  run('web', VITE_BIN, [], { cwd: WEB_DIR });
})();
