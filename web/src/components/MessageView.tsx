import ReactMarkdown from 'react-markdown';
import remarkGfm from 'remark-gfm';

import type { ContentBlock } from '@pawterm/shared';

import { ToolCard } from './ToolCard';

interface AssistantPayload {
  type: 'assistant';
  model?: string;
  content: ContentBlock[];
}

interface UserPayload {
  type: 'user';
  content: ContentBlock[];
}

interface ResultPayload {
  type: 'result';
  duration_ms?: number;
  total_cost_usd?: number;
  num_turns?: number;
}

interface ErrorPayload {
  message: string;
}

export function AssistantMessage({ payload }: { payload: AssistantPayload }) {
  return (
    <article className="mb-6">
      <div className="flex items-center gap-2 mb-2">
        <span className="text-[10px] font-semibold tracking-widest text-accent">CLAUDE</span>
        {payload.model && (
          <span className="text-[10px] font-mono text-dim">{payload.model}</span>
        )}
      </div>
      <div className="space-y-2">
        {payload.content.map((b, i) => (
          <BlockRenderer key={i} block={b} />
        ))}
      </div>
    </article>
  );
}

export function UserToolResults({ payload }: { payload: UserPayload }) {
  // User messages from server contain only tool_result blocks (echoed by SDK).
  return (
    <div className="-mt-3 mb-4 space-y-1">
      {payload.content
        .filter((b): b is Extract<ContentBlock, { type: 'tool_result' }> => b.type === 'tool_result')
        .map((b, i) => (
          <ToolResultBlock key={i} block={b} />
        ))}
    </div>
  );
}

export function LocalUserMessage({ text }: { text: string }) {
  return (
    <article className="mb-6">
      <div className="flex items-center gap-2 mb-2">
        <span className="text-[10px] font-semibold tracking-widest text-muted">YOU</span>
      </div>
      <div className="text-[14px] text-text whitespace-pre-wrap leading-relaxed">{text}</div>
    </article>
  );
}

export function ResultLine({ payload }: { payload: ResultPayload }) {
  const dur = payload.duration_ms ? `${(payload.duration_ms / 1000).toFixed(1)}s` : '-';
  const cost = payload.total_cost_usd ? `$${payload.total_cost_usd.toFixed(4)}` : '-';
  const turns = payload.num_turns ?? '-';
  return (
    <div className="mb-6 text-[10px] font-mono text-dim flex items-center gap-2">
      <span>{cost}</span>
      <span className="text-border">·</span>
      <span>{dur}</span>
      <span className="text-border">·</span>
      <span>turn {turns}</span>
    </div>
  );
}

export function ErrorLine({ payload }: { payload: ErrorPayload }) {
  return (
    <div className="mb-4 px-3 py-2 rounded bg-red-500/10 border border-red-500/40 text-red-300 text-[12px] flex items-start gap-2">
      <span className="font-semibold">Error:</span>
      <span>{payload.message}</span>
    </div>
  );
}

function BlockRenderer({ block }: { block: ContentBlock }) {
  switch (block.type) {
    case 'text':
      return (
        <div className="prose prose-invert prose-sm max-w-none text-[14px] leading-relaxed [&_p]:my-2 [&_ul]:my-2 [&_ol]:my-2 [&_pre]:bg-bg [&_pre]:border [&_pre]:border-border [&_code]:text-accent [&_code]:bg-surfaceHi [&_code]:px-1 [&_code]:py-0.5 [&_code]:rounded">
          <ReactMarkdown remarkPlugins={[remarkGfm]}>{block.text}</ReactMarkdown>
        </div>
      );
    case 'thinking':
      return (
        <div className="border-l-2 border-dim/40 pl-3 text-[12px] italic text-muted whitespace-pre-wrap">
          {block.text}
        </div>
      );
    case 'tool_use':
      return <ToolCard block={block} />;
    case 'tool_result':
      return <ToolResultBlock block={block} />;
  }
}

function ToolResultBlock({ block }: { block: Extract<ContentBlock, { type: 'tool_result' }> }) {
  const text = extractText(block.content);
  const truncated = text.length > 400 ? `${text.slice(0, 400)}\n…` : text;
  return (
    <pre
      className={`m-0 px-3 py-2 border-l-2 text-[11px] font-mono whitespace-pre-wrap ${
        block.is_error ? 'border-red-500/60 text-red-300' : 'border-border text-muted'
      }`}
    >
      {truncated}
    </pre>
  );
}

function extractText(content: unknown): string {
  if (!content) return '';
  if (typeof content === 'string') return content;
  if (Array.isArray(content)) {
    return content
      .map((b) => (b && typeof b === 'object' && 'text' in b ? String((b as { text: unknown }).text) : String(b)))
      .join('\n');
  }
  return String(content);
}
