import type { ContentBlock } from '@pawterm/shared';

/**
 * Convert raw SDK messages (from @anthropic-ai/claude-agent-sdk) to wire dicts.
 *
 * The SDK emits objects whose `type` field already matches our protocol;
 * here we just normalize block shapes and prune internal fields.
 */

export function messageToWire(msg: any): any | null {
  if (!msg || typeof msg !== 'object') return null;

  const type = msg.type;

  switch (type) {
    case 'system':
      // compact_boundary 是会话被自动/手动压缩的边界标记，
      // jsonl 里独立存为 { type:'system', subtype:'compact_boundary', compactMetadata: {...} }。
      // 客户端按这个画一条分隔线，提示用户"前面消息已被压缩"。
      //
      // 注：截至 claude-agent-sdk 当前版本，getSessionMessages 会**直接吞掉**
      // compact_boundary 之前的所有消息并过滤掉 boundary 本身，因此这条分支
      // 在历史回放时永远命中不到。保留代码是为了：
      //   1) SDK 哪天暴露元事件时自动接上；
      //   2) 实时流（用户在会话中触发 /compact）若 SDK 转发，也能渲染。
      // 要真正显示分隔线，需要服务端绕过 SDK 直接读 jsonl，目前不做。
      if (msg.subtype === 'compact_boundary') {
        const meta = (msg.compactMetadata ?? {}) as {
          trigger?: string;
          preTokens?: number;
          postTokens?: number;
          durationMs?: number;
        };
        return {
          type: 'compact_boundary',
          trigger: meta.trigger ?? null,
          pre_tokens: meta.preTokens ?? null,
          post_tokens: meta.postTokens ?? null,
          duration_ms: meta.durationMs ?? null,
        };
      }
      return {
        type: 'system',
        subtype: msg.subtype ?? null,
        data: safe(msg.data),
      };

    case 'assistant':
      return {
        type: 'assistant',
        model: msg.message?.model ?? msg.model,
        content: extractContent(msg.message?.content ?? msg.content),
        parent_tool_use_id: msg.parent_tool_use_id ?? null,
      };

    case 'user':
      return {
        type: 'user',
        content: extractContent(msg.message?.content ?? msg.content ?? []),
        parent_tool_use_id: msg.parent_tool_use_id ?? null,
      };

    case 'result':
      return {
        type: 'result',
        subtype: msg.subtype,
        duration_ms: msg.duration_ms,
        duration_api_ms: msg.duration_api_ms,
        is_error: !!msg.is_error,
        num_turns: msg.num_turns,
        session_id: msg.session_id,
        total_cost_usd: msg.total_cost_usd,
        usage: safe(msg.usage),
      };

    case 'stream_event': {
      // Partial assistant stream: forward only useful text deltas to keep client cheap.
      const ev = msg.event;
      if (!ev) return null;
      // Anthropic stream event types: message_start | content_block_start | content_block_delta | content_block_stop | message_delta | message_stop
      if (ev.type === 'content_block_delta') {
        const delta = ev.delta;
        if (delta?.type === 'text_delta' && typeof delta.text === 'string') {
          return {
            type: 'stream_delta',
            index: ev.index,
            kind: 'text',
            text: delta.text,
            parent_tool_use_id: msg.parent_tool_use_id ?? null,
          };
        }
        if (delta?.type === 'thinking_delta' && typeof delta.thinking === 'string') {
          return {
            type: 'stream_delta',
            index: ev.index,
            kind: 'thinking',
            text: delta.thinking,
            parent_tool_use_id: msg.parent_tool_use_id ?? null,
          };
        }
      }
      if (ev.type === 'content_block_start') {
        return {
          type: 'stream_block_start',
          index: ev.index,
          kind: ev.content_block?.type ?? 'unknown',
          parent_tool_use_id: msg.parent_tool_use_id ?? null,
        };
      }
      if (ev.type === 'content_block_stop') {
        return {
          type: 'stream_block_stop',
          index: ev.index,
          parent_tool_use_id: msg.parent_tool_use_id ?? null,
        };
      }
      return null;
    }

    default:
      return null;
  }
}

function extractContent(content: unknown): ContentBlock[] {
  if (!content) return [];
  if (typeof content === 'string') return [{ type: 'text', text: content }];
  if (!Array.isArray(content)) return [];

  return content
    .map((b: any): ContentBlock | null => {
      if (!b || typeof b !== 'object') return null;
      switch (b.type) {
        case 'text':
          return { type: 'text', text: String(b.text ?? '') };
        case 'thinking':
          return { type: 'thinking', text: String(b.thinking ?? b.text ?? '') };
        case 'tool_use':
          return {
            type: 'tool_use',
            id: String(b.id ?? ''),
            name: String(b.name ?? ''),
            input: typeof b.input === 'object' && b.input !== null ? b.input : {},
          };
        case 'tool_result':
          return {
            type: 'tool_result',
            tool_use_id: String(b.tool_use_id ?? ''),
            content: normalizeToolResultContent(b.content),
            is_error: !!b.is_error,
          };
        default:
          return null;
      }
    })
    .filter((b): b is ContentBlock => b !== null);
}

/**
 * JSON.stringify with circular-reference safety. Falls back to String(v)
 * rather than throwing — protects the wire pipeline from malformed tool
 * outputs (e.g. graph data, debug dumps with parent pointers).
 */
function safeStringify(v: unknown): string {
  try {
    return JSON.stringify(v, null, 2);
  } catch {
    // Fallback for circular refs or other non-serializable values.
    return String(v);
  }
}

function normalizeToolResultContent(content: unknown): any {
  if (content == null) return null;
  if (typeof content === 'string') return content;
  if (Array.isArray(content)) {
    return content.map((item: any) => {
      if (item && typeof item === 'object' && item.type === 'image') {
        // Preserve image blocks as-is — they have base64 source we shouldn't stringify.
        return item;
      }
      if (item && typeof item === 'object' && 'text' in item) {
        const t = item.text;
        const text = typeof t === 'string' ? t : safeStringify(t);
        return { type: 'text', text };
      }
      // Anything else (including raw JSON objects from MCP tools): stringify whole item.
      return { type: 'text', text: safeStringify(item) };
    });
  }
  if (typeof content === 'object') {
    return safeStringify(content);
  }
  return String(content);
}

function safe(v: unknown): unknown {
  if (v === null || v === undefined) return v;
  if (typeof v === 'string' || typeof v === 'number' || typeof v === 'boolean') return v;
  if (Array.isArray(v)) return v.map(safe);
  if (typeof v === 'object') {
    const out: Record<string, unknown> = {};
    for (const [k, val] of Object.entries(v as Record<string, unknown>)) {
      out[k] = safe(val);
    }
    return out;
  }
  return String(v);
}
