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
});
