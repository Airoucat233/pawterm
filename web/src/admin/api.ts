/**
 * Admin API helpers — all calls carry Bearer token
 */
import type { AdminAccessTokenResponse as WireAdminAccessTokenResponse, PairedDevice, QrResponse } from '@pawterm/shared';

function base(): string {
  // In dev (vite proxy) prefix is /api; in prod served from same origin, no prefix needed.
  // We detect by hostname — if we're on the same port as server, no proxy needed.
  return '';
}

function headers(token: string): HeadersInit {
  return { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' };
}

interface AdminAccessTokenResponse {
  token: string;
  expiresAt: number;
}

export async function createAdminLoginCode(rootToken: string): Promise<string> {
  const r = await fetch(`${base()}/admin/login-codes`, {
    method: 'POST',
    headers: headers(rootToken),
    body: '{}',
  });
  if (!r.ok) throw new Error('login code failed');
  const data = await r.json() as { admin_login_code?: string };
  if (!data.admin_login_code) throw new Error('missing admin_login_code');
  return data.admin_login_code;
}

export async function exchangeAdminLoginCode(adminLoginCode: string): Promise<AdminAccessTokenResponse> {
  const r = await fetch(`${base()}/admin/access-token`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ admin_login_code: adminLoginCode }),
  });
  if (!r.ok) throw new Error('access token failed');
  const data = await r.json() as Partial<WireAdminAccessTokenResponse>;
  if (!data.admin_access_token) throw new Error('missing admin_access_token');
  return { token: data.admin_access_token, expiresAt: data.expires_at ?? 0 };
}

export async function renewAdminAccessToken(token: string): Promise<AdminAccessTokenResponse> {
  const r = await fetch(`${base()}/admin/access-token/renew`, {
    method: 'POST',
    headers: headers(token),
    body: '{}',
  });
  if (!r.ok) throw new Error('renew failed');
  const data = await r.json() as Partial<WireAdminAccessTokenResponse>;
  if (!data.admin_access_token) throw new Error('missing admin_access_token');
  return { token: data.admin_access_token, expiresAt: data.expires_at ?? 0 };
}

export async function setAdminPassword(token: string, password: string): Promise<void> {
  const r = await fetch(`${base()}/admin/password`, {
    method: 'POST',
    headers: headers(token),
    body: JSON.stringify({ password }),
  });
  if (!r.ok) throw new Error('password failed');
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
