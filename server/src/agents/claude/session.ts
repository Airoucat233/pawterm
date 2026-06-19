import {
  query,
  type Options,
  type ThinkingConfig as SdkThinkingConfig,
} from '@anthropic-ai/claude-agent-sdk';

import type { PermissionMode, ThinkingConfig } from '@pawterm/shared';
import { buildAgentEnv } from '../../agent-env.js';
import { type AskUserQuestionRegistry, makeAskUserMcpServer } from '../../ask-user-tool.js';
import { ToolPermissionRegistry } from '../../tool-permission.js';

/** server 通过这个回调把"某工具正在等待审批"广播给客户端（chat-rest 注入）。 */
export interface ToolPermissionRequestEvent {
  request_id: string;
  tool_name: string;
  input: Record<string, unknown>;
  title?: string | null;
  display_name?: string | null;
  description?: string | null;
  reason_type?: string | null;
  safety_manual?: boolean;
}

/**
 * Wire 的 ThinkingConfig 用 snake_case（budget_tokens），SDK 期望 camelCase
 * （budgetTokens）。其他字段（type, display）两边一致，直接展开。
 */
function thinkingConfigToSdk(config: ThinkingConfig): SdkThinkingConfig {
  if (config.type === 'enabled') {
    return {
      type: 'enabled',
      ...(config.budget_tokens !== undefined ? { budgetTokens: config.budget_tokens } : {}),
      ...(config.display !== undefined ? { display: config.display } : {}),
    };
  }
  if (config.type === 'adaptive') {
    return {
      type: 'adaptive',
      ...(config.display !== undefined ? { display: config.display } : {}),
    };
  }
  return { type: 'disabled' };
}

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
  /**
   * 用户在 runtime 中显式设置的 thinking 配置。未指定时让 SDK 用默认行为
   * （Opus 4.6+ 默认 adaptive）。设置后会进入 SDK query options.thinking。
   */
  readonly thinking?: ThinkingConfig;

  private inputResolver?: (msg: any) => void;
  private inputQueue: any[] = [];
  private finished = false;
  private iter?: AsyncGenerator<any>;
  private readonly askRegistry: AskUserQuestionRegistry;
  private readonly toolPermissionRegistry: ToolPermissionRegistry;
  private readonly onToolPermissionRequest?: (req: ToolPermissionRequestEvent) => void;

  constructor(opts: {
    cwd: string;
    permissionMode: PermissionMode;
    resume?: string;
    sessionId?: string;
    model?: string;
    thinking?: ThinkingConfig;
    askRegistry: AskUserQuestionRegistry;
    onToolPermissionRequest?: (req: ToolPermissionRequestEvent) => void;
  }) {
    this.cwd = opts.cwd;
    this.permissionMode = opts.permissionMode;
    this.resume = opts.resume;
    this.sessionId = opts.sessionId;
    this.model = opts.model;
    this.thinking = opts.thinking;
    this.askRegistry = opts.askRegistry;
    this.toolPermissionRegistry = new ToolPermissionRegistry();
    this.onToolPermissionRequest = opts.onToolPermissionRequest;
  }

  /** 客户端经 /chat/tool-permission 回传决定，resolve 对应的 canUseTool。 */
  answerToolPermission(
    requestId: string,
    decision: 'allow' | 'deny',
    opts: { dontAskAgain?: boolean } = {},
  ): boolean {
    return this.toolPermissionRegistry.answer(requestId, decision, opts);
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
      env: buildAgentEnv(),
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
      //
      // 其他 tool 在 'ask' 路径下统一放行——我们的安全模型靠 cwd 白名单 +
      // permission_mode（acceptEdits / bypassPermissions）把控，到这一层就该信任。
      // PermissionResultAllow 强制要求 updatedInput 字段（Zod schema），缺了会
      // 抛 "expected record, received undefined" 让整个 session 挂掉。这里
      // 透传 input 不修改即可满足 schema。
      canUseTool: async (toolName, input, opts) => {
        if (toolName === 'AskUserQuestion') {
          return this.askRegistry.register('native', opts.toolUseID, input as Record<string, unknown>);
        }
        // 走到这里 = SDK 上游（permission_mode / allow-deny 规则 / 安全工具
        // 自动放行）没自动决定，需要用户拍板——对齐 Claude Code CLI 的交互审批。
        // bypassPermissions 模式下 SDK 根本不调 canUseTool，所以这里天然只在
        // default / acceptEdits / auto 等需要审批的模式触发。
        const o = opts as Record<string, unknown>;
        const toolUseId = opts.toolUseID;
        // 诊断日志：记录每次进入审批路径的工具 + 当前 mode + SDK 给的升级原因。
        // 方便核验"auto 模式下到底哪些工具会进 canUseTool"——若 auto 下普通工具
        // 也进，说明需要按 classifier_approvable 收口（只在 safety 升级时弹）。
        // 看日志：grep '\[canUseTool\]' ~/.config/pawterm/server.log（或测试服日志）。
        console.error('[canUseTool]', JSON.stringify({
          mode: this.permissionMode,
          tool: toolName,
          reason_type: (o.decision_reason_type as string) ?? null,
          classifier_approvable: (o.classifier_approvable as boolean) ?? null,
          blocked_path: (o.blockedPath as string) ?? null,
        }));
        this.onToolPermissionRequest?.({
          request_id: toolUseId,
          tool_name: toolName,
          input: input as Record<string, unknown>,
          title: (o.title as string) ?? null,
          display_name: (o.displayName as string) ?? null,
          description: (o.description as string) ?? null,
          reason_type: (o.decision_reason_type as string) ?? null,
          safety_manual: o.classifier_approvable === false,
        });
        return this.toolPermissionRegistry.register(
          toolUseId,
          input as Record<string, unknown>,
          toolName,
        );
      },
      ...(bypassing ? { allowDangerouslySkipPermissions: true } : {}),
      // resume takes priority; sessionId is for brand-new sessions only
      ...(this.resume
        ? { resume: this.resume }
        : this.sessionId
          ? { sessionId: this.sessionId }
          : {}),
      ...(this.model ? { model: this.model } : {}),
      // ThinkingConfig wire 字段命名是 snake_case（budget_tokens），SDK 期望
      // camelCase（budgetTokens）；这里做一次转换。
      ...(this.thinking ? { thinking: thinkingConfigToSdk(this.thinking) } : {}),
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
    // 把挂起的工具审批按拒绝 resolve，避免 SDK / Promise 泄漏。
    this.toolPermissionRegistry.rejectAll('session closed');
    if (this.inputResolver) {
      this.inputResolver(null);
    }
  }
}
