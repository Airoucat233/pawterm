import { afterEach, describe, expect, it, vi } from 'vitest';
import type { NetworkInterfaceInfo } from 'node:os';

import { createNetworkAddressService, selectAdvertisedAddress } from '../network-address.js';

function iface(address: string, name = 'en0'): NetworkInterfaceInfo {
  return {
    address,
    netmask: '255.255.255.0',
    family: 'IPv4',
    mac: '00:00:00:00:00:00',
    internal: false,
    cidr: `${address}/24`,
  };
}

describe('network address selection', () => {
  afterEach(() => {
    vi.useRealTimers();
  });

  it('prefers a private LAN address over Tailscale and loopback', () => {
    const selected = selectAdvertisedAddress({
      lo0: [{ ...iface('127.0.0.1', 'lo0'), internal: true }],
      utun4: [iface('100.64.0.130', 'utun4')],
      en0: [iface('192.168.1.15', 'en0')],
    });

    expect(selected?.address).toBe('192.168.1.15');
    expect(selected?.name).toBe('en0');
  });

  it('uses RFC1918 10.x LAN addresses before Tailscale addresses', () => {
    const selected = selectAdvertisedAddress({
      utun4: [iface('100.64.0.130', 'utun4')],
      en0: [iface('10.36.10.160', 'en0')],
    });

    expect(selected?.address).toBe('10.36.10.160');
  });

  it('falls back to Tailscale when no LAN address exists', () => {
    const selected = selectAdvertisedAddress({
      utun4: [iface('100.64.0.130', 'utun4')],
    });

    expect(selected?.address).toBe('100.64.0.130');
  });

  it('ignores loopback and link-local addresses', () => {
    const selected = selectAdvertisedAddress({
      lo0: [{ ...iface('127.0.0.1', 'lo0'), internal: true }],
      en0: [iface('169.254.1.9', 'en0')],
    });

    expect(selected).toBeNull();
  });

  it('notifies when the advertised address changes', () => {
    vi.useFakeTimers();
    let ifaces = {
      en0: [iface('10.36.10.160', 'en0')],
    };
    const changes: Array<{ current: string | null; previous: string | null }> = [];
    const service = createNetworkAddressService({
      pollMs: 1000,
      getInterfaces: () => ifaces,
      onChange: (current, previous) => {
        changes.push({
          current: current?.address ?? null,
          previous: previous?.address ?? null,
        });
      },
    });

    service.start();
    ifaces = {
      en0: [iface('192.168.1.15', 'en0')],
    };
    vi.advanceTimersByTime(1000);
    service.stop();

    expect(changes).toEqual([
      { current: '192.168.1.15', previous: '10.36.10.160' },
    ]);
  });
});
