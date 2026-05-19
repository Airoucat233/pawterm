/**
 * PawTerm Admin — Developer Debug Center
 * Aesthetic: Terminal-industrial precision. Signal grid. Live data.
 */
import { useState, useEffect, useRef } from 'react';
import clsx from 'clsx';
import { useAdminStore } from './store';
import { useHealthPing, useDevicesPoll, useAdminSSE } from './useAdminData';
import { revokeDevice, approvePair, denyPair, openPairWindow } from './api';
import type { AdminEvent } from '@pawterm/shared';

// ─── Token gate ──────────────────────────────────────────────────────────────

function TokenGate({ children }: { children: React.ReactNode }) {
  const token = useAdminStore((s) => s.token);
  const setToken = useAdminStore((s) => s.setToken);
  const [input, setInput] = useState('');

  useEffect(() => {
    const params = new URLSearchParams(window.location.search);
    const t = params.get('token');
    if (t && !token) setToken(t);
  }, [token, setToken]);

  if (token) return <>{children}</>;

  return (
    <div className="min-h-screen bg-[#0B1210] flex items-center justify-center font-mono">
      <div className="border border-[#2A332E] bg-[#141B18] p-8 w-96">
        <div className="text-[#10B981] text-xs tracking-[0.3em] uppercase mb-6">
          PawTerm Admin
        </div>
        <p className="text-[#4D6358] text-xs mb-4">
          Enter your admin token to continue.
        </p>
        <input
          type="password"
          value={input}
          onChange={(e) => setInput(e.target.value)}
          onKeyDown={(e) => e.key === 'Enter' && input && setToken(input)}
          placeholder="sk-..."
          className="w-full bg-[#0B1210] border border-[#2A332E] text-[#E6E6E6] text-xs px-3 py-2 outline-none focus:border-[#10B981] font-mono mb-3"
          autoFocus
        />
        <button
          onClick={() => input && setToken(input)}
          className="w-full bg-[#10B981] text-[#0B1210] text-xs font-bold py-2 tracking-widest hover:bg-[#0ea573] transition-colors"
        >
          CONNECT
        </button>
      </div>
    </div>
  );
}

// ─── Status dot ──────────────────────────────────────────────────────────────

function StatusDot({ online }: { online: boolean }) {
  return (
    <span className="relative inline-flex h-2 w-2 mr-2">
      {online && (
        <span className="animate-ping absolute inline-flex h-full w-full rounded-full bg-[#10B981] opacity-75" />
      )}
      <span
        className={clsx(
          'relative inline-flex rounded-full h-2 w-2',
          online ? 'bg-[#10B981]' : 'bg-[#EF4444]'
        )}
      />
    </span>
  );
}

// ─── Top status bar ───────────────────────────────────────────────────────────

function StatusBar() {
  const online = useAdminStore((s) => s.serverOnline);
  const hostname = useAdminStore((s) => s.hostname);
  const serverId = useAdminStore((s) => s.serverId);
  const port = useAdminStore((s) => s.port);
  const token = useAdminStore((s) => s.token);
  const clearToken = useAdminStore((s) => s.clearToken);

  const shortId = serverId ? serverId.slice(-8) : '--------';
  const displayHost = hostname ?? 'localhost';
  const displayPort = port ?? 8765;

  return (
    <header className="flex items-center gap-4 px-4 py-2 bg-[#141B18] border-b border-[#2A332E] font-mono text-xs">
      <div className="flex items-center">
        <StatusDot online={online} />
        <span className={online ? 'text-[#10B981]' : 'text-[#EF4444]'}>
          {online ? 'ONLINE' : 'OFFLINE'}
        </span>
      </div>
      <span className="text-[#4D6358]">/</span>
      <span className="text-[#E6E6E6]">
        {displayHost}:{displayPort}
      </span>
      <span className="text-[#4D6358]">/</span>
      <span className="text-[#4D6358]">
        id:<span className="text-[#9BA39E]">{shortId}</span>
      </span>
      <span className="flex-1" />
      <span className="text-[#4D6358] text-[10px]">
        token: <span className="text-[#9BA39E]">{token ? `${token.slice(0, 8)}…` : '—'}</span>
      </span>
      <button
        onClick={clearToken}
        className="text-[#4D6358] hover:text-[#EF4444] transition-colors text-[10px] tracking-widest ml-2"
      >
        [DISCONNECT]
      </button>
    </header>
  );
}

// ─── QR Card ─────────────────────────────────────────────────────────────────

