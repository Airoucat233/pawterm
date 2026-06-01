import { describe, expect, it } from 'vitest';

import { mdnsServiceName } from '../mdns.js';

describe('mDNS advertisement', () => {
  it('includes the port in the service name so dev and stable servers can coexist', () => {
    expect(mdnsServiceName({ hostname: 'MacBook-Pro', port: 8765 })).toBe(
      'PawTerm on MacBook-Pro:8765',
    );
    expect(mdnsServiceName({ hostname: 'MacBook-Pro', port: 18765 })).toBe(
      'PawTerm on MacBook-Pro:18765',
    );
  });
});
