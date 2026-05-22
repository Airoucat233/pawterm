import { describe, expect, it } from 'vitest';
import { parseRuntimeFromChatBody, parseRuntimePatchForAgent } from '../agents/http-helpers.js';

describe('parseRuntimeFromChatBody', () => {
  it('keeps old claude body compatibility', () => {
    expect(parseRuntimeFromChatBody({
      model: 'claude-sonnet-4-6',
      permission_mode: 'acceptEdits',
    })).toEqual({
      agent: 'claude',
      model: 'claude-sonnet-4-6',
      permission_mode: 'acceptEdits',
    });
  });

  it('accepts explicit codex runtime', () => {
    expect(parseRuntimeFromChatBody({
      agent: 'codex',
      runtime: {
        agent: 'codex',
        model: 'gpt-5.4',
        sandbox: 'workspace-write',
        approval_policy: 'on-request',
      },
    })).toEqual({
      agent: 'codex',
      model: 'gpt-5.4',
      sandbox: 'workspace-write',
      approval_policy: 'on-request',
    });
  });

  it('rejects runtime agent mismatch', () => {
    expect(() => parseRuntimeFromChatBody({
      agent: 'codex',
      runtime: { agent: 'claude', permission_mode: 'acceptEdits' },
    })).toThrow(/runtime agent mismatch/);
  });

  it('rejects explicit claude runtime without permission mode', () => {
    expect(() => parseRuntimeFromChatBody({
      agent: 'claude',
      runtime: { agent: 'claude' },
    })).toThrow(/permission_mode/);
  });

  it('rejects incomplete codex runtime', () => {
    expect(() => parseRuntimeFromChatBody({
      agent: 'codex',
      runtime: { agent: 'codex', sandbox: 'workspace-write' },
    })).toThrow(/approval_policy/);
  });
});

describe('parseRuntimePatchForAgent', () => {
  it('rejects runtime patch agent mismatch', () => {
    expect(() => parseRuntimePatchForAgent('claude', { agent: 'codex', model: 'gpt-5.4' }))
      .toThrow(/runtime agent mismatch/);
  });

  it('accepts a claude runtime patch', () => {
    expect(parseRuntimePatchForAgent(undefined, {
      agent: 'claude',
      model: 'claude-sonnet-4-6',
      permission_mode: 'plan',
    })).toEqual({
      agent: 'claude',
      patch: {
        agent: 'claude',
        model: 'claude-sonnet-4-6',
        permission_mode: 'plan',
      },
    });
  });
});
