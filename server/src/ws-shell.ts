import { existsSync, mkdtempSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, join, resolve } from 'node:path';

import type { WebSocket } from '@fastify/websocket';
import type { FastifyRequest } from 'fastify';
import * as pty from 'node-pty';

import type { ShellClientMessage, ShellServerMessage } from '@pawterm/shared';

import { isPathAllowed } from './config.js';

/**
 * Pick a usable login shell. Order:
 *   1. msg.shell from client (if exists)
 *   2. $SHELL env (if exists)
 *   3. /bin/zsh → /bin/bash → /bin/sh
 */
function pickShell(requested: string | undefined): string {
  const candidates = [
    requested,
    process.env.SHELL,
    '/bin/zsh',
    '/bin/bash',
    '/bin/sh',
  ];
  for (const c of candidates) {
    if (c && existsSync(c)) return c;
  }
  return '/bin/sh';
}

/**
 * 注入一个 OSC 7 cwd 报告 hook，供 app 侧 cwd 状态条实时跟随 cd。
 * **不修改用户的 PROMPT/PS1** —— starship/p10k/oh-my-zsh 等主题完全保留原状。
 *
 * 实现：
 * - zsh: ZDOTDIR=临时目录，临时目录里 4 个 rc 文件分别先 source 用户原文件，
 *        再在 .zshrc 末尾追加 precmd hook（emit OSC 7）。
 * - bash: --rcfile=临时 bashrc。先 source 用户 .bashrc/.bash_profile，再在
 *         PROMPT_COMMAND 前面叠加 OSC 7 emit。
 * - 其它 shell: 跳过注入。
 *
 * 返回 { env, args, cleanup }；cleanup 在 socket 关闭时删除临时目录。
 */
function setupShellInjection(shell: string): {
  env: Record<string, string>;
  args: string[];
  cleanup: () => void;
} {
  const tmpDir = mkdtempSync(join(tmpdir(), 'cc-shell-'));
  const cleanup = () => {
    try { rmSync(tmpDir, { recursive: true, force: true }); } catch { /* ignore */ }
  };
  const shellName = basename(shell);

  // zsh 启动顺序：.zshenv → (.zprofile) → .zshrc → (.zlogin)。
  // 我们把 ZDOTDIR 指到临时目录，因此每个阶段都要主动 source 用户原文件，
  // 否则用户在 .zshenv 设置的 PATH/环境变量会全丢。
  const userHome = '$_PAWTERM_USER_ZDOTDIR';
  const sourceUserFile = (name: string) => `
if [ -n "$_PAWTERM_USER_ZDOTDIR" ] && [ -f "${userHome}/${name}" ]; then
  ZDOTDIR="$_PAWTERM_USER_ZDOTDIR"
  source "${userHome}/${name}"
  ZDOTDIR="$_PAWTERM_INJECT_ZDOTDIR"
fi`;

  const zshEnv = `
export _PAWTERM_INJECT_ZDOTDIR="$ZDOTDIR"${sourceUserFile('.zshenv')}
`;
  const zshProfile = `${sourceUserFile('.zprofile')}\n`;
  // 注入放在 source 用户 zshrc 之**后**——这样用户 zshrc 里若重置 precmd_functions
  // 数组（oh-my-zsh 偶有），我们的 hook 仍能挂上。**不**改 PROMPT。
  const zshRc = `${sourceUserFile('.zshrc')}

# Claude Companion: OSC 7 cwd reporter — drives the app-side cwd bar.
# Does NOT modify the user's PROMPT.
__cc_emit_cwd() { printf '\\e]7;%s\\a' "$PWD"; }
autoload -Uz add-zsh-hook 2>/dev/null
add-zsh-hook precmd __cc_emit_cwd 2>/dev/null
__cc_emit_cwd
`;
  const zshLogin = `${sourceUserFile('.zlogin')}\n`;

  const bashRc = `
# Source the user's real bashrc / bash_profile first.
[ -f "$HOME/.bashrc" ] && source "$HOME/.bashrc"
[ -f "$HOME/.bash_profile" ] && source "$HOME/.bash_profile"

# Claude Companion: OSC 7 cwd reporter. Does NOT modify the user's PS1.
__cc_emit_cwd() { printf '\\e]7;%s\\a' "$PWD"; }
PROMPT_COMMAND="__cc_emit_cwd; \${PROMPT_COMMAND:-:}"
__cc_emit_cwd
`;

  if (shellName === 'zsh') {
    writeFileSync(join(tmpDir, '.zshenv'), zshEnv, { mode: 0o600 });
    writeFileSync(join(tmpDir, '.zprofile'), zshProfile, { mode: 0o600 });
    writeFileSync(join(tmpDir, '.zshrc'), zshRc, { mode: 0o600 });
    writeFileSync(join(tmpDir, '.zlogin'), zshLogin, { mode: 0o600 });
    return {
      env: {
        _PAWTERM_USER_ZDOTDIR: process.env.ZDOTDIR ?? process.env.HOME ?? '',
        ZDOTDIR: tmpDir,
      },
      args: ['-l'],
      cleanup,
    };
  }

  if (shellName === 'bash') {
    const rcPath = join(tmpDir, 'bashrc');
    writeFileSync(rcPath, bashRc, { mode: 0o600 });
    return {
      env: {},
      args: ['--rcfile', rcPath, '-i'],
      cleanup,
    };
  }

  // 其它 shell（/bin/sh, fish, ...）暂不注入，按原 login shell 启动。
  cleanup();
  return { env: {}, args: ['-l'], cleanup: () => {} };
}

