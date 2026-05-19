import { randomBytes, randomUUID } from 'node:crypto';
import { settings, persistPairedDevices, type StoredDevice } from './config.js';
import { adminEventBus } from './event-bus.js';

const PIN_WINDOW_MS = 5 * 60 * 1000; // 5 minutes
const RATE_LIMIT_MAX_FAILURES = 5;
const RATE_LIMIT_COOLDOWN_MS = 60 * 1000; // 60 seconds

// Pair request constants
const PAIR_REQUEST_EXPIRE_MS = 60 * 1000; // 60 seconds
const PAIR_REQUEST_IP_COOLDOWN_MS = 30 * 1000; // 30 seconds between requests per IP
const PAIR_REQUEST_MAX_PENDING = 5; // global limit on pending requests

interface PairingWindow {
  pin: string;
  expiresAt: number;
}

interface RateLimitEntry {
  failures: number;
  cooldownUntil: number | null;
}

export interface PairRequest {
  requestId: string;
  deviceId: string;
  deviceName: string;
  ip: string;
  createdAt: number;
  status: 'pending' | 'approved' | 'denied' | 'expired';
  deviceToken?: string;
}

class PairingManager {
  private window: PairingWindow | null = null;
  private rateLimitMap = new Map<string, RateLimitEntry>();

  // Phone-triggered pair requests
  private pairRequests = new Map<string, PairRequest>();
  // Track last request time per IP for rate limiting
  private pairRequestIpTimestamps = new Map<string, number>();
  // Long-poll listeners: requestId -> set of resolve functions
  private pairPollListeners = new Map<string, Set<(req: PairRequest) => void>>();
  // Cleanup timer
  private cleanupTimer: ReturnType<typeof setInterval> | null = null;

  /**
   * Open a new pairing window. Generates a 6-digit PIN, valid for 5 minutes.
   * Returns the PIN and its expiry timestamp.
   */
  openWindow(): PairWindowResponse {
    const pin = String(Math.floor(Math.random() * 1_000_000)).padStart(6, '0');
    const expiresAt = Date.now() + PIN_WINDOW_MS;
    this.window = { pin, expiresAt };
    return { pin, expiresAt };
  }

  /**
   * Returns 'open' when a valid pairing window exists, 'closed' otherwise.
   */
  getState(): 'open' | 'closed' {
    if (!this.window) return 'closed';
    if (Date.now() > this.window.expiresAt) {
      this.window = null;
      return 'closed';
    }
    return 'open';
  }

  /**
   * Try to redeem a PIN. On success, creates a deviceToken and persists it.
   */
  async tryRedeemPin(
    pin: string,
    deviceId: string,
    deviceName: string,
    clientIp: string,
  ): Promise<
    | { ok: true; deviceToken: string; serverId: string }
    | { ok: false; error: 'bad_pin' | 'pairing_closed' | 'rate_limited' }
  > {
    // Rate limit check
    const rl = this.getRateLimitEntry(clientIp);
    if (rl.cooldownUntil !== null && Date.now() < rl.cooldownUntil) {
      return { ok: false, error: 'rate_limited' };
    }

    // Window check
    if (this.getState() === 'closed') {
      return { ok: false, error: 'pairing_closed' };
    }

    // PIN check
    if (pin !== this.window!.pin) {
      rl.failures += 1;
      if (rl.failures >= RATE_LIMIT_MAX_FAILURES) {
        rl.cooldownUntil = Date.now() + RATE_LIMIT_COOLDOWN_MS;
        rl.failures = 0;
      }
      return { ok: false, error: 'bad_pin' };
    }

    // Success — close the window and issue a token
    this.window = null;
    this.resetRateLimit(clientIp);

    return this.issueDeviceToken(deviceId, deviceName);
  }

