import { createContext } from 'react';

export interface AskContextValue {
  submitAnswer: (
    toolUseId: string,
    answers: Record<string, string>,
    annotations?: Record<string, { preview?: string; notes?: string }>,
  ) => Promise<void>;
}

/** Provides submitAnswer to any ToolCard in the tree — set by ChatTab. */
export const AskContext = createContext<AskContextValue | null>(null);
