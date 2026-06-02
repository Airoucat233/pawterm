import { mkdir, mkdtemp, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { describe, expect, it } from 'vitest';

import { listFsEntries } from '../fs-api.js';

describe('filesystem API helpers', () => {
  it('includes dotfiles and dot directories in directory listings', async () => {
    const dir = await mkdtemp(join(tmpdir(), 'pawterm-fs-api-'));
    await writeFile(join(dir, '.env'), 'TOKEN=x\n', 'utf8');
    await mkdir(join(dir, '.config'));
    await writeFile(join(dir, 'README.md'), '# test\n', 'utf8');

    const entries = await listFsEntries(dir);
    const names = entries.map((entry) => entry.name);

    expect(names).toContain('.env');
    expect(names).toContain('.config');
    expect(names).toContain('README.md');
  });
});
