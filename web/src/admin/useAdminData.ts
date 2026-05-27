/**
 * Data-fetching hooks: health ping, devices poll, SSE subscription
 */
import { useEffect, useRef, useCallback } from 'react';
import { useAdminStore } from './store';
import { apiBase, fetchHealth, fetchDevices, renewAdminAccessToken } from './api';
import type { AdminEvent } from '@pawterm/shared';

const POLL_INTERVAL = 5000;
const SSE_RECONNECT_DELAY = 5000;
const RENEW_BEFORE_MS = 10 * 60 * 1000;

export function useAdminAccessRenew() {
  const token = useAdminStore((s) => s.token);
  const tokenExpiresAt = useAdminStore((s) => s.tokenExpiresAt);
  const setToken = useAdminStore((s) => s.setToken);
  const clearToken = useAdminStore((s) => s.clearToken);

  useEffect(() => {
    if (!token || !tokenExpiresAt) return;
    let alive = true;
    let timer: ReturnType<typeof setTimeout> | null = null;

    async function renew() {
      if (!token) return;
      try {
        const next = await renewAdminAccessToken(token);
        if (alive) setToken(next.token, next.expiresAt);
      } catch {
        if (alive) clearToken();
      }
    }

    const delay = Math.max(0, tokenExpiresAt - Date.now() - RENEW_BEFORE_MS);
    timer = setTimeout(() => void renew(), delay);

    return () => {
      alive = false;
      if (timer) clearTimeout(timer);
    };
  }, [token, tokenExpiresAt, setToken, clearToken]);
}

export function useHealthPing() {
  const token = useAdminStore((s) => s.token);
  const setHealth = useAdminStore((s) => s.setHealth);

  useEffect(() => {
    if (!token) return;
    let alive = true;

    async function ping() {
      try {
        const h = await fetchHealth();
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
  const clearToken = useAdminStore((s) => s.clearToken);
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
    let abort: AbortController | null = null;
    let reconnectTimer: ReturnType<typeof setTimeout> | null = null;
    let alive = true;

    async function connect() {
      if (!alive) return;
      abort = new AbortController();
      try {
        const response = await fetch(`${apiBase()}/admin/events`, {
          headers: {
            Accept: 'text/event-stream',
            Authorization: `Bearer ${token}`,
          },
          signal: abort.signal,
        });
        if (response.status === 401 || response.status === 403) {
          clearToken();
          return;
        }
        if (!response.ok || !response.body) throw new Error(`SSE HTTP ${response.status}`);

        const reader = response.body.getReader();
        const decoder = new TextDecoder();
        let buffer = '';
        while (alive) {
          const { value, done } = await reader.read();
          if (done) break;
          buffer += decoder.decode(value, { stream: true });
          const blocks = buffer.split(/\n\n/);
          buffer = blocks.pop() ?? '';
          for (const block of blocks) {
            const data = block
              .split(/\r?\n/)
              .filter((line) => line.startsWith('data:'))
              .map((line) => line.slice(5).trimStart())
              .join('\n');
            if (!data) continue;
            try {
              handleEvent(JSON.parse(data) as AdminEvent);
            } catch {
              // ignore malformed SSE data
            }
          }
        }
      } catch {
        // reconnect below unless the component has unmounted
      }
      if (alive) reconnectTimer = setTimeout(() => void connect(), SSE_RECONNECT_DELAY);
    }

    void connect();

    return () => {
      alive = false;
      abort?.abort();
      if (reconnectTimer) clearTimeout(reconnectTimer);
    };
  }, [token, handleEvent, clearToken]);
}
