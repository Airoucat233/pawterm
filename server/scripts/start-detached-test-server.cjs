#!/usr/bin/env node

const fs = require('node:fs');
const { spawn } = require('node:child_process');

const [serverDir, configFile, logFile, pidFile] = process.argv.slice(2);

if (!serverDir || !configFile || !logFile || !pidFile) {
  console.error('Usage: start-detached-test-server.cjs <serverDir> <configFile> <logFile> <pidFile>');
  process.exit(2);
}

const logFd = fs.openSync(logFile, 'w');
const child = spawn(process.execPath, ['--import', 'tsx', 'src/index.ts'], {
  cwd: serverDir,
  env: { ...process.env, PAWTERM_CONFIG: configFile },
  detached: true,
  stdio: ['ignore', logFd, logFd],
});

fs.writeFileSync(pidFile, String(child.pid));
child.unref();
