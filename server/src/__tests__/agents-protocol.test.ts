import { describe, expect, it } from 'vitest';
import { parseAgentQuery, parseClaudeRuntimeFromBody } from '../agents/http-helpers.js';

describe('agent HTTP helpers', () => {
  it('defaults missing agent query to claude', () => {
    expect(parseAgentQuery(undefined)).toBe('claude');
  });

  it('accepts all for session list only', () => {
    expect(parseAgentQuery('all', { allowAll: true })).toBe('all');
  });

  it('rejects all for single-provider routes', () => {
    expect(() => parseAgentQuery('all')).toThrow(/agent=all is not valid/);
  });

  it('builds a claude runtime from old chat body fields', () => {
    expect(parseClaudeRuntimeFromBody({ model: 'claude-sonnet-4-6', permission_mode: 'plan' })).toEqual({
      agent: 'claude',
      model: 'claude-sonnet-4-6',
      permission_mode: 'plan',
    });
  });
});
