import { resolve } from 'node:path';

import type { WebSocket } from '@fastify/websocket';
import type { FastifyRequest } from 'fastify';

import type { ChatClientMessage, ChatServerMessage } from '@cc/shared';

import { isPathAllowed, settings } from './config.js';
import { messageToWire } from './serialize.js';
import { ChatSession } from './session-manager.js';

export function handleChatSocket(socket: WebSocket, _req: FastifyRequest): void {
  let session: ChatSession | null = null;
  let busy = false;

  function send(payload: ChatServerMessage): void {
    if (socket.readyState !== 1) return;
    socket.send(JSON.stringify(payload));
  }

  async function streamResponses(iter: AsyncIterableIterator<any>): Promise<void> {
    try {
      for await (const sdkMsg of iter) {
        const wire = messageToWire(sdkMsg);
        if (wire) {
          // Tag live messages with server-side wall-clock for accurate display.
          const stamped = { ...wire, timestamp: Date.now() } as ChatServerMessage;
          send(stamped);
          if ((wire as any).type === 'result') busy = false;
        }
      }
    } catch (err) {
      send({ type: 'error', message: `stream error: ${(err as Error).message}` });
      busy = false;
    }
  }

  socket.on('message', (raw: Buffer | string) => {
    let msg: ChatClientMessage;
    try {
      msg = JSON.parse(raw.toString()) as ChatClientMessage;
    } catch {
      send({ type: 'error', message: 'Invalid JSON' });
      return;
    }

    switch (msg.type) {
      case 'init': {
        const cwd = resolve(msg.cwd);
        if (!isPathAllowed(cwd)) {
          send({ type: 'error', message: `Project not allowed: ${cwd}` });
          return;
        }
        const permissionMode = msg.permission_mode ?? settings.permissionMode;
        try {
          session?.close();
          session = new ChatSession({ cwd, permissionMode, resume: msg.resume, model: msg.model });
          const iter = session.start();
          send({
            type: 'session_ready',
            session_key: cryptoRandomId(),
            cwd,
            permission_mode: permissionMode,
            resumed: msg.resume ?? null,
          });
          // Start consuming SDK output in background.
          streamResponses(iter).catch((err) => {
            send({ type: 'error', message: `iterator failed: ${(err as Error).message}` });
          });
        } catch (err) {
          send({ type: 'error', message: `Failed to start session: ${(err as Error).message}` });
        }
        break;
      }

      case 'user_message': {
        if (!session) {
          send({ type: 'error', message: 'Session not initialized' });
          return;
        }
        if (busy) {
          send({ type: 'error', message: 'Previous turn still streaming' });
          return;
        }
        busy = true;
        session.pushUserMessage(msg.text);
        break;
      }

      case 'set_model': {
        session?.setModel(msg.model).catch((err) => {
          send({ type: 'error', message: `setModel failed: ${(err as Error).message}` });
        });
        break;
      }

      case 'set_permission_mode': {
        session?.setPermissionMode(msg.mode).catch((err) => {
          send({ type: 'error', message: `setPermissionMode failed: ${(err as Error).message}` });
        });
        break;
      }

      case 'interrupt': {
        session?.interrupt().catch(() => {});
        break;
      }

      case 'ping': {
        send({ type: 'pong' });
        break;
      }
    }
  });

  socket.on('close', () => {
    session?.close();
    session = null;
  });

  socket.on('error', () => {
    session?.close();
    session = null;
  });
}

function cryptoRandomId(): string {
  return Math.random().toString(36).slice(2) + Date.now().toString(36);
}
