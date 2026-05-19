/**
 * Admin panel Zustand store — token auth + SSE event queue
 */
import { create } from 'zustand';
import { persist } from 'zustand/middleware';
import type { AdminEvent, PairedDevice } from '@pawterm/shared';

export interface PairRequestItem {
  requestId: string;
  deviceId: string;
  deviceName: string;
  ip: string;
  createdAt: number;
}

interface AdminState {
  // Auth
  token: string | null;
  setToken: (t: string) => void;
  clearToken: () => void;

  // Server health
  serverOnline: boolean;
  serverId: string | null;
  hostname: string | null;
  port: number | null;
  setHealth: (h: { online: boolean; serverId?: string; hostname?: string; port?: number }) => void;

  // Devices
  devices: PairedDevice[];
  setDevices: (d: PairedDevice[]) => void;
  removeDevice: (deviceId: string) => void;

  // Pair request queue
  pairQueue: PairRequestItem[];
  enqueuePairRequest: (r: PairRequestItem) => void;
  dequeuePairRequest: () => void;

  // Event log
  events: Array<{ id: string; event: AdminEvent; receivedAt: number }>;
  pushEvent: (e: AdminEvent) => void;
}

let _eventSeq = 0;

export const useAdminStore = create<AdminState>()(
  persist(
    (set, get) => ({
      token: null,
      setToken: (t) => set({ token: t }),
      clearToken: () => set({ token: null }),

      serverOnline: false,
      serverId: null,
      hostname: null,
      port: null,
      setHealth: (h) =>
        set({
          serverOnline: h.online,
          serverId: h.serverId ?? get().serverId,
          hostname: h.hostname ?? get().hostname,
          port: h.port ?? get().port,
        }),

      devices: [],
      setDevices: (d) => set({ devices: d }),
      removeDevice: (deviceId) =>
        set((s) => ({ devices: s.devices.filter((d) => d.deviceId !== deviceId) })),

      pairQueue: [],
      enqueuePairRequest: (r) =>
        set((s) => ({
          pairQueue: s.pairQueue.some((x) => x.requestId === r.requestId)
            ? s.pairQueue
            : [...s.pairQueue, r],
        })),
      dequeuePairRequest: () => set((s) => ({ pairQueue: s.pairQueue.slice(1) })),

      events: [],
      pushEvent: (e) =>
        set((s) => ({
          events: [
            { id: String(++_eventSeq), event: e, receivedAt: Date.now() },
            ...s.events,
          ].slice(0, 200), // keep last 200
        })),
    }),
    {
      name: 'pawterm-admin',
      partialize: (s) => ({ token: s.token }),
    }
  )
);
