import { describe, expect, it } from 'vitest';
import { runMessagesToWire } from '../chat-rest.js';

describe('runMessagesToWire', () => {
  it('keeps Codex realtime userMessage events with item uuid', () => {
    const wires = runMessagesToWire('codex', {
      method: 'turn/updated',
      params: {
        item: {
          type: 'userMessage',
          id: 'user-1',
          content: [{ type: 'text', text: '你好' }],
        },
      },
    });

    expect(wires).toEqual([{
      uuid: 'user-1',
      wire: expect.objectContaining({
        type: 'user',
        native_event: 'turn/updated',
      }),
    }]);
  });

  it('keeps Codex realtime assistant items with item uuid', () => {
    const wires = runMessagesToWire('codex', {
      method: 'turn/updated',
      params: {
        item: {
          type: 'agentMessage',
          id: 'agent-1',
          text: '你好',
        },
      },
    });

    expect(wires).toEqual([{
      uuid: 'agent-1',
      wire: expect.objectContaining({
        type: 'assistant',
        native_event: 'turn/updated',
      }),
    }]);
  });

  it('maps Codex assistant deltas to realtime text deltas without uuid dedupe', () => {
    const wires = runMessagesToWire('codex', {
      method: 'item/agentMessage/delta',
      params: { delta: '你好' },
    });

    expect(wires).toEqual([{
      uuid: null,
      wire: {
        type: 'stream_delta',
        index: 0,
        kind: 'text',
        text: '你好',
      },
    }]);
  });

  it('maps Codex approval requests to native tool cards', () => {
    const wires = runMessagesToWire('codex', {
      id: 'approval-1',
      method: 'item/commandExecution/requestApproval',
      params: { threadId: 'thread-1', itemId: 'item-1', command: 'git status' },
    });

    expect(wires).toEqual([{
      uuid: 'approval-1',
      wire: {
        type: 'assistant',
        content: [{
          type: 'tool_use',
          id: 'approval-1',
          name: 'item/commandExecution/requestApproval',
          input: { threadId: 'thread-1', itemId: 'item-1', command: 'git status' },
          native_type: 'item/commandExecution/requestApproval',
          native_event: 'item/commandExecution/requestApproval',
          raw_payload: {
            id: 'approval-1',
            method: 'item/commandExecution/requestApproval',
            params: { threadId: 'thread-1', itemId: 'item-1', command: 'git status' },
          },
        }],
      },
    }]);
  });

  it('maps Codex server request resolved events to tool results', () => {
    const wires = runMessagesToWire('codex', {
      method: 'serverRequest/resolved',
      params: { threadId: 'thread-1', requestId: 'approval-1' },
    });

    expect(wires).toEqual([{
      uuid: 'approval-1:resolved',
      wire: {
        type: 'assistant',
        content: [{
          type: 'tool_result',
          tool_use_id: 'approval-1',
          content: 'resolved',
          is_error: false,
          native_type: 'serverRequest/resolved',
          native_event: 'serverRequest/resolved',
          raw_payload: {
            method: 'serverRequest/resolved',
            params: { threadId: 'thread-1', requestId: 'approval-1' },
          },
        }],
      },
    }]);
  });
});
