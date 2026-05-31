import { execSync } from 'node:child_process';

/**
 * Resolve the user's login shell PATH once so background services launched by
 * launchd/systemd can still find nvm/homebrew-installed CLIs like codex.
 */
export function resolveLoginShellPath(
  env: NodeJS.ProcessEnv = process.env,
  exec: typeof execSync = execSync,
): string {
  try {
    const shell = env.SHELL ?? '/bin/zsh';
    // -i causes interactive-only plugins (gitstatus, p10k) to emit noise.
    // Source rc files manually so nvm/conda/homebrew paths are included.
    const rc = shell.includes('zsh')
      ? '[ -f ~/.zshrc ] && source ~/.zshrc'
      : '[ -f ~/.bashrc ] && source ~/.bashrc';
    return exec(`${shell} -lc '${rc}; echo $PATH'`, {
      encoding: 'utf-8',
      timeout: 5000,
    }).trim();
  } catch {
    return env.PATH ?? '';
  }
}

export const LOGIN_SHELL_PATH = resolveLoginShellPath();

export function buildAgentEnv(
  baseEnv: NodeJS.ProcessEnv = process.env,
  loginShellPath: string = LOGIN_SHELL_PATH,
): NodeJS.ProcessEnv {
  return {
    ...baseEnv,
    PATH: loginShellPath || baseEnv.PATH,
  };
}
