import { useEffect, useRef, useState } from 'react';

import type { ShellClientMessage, ShellServerMessage } from '@pawterm/shared';

interface UseShellOptions {
  cwd: string;
  cols: number;
  rows: number;
  enabled: boolean;
  onData: (data: string) => void;
  onExit?: (code: number) => void;
}

function wsUrl(path: string): string {
  const proto = location.protocol === 'https:' ? 'wss' : 'ws';
  return `${proto}://${location.host}${path}`;
}

export function useShellSocket({ cwd, cols, rows, enabled, onData, onExit }: UseShellOptions) {
  const [connected, setConnected] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const wsRef = useRef<WebSocket | null>(null);

  useEffect(() => {
    if (!enabled) return;
    setConnected(false);
    setError(null);

    const ws = new WebSocket(wsUrl('/ws/shell'));
    wsRef.current = ws;

    ws.onopen = () => {
      const init: ShellClientMessage = { type: 'init', cwd, cols, rows };
      ws.send(JSON.stringify(init));
    };

    ws.onmessage = (ev) => {
      let msg: ShellServerMessage;
      try {
        msg = JSON.parse(ev.data);
      } catch {
        return;
      }
      switch (msg.type) {
        case 'ready':
          setConnected(true);
          break;
        case 'output':
          onData(msg.data);
          break;
        case 'exit':
          onExit?.(msg.code);
          setConnected(false);
          break;
        case 'error':
          setError(msg.message);
          break;
      }
    };

    ws.onclose = () => setConnected(false);
    ws.onerror = () => setError('WebSocket error');

    return () => {
      ws.close();
      wsRef.current = null;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [cwd, enabled]);

  const sendInput = (data: string): void => {
    const msg: ShellClientMessage = { type: 'input', data };
    wsRef.current?.send(JSON.stringify(msg));
  };

  const resize = (newCols: number, newRows: number): void => {
    const msg: ShellClientMessage = { type: 'resize', cols: newCols, rows: newRows };
    wsRef.current?.send(JSON.stringify(msg));
  };

  const sendSignal = (signal: 'SIGINT' | 'SIGTERM' | 'SIGKILL'): void => {
    const msg: ShellClientMessage = { type: 'signal', signal };
    wsRef.current?.send(JSON.stringify(msg));
  };

  return { connected, error, sendInput, resize, sendSignal };
}