/**
 * OSC 7 sniffer. Strips matching escape sequences from output so the terminal
 * doesn't render garbage, and returns the latest cwd if any.
 *
 * OSC 7 format:
 *   ESC ] 7 ; <payload> BEL          (BEL = 0x07)
 *   ESC ] 7 ; <payload> ESC \         (ST  = ESC \)
 *
 * Payload is usually `file://<host><path>` — we accept that form and a bare
 * `<path>` form.
 */
class Osc7Sniffer {
  private buf = '';
  private onCwd: (cwd: string) => void;

  constructor(onCwd: (cwd: string) => void) {
    this.onCwd = onCwd;
  }

  /** Strip OSC 7 from `data` and call onCwd for any matched cwd. Returns cleaned data. */
  feed(data: string): string {
    this.buf += data;
    let out = '';
    let i = 0;
    while (i < this.buf.length) {
      const esc = this.buf.indexOf('\x1b]7;', i);
      if (esc < 0) {
        out += this.buf.substring(i);
        i = this.buf.length;
        break;
      }
      out += this.buf.substring(i, esc);
      // find terminator: BEL or ESC \
      const payloadStart = esc + 4;
      let termIdx = -1;
      let termLen = 0;
      for (let j = payloadStart; j < this.buf.length; j++) {
        const c = this.buf.charCodeAt(j);
        if (c === 0x07) { termIdx = j; termLen = 1; break; }
        if (c === 0x1b && this.buf.charCodeAt(j + 1) === 0x5c) { termIdx = j; termLen = 2; break; }
      }
      if (termIdx < 0) {
        // partial — keep from `esc` in buffer for next feed
        this.buf = this.buf.substring(esc);
        return out;
      }
      const payload = this.buf.substring(payloadStart, termIdx);
      this.handle(payload);
      i = termIdx + termLen;
    }
    this.buf = '';
    return out;
  }

  private handle(payload: string): void {
    // `file://<host>/path` or bare `/path`
    let cwd = payload;
    const m = /^file:\/\/[^/]*(\/.*)$/.exec(payload);
    if (m) cwd = decodeURIComponent(m[1]!);
    if (cwd.startsWith('/')) this.onCwd(cwd);
  }
}

