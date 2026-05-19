import { describe, it, expect, beforeEach, vi, afterEach } from 'vitest';

vi.mock('../config.js', () => {
  const pairedDevices: Array<{
    deviceId: string;
    name: string;
    deviceToken: string;
    pairedAt: number;
    lastSeen: number | null;
  }> = [];

  return {
    settings: {
      adminToken: 'sk-admin-test',
      serverId: 'test-server-uuid',
      pairedDevices,
    },
    persistPairedDevices: vi.fn().mockResolvedValue(undefined),
  };
});

// Import after mock
const { pairingManager } = await import('../pair.js');
const { adminEventBus } = await import('../event-bus.js');
const { settings } = await import('../config.js');

describe('PairRequest (phone-triggered pairing)', () => {
  beforeEach(() => {
    pairingManager._resetPairRequests();
    pairingManager._getRateLimitMap().clear();
    (settings.pairedDevices as unknown[]).length = 0;
  });

  afterEach(() => {
    pairingManager._resetPairRequests();
  });

  describe('submitRequest', () => {
    it('returns a PairRequest with pending status', () => {
      const result = pairingManager.submitRequest('dev1', 'My Phone', '1.2.3.4');
      expect(result.ok).toBe(true);
      if (result.ok) {
        expect(result.request.status).toBe('pending');
        expect(result.request.deviceId).toBe('dev1');
        expect(result.request.deviceName).toBe('My Phone');
        expect(result.request.ip).toBe('1.2.3.4');
        expect(result.request.requestId).toMatch(
          /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/,
        );
      }
    });

    it('rate-limits same IP within 30s', () => {
      const r1 = pairingManager.submitRequest('dev1', 'Phone A', '5.5.5.5');
      expect(r1.ok).toBe(true);

      const r2 = pairingManager.submitRequest('dev2', 'Phone B', '5.5.5.5');
      expect(r2.ok).toBe(false);
      if (!r2.ok) expect(r2.error).toBe('rate_limited');
    });

    it('allows different IPs independently', () => {
      const r1 = pairingManager.submitRequest('dev1', 'Phone A', '1.1.1.1');
      const r2 = pairingManager.submitRequest('dev2', 'Phone B', '2.2.2.2');
      expect(r1.ok).toBe(true);
      expect(r2.ok).toBe(true);
    });

    it('rejects when global pending limit (5) is reached', () => {
      for (let i = 0; i < 5; i++) {
        const r = pairingManager.submitRequest(`dev${i}`, `Phone ${i}`, `10.0.0.${i}`);
        expect(r.ok).toBe(true);
      }
      // 6th request from a new IP
      const r6 = pairingManager.submitRequest('dev99', 'Phone 99', '99.99.99.99');
      expect(r6.ok).toBe(false);
      if (!r6.ok) expect(r6.error).toBe('too_many_pending');
    });

    it('emits pair_request event on submit', () => {
      const handler = vi.fn();
      const unsub = adminEventBus.subscribe(handler);
      pairingManager.submitRequest('dev1', 'My Phone', '1.2.3.4');
      unsub();
      expect(handler).toHaveBeenCalledOnce();
      const event = handler.mock.calls[0]![0];
      expect(event.type).toBe('pair_request');
      expect(event.deviceId).toBe('dev1');
    });
  });

  describe('approve', () => {
    it('returns deviceToken and serverId on approve', async () => {
      const submitResult = pairingManager.submitRequest('dev1', 'My Phone', '1.2.3.4');
      expect(submitResult.ok).toBe(true);
      if (!submitResult.ok) return;

      const result = await pairingManager.approve(submitResult.request.requestId);
      expect(result).not.toBeNull();
      expect(result!.deviceToken).toMatch(/^dt-[0-9a-f]{48}$/);
      expect(result!.serverId).toBe('test-server-uuid');
    });

    it('marks request as approved', async () => {
      const submitResult = pairingManager.submitRequest('dev1', 'My Phone', '1.2.3.4');
      if (!submitResult.ok) return;
      await pairingManager.approve(submitResult.request.requestId);
      const req = pairingManager.getRequest(submitResult.request.requestId);
      expect(req?.status).toBe('approved');
      expect(req?.deviceToken).toMatch(/^dt-/);
    });

    it('emits device_paired event on approve', async () => {
      const events: unknown[] = [];
      const unsub = adminEventBus.subscribe((e) => events.push(e));
      const submitResult = pairingManager.submitRequest('dev1', 'My Phone', '1.2.3.4');
      if (!submitResult.ok) { unsub(); return; }
      await pairingManager.approve(submitResult.request.requestId);
      unsub();

      const pairedEvent = events.find((e: any) => e.type === 'device_paired');
      expect(pairedEvent).toBeDefined();
      expect((pairedEvent as any).deviceId).toBe('dev1');
    });

    it('returns null for unknown requestId', async () => {
      const result = await pairingManager.approve('nonexistent-id');
      expect(result).toBeNull();
    });

    it('cannot approve same request twice', async () => {
      const submitResult = pairingManager.submitRequest('dev1', 'My Phone', '1.2.3.4');
      if (!submitResult.ok) return;
      await pairingManager.approve(submitResult.request.requestId);
      const second = await pairingManager.approve(submitResult.request.requestId);
      expect(second).toBeNull();
    });
  });

  describe('deny', () => {
    it('marks request as denied', () => {
      const submitResult = pairingManager.submitRequest('dev1', 'My Phone', '1.2.3.4');
      if (!submitResult.ok) return;
      const denied = pairingManager.deny(submitResult.request.requestId);
      expect(denied).toBe(true);
      const req = pairingManager.getRequest(submitResult.request.requestId);
      expect(req?.status).toBe('denied');
      expect(req?.deviceToken).toBeUndefined();
    });

    it('returns false for unknown requestId', () => {
      expect(pairingManager.deny('nonexistent')).toBe(false);
    });

    it('cannot deny an already denied request', () => {
      const submitResult = pairingManager.submitRequest('dev1', 'My Phone', '1.2.3.4');
      if (!submitResult.ok) return;
      pairingManager.deny(submitResult.request.requestId);
      expect(pairingManager.deny(submitResult.request.requestId)).toBe(false);
    });
  });

  describe('60s auto-expiry', () => {
    it('cleanup marks pending requests expired after 60s', async () => {
      vi.useFakeTimers();
      try {
        const submitResult = pairingManager.submitRequest('dev1', 'My Phone', '1.2.3.4');
        if (!submitResult.ok) return;

        const req = pairingManager.getRequest(submitResult.request.requestId)!;
        // Backdate createdAt by 61 seconds
        req.createdAt = Date.now() - 61_000;

        // Advance time to trigger cleanup interval
        vi.advanceTimersByTime(6_000);

        expect(req.status).toBe('expired');
      } finally {
        vi.useRealTimers();
        pairingManager._resetPairRequests();
      }
    });
  });

  describe('waitForRequestUpdate (long-poll)', () => {
    it('resolves immediately for non-pending requests', async () => {
      const submitResult = pairingManager.submitRequest('dev1', 'My Phone', '1.2.3.4');
      if (!submitResult.ok) return;
      pairingManager.deny(submitResult.request.requestId);
      const result = await pairingManager.waitForRequestUpdate(submitResult.request.requestId, 100);
      expect(result?.status).toBe('denied');
    });

    it('resolves when request is approved during wait', async () => {
      const submitResult = pairingManager.submitRequest('dev1', 'My Phone', '1.2.3.4');
      if (!submitResult.ok) return;
      const requestId = submitResult.request.requestId;

      const waitPromise = pairingManager.waitForRequestUpdate(requestId, 5_000);
      // Approve after a small delay
      await Promise.resolve(); // yield
      pairingManager.approve(requestId);

      const result = await waitPromise;
      expect(result?.status).toBe('approved');
    });

    it('resolves with current state after timeout', async () => {
      const submitResult = pairingManager.submitRequest('dev1', 'My Phone', '1.2.3.4');
      if (!submitResult.ok) return;
      const result = await pairingManager.waitForRequestUpdate(submitResult.request.requestId, 50);
      expect(result?.status).toBe('pending');
    });

    it('returns null for unknown requestId', async () => {
      const result = await pairingManager.waitForRequestUpdate('nonexistent', 50);
      expect(result).toBeNull();
    });
  });

  describe('adminEventBus subscribe/unsubscribe', () => {
    it('does not leak listeners after unsubscribe', () => {
      const before = adminEventBus.listenerCount('admin_event');
      const handlers = Array.from({ length: 5 }, () => {
        const unsub = adminEventBus.subscribe(vi.fn());
        return unsub;
      });
      expect(adminEventBus.listenerCount('admin_event')).toBe(before + 5);
      handlers.forEach((u) => u());
      expect(adminEventBus.listenerCount('admin_event')).toBe(before);
    });
  });
});
