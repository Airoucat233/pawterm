import { randomBytes } from 'node:crypto';

export interface AdminAccessToken {
  accessToken: string;
  expiresAt: number;
}

export interface AdminLoginCode {
  loginCode: string;
  expiresAt: number;
}

interface AdminAccessManagerOptions {
  now?: () => number;
  loginCodeTtlMs?: number;
  accessTokenTtlMs?: number;
  maxAccessTokenLifetimeMs?: number;
}

interface AccessTokenRecord {
  expiresAt: number;
  maxExpiresAt: number;
}

export class AdminAccessManager {
  private readonly now: () => number;
  private readonly loginCodeTtlMs: number;
  private readonly accessTokenTtlMs: number;
  private readonly maxAccessTokenLifetimeMs: number;
  private readonly loginCodes = new Map<string, number>();
  private readonly accessTokens = new Map<string, AccessTokenRecord>();

  constructor(opts: AdminAccessManagerOptions = {}) {
    this.now = opts.now ?? Date.now;
    this.loginCodeTtlMs = opts.loginCodeTtlMs ?? 60_000;
    this.accessTokenTtlMs = opts.accessTokenTtlMs ?? 12 * 60 * 60 * 1000;
    this.maxAccessTokenLifetimeMs = opts.maxAccessTokenLifetimeMs ?? 7 * 24 * 60 * 60 * 1000;
  }

  createLoginCode(): AdminLoginCode {
    this.pruneExpired();
    const loginCode = `alc-${randomBytes(16).toString('hex')}`;
    const expiresAt = this.now() + this.loginCodeTtlMs;
    this.loginCodes.set(loginCode, expiresAt);
    return { loginCode, expiresAt };
  }

  redeemLoginCode(loginCode: string): AdminAccessToken | null {
    this.pruneExpired();
    const expiresAt = this.loginCodes.get(loginCode);
    this.loginCodes.delete(loginCode);
    if (!expiresAt || expiresAt <= this.now()) return null;
    return this.createAccessToken();
  }

  isAdminAccessToken(token: string): boolean {
    this.pruneExpired();
    const record = this.accessTokens.get(token);
    return !!record && record.expiresAt > this.now() && record.maxExpiresAt > this.now();
  }

  renewAccessToken(token: string): AdminAccessToken | null {
    this.pruneExpired();
    const record = this.accessTokens.get(token);
    this.accessTokens.delete(token);
    if (!record || record.expiresAt <= this.now() || record.maxExpiresAt <= this.now()) return null;
    return this.createAccessToken(record.maxExpiresAt);
  }

  private createAccessToken(maxExpiresAt = this.now() + this.maxAccessTokenLifetimeMs): AdminAccessToken {
    const accessToken = `aat-${randomBytes(16).toString('hex')}`;
    const expiresAt = Math.min(this.now() + this.accessTokenTtlMs, maxExpiresAt);
    this.accessTokens.set(accessToken, { expiresAt, maxExpiresAt });
    return { accessToken, expiresAt };
  }

  private pruneExpired(): void {
    const now = this.now();
    for (const [code, expiresAt] of this.loginCodes) {
      if (expiresAt <= now) this.loginCodes.delete(code);
    }
    for (const [token, record] of this.accessTokens) {
      if (record.expiresAt <= now || record.maxExpiresAt <= now) this.accessTokens.delete(token);
    }
  }
}

export const adminAccessManager = new AdminAccessManager();
