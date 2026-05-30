import { randomBytes, scryptSync, timingSafeEqual } from 'node:crypto';

const KEY_LEN = 64;

export function hashAdminPassword(password: string): string {
  const salt = randomBytes(16).toString('hex');
  const hash = scryptSync(password, salt, KEY_LEN).toString('hex');
  return `scrypt$${salt}$${hash}`;
}

export function verifyAdminPassword(password: string, storedHash: string | undefined): boolean {
  if (!storedHash) return false;
  const parts = storedHash.split('$');
  if (parts.length !== 3 || parts[0] !== 'scrypt') return false;
  const [, salt, hash] = parts;
  if (!salt || !hash) return false;

  try {
    const expected = Buffer.from(hash, 'hex');
    if (expected.length !== KEY_LEN) return false;
    const actual = scryptSync(password, salt, KEY_LEN);
    return timingSafeEqual(actual, expected);
  } catch {
    return false;
  }
}
