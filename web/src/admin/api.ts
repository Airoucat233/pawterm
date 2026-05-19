/**
 * Admin API helpers — all calls carry Bearer token
 */
import type { PairedDevice, QrResponse } from '@pawterm/shared';

function base(): string {
  // In dev (vite proxy) prefix is /api; in prod served from same origin, no prefix needed.
  // We detect by hostname — if we're on the same port as server, no proxy needed.
  return '';
}

function headers(token: string): HeadersInit {
  return { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' };
}

export async function fetchHealth(token: string) {
  const r = await fetch(`${base()}/health`, {
    headers: { Authorization: `Bearer ${token}` },
  });
  if (!r.ok) throw new Error('health failed');
  return r.json() as Promise<{
    status: string;
    version: string;
    hostname: string;
    serverId?: string;
  }>;
}

export async function fetchQr(token: string): Promise<QrResponse> {
  const r = await fetch(`${base()}/admin/qr`, { headers: headers(token) });
  if (!r.ok) throw new Error('qr failed');
  return r.json();
}

export async function fetchDevices(token: string): Promise<PairedDevice[]> {
  const r = await fetch(`${base()}/admin/devices`, { headers: headers(token) });
  if (!r.ok) throw new Error('devices failed');
  return r.json();
}

export async function revokeDevice(token: string, deviceId: string): Promise<void> {
  const r = await fetch(`${base()}/admin/devices/${encodeURIComponent(deviceId)}`, {
    method: 'DELETE',
    headers: headers(token),
  });
  if (!r.ok) throw new Error('revoke failed');
}

export async function approvePair(token: string, requestId: string): Promise<void> {
  const r = await fetch(`${base()}/admin/pair-approve`, {
    method: 'POST',
    headers: headers(token),
    body: JSON.stringify({ requestId }),
  });
  if (!r.ok) throw new Error('approve failed');
}

export async function denyPair(token: string, requestId: string): Promise<void> {
  const r = await fetch(`${base()}/admin/pair-deny`, {
    method: 'POST',
    headers: headers(token),
    body: JSON.stringify({ requestId }),
  });
  if (!r.ok) throw new Error('deny failed');
}

export async function openPairWindow(token: string): Promise<{ pin: string }> {
  const r = await fetch(`${base()}/admin/pair-window`, {
    method: 'POST',
    headers: headers(token),
  });
  if (!r.ok) throw new Error('pair-window failed');
  return r.json();
}
