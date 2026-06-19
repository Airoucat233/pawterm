import { describe, expect, it, vi } from 'vitest';

import { restartDarwinService, waitForPortRelease } from '../service.js';

describe('restartDarwinService', () => {
  it('uses launchctl kickstart and skips the legacy fallback on success', () => {
    const kickstart = vi.fn<(uid: number) => number | null>().mockReturnValue(0);
    const fallback = vi.fn<() => void>();
    restartDarwinService({ kickstart, fallback, getUid: () => 501 });
    expect(kickstart).toHaveBeenCalledWith(501);
    expect(fallback).not.toHaveBeenCalled();
  });

  it('falls back to unload/load when kickstart fails', () => {
    const kickstart = vi.fn<(uid: number) => number | null>().mockReturnValue(1);
    const fallback = vi.fn<() => void>();
    restartDarwinService({ kickstart, fallback, getUid: () => 501 });
    expect(kickstart).toHaveBeenCalledWith(501);
    expect(fallback).toHaveBeenCalledTimes(1);
  });

  it('falls back when the uid is unavailable (no kickstart attempt)', () => {
    const kickstart = vi.fn<(uid: number) => number | null>();
    const fallback = vi.fn<() => void>();
    restartDarwinService({ kickstart, fallback, getUid: () => null });
    expect(kickstart).not.toHaveBeenCalled();
    expect(fallback).toHaveBeenCalledTimes(1);
  });
});

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
