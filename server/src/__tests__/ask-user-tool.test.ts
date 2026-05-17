import { describe, expect, it, vi } from 'vitest';
import { AskUserQuestionRegistry, formatAnswers } from '../ask-user-tool.js';

describe('AskUserQuestionRegistry', () => {
  it('resolves the registered promise when answer() is called', async () => {
    const r = new AskUserQuestionRegistry();
    const promise = r.register('id1');
    const ok = r.answer('id1', 'hello');
    expect(ok).toBe(true);
    const result = await promise;
    expect(result.content).toEqual([{ type: 'text', text: 'hello' }]);
  });

  it('answer() returns false for unknown tool_use_id', () => {
    const r = new AskUserQuestionRegistry();
    expect(r.answer('nope', 'x')).toBe(false);
  });

  it('rejectAll() rejects all pending promises', async () => {
    const r = new AskUserQuestionRegistry();
    const p1 = r.register('a');
    const p2 = r.register('b');
    r.rejectAll('socket closed');
    await expect(p1).rejects.toThrow('socket closed');
    await expect(p2).rejects.toThrow('socket closed');
  });

  it('answer() after rejectAll() returns false', () => {
    const r = new AskUserQuestionRegistry();
    r.register('a').catch(() => {}); // swallow rejection
    r.rejectAll('x');
    expect(r.answer('a', 'late')).toBe(false);
  });

  it('register times out after the configured ms', async () => {
    vi.useFakeTimers();
    const r = new AskUserQuestionRegistry({ timeoutMs: 1000 });
    const p = r.register('id1').catch((e) => e);
    vi.advanceTimersByTime(1001);
    const err = await p;
    expect(err).toBeInstanceOf(Error);
    expect((err as Error).message).toMatch(/30 minutes|within/i);
    vi.useRealTimers();
  });

  it('pendingToolUseId is initially null', () => {
    const r = new AskUserQuestionRegistry();
    expect(r.pendingToolUseId).toBeNull();
  });

  it('pendingToolUseId can be set and cleared externally', () => {
    const r = new AskUserQuestionRegistry();
    r.pendingToolUseId = 'toolu_abc';
    expect(r.pendingToolUseId).toBe('toolu_abc');
    r.pendingToolUseId = null;
    expect(r.pendingToolUseId).toBeNull();
  });
});

describe('formatAnswers', () => {
  it('formats single question single answer', () => {
    const out = formatAnswers({ 'Which library?': 'date-fns' });
    expect(out).toContain('Q: Which library?');
    expect(out).toContain('A: date-fns');
    expect(out).toContain('User has answered your questions:');
    expect(out).toContain('You can now continue');
  });

  it('separates multiple questions with blank line', () => {
    const out = formatAnswers({ Q1: 'A1', Q2: 'A2' });
    expect(out).toMatch(/Q: Q1\nA: A1\n\nQ: Q2\nA: A2/);
  });

  it('includes preview when annotation present', () => {
    const out = formatAnswers(
      { 'Which layout?': 'Sidebar' },
      { 'Which layout?': { preview: '```\n[ nav | content ]\n```' } },
    );
    expect(out).toContain('selected preview:');
    expect(out).toContain('[ nav | content ]');
  });
});