  /**
   * Issue a device token without PIN (QR claim path, already authenticated via adminToken).
   */
  async issueDeviceToken(
    deviceId: string,
    deviceName: string,
  ): Promise<{ ok: true; deviceToken: string; serverId: string }> {
    const deviceToken = 'dt-' + randomBytes(24).toString('hex');
    const now = Date.now();

    // Replace existing device with same deviceId, or push new
    const existingIdx = settings.pairedDevices.findIndex((d) => d.deviceId === deviceId);
    const entry: StoredDevice = {
      deviceId,
      name: deviceName,
      deviceToken,
      pairedAt: now,
      lastSeen: null,
    };

    if (existingIdx >= 0) {
      settings.pairedDevices[existingIdx] = entry;
    } else {
      settings.pairedDevices.push(entry);
    }

    await persistPairedDevices();
    return { ok: true, deviceToken, serverId: settings.serverId };
  }

  /**
   * Issue a device token and emit device_paired event.
   * Use approve() for phone-triggered requests (to also update request status).
   */
  async issueDeviceTokenAndNotify(
    deviceId: string,
    deviceName: string,
  ): Promise<{ ok: true; deviceToken: string; serverId: string }> {
    const result = await this.issueDeviceToken(deviceId, deviceName);
    adminEventBus.emitEvent({ type: 'device_paired', deviceId, name: deviceName });
    return result;
  }

  /**
   * Revoke a device by deviceId. Returns true if found and removed.
   */
  async revokeDevice(deviceId: string): Promise<boolean> {
    const before = settings.pairedDevices.length;
    settings.pairedDevices = settings.pairedDevices.filter((d) => d.deviceId !== deviceId);
    if (settings.pairedDevices.length === before) return false;
    await persistPairedDevices();
    adminEventBus.emitEvent({ type: 'device_revoked', deviceId });
    return true;
  }

  // ===== Phone-triggered pair requests =====

  /**
   * Start the cleanup timer for expired pair requests.
   * Called lazily on first submitRequest so tests can avoid timers.
   */
  private startCleanupTimer(): void {
    if (this.cleanupTimer !== null) return;
    this.cleanupTimer = setInterval(() => {
      const now = Date.now();
      for (const [id, req] of this.pairRequests) {
        if (req.status === 'pending' && now - req.createdAt > PAIR_REQUEST_EXPIRE_MS) {
          req.status = 'expired';
          this._notifyPollListeners(id, req);
        }
      }
    }, 5000);
    // Allow process to exit even if timer is running
    if (this.cleanupTimer.unref) this.cleanupTimer.unref();
  }

  /**
   * Submit a phone-triggered pair request.
   * Rate-limits per IP (30s) and globally (max 5 pending).
   */
  submitRequest(
    deviceId: string,
    deviceName: string,
    ip: string,
  ): { ok: true; request: PairRequest } | { ok: false; error: 'rate_limited' | 'too_many_pending' } {
    // IP-based rate limit: 1 request per 30s per IP
    const lastTs = this.pairRequestIpTimestamps.get(ip);
    if (lastTs !== undefined && Date.now() - lastTs < PAIR_REQUEST_IP_COOLDOWN_MS) {
      return { ok: false, error: 'rate_limited' };
    }

    // Global pending limit
    const pendingCount = [...this.pairRequests.values()].filter((r) => r.status === 'pending').length;
    if (pendingCount >= PAIR_REQUEST_MAX_PENDING) {
      return { ok: false, error: 'too_many_pending' };
    }

    this.startCleanupTimer();
    this.pairRequestIpTimestamps.set(ip, Date.now());

    const request: PairRequest = {
      requestId: randomUUID(),
      deviceId,
      deviceName,
      ip,
      createdAt: Date.now(),
      status: 'pending',
    };
    this.pairRequests.set(request.requestId, request);

    adminEventBus.emitEvent({
      type: 'pair_request',
      requestId: request.requestId,
      deviceId: request.deviceId,
      deviceName: request.deviceName,
      ip: request.ip,
      createdAt: request.createdAt,
    });

    return { ok: true, request };
  }

