import { useQuery } from '@tanstack/react-query';
import { Bot, ChevronDown, ChevronRight, Folder, FolderOpen, Plus, RefreshCw } from 'lucide-react';
import { useState } from 'react';

import type { Project, SessionSummary } from '@pawterm/shared';

import { api } from '../api/rest';
import { useAppStore } from '../state/store';

function shortPath(p: string): string {
  const home = p.replace(/^\/Users\/[^/]+/, '~');
  return home.length <= 32 ? home : `${home.slice(0, 14)}…${home.slice(-15)}`;
}

export function Sidebar() {
  const health = useQuery({ queryKey: ['health'], queryFn: api.health, refetchInterval: 5000 });
  const projects = useQuery({ queryKey: ['projects'], queryFn: api.projects });
  const [expanded, setExpanded] = useState<Set<string>>(new Set());
  const currentSession = useAppStore((s) => s.currentSession);
  const startNewSession = useAppStore((s) => s.startNewSession);
  const pickSession = useAppStore((s) => s.pickSession);

  return (
    <aside className="w-72 shrink-0 border-r border-border bg-surface flex flex-col">
      <header className="px-4 py-3 flex items-center gap-3">
        <div className="w-9 h-9 rounded-lg border border-accent bg-accent/10 grid place-items-center">
          <Bot size={18} className="text-accent" />
        </div>
        <div className="min-w-0">
          <div className="text-[14px] font-semibold leading-tight">Claude Companion</div>
          <div className="text-[10px] text-dim font-mono leading-tight">
            {health.data ? `server v${health.data.version}` : 'connecting…'}
          </div>
        </div>
      </header>

      <div className="border-t border-border" />

      <div className="px-4 py-2 flex items-center justify-between">
        <span className="text-[10px] uppercase tracking-wider text-muted font-semibold">Projects</span>
        <button
          onClick={() => projects.refetch()}
          className="text-muted hover:text-text p-1 rounded"
          title="刷新"
        >
          <RefreshCw size={12} />
        </button>
      </div>

      <div className="flex-1 overflow-y-auto pb-3">
        {projects.isLoading && <div className="px-4 py-2 text-xs text-muted">载入中…</div>}
        {projects.error && (
          <div className="px-4 py-2 text-xs text-red-400">{(projects.error as Error).message}</div>
        )}
        {projects.data?.map((p) => (
          <ProjectNode
            key={p.path}
            project={p}
            expanded={expanded.has(p.path)}
            isCurrent={currentSession?.cwd === p.path}
            currentSessionId={currentSession?.resumeId}
            onToggle={() => {
              setExpanded((prev) => {
                const next = new Set(prev);
                if (next.has(p.path)) next.delete(p.path);
                else next.add(p.path);
                return next;
              });
            }}
            onNew={() => startNewSession(p)}
            onPickSession={(s) => pickSession(p, s)}
          />
        ))}
      </div>
    </aside>
  );
}

interface NodeProps {
  project: Project;
  expanded: boolean;
  isCurrent: boolean;
  currentSessionId?: string;
  onToggle: () => void;
  onNew: () => void;
  onPickSession: (s: SessionSummary) => void;
}

function ProjectNode({
  project,
  expanded,
  isCurrent,
  currentSessionId,
  onToggle,
  onNew,
  onPickSession,
}: NodeProps) {
  return (
    <div>
      <button
        onClick={onToggle}
        className="w-full text-left px-3 py-2 hover:bg-surfaceHi flex items-center gap-2"
      >
        {expanded ? (
          <FolderOpen size={14} className={isCurrent ? 'text-accent' : 'text-muted'} />
        ) : (
          <Folder size={14} className={isCurrent ? 'text-accent' : 'text-muted'} />
        )}
        <div className="min-w-0 flex-1">
          <div
            className={`text-[13px] truncate ${
              isCurrent ? 'text-accent font-semibold' : 'text-text font-medium'
            }`}
          >
            {project.name}
          </div>
          <div className="text-[10px] text-dim font-mono truncate">{shortPath(project.path)}</div>
        </div>
        {expanded ? (
          <ChevronDown size={14} className="text-muted" />
        ) : (
          <ChevronRight size={14} className="text-muted" />
        )}
      </button>
      {expanded && <SessionsList project={project} currentSessionId={currentSessionId} onNew={onNew} onPick={onPickSession} />}
    </div>
  );
}

interface ListProps {
  project: Project;
  currentSessionId?: string;
  onNew: () => void;
  onPick: (s: SessionSummary) => void;
}

function SessionsList({ project, currentSessionId, onNew, onPick }: ListProps) {
  const q = useQuery({
    queryKey: ['sessions', project.path],
    queryFn: () => api.listSessions(project.path),
  });

  return (
    <div className="pl-6 pr-2 pb-2">
      <button
        onClick={onNew}
        className="w-full mb-1 flex items-center gap-2 px-2 py-1.5 rounded text-[12px] text-accent bg-accent/10 hover:bg-accent/20"
      >
        <Plus size={12} />
        <span>新对话</span>
      </button>

      {q.isLoading && <div className="px-2 py-1 text-[11px] text-dim">载入中…</div>}
      {q.error && <div className="px-2 py-1 text-[11px] text-red-400">{(q.error as Error).message}</div>}
      {q.data?.length === 0 && <div className="px-2 py-1 text-[11px] text-dim">暂无历史 session</div>}
      {q.data?.map((s) => (
        <SessionTile key={s.session_id} session={s} isCurrent={s.session_id === currentSessionId} onClick={() => onPick(s)} />
      ))}
    </div>
  );
}

function SessionTile({
  session,
  isCurrent,
  onClick,
}: {
  session: SessionSummary;
  isCurrent: boolean;
  onClick: () => void;
}) {
  const title = session.title ?? session.summary ?? '(Untitled)';
  const time = session.last_modified
    ? new Date(session.last_modified).toLocaleString(undefined, {
        month: '2-digit',
        day: '2-digit',
        hour: '2-digit',
        minute: '2-digit',
      })
    : '';
  return (
    <button
      onClick={onClick}
      className={`group w-full flex items-stretch gap-2 px-1.5 py-1.5 rounded mb-0.5 text-left ${
        isCurrent ? 'bg-accent/15' : 'hover:bg-surfaceHi'
      }`}
    >
      <div
        className={`w-[3px] rounded-full ${isCurrent ? 'bg-accent' : 'bg-border'}`}
        style={{ minHeight: 26 }}
      />
      <div className="min-w-0 flex-1">
        <div className={`text-[12px] truncate ${isCurrent ? 'text-accent font-semibold' : 'text-text'}`}>
          {title}
        </div>
        {time && <div className="text-[10px] text-dim font-mono mt-0.5">{time}</div>}
      </div>
    </button>
  );
}
