import { describe, expect, it } from 'vitest';

import { hashAdminPassword, verifyAdminPassword } from '../admin-password.js';

describe('admin password hashing', () => {
  it('stores admin passwords as scrypt hashes and verifies them', () => {
    const hash = hashAdminPassword('abc12345');

    expect(hash).toMatch(/^scrypt\$/);
    expect(hash).not.toContain('abc12345');
    expect(verifyAdminPassword('abc12345', hash)).toBe(true);
    expect(verifyAdminPassword('wrong123', hash)).toBe(false);
  });

  it('rejects malformed password hashes', () => {
    expect(verifyAdminPassword('abc12345', '')).toBe(false);
    expect(verifyAdminPassword('abc12345', 'abc12345')).toBe(false);
    expect(verifyAdminPassword('abc12345', 'scrypt$bad')).toBe(false);
  });
});