  /**
   * Approve a pending pair request. Issues a deviceToken.
   */
  async approve(requestId: string): Promise<{ deviceToken: string; serverId: string } | null> {
    const req = this.pairRequests.get(requestId);
    if (!req || req.status !== 'pending') return null;

    const result = await this.issueDeviceToken(req.deviceId, req.deviceName);
    req.status = 'approved';
    req.deviceToken = result.deviceToken;
    this._notifyPollListeners(requestId, req);

    adminEventBus.emitEvent({ type: 'device_paired', deviceId: req.deviceId, name: req.deviceName });

    return { deviceToken: result.deviceToken, serverId: result.serverId };
  }

  /**
   * Deny a pending pair request.
   */
  deny(requestId: string): boolean {
    const req = this.pairRequests.get(requestId);
    if (!req || req.status !== 'pending') return false;
    req.status = 'denied';
    this._notifyPollListeners(requestId, req);
    return true;
  }

  getRequest(requestId: string): PairRequest | undefined {
    return this.pairRequests.get(requestId);
  }

  listPendingRequests(): PairRequest[] {
    return [...this.pairRequests.values()].filter((r) => r.status === 'pending');
  }

  /**
   * Long-poll: resolves immediately if already settled, otherwise waits up to timeoutMs.
   */
  waitForRequestUpdate(requestId: string, timeoutMs: number): Promise<PairRequest | null> {
    const req = this.pairRequests.get(requestId);
    if (!req) return Promise.resolve(null);
    if (req.status !== 'pending') return Promise.resolve(req);

    return new Promise((resolve) => {
      let listeners = this.pairPollListeners.get(requestId);
      if (!listeners) {
        listeners = new Set();
        this.pairPollListeners.set(requestId, listeners);
      }

      const handler = (updated: PairRequest) => {
        clearTimeout(timer);
        listeners!.delete(handler);
        resolve(updated);
      };
      listeners.add(handler);

      const timer = setTimeout(() => {
        listeners!.delete(handler);
        resolve(this.pairRequests.get(requestId) ?? null);
      }, timeoutMs);
    });
  }

  private _notifyPollListeners(requestId: string, req: PairRequest): void {
    const listeners = this.pairPollListeners.get(requestId);
    if (!listeners) return;
    for (const handler of listeners) {
      handler(req);
    }
    this.pairPollListeners.delete(requestId);
  }

  /** For testing: reset pair request state */
  _resetPairRequests(): void {
    this.pairRequests.clear();
    this.pairRequestIpTimestamps.clear();
    this.pairPollListeners.clear();
    if (this.cleanupTimer !== null) {
      clearInterval(this.cleanupTimer);
      this.cleanupTimer = null;
    }
  }

  /** For testing: directly set a pair request */
  _setPairRequest(req: PairRequest): void {
    this.pairRequests.set(req.requestId, req);
  }

  private getRateLimitEntry(ip: string): RateLimitEntry {
    let entry = this.rateLimitMap.get(ip);
    if (!entry) {
      entry = { failures: 0, cooldownUntil: null };
      this.rateLimitMap.set(ip, entry);
    }
    // Reset cooldown if it's expired
    if (entry.cooldownUntil !== null && Date.now() >= entry.cooldownUntil) {
      entry.cooldownUntil = null;
      entry.failures = 0;
    }
    return entry;
  }

  private resetRateLimit(ip: string): void {
    this.rateLimitMap.delete(ip);
  }

  /** For testing: directly set the window */
  _setWindow(window: PairingWindow | null): void {
    this.window = window;
  }

  /** For testing: get current window */
  _getWindow(): PairingWindow | null {
    return this.window;
  }

  /** For testing: get rate limit map */
  _getRateLimitMap(): Map<string, RateLimitEntry> {
    return this.rateLimitMap;
  }
}

// Re-export types for response shapes
export interface PairWindowResponse {
  pin: string;
  expiresAt: number;
}

export const pairingManager = new PairingManager();
