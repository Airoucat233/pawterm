import { execSync, spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, unlinkSync, writeFileSync } from 'node:fs';
import { homedir, platform } from 'node:os';
import { resolve } from 'node:path';

const LABEL = 'com.airoucat.pawterm-server';
const HOME = homedir();
const PLIST_PATH = resolve(HOME, 'Library', 'LaunchAgents', `${LABEL}.plist`);
const SYSTEMD_DIR = resolve(HOME, '.config', 'systemd', 'user');
const SYSTEMD_UNIT = resolve(SYSTEMD_DIR, 'pawterm-server.service');
const CONFIG_DIR = resolve(HOME, '.config', 'pawterm');
const LOG_PATH = resolve(CONFIG_DIR, 'server.log');

type SupportedPlatform = 'darwin' | 'linux';

function currentPlatform(): SupportedPlatform | null {
  const p = platform();
  if (p === 'darwin') return 'darwin';
  if (p === 'linux') return 'linux';
  return null;
}

function darwinPlist(nodeBin: string, scriptPath: string): string {
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
\t<key>Label</key>
\t<string>${LABEL}</string>
\t<key>ProgramArguments</key>
\t<array>
\t\t<string>${nodeBin}</string>
\t\t<string>${scriptPath}</string>
\t</array>
\t<key>RunAtLoad</key>
\t<true/>
\t<key>KeepAlive</key>
\t<true/>
\t<key>StandardOutPath</key>
\t<string>${LOG_PATH}</string>
\t<key>StandardErrorPath</key>
\t<string>${LOG_PATH}</string>
</dict>
</plist>
`;
}

function linuxUnit(nodeBin: string, scriptPath: string): string {
  return `[Unit]
Description=PawTerm Server
After=network.target

[Service]
ExecStart=${nodeBin} ${scriptPath}
Restart=always
StandardOutput=append:${LOG_PATH}
StandardError=append:${LOG_PATH}

[Install]
WantedBy=default.target
`;
}

function exec(cmd: string): void {
  execSync(cmd, { stdio: 'inherit' });
}

function tryExec(cmd: string): void {
  try { execSync(cmd, { stdio: 'ignore' }); } catch { /* ignore */ }
}

function warnIfNpx(): void {
  const script = process.argv[1] ?? '';
  if (script.includes('_npx') || script.includes('/.npm/') || script.includes('/npx/')) {
    console.warn('⚠  Looks like you ran via npx. The service will point to the npx cache,');
    console.warn('   which may be cleaned up. For a persistent install, use:');
    console.warn('     npm install -g pawterm-server');
    console.warn('     pawterm-server install');
    console.warn('');
  }
}

export function runServiceCommand(cmd: string): void {
  const p = currentPlatform();

  if (cmd === 'install') {
    if (!p) { console.error('Service management is only supported on macOS and Linux.'); process.exit(1); }
    warnIfNpx();
    mkdirSync(CONFIG_DIR, { recursive: true });
    const nodeBin = process.execPath;
    const scriptPath = process.argv[1]!;

    if (p === 'darwin') {
      mkdirSync(resolve(HOME, 'Library', 'LaunchAgents'), { recursive: true });
      tryExec(`launchctl unload "${PLIST_PATH}"`);
      writeFileSync(PLIST_PATH, darwinPlist(nodeBin, scriptPath));
      console.log('✓ Service installed (not started)');
      console.log('  Auto-starts at login');
      console.log(`  Logs:  ${LOG_PATH}`);
      console.log(`  Plist: ${PLIST_PATH}`);
    } else {
      mkdirSync(SYSTEMD_DIR, { recursive: true });
      writeFileSync(SYSTEMD_UNIT, linuxUnit(nodeBin, scriptPath));
      exec('systemctl --user daemon-reload');
      exec('systemctl --user enable pawterm-server');
      console.log('✓ Service installed (not started)');
      console.log('  Auto-starts at login (loginctl enable-linger may be required)');
      console.log(`  Logs: ${LOG_PATH}`);
    }
    return;
  }

  if (cmd === 'uninstall') {
    if (p === 'darwin') {
      if (!existsSync(PLIST_PATH)) { console.log('Service is not installed.'); return; }
      tryExec(`launchctl unload "${PLIST_PATH}"`);
      unlinkSync(PLIST_PATH);
      console.log('✓ Service uninstalled');
    } else if (p === 'linux') {
      tryExec('systemctl --user disable --now pawterm-server');
      if (existsSync(SYSTEMD_UNIT)) { unlinkSync(SYSTEMD_UNIT); tryExec('systemctl --user daemon-reload'); }
      console.log('✓ Service uninstalled');
    } else {
      console.error('Unsupported platform.');
    }
    return;
  }

  if (cmd === 'start') {
    if (p === 'darwin') {
      if (!existsSync(PLIST_PATH)) { console.error('Service not installed. Run: pawterm-server install'); process.exit(1); }
      const running = spawnSync('launchctl', ['list', LABEL], { encoding: 'utf-8' });
      if (running.status === 0) { console.log('Service is already running.'); return; }
      exec(`launchctl load "${PLIST_PATH}"`);
      console.log('✓ Service started');
    } else if (p === 'linux') {
      exec('systemctl --user start pawterm-server');
      console.log('✓ Service started');
    } else {
      console.error('Unsupported platform.');
    }
    return;
  }

  if (cmd === 'stop') {
    if (p === 'darwin') {
      if (!existsSync(PLIST_PATH)) { console.error('Service not installed.'); process.exit(1); }
      const running = spawnSync('launchctl', ['list', LABEL], { encoding: 'utf-8' });
      if (running.status !== 0) { console.log('Service is not running.'); return; }
      exec(`launchctl unload "${PLIST_PATH}"`);
      console.log('✓ Service stopped');
    } else if (p === 'linux') {
      exec('systemctl --user stop pawterm-server');
      console.log('✓ Service stopped');
    } else {
      console.error('Unsupported platform.');
    }
    return;
  }

  if (cmd === 'restart') {
    if (p === 'darwin') {
      if (!existsSync(PLIST_PATH)) { console.error('Service not installed. Run: pawterm-server install'); process.exit(1); }
      tryExec(`launchctl unload "${PLIST_PATH}"`);
      exec(`launchctl load "${PLIST_PATH}"`);
      console.log('✓ Service restarted');
    } else if (p === 'linux') {
      exec('systemctl --user restart pawterm-server');
      console.log('✓ Service restarted');
    } else {
      console.error('Unsupported platform.');
    }
    return;
  }

  if (cmd === 'help') {
    console.log(`
Usage: pawterm-server [command]

  (no command)       Start the server in foreground
  install            Install and start as a background service (auto-starts at login)
  uninstall          Remove the background service
  start              Start the background service
  stop               Stop the background service
  restart            Restart the background service
  status             Show service status
  update             Update to the latest version and restart
  logs [n]           Tail service logs (default: last 50 lines)
  --version, -v      Print version
  help               Show this help
`);
    return;
  }

  if (cmd === 'update') {
    console.log('Updating pawterm-server...');
    exec('npm install -g pawterm-server');
    if (p === 'darwin' && existsSync(PLIST_PATH)) {
      tryExec(`launchctl unload "${PLIST_PATH}"`);
      exec(`launchctl load "${PLIST_PATH}"`);
      console.log('✓ Service restarted');
    } else if (p === 'linux') {
      tryExec('systemctl --user restart pawterm-server');
      console.log('✓ Service restarted');
    }
    return;
  }

  if (cmd === 'logs') {
    if (!existsSync(LOG_PATH)) {
      console.log(`No log file yet: ${LOG_PATH}`);
      console.log('Start the service first: pawterm-server install');
      return;
    }
    const lines = process.argv[3] ?? '50';
    spawnSync('tail', ['-n', lines, '-f', LOG_PATH], { stdio: 'inherit' });
    return;
  }

  if (cmd === 'status') {
    if (p === 'darwin') {
      const r = spawnSync('launchctl', ['list', LABEL], { encoding: 'utf-8' });
      if (r.status === 0) {
        console.log('● pawterm-server  [running]');
        if (r.stdout.trim()) console.log(r.stdout.trim());
      } else {
        console.log('● pawterm-server  [not running]');
        if (!existsSync(PLIST_PATH)) console.log('  not installed — run: pawterm-server install');
        else console.log('  installed but stopped — run: pawterm-server start');
      }
      console.log(`  Logs: ${LOG_PATH}`);
    } else if (p === 'linux') {
      spawnSync('systemctl', ['--user', 'status', 'pawterm-server'], { stdio: 'inherit' });
    } else {
      console.error('Unsupported platform.');
    }
    return;
  }
}
