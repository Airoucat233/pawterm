import { describe, expect, it } from 'vitest';
import { codexThreadItemToWire } from '../agents/codex/serialize.js';

describe('codexThreadItemToWire', () => {
  it('keeps commandExecution as the native tool name', () => {
    const item = {
      type: 'commandExecution',
      id: 'cmd_1',
      command: 'pnpm test',
      cwd: '/repo',
      status: 'completed',
      aggregatedOutput: 'ok',
      exitCode: 0,
      durationMs: 120,
    };
    const wire = codexThreadItemToWire(item);
    expect(wire).toEqual({
      type: 'assistant',
      content: [
        {
          type: 'tool_use',
          id: 'cmd_1',
          name: 'commandExecution',
          input: { command: 'pnpm test', cwd: '/repo' },
          native_type: 'commandExecution',
          native_event: undefined,
          raw_payload: item,
        },
        {
          type: 'tool_result',
          tool_use_id: 'cmd_1',
          content: 'ok',
          is_error: false,
          native_type: 'commandExecution',
          native_event: undefined,
          raw_payload: item,
        },
      ],
      native: item,
    });
  });

  it('does not synthesize a tool result for in-progress commandExecution', () => {
    const wire = codexThreadItemToWire({
      type: 'commandExecution',
      id: 'cmd_live',
      command: 'sleep 10',
      cwd: '/repo',
      status: 'inProgress',
      aggregatedOutput: null,
      exitCode: null,
    });
    expect(wire?.type).toBe('assistant');
    if (wire?.type !== 'assistant') throw new Error('expected assistant message');
    expect(wire.content).toHaveLength(1);
    expect(wire.content[0]).toMatchObject({
      type: 'tool_use',
      name: 'commandExecution',
    });
  });

  it('keeps fileChange as the native tool name', () => {
    const item = {
      type: 'fileChange',
      id: 'file_1',
      changes: [{ path: '/repo/a.ts', kind: 'update' }],
      status: 'applied',
    };
    const wire = codexThreadItemToWire(item);
    expect(wire?.type).toBe('assistant');
    if (wire?.type !== 'assistant') throw new Error('expected assistant message');
    expect(wire?.content[0]).toMatchObject({
      type: 'tool_use',
      id: 'file_1',
      name: 'fileChange',
      native_type: 'fileChange',
    });
  });

  it('converts agentMessage to assistant text', () => {
    const item = {
      type: 'agentMessage',
      id: 'msg_1',
      text: 'hello',
      phase: null,
      memoryCitation: null,
    };
    const wire = codexThreadItemToWire(item);
    expect(wire).toEqual({
      type: 'assistant',
      content: [{ type: 'text', text: 'hello' }],
      native: item,
    });
  });

  it('does not echo Codex webSearch input as the tool result', () => {
    const item = {
      type: 'webSearch',
      id: 'ws_1',
      query: 'OpenAI Codex web search tool support',
      action: {
        type: 'search',
        query: 'OpenAI Codex web search tool support',
        queries: ['OpenAI Codex web search tool support'],
      },
    };

    const wire = codexThreadItemToWire(item);

    expect(wire).toEqual({
      type: 'assistant',
      content: [
        {
          type: 'tool_use',
          id: 'ws_1',
          name: 'WebSearch',
          input: {
            query: 'OpenAI Codex web search tool support',
            queries: ['OpenAI Codex web search tool support'],
            action: 'search',
          },
          native_type: 'webSearch',
          native_event: undefined,
          raw_payload: item,
        },
        {
          type: 'tool_result',
          tool_use_id: 'ws_1',
          content: 'Search completed.',
          is_error: false,
          native_type: 'webSearch',
          native_event: undefined,
          raw_payload: item,
        },
      ],
      native: item,
    });
  });

  it('uses Codex webSearch results as the tool result when present', () => {
    const item = {
      type: 'webSearch',
      id: 'ws_2',
      query: 'PawTerm',
      action: { type: 'search', query: 'PawTerm' },
      results: [
        { title: 'PawTerm docs', url: 'https://example.com/pawterm' },
      ],
    };

    const wire = codexThreadItemToWire(item);

    expect(wire?.type).toBe('assistant');
    if (wire?.type !== 'assistant') throw new Error('expected assistant message');
    expect(wire.content[1]).toMatchObject({
      type: 'tool_result',
      tool_use_id: 'ws_2',
      content: JSON.stringify(item.results, null, 2),
      is_error: false,
    });
  });

  it('does not throw on circular native payloads', () => {
    const result: any = { ok: true };
    result.self = result;
    const args: any = { path: '/repo/a.ts' };
    args.self = args;
    const item: any = {
      type: 'mcpToolCall',
      id: 'mcp_1',
      server: 'fs',
      tool: 'read',
      arguments: args,
      result,
    };
    item.self = item;

    expect(() => codexThreadItemToWire(item)).not.toThrow();
    const wire = codexThreadItemToWire(item);
    expect(wire?.type).toBe('assistant');
    if (wire?.type !== 'assistant') throw new Error('expected assistant message');
    expect(() => JSON.stringify(wire)).not.toThrow();
    expect(wire.content[0]).toMatchObject({
      type: 'tool_use',
      name: 'mcpToolCall',
      native_type: 'mcpToolCall',
    });
  });

  it('does not throw on circular file change input', () => {
    const change: any = { path: '/repo/a.ts', kind: 'update' };
    change.self = change;
    const wire = codexThreadItemToWire({
      type: 'fileChange',
      id: 'file_circular',
      changes: [change],
      status: 'applied',
    });

    expect(() => JSON.stringify(wire)).not.toThrow();
  });

  it('does not throw on circular dynamic tool content', () => {
    const contentItems: any = { output: 'done' };
    contentItems.self = contentItems;

    expect(() => codexThreadItemToWire({
      type: 'dynamicToolCall',
      id: 'dyn_1',
      namespace: 'shell',
      tool: 'run',
      contentItems,
      success: true,
    })).not.toThrow();
  });
});
