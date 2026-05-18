// ============================================================
// ask-user-tool.ts
// ============================================================
// AskUserQuestionRegistry — suspends an ask-question handler
// (either MCP or native canUseTool) until the client answers,
// then resolves with the appropriate result type.
//
// Two execution paths share this registry:
//
//   'mcp'    — Claude calls mcp__ask-user-question__AskUserQuestion.
//              The MCP handler suspends via register('mcp', toolUseId)
//              and expects a CallToolResult back.
//              chat-rest.ts pre-sets pendingToolUseId after broadcasting
//              the assistant message, before the MCP handler fires.
//
//   'native' — Claude calls the built-in AskUserQuestion tool.
//              The SDK's canUseTool callback suspends via
//              register('native', toolUseId) and expects a
//              PermissionResult { behavior:'allow', updatedInput } back.
//
// Both paths surface to the client through the same /chat/answer
// endpoint. The `mode` field on each pending entry is the internal
// marker that drives dispatch inside answer() — callers never see it.
// ============================================================

import { createSdkMcpServer, tool } from '@anthropic-ai/claude-agent-sdk';
import { z } from 'zod';

// Use the MCP SDK's CallToolResult type as imported by the agent SDK.
// Fallback local definition to avoid sub-path import brittleness:
type CallToolResult = { content: Array<{ type: 'text'; text: string }> };
type PermissionResult = { behavior: 'allow'; updatedInput: Record<string, unknown> };

type Rejecter = (err: Error) => void;

// The subtle mode marker: each pending entry knows which resolver shape to use.
type PendingEntry =
  | { mode: 'mcp';    resolve: (r: CallToolResult)   => void; reject: Rejecter; timer: ReturnType<typeof setTimeout> }
  | { mode: 'native'; resolve: (r: PermissionResult) => void; reject: Rejecter; timer: ReturnType<typeof setTimeout> };

const DEFAULT_TIMEOUT_MS = 30 * 60 * 1000;

export class AskUserQuestionRegistry {
  private pending = new Map<string, PendingEntry>();
  private readonly timeoutMs: number;

  /**
   * Set by consumeSdk() immediately after broadcasting an assistant message
   * that contains a `mcp__ask-user-question__AskUserQuestion` tool_use block.
   * The MCP handler reads and clears this before calling register().
   */
  pendingToolUseId: string | null = null;

  constructor(opts: { timeoutMs?: number } = {}) {
    this.timeoutMs = opts.timeoutMs ?? DEFAULT_TIMEOUT_MS;
  }

  /** MCP path: resolves with a text CallToolResult. */
  register(mode: 'mcp', toolUseId: string): Promise<CallToolResult>;
  /** Native canUseTool path: resolves with a PermissionResult. */
  register(mode: 'native', toolUseId: string): Promise<PermissionResult>;
  register(mode: 'mcp' | 'native', toolUseId: string): Promise<CallToolResult | PermissionResult> {
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        if (this.pending.has(toolUseId)) {
          this.pending.delete(toolUseId);
          reject(new Error('User did not answer within 30 minutes'));
        }
      }, this.timeoutMs);
      // Cast is safe: the overloads guarantee resolve type matches mode.
      this.pending.set(toolUseId, { mode, resolve, reject, timer } as PendingEntry);
    });
  }

  /**
   * Called by /chat/answer for both paths.
   * Dispatches based on the hidden `mode` marker — callers don't need to know.
   */
  answer(
    toolUseId: string,
    answers: Record<string, string>,
    annotations?: Record<string, { preview?: string; notes?: string }>,
  ): boolean {
    const entry = this.pending.get(toolUseId);
    if (!entry) return false;
    clearTimeout(entry.timer);
    this.pending.delete(toolUseId);

    if (entry.mode === 'mcp') {
      entry.resolve({ content: [{ type: 'text', text: formatAnswers(answers, annotations) }] });
    } else {
      // native: return structured updatedInput so the SDK passes it into call()
      entry.resolve({ behavior: 'allow', updatedInput: { answers, ...(annotations && { annotations }) } });
    }
    return true;
  }

  rejectAll(reason: string): void {
    for (const [, { reject, timer }] of this.pending) {
      clearTimeout(timer);
      reject(new Error(reason));
    }
    this.pending.clear();
  }
}

// ============================================================
// Zod schema for AskUserQuestion input
// ============================================================

const optionSchema = z.object({
  label: z.string().describe('The display text for this option that the user will see and select.'),
  description: z.string().describe('Explanation of what this option means.'),
  preview: z.string().optional().describe('Optional preview content rendered when this option is focused.'),
});

const questionSchema = z.object({
  question: z.string().describe('The complete question to ask the user. Should be clear, specific, and end with a question mark.'),
  header: z.string().describe('Very short label displayed as a chip/tag (max 12 chars).'),
  options: z.array(optionSchema).min(2).max(4).describe('The available choices for this question. Must have 2-4 options.'),
  multiSelect: z.boolean().default(false).describe('Set to true to allow the user to select multiple options.'),
});

const inputSchema = {
  questions: z.array(questionSchema).min(1).max(4).describe('Questions to ask the user (1-4 questions)'),
};

const TOOL_DESCRIPTION = `Use this tool when you need to ask the user questions during execution. This allows you to:
1. Gather user preferences or requirements
2. Clarify ambiguous instructions
3. Get decisions on implementation choices as you work
4. Offer choices to the user about what direction to take.

Usage notes:
- Users will always be able to select "Other" to provide custom text input
- Use multiSelect: true to allow multiple answers to be selected for a question
- If you recommend a specific option, make that the first option in the list and add "(Recommended)" at the end of the label
`;

// ============================================================
// MCP Server factory
// ============================================================

export function makeAskUserMcpServer(registry: AskUserQuestionRegistry) {
  return createSdkMcpServer({
    name: 'ask-user-question',
    tools: [
      tool(
        'AskUserQuestion',
        TOOL_DESCRIPTION,
        inputSchema,
        async (_input, _extra: unknown): Promise<CallToolResult> => {
          // The SDK's MCP extra is RequestHandlerExtra from the MCP SDK —
          // it has requestId and signal, but NOT the Anthropic tool_use_id.
          // chat-rest.ts sets registry.pendingToolUseId after broadcasting
          // the assistant SSE event and before this handler fires.
          const toolUseId = registry.pendingToolUseId;
          if (!toolUseId) {
            throw new Error(
              'AskUserQuestion called without a pre-notified tool_use_id — ' +
              'check consumeSdk in chat-rest.ts',
            );
          }
          registry.pendingToolUseId = null;
          return registry.register('mcp', toolUseId);
        },
      ),
    ],
  });
}

// ============================================================
// formatAnswers — converts client answers to the tool result
// string that gets passed back to Claude.
// ============================================================

export function formatAnswers(
  questionsAnswered: Record<string, string>,
  annotations?: Record<string, { preview?: string; notes?: string }>,
): string {
  const parts: string[] = [];
  for (const [question, answer] of Object.entries(questionsAnswered)) {
    const seg: string[] = [`Q: ${question}`, `A: ${answer}`];
    const ann = annotations?.[question];
    if (ann?.preview) seg.push(`selected preview:\n${ann.preview}`);
    if (ann?.notes) seg.push(`notes:\n${ann.notes}`);
    parts.push(seg.join('\n'));
  }
  return `User has answered your questions:\n\n${parts.join('\n\n')}\n\nYou can now continue with the user's answers in mind.`;
}
