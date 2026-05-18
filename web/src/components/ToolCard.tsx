import { useContext } from 'react';

import type { ContentBlock } from '@pawterm/shared';

import { AskContext } from '../api/askContext';
import type { AskQuestion } from '../api/wsChat';
import { getToolConfig, toolColor } from '../tools/toolConfigs';
import { DiffView } from './DiffView';

interface Props {
  block: Extract<ContentBlock, { type: 'tool_use' }>;
}

export function ToolCard({ block }: Props) {
  const cfg = getToolConfig(block.name);
  const Icon = cfg.icon;
  const color = toolColor[cfg.color];
  const input = block.input;

  const summary = cfg.inputSummaryKey ? String(input[cfg.inputSummaryKey] ?? '') : '';
  const shortSummary = summary.length > 80 ? `…${summary.slice(-80)}` : summary;

  return (
    // data-tool-use-id lets ChatTab find this element imperatively to trigger the shake animation
    <div
      data-tool-use-id={block.id}
      className="my-2 rounded-md bg-surface border border-border overflow-hidden"
      style={{ borderLeft: `3px solid ${color}` }}
    >
      <div className="flex items-center gap-2 px-3 py-2">
        <Icon size={14} style={{ color }} />
        <span className="text-[12px] font-semibold text-text">{block.name}</span>
        {shortSummary && (
          <span className="ml-1 font-mono text-[11px] text-muted truncate flex-1">{shortSummary}</span>
        )}
        {block.name === 'Edit' && <EditCounts input={input} />}
      </div>
      <div className="px-3 pb-3">{renderBody(cfg.showBody, input, block.id)}</div>
    </div>
  );
}

function EditCounts({ input }: { input: Record<string, unknown> }) {
  const oldStr = String(input.old_string ?? '');
  const newStr = String(input.new_string ?? '');
  const adds = newStr ? newStr.split('\n').length : 0;
  const dels = oldStr ? oldStr.split('\n').length : 0;
  return (
    <span className="ml-2 font-mono text-[10px] text-dim shrink-0">
      +{adds} −{dels}
    </span>
  );
}

function renderBody(
  kind: ReturnType<typeof getToolConfig>['showBody'],
  input: Record<string, unknown>,
  toolUseId: string,
) {
  if (kind === 'none') return null;

  if (kind === 'ask') {
    const questions = (input.questions ?? []) as AskQuestion[];
    return <AskBody toolUseId={toolUseId} questions={questions} />;
  }

  if (kind === 'diff') {
    return <DiffView oldString={String(input.old_string ?? '')} newString={String(input.new_string ?? '')} />;
  }

  if (kind === 'bash') {
    return (
      <pre className="rounded bg-bg border border-border/60 text-[11px] text-text font-mono p-2 m-0 whitespace-pre-wrap">
        $ {String(input.command ?? '')}
      </pre>
    );
  }

  if (kind === 'file') {
    const content = String(input.content ?? '');
    const truncated = content.length > 800 ? `${content.slice(0, 800)}\n…` : content;
    return (
      <pre className="rounded bg-bg border border-border/60 text-[11px] text-text font-mono p-2 m-0 max-h-80 overflow-auto whitespace-pre-wrap">
        {truncated}
      </pre>
    );
  }

  if (kind === 'todo') {
    const todos = input.todos as
      | Array<{ status?: string; content?: string; activeForm?: string }>
      | undefined;
    if (!todos?.length) return null;
    return (
      <ul className="space-y-1">
        {todos.map((t, i) => {
          const status = t.status ?? 'pending';
          const text = status === 'in_progress' && t.activeForm ? t.activeForm : t.content ?? '';
          const dot =
            status === 'completed' ? '✓' : status === 'in_progress' ? '◐' : '○';
          const dotColor =
            status === 'completed' ? 'text-emerald-400' : status === 'in_progress' ? 'text-accent' : 'text-dim';
          const lineThrough = status === 'completed' ? 'line-through opacity-60' : '';
          return (
            <li key={i} className="flex items-start gap-2 text-[12px]">
              <span className={dotColor}>{dot}</span>
              <span className={`text-text ${lineThrough}`}>{text}</span>
            </li>
          );
        })}
      </ul>
    );
  }

  // kv fallback
  return (
    <div className="space-y-0.5 font-mono text-[11px]">
      {Object.entries(input).map(([k, v]) => (
        <div key={k} className="text-text">
          <span className="text-muted">{k}: </span>
          {typeof v === 'string' ? v : JSON.stringify(v)}
        </div>
      ))}
    </div>
  );
}

// ─── AskUserQuestion card body ────────────────────────────────────────────────

function AskBody({ toolUseId, questions }: { toolUseId: string; questions: AskQuestion[] }) {
  const ctx = useContext(AskContext);

  const handleSelect = (question: string, label: string) => {
    ctx?.submitAnswer(toolUseId, { [question]: label });
  };

  if (!questions.length) return null;

  return (
    <div className="space-y-4 pt-1">
      {questions.map((q) => (
        <div key={q.question}>
          <p className="text-[13px] font-medium text-text mb-2">{q.question}</p>
          <div className="space-y-1.5">
            {q.options.map((opt) => (
              <button
                key={opt.label}
                onClick={() => handleSelect(q.question, opt.label)}
                disabled={!ctx}
                className="w-full text-left px-3 py-2 rounded-md border border-border bg-bg hover:border-accent hover:bg-accent/10 transition-colors disabled:opacity-40 disabled:cursor-not-allowed"
              >
                <span className="text-[12px] font-medium text-text block">{opt.label}</span>
                {opt.description && (
                  <span className="text-[11px] text-muted block mt-0.5">{opt.description}</span>
                )}
              </button>
            ))}
          </div>
        </div>
      ))}
    </div>
  );
}
