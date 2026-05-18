import { defineConfig } from 'tsup';
import { version } from './package.json';

export default defineConfig({
  entry: ['src/index.ts'],
  format: ['esm'],
  target: 'node20',
  bundle: true,
  // inline @pawterm/shared so the published package has no workspace dependency
  noExternal: ['@pawterm/shared'],
  // keep native modules (node-pty) as external — they ship prebuilds
  external: ['node-pty'],
  outDir: 'dist',
  clean: true,
  sourcemap: false,
  define: {
    __SERVER_VERSION__: JSON.stringify(version),
  },
  banner: {
    js: '#!/usr/bin/env node',
  },
});
