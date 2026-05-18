import { create } from 'zustand';

import type { Project, SessionSummary } from '@pawterm/shared';

export type TabId = 'chat' | 'shell' | 'files' | 'git';

interface AppState {
  selectedProject: Project | null;
  currentSession: { cwd: string; resumeId?: string; label: string } | null;
  activeTab: TabId;

  selectProject: (p: Project) => void;
  startNewSession: (p: Project) => void;
  pickSession: (p: Project, s: SessionSummary) => void;
  clearSession: () => void;
  setTab: (id: TabId) => void;
}

export const useAppStore = create<AppState>((set) => ({
  selectedProject: null,
  currentSession: null,
  activeTab: 'chat',

  selectProject: (p) => set({ selectedProject: p }),
  startNewSession: (p) =>
    set({
      selectedProject: p,
      currentSession: { cwd: p.path, label: p.name },
    }),
  pickSession: (p, s) =>
    set({
      selectedProject: p,
      currentSession: {
        cwd: p.path,
        resumeId: s.session_id,
        label: `${p.name} · ${s.title ?? s.summary ?? '(Untitled)'}`,
      },
    }),
  clearSession: () => set({ currentSession: null }),
  setTab: (id) => set({ activeTab: id }),
}));
