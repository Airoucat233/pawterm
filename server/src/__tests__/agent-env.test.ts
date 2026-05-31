import { describe, expect, it } from 'vitest';
import { buildAgentEnv } from '../agent-env.js';

describe('buildAgentEnv', () => {
  it('overrides service PATH with login shell PATH for agent subprocesses', () => {
    expect(buildAgentEnv(
      { PATH: '/usr/bin:/bin', CUSTOM: 'ok' },
      '/Users/me/.nvm/versions/node/v20/bin:/opt/homebrew/bin:/usr/bin:/bin',
    )).toEqual({
      PATH: '/Users/me/.nvm/versions/node/v20/bin:/opt/homebrew/bin:/usr/bin:/bin',
      CUSTOM: 'ok',
    });
  });
});
