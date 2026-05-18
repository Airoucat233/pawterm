import { useEffect, useRef, useState, useCallback } from 'react';

import type { ChatClientMessage, ChatServerMessage, ContentBlock } from '@pawterm/shared';
import { api } from './rest';

export interface ChatTurn {
  kind: 'local-user' | 'assistant' | 'tool-result' | 'system-result' | 'error';
  payload: unknown;
  ts: number;
  id: string;
}

// Types for AskUserQuestion pending state
export interface AskOption {
  label: string;
  description: string;
  preview?: string;
}
export interface AskQuestion {
  question: string;
  header: string;
  options: AskOption[];
  multiSelect: boolean;
}
export interface PendingAsk {
  toolUseId: string;
  questions: AskQuestion[];
}

interface UseChatOptions {
  cwd: string;
  resumeId?: string;
  enabled: boolean;
}

interface UseChatReturn {
  messages: ChatTurn[];
  connected: boolean;
  busy: boolean;
  error: string | null;
  pendingAsk: PendingAsk | null;
  send: (text: string) => void;
  interrupt: () => void;
  clear: () => void;
  submitAnswer: (
    toolUseId: string,
    answers: Record<string, string>,
    annotations?: Record<string, { preview?: string; notes?: string }>,
  ) => Promise<void>;
}

// Tool names that trigger the AskUserQuestion flow (both paths)
const ASK_TOOL_NAMES = new Set(['AskUserQuestion', 'mcp__ask-user-question__AskUserQuestion']);

function wsUrl(path: string): string {
  const proto = location.protocol === 'https:' ? 'wss' : 'ws';
  return `${proto}://${location.host}${path}`;
}

export function useChatSocket({ cwd, resumeId, enabled }: UseChatOptions): UseChatReturn {
  const [messages, setMessages] = useState<ChatTurn[]>([]);
  const [connected, setConnected] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [pendingAsk, setPendingAsk] = useState<PendingAsk | null>(null);
  const sessionUuidRef = useRef<string | null>(null);
  const wsRef = useRef<WebSocket | null>(null);
  const sessionKey = `${cwd}|${resumeId ?? 'new'}`;

  const append = useCallback((turn: Omit<ChatTurn, 'id' | 'ts'>) => {
    setMessages((prev) => [
      ...prev,
      { ...turn, id: Math.random().toString(36).slice(2), ts: Date.now() },
    ]);
  }, []);

  useEffect(() => {
    if (!enabled) return;

    setMessages([]);
    setError(null);
    setBusy(false);
    setConnected(false);
    setPendingAsk(null);
    sessionUuidRef.current = null;

    const ws = new WebSocket(wsUrl('/ws/session'));
    wsRef.current = ws;

    ws.onopen = () => {
      const init: ChatClientMessage = {
        type: 'init',
        cwd,
        permission_mode: 'acceptEdits',
        ...(resumeId ? { resume: resumeId } : {}),
      };
      ws.send(JSON.stringify(init));
    };

    ws.onmessage = (ev) => {
      let msg: ChatServerMessage;
      try {
        msg = JSON.parse(ev.data);
      } catch {
        return;
      }
      switch (msg.type) {
        case 'session_ready':
          sessionUuidRef.current = msg.session_key;
          setConnected(true);
          break;
        case 'assistant': {
          // Detect AskUserQuestion tool_use — set pendingAsk to block the input
          const askBlock = (msg.content as ContentBlock[]).find(
            (b): b is Extract<ContentBlock, { type: 'tool_use' }> =>
              b.type === 'tool_use' && ASK_TOOL_NAMES.has(b.name),
          );
          if (askBlock) {
            setPendingAsk({
              toolUseId: askBlock.id,
              questions: ((askBlock.input as Record<string, unknown>).questions ?? []) as AskQuestion[],
            });
          }
          append({ kind: 'assistant', payload: msg });
          break;
        }
        case 'user': {
          // Clear pendingAsk when the tool_result for the ask arrives (Claude got the answer)
          const content = (msg as { content?: ContentBlock[] }).content ?? [];
          const answeredId = pendingAsk?.toolUseId;
          if (answeredId && content.some(b => b.type === 'tool_result' && b.tool_use_id === answeredId)) {
            setPendingAsk(null);
          }
          append({ kind: 'tool-result', payload: msg });
          break;
        }
        case 'result':
          setBusy(false);
          setPendingAsk(null); // safety: clear any stale ask on turn end
          append({ kind: 'system-result', payload: msg });
          break;
        case 'error':
          setError(msg.message);
          append({ kind: 'error', payload: msg });
          break;
        case 'pong':
        case 'system':
          break;
      }
    };

    ws.onerror = () => setError('WebSocket error');
    ws.onclose = () => {
      setConnected(false);
      setBusy(false);
      setPendingAsk(null);
    };

    return () => {
      ws.close();
      wsRef.current = null;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [sessionKey, enabled]);

  const send = useCallback(
    (text: string) => {
      if (!wsRef.current || !connected || busy) return;
      const t = text.trim();
      if (!t) return;
      append({ kind: 'local-user', payload: { text: t } });
      setBusy(true);
      const msg: ChatClientMessage = { type: 'user_message', text: t };
      wsRef.current.send(JSON.stringify(msg));
    },
    [connected, busy, append],
  );

  const interrupt = useCallback(() => {
    if (!wsRef.current || !busy) return;
    const msg: ChatClientMessage = { type: 'interrupt' };
    wsRef.current.send(JSON.stringify(msg));
  }, [busy]);

  const clear = useCallback(() => setMessages([]), []);

  const submitAnswer = useCallback(
    async (
      toolUseId: string,
      answers: Record<string, string>,
      annotations?: Record<string, { preview?: string; notes?: string }>,
    ) => {
      const uuid = sessionUuidRef.current;
      if (!uuid) throw new Error('No active session');
      await api.answerQuestion({ uuid, tool_use_id: toolUseId, answers, annotations });
      // pendingAsk will be cleared when the tool_result arrives via WebSocket,
      // but clear it optimistically here so the input unblocks immediately.
      setPendingAsk(null);
    },
    [],
  );

  return { messages, connected, busy, error, pendingAsk, send, interrupt, clear, submitAnswer };
}
