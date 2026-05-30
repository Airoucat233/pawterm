import type { AgentInfo, AgentKind } from '@pawterm/shared';
import { ClaudeAgentProvider } from './claude/provider.js';
import { CodexAgentProvider } from './codex/provider.js';
import type { AgentProvider } from './types.js';
import { UnknownAgentError } from './types.js';

export class AgentRegistry {
  private readonly providers = new Map<AgentKind, AgentProvider>();

  constructor(providers: AgentProvider[]) {
    for (const provider of providers) {
      this.providers.set(provider.kind, provider);
    }
  }

  resolve(agent: string | undefined | null): AgentProvider {
    const key = (agent ?? 'claude') as AgentKind;
    const provider = this.providers.get(key);
    if (!provider) throw new UnknownAgentError(String(agent));
    return provider;
  }

  async listInfos(): Promise<AgentInfo[]> {
    const infos: AgentInfo[] = [];
    for (const provider of this.providers.values()) {
      infos.push(await provider.getInfo());
    }
    return infos;
  }
}

export const defaultAgentRegistry = new AgentRegistry([
  new ClaudeAgentProvider({
    sessionHolderFor: async () => {
      const [{ findAllHolders }, { getActiveRunHolder }] = await Promise.all([
        import('../holder-detect.js'),
        import('../chat-rest.js'),
      ]);
      const allHolders = await findAllHolders();
      return (sessionId) => {
        const activeHolder = getActiveRunHolder(sessionId);
        if (activeHolder) return activeHolder;
        if (allHolders.has(sessionId)) return 'server';
        return null;
      };
    },
  }),
  new CodexAgentProvider(),
]);
