import { query, type Options } from '@anthropic-ai/claude-agent-sdk';

import type { PermissionMode } from '@pawterm/shared';
import { type AskUserQuestionRegistry, makeAskUserMcpServer } from './ask-user-tool.js';

/**
 * One ClaudeSDK conversation. We use the SDK's streaming `query()` with an
 * input async generator so we can feed user messages over the lifetime of
 * a single WebSocket.
 */
export class ChatSession {
  readonly cwd: string;
  readonly permissionMode: PermissionMode;
  readonly resume?: string;
  readonly sessionId?: string;
  readonly model?: string;

  private inputResolver?: (msg: any) => void;
  private inputQueue: any[] = [];
  private finished = false;
  private iter?: AsyncGenerator<any>;
  private readonly askRegistry: AskUserQuestionRegistry;

  constructor(opts: {
    cwd: string;
    permissionMode: PermissionMode;
    resume?: string;
    sessionId?: string;
    model?: string;
    askRegistry: AskUserQuestionRegistry;
  }) {
    this.cwd = opts.cwd;
    this.permissionMode = opts.permissionMode;
    this.resume = opts.resume;
    this.sessionId = opts.sessionId;
    this.model = opts.model;
    this.askRegistry = opts.askRegistry;
  }

  /** Build the async iterator the SDK will read user messages from. */
  private inputGen = async function* (this: ChatSession): AsyncGenerator<any> {
    while (!this.finished) {
      if (this.inputQueue.length > 0) {
        yield this.inputQueue.shift();
        continue;
      }
      const next = await new Promise<any>((resolve) => {
        this.inputResolver = resolve;
      });
      this.inputResolver = undefined;
      if (next === null) return; // stop signal
      yield next;
    }
  };

  start(): AsyncIterableIterator<any> {
    // bypassPermissions 模式必须额外传 allowDangerouslySkipPermissions=true，
    // 否则 SDK 会拒绝启动。这个组合让 Claude 摆脱"只能读写 cwd 子树"的限制 ——
    // 它能访问整个服务端文件系统（场景：LAN/Tailscale 私有部署，用户操作的是
    // 自己拥有 shell 权限的机器，本来就该有全权访问）。
    const bypassing = this.permissionMode === 'bypassPermissions';
    const options: Options = {
      cwd: this.cwd,
      permissionMode: this.permissionMode,
      // Emit SDKPartialAssistantMessage events for char-level streaming.
      includePartialMessages: true,
      // Forward sub-agent (Task tool) text/tool messages with parent_tool_use_id set,
      // so the client can render a nested transcript inside the Task tool card.
      forwardSubagentText: true,
      mcpServers: {
        'ask-user-question': makeAskUserMcpServer(this.askRegistry),
      },
      // Native built-in AskUserQuestion path: checkPermissions returns behavior:'ask',
      // which triggers canUseTool. We suspend here (register 'native') and wait for
      // /chat/answer — same client flow as the MCP path, different internal resolver shape.
      canUseTool: async (toolName, _input, opts) => {
        if (toolName === 'AskUserQuestion') {
          return this.askRegistry.register('native', opts.toolUseID);
        }
        return { behavior: 'allow' as const };
      },
      ...(bypassing ? { allowDangerouslySkipPermissions: true } : {}),
      // resume takes priority; sessionId is for brand-new sessions only
      ...(this.resume
        ? { resume: this.resume }
        : this.sessionId
          ? { sessionId: this.sessionId }
          : {}),
      ...(this.model ? { model: this.model } : {}),
    };
    this.iter = query({ prompt: this.inputGen.call(this), options });
    return this.iter as unknown as AsyncIterableIterator<any>;
  }

  /** Runtime model switch — SDK supports this via setModel on the iterator. */
  async setModel(model: string): Promise<void> {
    const iter = this.iter as any;
    if (iter?.setModel) {
      await iter.setModel(model);
    }
  }

  /** Runtime permission-mode switch — SDK iterator has setPermissionMode. */
  async setPermissionMode(mode: PermissionMode): Promise<void> {
    const iter = this.iter as any;
    if (iter?.setPermissionMode) {
      await iter.setPermissionMode(mode);
    }
  }

  pushUserMessage(text: string): void {
    const msg = {
      type: 'user',
      message: { role: 'user', content: text },
      parent_tool_use_id: null,
      session_id: '',
    };
    if (this.inputResolver) {
      this.inputResolver(msg);
    } else {
      this.inputQueue.push(msg);
    }
  }

  /**
   * Called from the REST answer-question route. Resolves the pending
   * AskUserQuestion tool call so Claude can continue.
   */
  answerQuestion(
    toolUseId: string,
    answers: Record<string, string>,
    annotations?: Record<string, { preview?: string; notes?: string }>,
  ): boolean {
    // registry.answer() dispatches internally based on the hidden mode marker:
    // 'mcp'    → formats text, resolves CallToolResult
    // 'native' → resolves PermissionResult { behavior:'allow', updatedInput }
    return this.askRegistry.answer(toolUseId, answers, annotations);
  }

  async getContextUsage(): Promise<unknown> {
    const iter = this.iter as any;
    if (!iter?.getContextUsage) {
      throw new Error('getContextUsage not available — session not started');
    }
    return iter.getContextUsage();
  }

  async interrupt(): Promise<void> {
    if (this.iter && (this.iter as any).interrupt) {
      await (this.iter as any).interrupt();
    }
  }

  close(): void {
    this.finished = true;
    if (this.inputResolver) {
      this.inputResolver(null);
    }
  }
}
