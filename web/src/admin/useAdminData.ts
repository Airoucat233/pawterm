/**
 * Data-fetching hooks: health ping, devices poll, SSE subscription
 */
import { useEffect, useRef, useCallback } from 'react';
import { useAdminStore } from './store';
import { fetchHealth, fetchDevices } from './api';
import type { AdminEvent } from '@pawterm/shared';

const POLL_INTERVAL = 5000;
const SSE_RECONNECT_DELAY = 5000;

export function useHealthPing() {
  const token = useAdminStore((s) => s.token);
  const setHealth = useAdminStore((s) => s.setHealth);

  useEffect(() => {
    if (!token) return;
    let alive = true;

    async function ping() {
      try {
        const h = await fetchHealth(token!);
        if (alive)
          setHealth({
            online: h.status === 'ok',
            serverId: h.serverId,
            hostname: h.hostname,
          });
      } catch {
        if (alive) setHealth({ online: false });
      }
    }

    ping();
    const id = setInterval(ping, POLL_INTERVAL);
    return () => {
      alive = false;
      clearInterval(id);
    };
  }, [token, setHealth]);
}

export function useDevicesPoll() {
  const token = useAdminStore((s) => s.token);
  const setDevices = useAdminStore((s) => s.setDevices);

  useEffect(() => {
    if (!token) return;
    let alive = true;

    async function poll() {
      try {
        const d = await fetchDevices(token!);
        if (alive) setDevices(d);
      } catch {
        // silent — health indicator covers connectivity
      }
    }

    poll();
    const id = setInterval(poll, POLL_INTERVAL);
    return () => {
      alive = false;
      clearInterval(id);
    };
  }, [token, setDevices]);
}

export function useAdminSSE() {
  const token = useAdminStore((s) => s.token);
  const pushEvent = useAdminStore((s) => s.pushEvent);
  const enqueuePairRequest = useAdminStore((s) => s.enqueuePairRequest);
  const setDevices = useAdminStore((s) => s.setDevices);
  const fetchDevicesRef = useRef(fetchDevices);
  fetchDevicesRef.current = fetchDevices;

  const handleEvent = useCallback(
    (e: AdminEvent) => {
      pushEvent(e);
      if (e.type === 'pair_request') {
        enqueuePairRequest({
          requestId: e.requestId,
          deviceId: e.deviceId,
          deviceName: e.deviceName,
          ip: e.ip,
          createdAt: e.createdAt,
        });
      }
      // Refresh device list on pair/revoke events
      if (
        (e.type === 'device_paired' || e.type === 'device_revoked') &&
        token
      ) {
        fetchDevicesRef.current(token).then(setDevices).catch(() => {});
      }
    },
    [pushEvent, enqueuePairRequest, setDevices, token]
  );

  useEffect(() => {
    if (!token) return;
    let es: EventSource | null = null;
    let reconnectTimer: ReturnType<typeof setTimeout> | null = null;
    let alive = true;

    function connect() {
      if (!alive) return;
      es = new EventSource(`/admin/events?token=${encodeURIComponent(token!)}`);

      es.onmessage = (msg) => {
        try {
          const event = JSON.parse(msg.data) as AdminEvent;
          handleEvent(event);
        } catch {
          // ignore malformed
        }
      };

      es.onerror = () => {
        es?.close();
        if (alive) {
          reconnectTimer = setTimeout(connect, SSE_RECONNECT_DELAY);
        }
      };
    }

    connect();

    return () => {
      alive = false;
      es?.close();
      if (reconnectTimer) clearTimeout(reconnectTimer);
    };
  }, [token, handleEvent]);
}
