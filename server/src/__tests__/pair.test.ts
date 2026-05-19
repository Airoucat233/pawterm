import { describe, it, expect, beforeEach, vi } from 'vitest';

// We test PairingManager by extracting the class logic.
// Since settings is a singleton, we mock the config module.

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

// Import after mock is set up
const { pairingManager } = await import('../pair.js');
const { settings, persistPairedDevices } = await import('../config.js');

describe('PairingManager', () => {
  beforeEach(() => {
    // Reset state between tests
    pairingManager._setWindow(null);
    pairingManager._getRateLimitMap().clear();
    (settings.pairedDevices as unknown[]).length = 0;
    vi.mocked(persistPairedDevices).mockClear();
  });

  describe('openWindow', () => {
    it('generates a 6-digit PIN', () => {
      const { pin } = pairingManager.openWindow();
      expect(pin).toMatch(/^\d{6}$/);
    });

    it('sets expiresAt ~5 minutes from now', () => {
      const before = Date.now();
      const { expiresAt } = pairingManager.openWindow();
      const after = Date.now();
      expect(expiresAt).toBeGreaterThanOrEqual(before + 5 * 60 * 1000 - 100);
      expect(expiresAt).toBeLessThanOrEqual(after + 5 * 60 * 1000 + 100);
    });

    it('switches state to open', () => {
      expect(pairingManager.getState()).toBe('closed');
      pairingManager.openWindow();
      expect(pairingManager.getState()).toBe('open');
    });
  });

  describe('getState', () => {
    it('returns closed when no window', () => {
      expect(pairingManager.getState()).toBe('closed');
    });

    it('returns open when window is valid', () => {
      pairingManager.openWindow();
      expect(pairingManager.getState()).toBe('open');
    });

    it('returns closed and clears window when expired', () => {
      pairingManager._setWindow({ pin: '123456', expiresAt: Date.now() - 1 });
      expect(pairingManager.getState()).toBe('closed');
      expect(pairingManager._getWindow()).toBeNull();
    });
  });

  describe('tryRedeemPin', () => {
    it('returns pairing_closed when no window', async () => {
      const result = await pairingManager.tryRedeemPin('123456', 'dev1', 'My Phone', '1.2.3.4');
      expect(result).toEqual({ ok: false, error: 'pairing_closed' });
    });

    it('returns bad_pin for wrong PIN', async () => {
      pairingManager.openWindow();
      const result = await pairingManager.tryRedeemPin('000000', 'dev1', 'My Phone', '1.2.3.4');
      expect(result).toEqual({ ok: false, error: 'bad_pin' });
    });

    it('returns ok and deviceToken for correct PIN', async () => {
      const { pin } = pairingManager.openWindow();
      const result = await pairingManager.tryRedeemPin(pin, 'dev1', 'My Phone', '1.2.3.4');
      expect(result.ok).toBe(true);
      if (result.ok) {
        expect(result.deviceToken).toMatch(/^dt-[0-9a-f]{48}$/);
        expect(result.serverId).toBe('test-server-uuid');
      }
    });

    it('closes window after successful redemption', async () => {
      const { pin } = pairingManager.openWindow();
      await pairingManager.tryRedeemPin(pin, 'dev1', 'My Phone', '1.2.3.4');
      expect(pairingManager.getState()).toBe('closed');
    });

    it('persists pairedDevices after successful redemption', async () => {
      const { pin } = pairingManager.openWindow();
      await pairingManager.tryRedeemPin(pin, 'dev1', 'My Phone', '1.2.3.4');
      expect(persistPairedDevices).toHaveBeenCalledOnce();
      expect(settings.pairedDevices).toHaveLength(1);
      expect(settings.pairedDevices[0]!.deviceId).toBe('dev1');
    });

    it('replaces existing device with same deviceId', async () => {
      const { pin: pin1 } = pairingManager.openWindow();
      await pairingManager.tryRedeemPin(pin1, 'dev1', 'My Phone', '1.2.3.4');
      const oldToken = settings.pairedDevices[0]!.deviceToken;

      const { pin: pin2 } = pairingManager.openWindow();
      await pairingManager.tryRedeemPin(pin2, 'dev1', 'My Phone Renamed', '1.2.3.4');
      expect(settings.pairedDevices).toHaveLength(1);
      expect(settings.pairedDevices[0]!.deviceToken).not.toBe(oldToken);
      expect(settings.pairedDevices[0]!.name).toBe('My Phone Renamed');
    });

    describe('rate limiting', () => {
      it('returns rate_limited after 5 failures', async () => {
        pairingManager.openWindow();
        for (let i = 0; i < 5; i++) {
          await pairingManager.tryRedeemPin('000000', 'dev1', 'My Phone', '9.9.9.9');
        }
        // Next attempt should be rate_limited (window may be closed, but rate limit applies first... actually
        // the pairing window is still open after 5 bad PINs — the window doesn't close on failure.
        // Re-open window if needed)
        pairingManager.openWindow();
        const result = await pairingManager.tryRedeemPin('000000', 'dev1', 'My Phone', '9.9.9.9');
        expect(result).toEqual({ ok: false, error: 'rate_limited' });
      });

      it('different IPs have independent rate limits', async () => {
        pairingManager.openWindow();
        for (let i = 0; i < 5; i++) {
          await pairingManager.tryRedeemPin('000000', 'dev1', 'My Phone', '1.1.1.1');
        }
        // IP 2.2.2.2 should not be rate limited
        const result = await pairingManager.tryRedeemPin('000000', 'dev1', 'My Phone', '2.2.2.2');
        expect(result).toEqual({ ok: false, error: 'bad_pin' }); // bad_pin, not rate_limited
      });
    });

    it('returns pairing_closed for expired window', async () => {
      pairingManager._setWindow({ pin: '999999', expiresAt: Date.now() - 1 });
      const result = await pairingManager.tryRedeemPin('999999', 'dev1', 'My Phone', '1.2.3.4');
      expect(result).toEqual({ ok: false, error: 'pairing_closed' });
    });
  });

  describe('issueDeviceToken', () => {
    it('issues a dt- prefixed token', async () => {
      const result = await pairingManager.issueDeviceToken('dev2', 'Tablet');
      expect(result.ok).toBe(true);
      expect(result.deviceToken).toMatch(/^dt-/);
      expect(result.serverId).toBe('test-server-uuid');
    });
  });

  describe('revokeDevice', () => {
    it('removes device from pairedDevices', async () => {
      await pairingManager.issueDeviceToken('dev3', 'Watch');
      expect(settings.pairedDevices).toHaveLength(1);
      const revoked = await pairingManager.revokeDevice('dev3');
      expect(revoked).toBe(true);
      expect(settings.pairedDevices).toHaveLength(0);
    });

    it('returns false for unknown deviceId', async () => {
      const revoked = await pairingManager.revokeDevice('nonexistent');
      expect(revoked).toBe(false);
    });

    it('calls persistPairedDevices after revoke', async () => {
      await pairingManager.issueDeviceToken('dev4', 'PC');
      vi.mocked(persistPairedDevices).mockClear();
      await pairingManager.revokeDevice('dev4');
      expect(persistPairedDevices).toHaveBeenCalledOnce();
    });
  });
});
