#!/usr/bin/env node

const { spawn, spawnSync } = require('node:child_process');
const { resolve } = require('node:path');

const ROOT = resolve(__dirname, '..');
const APP_DIR = resolve(ROOT, 'app');
const POLL_MS = 2000;
const BOOT_TIMEOUT_MS = 120000;

function runCapture(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: options.cwd ?? ROOT,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  if (result.status !== 0) {
    const detail = (result.stderr || result.stdout || '').trim();
    throw new Error(`${command} ${args.join(' ')} failed${detail ? `: ${detail}` : ''}`);
  }
  return result.stdout;
}

function parseJson(text, fallback) {
  try {
    return JSON.parse(text);
  } catch {
    return fallback;
  }
}

function androidDevices() {
  const devices = parseJson(runCapture('flutter', ['devices', '--machine'], { cwd: APP_DIR }), []);
  return devices.filter((device) => {
    const targetPlatform = String(device.targetPlatform ?? '').toLowerCase();
    return targetPlatform.includes('android') && device.emulator === true;
  });
}

function firstEmulatorId() {
  const output = runCapture('flutter', ['emulators'], { cwd: APP_DIR });
  const emulators = output
    .split(/\r?\n/)
    .map((line) => line.split('•').map((part) => part.trim()))
    .filter((parts) => parts.length >= 4 && parts[0] && parts[0] !== 'Id')
    .map(([id, name, manufacturer, platform]) => ({ id, name, manufacturer, platform }));
  const android = emulators.find((emulator) => {
    const id = String(emulator.id ?? '').toLowerCase();
    const name = String(emulator.name ?? '').toLowerCase();
    const platform = String(emulator.platform ?? '').toLowerCase();
    return platform.includes('android') || id.includes('android') || name.includes('android') || id.includes('pixel');
  });
  return android?.id;
}

function start(command, args, options = {}) {
  return spawn(command, args, {
    cwd: options.cwd ?? ROOT,
    env: process.env,
    stdio: 'inherit',
    shell: false,
  });
}

async function waitForAndroidDevice() {
  const deadline = Date.now() + BOOT_TIMEOUT_MS;
  while (Date.now() < deadline) {
    const devices = androidDevices();
    if (devices.length > 0) return devices[0].id;
    await new Promise((resolve) => setTimeout(resolve, POLL_MS));
  }
  throw new Error('Timed out waiting for Android emulator to boot.');
}

async function ensureAndroidDevice() {
  const existing = androidDevices();
  if (existing.length > 0) return existing[0].id;

  const emulatorId = firstEmulatorId();
  if (!emulatorId) {
    throw new Error('No Android emulator found. Create one in Android Studio first.');
  }

  console.log(`[pawterm android] launching emulator: ${emulatorId}`);
  start('flutter', ['emulators', '--launch', emulatorId], { cwd: APP_DIR });
  return waitForAndroidDevice();
}

(async () => {
  try {
    const deviceId = await ensureAndroidDevice();
    console.log(`[pawterm android] running PawTerm Dev on ${deviceId}`);
    const child = start('flutter', ['run', '--flavor', 'dev', '--dart-define=PAWTERM_DEFAULT_PORT=8765', '-d', deviceId], { cwd: APP_DIR });
    child.on('exit', (code, signal) => {
      process.exit(signal ? 1 : (code ?? 0));
    });
  } catch (err) {
    console.error(`[pawterm android] ${err instanceof Error ? err.message : String(err)}`);
    process.exit(1);
  }
})();
