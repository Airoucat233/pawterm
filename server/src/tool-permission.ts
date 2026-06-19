// ============================================================
// tool-permission.ts
// ToolPermissionRegistry —— 挂起 Claude 的 canUseTool 回调，直到客户端通过
// /chat/tool-permission 给出 allow / deny 决定，再 resolve 成 SDK 期望的
// PermissionResult。对齐 Claude Code CLI 的交互审批：SDK 上游已按 mode/规则
// 过滤，调到 canUseTool 就代表"需要用户拍板"。
// ============================================================

export type SdkPermissionResult =
  | { behavior: 'allow'; updatedInput: Record<string, unknown>; updatedPermissions?: unknown[] }
  | { behavior: 'deny'; message: string };

type Pending = {
  resolve: (r: SdkPermissionResult) => void;
  timer: ReturnType<typeof setTimeout>;
  originalInput: Record<string, unknown>;
  toolName: string;
};

const DEFAULT_TIMEOUT_MS = 30 * 60 * 1000;

export class ToolPermissionRegistry {
  private pending = new Map<string, Pending>();
  private readonly timeoutMs: number;

  constructor(opts: { timeoutMs?: number } = {}) {
    this.timeoutMs = opts.timeoutMs ?? DEFAULT_TIMEOUT_MS;
  }

  /** 挂起一个工具审批；canUseTool await 这个 Promise，直到 answer() 被调用。 */
  register(
    toolUseId: string,
    originalInput: Record<string, unknown>,
    toolName: string,
  ): Promise<SdkPermissionResult> {
    return new Promise((resolve) => {
      const timer = setTimeout(() => {
        if (this.pending.delete(toolUseId)) {
          // 超时按拒绝，避免无限挂起 SDK。
          resolve({ behavior: 'deny', message: 'Permission request timed out (no answer in 30 minutes)' });
        }
      }, this.timeoutMs);
      this.pending.set(toolUseId, { resolve, timer, originalInput, toolName });
    });
  }

  /** 客户端给出决定，resolve 对应的 canUseTool。未知 id 返回 false。 */
  answer(
    toolUseId: string,
    decision: 'allow' | 'deny',
    opts: { dontAskAgain?: boolean } = {},
  ): boolean {
    const entry = this.pending.get(toolUseId);
    if (!entry) return false;
    clearTimeout(entry.timer);
    this.pending.delete(toolUseId);
    if (decision === 'deny') {
      entry.resolve({ behavior: 'deny', message: 'Tool call denied by user' });
      return true;
    }
    const result: SdkPermissionResult = {
      behavior: 'allow',
      updatedInput: entry.originalInput,
    };
    if (opts.dontAskAgain) {
      // CLI 的 "Yes, and don't ask again"：给本 session 加一条 allow 规则，
      // 之后同名工具不再询问。结构以 SDK PermissionUpdate 为准；若不被接受，
      // 退化为不带规则的纯 allow（功能不丢，只是每次都问）。
      result.updatedPermissions = [
        {
          type: 'addRules',
          rules: [{ toolName: entry.toolName }],
          behavior: 'allow',
          destination: 'session',
        },
      ];
    }
    entry.resolve(result);
    return true;
  }

  /** 会话结束/中断时调用：把所有挂起的审批按拒绝 resolve，避免泄漏。 */
  rejectAll(reason: string): void {
    for (const [, p] of this.pending) {
      clearTimeout(p.timer);
      p.resolve({ behavior: 'deny', message: reason });
    }
    this.pending.clear();
  }
}
