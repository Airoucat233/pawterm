import { describe, expect, it } from 'vitest';
import { ToolPermissionRegistry } from '../tool-permission.js';

describe('ToolPermissionRegistry', () => {
  it('resolves allow, echoing original input as updatedInput', async () => {
    const reg = new ToolPermissionRegistry({ timeoutMs: 1000 });
    const p = reg.register('t1', { command: 'ls' }, 'Bash');
    expect(reg.answer('t1', 'allow')).toBe(true);
    await expect(p).resolves.toEqual({ behavior: 'allow', updatedInput: { command: 'ls' } });
  });

  it('resolves deny with a message', async () => {
    const reg = new ToolPermissionRegistry({ timeoutMs: 1000 });
    const p = reg.register('t2', { command: 'rm -rf /' }, 'Bash');
    expect(reg.answer('t2', 'deny')).toBe(true);
    await expect(p).resolves.toEqual({
      behavior: 'deny',
      message: expect.stringContaining('denied'),
    });
  });

  it('attaches a session allow rule when dontAskAgain', async () => {
    const reg = new ToolPermissionRegistry({ timeoutMs: 1000 });
    const p = reg.register('t3', { command: 'ls' }, 'Bash');
    reg.answer('t3', 'allow', { dontAskAgain: true });
    const r = (await p) as { behavior: 'allow'; updatedPermissions?: unknown[] };
    expect(r.behavior).toBe('allow');
    expect(Array.isArray(r.updatedPermissions)).toBe(true);
  });

  it('answer on unknown id returns false', () => {
    const reg = new ToolPermissionRegistry({ timeoutMs: 1000 });
    expect(reg.answer('nope', 'allow')).toBe(false);
  });

  it('rejectAll denies everything pending', async () => {
    const reg = new ToolPermissionRegistry({ timeoutMs: 1000 });
    const p = reg.register('t4', {}, 'Bash');
    reg.rejectAll('session ended');
    await expect(p).resolves.toEqual({ behavior: 'deny', message: 'session ended' });
    expect(reg.answer('t4', 'allow')).toBe(false);
  });
});