function QrCard() {
  const token = useAdminStore((s) => s.token);
  const [qrSvg, setQrSvg] = useState<string | null>(null);
  const [pin, setPin] = useState<string | null>(null);
  const [pinLoading, setPinLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!token) return;
    fetch('/admin/qr', { headers: { Authorization: `Bearer ${token}` } })
      .then((r) => r.json())
      .then((d) => setQrSvg(d.svg))
      .catch(() => setError('QR unavailable'));
  }, [token]);

  async function handleShowPin() {
    if (!token) return;
    setPinLoading(true);
    try {
      const { pin: p } = await openPairWindow(token);
      setPin(p);
    } catch {
      setPin(null);
      setError('Could not open pairing window');
    } finally {
      setPinLoading(false);
    }
  }

  return (
    <div className="bg-[#141B18] border border-[#2A332E] p-4 flex flex-col gap-3">
      <div className="text-[#4D6358] text-[10px] tracking-[0.3em] uppercase">
        Scan to pair
      </div>

      <div className="flex items-center justify-center bg-[#0B1210] border border-[#2A332E] p-3 min-h-[200px]">
        {error ? (
          <span className="text-[#EF4444] text-xs">{error}</span>
        ) : qrSvg ? (
          <div
            className="w-full max-w-[200px] aspect-square [&>svg]:w-full [&>svg]:h-full"
            dangerouslySetInnerHTML={{ __html: qrSvg }}
          />
        ) : (
          <span className="text-[#4D6358] text-xs animate-pulse">loading…</span>
        )}
      </div>

      {pin ? (
        <div className="border border-[#10B981]/30 bg-[#10B981]/5 p-3 text-center">
          <div className="text-[#4D6358] text-[10px] mb-1">6-digit PIN</div>
          <div className="text-[#10B981] text-2xl font-mono tracking-[0.4em] font-bold">
            {pin}
          </div>
          <div className="text-[#4D6358] text-[10px] mt-1">valid 5 min</div>
        </div>
      ) : (
        <button
          onClick={handleShowPin}
          disabled={pinLoading}
          className="text-[#4D6358] text-xs hover:text-[#10B981] transition-colors text-center disabled:opacity-50"
        >
          {pinLoading ? 'opening…' : '↳ or use 6-digit PIN'}
        </button>
      )}
    </div>
  );
}

// ─── Status Card ──────────────────────────────────────────────────────────────

