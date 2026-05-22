import type { ChatServerMessage, ContentBlock } from '@pawterm/shared';

type CodexItem = Record<string, any> & { type?: string; id?: string };

function safeInput(value: unknown): Record<string, unknown> {
  return value && typeof value === 'object' && !Array.isArray(value)
    ? value as Record<string, unknown>
    : {};
}

function toolUse(item: CodexItem, input: Record<string, unknown>): ContentBlock {
  const native = String(item.type ?? 'unknown');
  return {
    type: 'tool_use',
    id: String(item.id ?? native),
    name: native,
    input: safe(input) as Record<string, unknown>,
    native_type: native,
    native_event: undefined,
    raw_payload: safe(item),
  };
}

function toolResult(item: CodexItem, content: unknown, isError = false): ContentBlock {
  const native = String(item.type ?? 'unknown');
  return {
    type: 'tool_result',
    tool_use_id: String(item.id ?? native),
    content: content == null ? null : String(content),
    is_error: isError,
    native_type: native,
    native_event: undefined,
    raw_payload: safe(item),
  };
}

export function codexThreadItemToWire(item: CodexItem): ChatServerMessage | null {
  switch (item.type) {
    case 'userMessage':
      return {
        type: 'user',
        content: Array.isArray(item.content)
          ? item.content.map((c: any) => ({ type: 'text', text: String(c.text ?? c.content ?? '') }))
          : [],
      };
    case 'agentMessage':
      return { type: 'assistant', content: [{ type: 'text', text: String(item.text ?? '') }] };
    case 'reasoning':
      return {
        type: 'assistant',
        content: [{
          type: 'thinking',
          text: [...(item.summary ?? []), ...(item.content ?? [])].map(String).join('\n'),
        }],
      };
    case 'plan':
      return {
        type: 'assistant',
        content: [toolUse(item, { text: String(item.text ?? '') })],
      };
    case 'commandExecution':
      return {
        type: 'assistant',
        content: [
          toolUse(item, { command: item.command ?? '', cwd: item.cwd ?? '' }),
          toolResult(item, item.aggregatedOutput ?? '', item.exitCode != null && item.exitCode !== 0),
        ],
      };
    case 'fileChange':
      return {
        type: 'assistant',
        content: [
          toolUse(item, { changes: item.changes ?? [], status: item.status ?? null }),
          toolResult(item, safeStringify({ changes: item.changes ?? [], status: item.status ?? null }), false),
        ],
      };
    case 'mcpToolCall':
      return {
        type: 'assistant',
        content: [
          toolUse(item, safeInput({ server: item.server, tool: item.tool, arguments: item.arguments })),
          toolResult(item, item.error ? safeStringify(item.error) : safeStringify(item.result ?? null), !!item.error),
        ],
      };
    case 'dynamicToolCall':
      return {
        type: 'assistant',
        content: [
          toolUse(item, safeInput({ namespace: item.namespace, tool: item.tool, arguments: item.arguments })),
          toolResult(item, safeStringify(item.contentItems ?? null), item.success === false),
        ],
      };
    default:
      return null;
  }
}

function safeStringify(value: unknown): string {
  try {
    return JSON.stringify(value, null, 2);
  } catch {
    return String(value);
  }
}

function safe(value: unknown, seen = new WeakSet<object>()): unknown {
  if (value === null || value === undefined) return value;
  if (typeof value === 'string' || typeof value === 'number' || typeof value === 'boolean') return value;
  if (typeof value === 'object') {
    if (seen.has(value)) return String(value);
    seen.add(value);
  }
  if (Array.isArray(value)) return value.map((item) => safe(item, seen));
  if (typeof value === 'object') {
    const out: Record<string, unknown> = {};
    for (const [key, item] of Object.entries(value as Record<string, unknown>)) {
      out[key] = safe(item, seen);
    }
    return out;
  }
  return String(value);
}
