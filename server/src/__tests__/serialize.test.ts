import { describe, expect, it } from 'vitest';
import { messageToWire } from '../serialize.js';

describe('normalizeToolResultContent (via messageToWire user msg)', () => {
  function wireToolResultContent(content: unknown) {
    const wire = messageToWire({
      type: 'user',
      message: {
        role: 'user',
        content: [{ type: 'tool_result', tool_use_id: 'x', content, is_error: false }],
      },
    });
    return (wire.content[0] as any).content;
  }

  it('passes plain strings through unchanged', () => {
    expect(wireToolResultContent('hello')).toBe('hello');
  });

  it('preserves text blocks with string text', () => {
    expect(wireToolResultContent([{ type: 'text', text: 'abc' }])).toEqual([
      { type: 'text', text: 'abc' },
    ]);
  });

  it('JSON-stringifies object-shaped text fields (this is the [object Object] bug)', () => {
    const result = wireToolResultContent([{ type: 'text', text: { a: 1, b: [2, 3] } }]);
    expect(result).toEqual([
      { type: 'text', text: '{\n  "a": 1,\n  "b": [\n    2,\n    3\n  ]\n}' },
    ]);
  });

  it('JSON-stringifies entire object items without text field', () => {
    const result = wireToolResultContent([{ some: 'data', nested: { x: 1 } }]);
    expect(result).toEqual([
      {
        type: 'text',
        text: '{\n  "some": "data",\n  "nested": {\n    "x": 1\n  }\n}',
      },
    ]);
  });

  it('JSON-stringifies whole-object content (non-array, non-string)', () => {
    expect(wireToolResultContent({ k: 'v' })).toBe('{\n  "k": "v"\n}');
  });

  it('preserves image content blocks as-is', () => {
    const img = { type: 'image', source: { data: 'b64...', media_type: 'image/png' } };
    expect(wireToolResultContent([img])).toEqual([img]);
  });

  it('handles null content', () => {
    expect(wireToolResultContent(null)).toBeNull();
  });

  it('safely handles circular references in object items (does not throw)', () => {
    const circular: any = { name: 'root', value: 42 };
    circular.self = circular;
    // Should NOT throw; fallback to String(v) which yields '[object Object]'
    // (the regression we accepted vs. crashing the whole wire pipeline).
    expect(() => wireToolResultContent([circular])).not.toThrow();
    const result = wireToolResultContent([circular]);
    expect(result).toHaveLength(1);
    expect(result[0].type).toBe('text');
    // Fallback path → String(circular) → "[object Object]"
    expect(typeof result[0].text).toBe('string');
  });

  it('handles undefined content the same as null', () => {
    expect(wireToolResultContent(undefined)).toBeNull();
  });
});

describe('Claude native tool metadata', () => {
  it('keeps Claude tool_use name unchanged and adds raw payload', () => {
    const raw = {
      type: 'assistant',
      message: {
        model: 'claude-sonnet-4-6',
        content: [
          { type: 'tool_use', id: 'toolu_1', name: 'Bash', input: { command: 'pnpm test' } },
        ],
      },
    };
    const wire = messageToWire(raw);
    expect(wire.content[0]).toMatchObject({
      type: 'tool_use',
      id: 'toolu_1',
      name: 'Bash',
      native_type: 'tool_use',
    });
    expect(wire.content[0].raw_payload).toEqual(raw.message.content[0]);
  });
});
