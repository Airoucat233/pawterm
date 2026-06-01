import { describe, expect, it, vi } from 'vitest';

import { waitForPortRelease } from '../service.js';

describe('service restart helpers', () => {
  it('waits until the TCP port is released before continuing', () => {
    const isPortInUse = vi
      .fn<() => boolean>()
      .mockReturnValueOnce(true)
      .mockReturnValueOnce(true)
      .mockReturnValueOnce(false);
    const sleep = vi.fn<(ms: number) => void>();

    const released = waitForPortRelease({
      port: 18765,
      timeoutMs: 1000,
      intervalMs: 100,
      isPortInUse,
      sleep,
    });

    expect(released).toBe(true);
    expect(isPortInUse).toHaveBeenCalledTimes(3);
    expect(sleep).toHaveBeenCalledTimes(2);
    expect(sleep).toHaveBeenCalledWith(100);
  });
});
