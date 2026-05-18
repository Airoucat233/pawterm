import { useEffect, useRef, useState, useCallback } from 'react';

import type { ChatClientMessage, ChatServerMessage } from '@pawterm/shared';

export interface ChatTurn {
  kind: 'local-user' | 'assistant' | 'tool-result' | 'system-result' | 'error';
  payload: unknown;
  ts: number;
  id: string;
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
  send: (text: string) => void;
  interrupt: () => void;
  clear: () => void;
}

function wsUrl(path: string): string {
  const proto = location.protocol === 'https:' ? 'wss' : 'ws';
  return `${proto}://${location.host}${path}`;
}

export function useChatSocket({ cwd, resumeId, enabled }: UseChatOptions): UseChatReturn {
  const [messages, setMessages] = useState<ChatTurn[]>([]);
  const [connected, setConnected] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
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
          setConnected(true);
          break;
        case 'assistant':
        case 'user':
          append({ kind: msg.type === 'assistant' ? 'assistant' : 'tool-result', payload: msg });
          break;
        case 'result':
          setBusy(false);
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

  return { messages, connected, busy, error, send, interrupt, clear };
}
