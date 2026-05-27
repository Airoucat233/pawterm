import { describe, expect, it } from 'vitest';

import { AdminAccessManager } from '../admin-auth.js';

describe('AdminAccessManager', () => {
  it('exchanges a one-time admin login code for an admin access token', () => {
    const auth = new AdminAccessManager();

    const login = auth.createLoginCode();
    expect(login.loginCode).toMatch(/^alc-[0-9a-f]{32}$/);

    const access = auth.redeemLoginCode(login.loginCode);
    expect(access?.accessToken).toMatch(/^aat-[0-9a-f]{32}$/);
    expect(auth.isAdminAccessToken(access!.accessToken)).toBe(true);
    expect(auth.redeemLoginCode(login.loginCode)).toBeNull();
  });

  it('rejects expired admin login codes and admin access tokens', () => {
    let now = 1_000;
    const auth = new AdminAccessManager({
      now: () => now,
      loginCodeTtlMs: 100,
      accessTokenTtlMs: 500,
    });

    const login = auth.createLoginCode();
    now = 1_101;
    expect(auth.redeemLoginCode(login.loginCode)).toBeNull();

    now = 2_000;
    const freshLogin = auth.createLoginCode();
    const access = auth.redeemLoginCode(freshLogin.loginCode);
    expect(access).not.toBeNull();
    expect(auth.isAdminAccessToken(access!.accessToken)).toBe(true);

    now = 2_501;
    expect(auth.isAdminAccessToken(access!.accessToken)).toBe(false);
  });

  it('renews a valid admin access token and revokes the old token', () => {
    let now = 1_000;
    const auth = new AdminAccessManager({
      now: () => now,
      accessTokenTtlMs: 500,
      maxAccessTokenLifetimeMs: 2_000,
    });
    const login = auth.createLoginCode();
    const first = auth.redeemLoginCode(login.loginCode)!;

    now = 1_400;
    const renewed = auth.renewAccessToken(first.accessToken);

    expect(renewed?.accessToken).toMatch(/^aat-[0-9a-f]{32}$/);
    expect(renewed!.accessToken).not.toBe(first.accessToken);
    expect(auth.isAdminAccessToken(first.accessToken)).toBe(false);
    expect(auth.isAdminAccessToken(renewed!.accessToken)).toBe(true);
  });

  it('refuses renew after the absolute access token lifetime', () => {
    let now = 1_000;
    const auth = new AdminAccessManager({
      now: () => now,
      accessTokenTtlMs: 5_000,
      maxAccessTokenLifetimeMs: 1_000,
    });
    const login = auth.createLoginCode();
    const first = auth.redeemLoginCode(login.loginCode)!;

    now = 2_001;
    expect(auth.renewAccessToken(first.accessToken)).toBeNull();
    expect(auth.isAdminAccessToken(first.accessToken)).toBe(false);
  });

  it('restores persisted admin access tokens after restart', () => {
    let now = 1_000;
    const firstProcess = new AdminAccessManager({
      now: () => now,
      accessTokenTtlMs: 5_000,
      maxAccessTokenLifetimeMs: 20_000,
    });
    const login = firstProcess.createLoginCode();
    const access = firstProcess.redeemLoginCode(login.loginCode)!;
    const persisted = firstProcess.snapshotAccessTokens();

    const restarted = new AdminAccessManager({
      now: () => now,
      initialAccessTokens: persisted,
    });

    expect(restarted.isAdminAccessToken(access.accessToken)).toBe(true);
    now = access.expiresAt + 1;
    expect(restarted.isAdminAccessToken(access.accessToken)).toBe(false);
  });
});