function StatusCard() {
  const serverId = useAdminStore((s) => s.serverId);
  const hostname = useAdminStore((s) => s.hostname);
  const port = useAdminStore((s) => s.port);
  const devices = useAdminStore((s) => s.devices);
  const [lanIp, setLanIp] = useState<string | null>(null);

  useEffect(() => {
    // Try to detect LAN IP via RTCPeerConnection (no server needed)
    try {
      const pc = new RTCPeerConnection({ iceServers: [] });
      pc.createDataChannel('');
      pc.createOffer().then((o) => pc.setLocalDescription(o));
      pc.onicecandidate = (e) => {
        if (!e.candidate) return;
        const m = e.candidate.candidate.match(/(\d+\.\d+\.\d+\.\d+)/);
        if (m && !m[1].startsWith('127.')) {
          setLanIp(m[1]);
          pc.close();
        }
      };
    } catch {
      // ignore
    }
  }, []);

  const rows: [string, React.ReactNode][] = [
    ['port', <span className="text-[#E6E6E6]">{port ?? '—'}</span>],
    [
      'serverId',
      <span className="text-[#E6E6E6] break-all text-[10px]">{serverId ?? '—'}</span>,
    ],
    [
      'devices',
      <span className="text-[#10B981] font-bold">{devices.length}</span>,
    ],
    ['LAN IP', <span className="text-[#E6E6E6]">{lanIp ?? 'detecting…'}</span>],
    ['hostname', <span className="text-[#E6E6E6]">{hostname ?? '—'}</span>],
  ];

  return (
    <div className="bg-[#141B18] border border-[#2A332E] p-4 flex flex-col gap-3">
      <div className="text-[#4D6358] text-[10px] tracking-[0.3em] uppercase">
        Server info
      </div>
      <table className="w-full text-xs font-mono">
        <tbody>
          {rows.map(([k, v]) => (
            <tr key={k} className="border-b border-[#1A221E] last:border-0">
              <td className="text-[#4D6358] py-1.5 pr-3 whitespace-nowrap align-top">{k}</td>
              <td className="py-1.5 align-top">{v}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

// ─── Devices Table ────────────────────────────────────────────────────────────

function DevicesTable() {
  const token = useAdminStore((s) => s.token);
  const devices = useAdminStore((s) => s.devices);
  const removeDevice = useAdminStore((s) => s.removeDevice);
  const [revoking, setRevoking] = useState<string | null>(null);

  async function handleRevoke(deviceId: string) {
    if (!token) return;
    setRevoking(deviceId);
    try {
      await revokeDevice(token, deviceId);
      removeDevice(deviceId);
    } catch {
      // silent
    } finally {
      setRevoking(null);
    }
  }

  function fmt(ms: number | null) {
    if (ms === null) return '—';
    return new Date(ms).toLocaleString(undefined, {
      month: 'short',
      day: 'numeric',
      hour: '2-digit',
      minute: '2-digit',
    });
  }

  return (
    <div className="bg-[#141B18] border border-[#2A332E] p-4 flex flex-col gap-3">
      <div className="text-[#4D6358] text-[10px] tracking-[0.3em] uppercase flex items-center gap-2">
        Paired devices
        <span className="bg-[#10B981]/10 text-[#10B981] px-1.5 py-0.5 text-[10px]">
          {devices.length}
        </span>
      </div>

      {devices.length === 0 ? (
        <p className="text-[#4D6358] text-xs text-center py-4">no paired devices</p>
      ) : (
        <div className="overflow-x-auto">
          <table className="w-full text-xs font-mono">
            <thead>
              <tr className="border-b border-[#2A332E]">
                {['device', 'paired', 'last seen', ''].map((h) => (
                  <th key={h} className="text-[#4D6358] text-left pb-2 pr-4 font-normal text-[10px] tracking-widest uppercase">
                    {h}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {devices.map((d) => (
                <tr key={d.deviceId} className="border-b border-[#1A221E] last:border-0 hover:bg-[#1A221E] transition-colors">
                  <td className="py-2 pr-4 text-[#E6E6E6] font-semibold">{d.name}</td>
                  <td className="py-2 pr-4 text-[#9BA39E]">{fmt(d.pairedAt)}</td>
                  <td className="py-2 pr-4 text-[#9BA39E]">{fmt(d.lastSeen)}</td>
                  <td className="py-2">
                    <button
                      onClick={() => handleRevoke(d.deviceId)}
                      disabled={revoking === d.deviceId}
                      className="text-[#4D6358] hover:text-[#EF4444] transition-colors text-[10px] tracking-widest disabled:opacity-40"
                    >
                      {revoking === d.deviceId ? 'revoking…' : '[REVOKE]'}
                    </button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}

// ─── Event log ───────────────────────────────────────────────────────────────

const EVENT_META: Record<string, { icon: string; color: string; label: (e: AdminEvent) => string }> = {
  pair_request: {
    icon: '📱',
    color: 'text-[#F59E0B]',
    label: (e) => `pair_request from ${(e as Extract<AdminEvent, { type: 'pair_request' }>).deviceName}`,
  },
  device_paired: {
    icon: '✓',
    color: 'text-[#10B981]',
    label: (e) => `device_paired: ${(e as Extract<AdminEvent, { type: 'device_paired' }>).name}`,
  },
  device_revoked: {
    icon: '✗',
    color: 'text-[#EF4444]',
    label: (e) => `device_revoked: ${(e as Extract<AdminEvent, { type: 'device_revoked' }>).deviceId.slice(-8)}`,
  },
  device_connected: {
    icon: '→',
    color: 'text-[#10B981]',
    label: (e) => `device_connected: ${(e as Extract<AdminEvent, { type: 'device_connected' }>).deviceId.slice(-8)}`,
  },
  device_disconnected: {
    icon: '←',
    color: 'text-[#9BA39E]',
    label: (e) => `device_disconnected: ${(e as Extract<AdminEvent, { type: 'device_disconnected' }>).deviceId.slice(-8)}`,
  },
  server_status: {
    icon: '•',
    color: 'text-[#4D6358]',
    label: (e) => {
      const s = e as Extract<AdminEvent, { type: 'server_status' }>;
      return `server_status: paired=${s.pairedDevices} active=${s.activeDevices}`;
    },
  },
};

function EventLog() {
  const events = useAdminStore((s) => s.events);
  const bottomRef = useRef<HTMLDivElement>(null);

  // Don't auto-scroll; newest is on top

  return (
    <div className="bg-[#141B18] border border-[#2A332E] p-4 flex flex-col gap-3 flex-1 min-h-0">
      <div className="text-[#4D6358] text-[10px] tracking-[0.3em] uppercase flex items-center gap-2">
        Live events
        <span className="w-1.5 h-1.5 rounded-full bg-[#10B981] animate-pulse" />
      </div>

      <div className="flex-1 overflow-y-auto font-mono text-[11px] space-y-0.5 min-h-0 max-h-48">
        {events.length === 0 ? (
          <p className="text-[#4D6358] text-xs py-2">waiting for events…</p>
        ) : (
          events.map(({ id, event, receivedAt }) => {
            const meta = EVENT_META[event.type] ?? {
              icon: '?',
              color: 'text-[#9BA39E]',
              label: () => event.type,
            };
            const ts = new Date(receivedAt).toLocaleTimeString(undefined, {
              hour: '2-digit',
              minute: '2-digit',
              second: '2-digit',
            });
            return (
              <div
                key={id}
                className="flex items-start gap-2 py-0.5 border-b border-[#1A221E] last:border-0 animate-[fadeInDown_0.2s_ease]"
              >
                <span className="text-[#4D6358] shrink-0 w-20">{ts}</span>
                <span className={clsx('shrink-0 w-4 text-center', meta.color)}>
                  {meta.icon}
                </span>
                <span className={clsx(meta.color)}>{meta.label(event)}</span>
              </div>
            );
          })
        )}
        <div ref={bottomRef} />
      </div>
    </div>
  );
}

// ─── Pair request Modal ───────────────────────────────────────────────────────

function PairRequestModal() {
  const token = useAdminStore((s) => s.token);
  const pairQueue = useAdminStore((s) => s.pairQueue);
  const dequeuePairRequest = useAdminStore((s) => s.dequeuePairRequest);
  const [acting, setActing] = useState(false);

  const current = pairQueue[0];
  if (!current) return null;

  async function handle(action: 'approve' | 'deny') {
    if (!token) return;
    setActing(true);
    try {
      if (action === 'approve') await approvePair(token, current.requestId);
      else await denyPair(token, current.requestId);
    } catch {
      // ignore — dequeue regardless
    } finally {
      setActing(false);
      dequeuePairRequest();
    }
  }

  const ago = Math.round((Date.now() - current.createdAt) / 1000);
  const agoStr = ago < 5 ? 'just now' : `${ago}s ago`;

  return (
    <div className="fixed inset-0 bg-black/70 flex items-center justify-center z-50 backdrop-blur-sm">
      <div className="bg-[#141B18] border border-[#F59E0B] w-80 p-6 font-mono shadow-2xl">
        <div className="text-[#F59E0B] text-[10px] tracking-[0.3em] uppercase mb-4">
          Pair request
        </div>

        <div className="space-y-2 mb-6 text-xs">
          <div className="flex gap-3">
            <span className="text-[#4D6358] w-16">device</span>
            <span className="text-[#E6E6E6] font-semibold">{current.deviceName}</span>
          </div>
          <div className="flex gap-3">
            <span className="text-[#4D6358] w-16">IP</span>
            <span className="text-[#9BA39E]">{current.ip}</span>
          </div>
          <div className="flex gap-3">
            <span className="text-[#4D6358] w-16">time</span>
            <span className="text-[#9BA39E]">{agoStr}</span>
          </div>
        </div>

        {pairQueue.length > 1 && (
          <div className="text-[#4D6358] text-[10px] mb-4">
            +{pairQueue.length - 1} more pending
          </div>
        )}

        <div className="flex gap-2">
          <button
            onClick={() => handle('approve')}
            disabled={acting}
            className="flex-1 bg-[#10B981] text-[#0B1210] text-xs font-bold py-2.5 tracking-widest hover:bg-[#0ea573] transition-colors disabled:opacity-40"
          >
            ✓ APPROVE
          </button>
          <button
            onClick={() => handle('deny')}
            disabled={acting}
            className="flex-1 border border-[#EF4444] text-[#EF4444] text-xs font-bold py-2.5 tracking-widest hover:bg-[#EF4444]/10 transition-colors disabled:opacity-40"
          >
            ✗ DENY
          </button>
        </div>
      </div>
    </div>
  );
}

// ─── Root ─────────────────────────────────────────────────────────────────────

function AdminDashboard() {
  useHealthPing();
  useDevicesPoll();
  useAdminSSE();

  return (
    <div className="min-h-screen bg-[#0B1210] text-[#E6E6E6] flex flex-col font-mono overflow-hidden">
      {/* Subtle scanline overlay */}
      <div
        className="pointer-events-none fixed inset-0 z-10 opacity-[0.02]"
        style={{
          backgroundImage:
            'repeating-linear-gradient(0deg, transparent, transparent 2px, rgba(255,255,255,0.3) 2px, rgba(255,255,255,0.3) 3px)',
        }}
      />

      <StatusBar />

      <main className="flex-1 p-4 grid grid-cols-[1fr_1fr] grid-rows-[auto_auto_1fr] gap-3 min-h-0">
        {/* Top row: QR left, Status right */}
        <QrCard />
        <StatusCard />

        {/* Middle: devices full width */}
        <div className="col-span-2">
          <DevicesTable />
        </div>

        {/* Bottom: event log full width */}
        <div className="col-span-2 flex flex-col min-h-0">
          <EventLog />
        </div>
      </main>

      <PairRequestModal />
    </div>
  );
}

export default function AdminApp() {
  return (
    <TokenGate>
      <AdminDashboard />
    </TokenGate>
  );
}