const INIT_TIMEOUT_MS = 10_000;

export function handleShellSocket(socket: WebSocket, _req: FastifyRequest): void {
  let term: pty.IPty | null = null;
  let initialized = false;
  let cleanupInjection: (() => void) | null = null;

  const initWatchdog = setTimeout(() => {
    if (!initialized) {
      try { socket.close(4000, 'init timeout'); } catch { /* ignore */ }
    }
  }, INIT_TIMEOUT_MS);

  function send(payload: ShellServerMessage): void {
    if (socket.readyState !== 1) return;
    socket.send(JSON.stringify(payload));
  }

  function teardown(): void {
    clearTimeout(initWatchdog);
    if (term) {
      try { term.kill('SIGKILL'); } catch { /* ignore */ }
      term = null;
    }
    cleanupInjection?.();
    cleanupInjection = null;
  }

  function spawnPty(
    cwd: string,
    shell: string,
    cols: number,
    rows: number,
    extraEnv: Record<string, string>,
    args: string[],
  ): pty.IPty {
    return pty.spawn(shell, args, {
      name: 'xterm-256color',
      cols,
      rows,
      cwd,
      env: {
        ...process.env,
        ...extraEnv,
        TERM: 'xterm-256color',
        COLORTERM: 'truecolor',
        FORCE_COLOR: '3',
        LANG: process.env.LANG ?? 'en_US.UTF-8',
      },
    });
  }

  socket.on('message', (raw: Buffer | string) => {
    let msg: ShellClientMessage;
    try {
      msg = JSON.parse(raw.toString()) as ShellClientMessage;
    } catch {
      send({ type: 'error', message: 'Invalid JSON' });
      return;
    }

    switch (msg.type) {
      case 'init': {
        if (initialized) {
          send({ type: 'error', message: 'Already initialized; open a new socket to re-init' });
          return;
        }
        const cwd = resolve(msg.cwd);
        if (!isPathAllowed(cwd)) {
          send({ type: 'error', message: `Project not allowed: ${cwd}` });
          try { socket.close(4001, 'forbidden cwd'); } catch { /* ignore */ }
          return;
        }
        if (!existsSync(cwd) || !statSync(cwd).isDirectory()) {
          send({ type: 'error', message: `cwd not a directory: ${cwd}` });
          try { socket.close(4003, 'bad cwd'); } catch { /* ignore */ }
          return;
        }
        initialized = true;
        clearTimeout(initWatchdog);
        const shell = pickShell(msg.shell);
        const injection = setupShellInjection(shell);
        cleanupInjection = injection.cleanup;
        try {
          term = spawnPty(cwd, shell, msg.cols, msg.rows, injection.env, injection.args);
          const sniffer = new Osc7Sniffer((newCwd) => {
            send({ type: 'cwd', cwd: newCwd });
          });
          term.onData((data) => {
            const cleaned = sniffer.feed(data);
            if (cleaned.length > 0) send({ type: 'output', data: cleaned });
          });
          term.onExit(({ exitCode }) => {
            send({ type: 'exit', code: exitCode });
            term = null;
            cleanupInjection?.();
            cleanupInjection = null;
          });
          send({ type: 'ready' });
        } catch (err) {
          const e = err as NodeJS.ErrnoException;
          const detail = [e.code, e.message].filter(Boolean).join(' · ');
          send({
            type: 'error',
            message: `spawn failed [shell=${shell} cwd=${cwd}] ${detail}`,
          });
          try { socket.close(4002, 'spawn failed'); } catch { /* ignore */ }
          cleanupInjection?.();
          cleanupInjection = null;
        }
        break;
      }

      case 'input':
        term?.write(msg.data);
        break;

      case 'resize':
        try { term?.resize(msg.cols, msg.rows); } catch { /* ignore */ }
        break;

      case 'signal':
        term?.kill(msg.signal);
        break;
    }
  });

  socket.on('close', teardown);
  socket.on('error', teardown);
}
