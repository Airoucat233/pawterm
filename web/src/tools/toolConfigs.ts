import {
  Code,
  Edit3,
  FileCode,
  FilePlus,
  FolderSearch,
  Globe,
  HelpCircle,
  ListChecks,
  Search,
  Sparkles,
  Terminal as TerminalIcon,
} from 'lucide-react';
import type { LucideIcon } from 'lucide-react';

export type ToolColorKey = 'edit' | 'bash' | 'read' | 'grep' | 'todo' | 'web' | 'task' | 'ask' | 'generic';

export const toolColor: Record<ToolColorKey, string> = {
  edit: '#10B981',
  bash: '#A78BFA',
  read: '#3B82F6',
  grep: '#06B6D4',
  todo: '#A78BFA',
  web: '#EAB308',
  task: '#F472B6',
  ask: '#F97316',
  generic: '#6B746F',
};

export interface ToolConfig {
  icon: LucideIcon;
  color: ToolColorKey;
  inputSummaryKey?: string; // which input field to show after the name (e.g. file_path)
  showBody: 'diff' | 'file' | 'bash' | 'kv' | 'todo' | 'ask' | 'none';
}

export const toolConfigs: Record<string, ToolConfig> = {
  Edit: { icon: Edit3, color: 'edit', inputSummaryKey: 'file_path', showBody: 'diff' },
  MultiEdit: { icon: Edit3, color: 'edit', inputSummaryKey: 'file_path', showBody: 'kv' },
  Write: { icon: FilePlus, color: 'edit', inputSummaryKey: 'file_path', showBody: 'file' },
  Read: { icon: FileCode, color: 'read', inputSummaryKey: 'file_path', showBody: 'none' },
  Bash: { icon: TerminalIcon, color: 'bash', inputSummaryKey: 'command', showBody: 'bash' },
  Grep: { icon: Search, color: 'grep', inputSummaryKey: 'pattern', showBody: 'kv' },
  Glob: { icon: FolderSearch, color: 'grep', inputSummaryKey: 'pattern', showBody: 'none' },
  TodoWrite: { icon: ListChecks, color: 'todo', showBody: 'todo' },
  WebFetch: { icon: Globe, color: 'web', inputSummaryKey: 'url', showBody: 'kv' },
  WebSearch: { icon: Globe, color: 'web', inputSummaryKey: 'query', showBody: 'kv' },
  Task: { icon: Sparkles, color: 'task', inputSummaryKey: 'description', showBody: 'kv' },
  // AskUserQuestion: two names, same config (MCP path has prefix, native path doesn't)
  AskUserQuestion: { icon: HelpCircle, color: 'ask', showBody: 'ask' },
  'mcp__ask-user-question__AskUserQuestion': { icon: HelpCircle, color: 'ask', showBody: 'ask' },
};

export function getToolConfig(name: string): ToolConfig {
  return (
    toolConfigs[name] ?? {
      icon: Code,
      color: 'generic',
      showBody: 'kv',
    }
  );
}
