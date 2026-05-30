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
});
