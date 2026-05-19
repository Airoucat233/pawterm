import { EventEmitter } from 'node:events';
import type { AdminEvent } from '@pawterm/shared';

class AdminEventBus extends EventEmitter {
  emitEvent(event: AdminEvent): void {
    this.emit('admin_event', event);
  }

  subscribe(handler: (event: AdminEvent) => void): () => void {
    this.on('admin_event', handler);
    return () => {
      this.off('admin_event', handler);
    };
  }
}

export const adminEventBus = new AdminEventBus();
// Prevent Node.js MaxListenersExceededWarning for many SSE connections
adminEventBus.setMaxListeners(100);
