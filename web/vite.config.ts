import react from '@vitejs/plugin-react';
import { resolve } from 'path';
import { defineConfig } from 'vite';

export default defineConfig({
  plugins: [react()],
  build: {
    rollupOptions: {
      input: {
        main: resolve(__dirname, 'index.html'),
        admin: resolve(__dirname, 'admin.html'),
      },
      output: {
        // Chat client stays at dist/; admin lands at dist/admin/
        entryFileNames: (chunk) => {
          if (chunk.name === 'admin') return 'admin/[name]-[hash].js';
          return 'assets/[name]-[hash].js';
        },
        chunkFileNames: 'assets/[name]-[hash].js',
        assetFileNames: (info) => {
          // Keep admin assets scoped to dist/admin/
          if (info.name?.includes('admin')) return 'admin/assets/[name]-[hash][extname]';
          return 'assets/[name]-[hash][extname]';
        },
      },
    },
  },
  server: {
    port: 5173,
    host: '0.0.0.0',
    proxy: {
      '/admin/events': {
        target: 'http://localhost:8765',
        changeOrigin: true,
      },
      '/admin': {
        target: 'http://localhost:8765',
        changeOrigin: true,
      },
      '/health': {
        target: 'http://localhost:8765',
        changeOrigin: true,
      },
      '/pair': {
        target: 'http://localhost:8765',
        changeOrigin: true,
      },
      '/api': {
        target: 'http://localhost:8765',
        rewrite: (p) => p.replace(/^\/api/, ''),
      },
      '/ws': {
        target: 'ws://localhost:8765',
        ws: true,
      },
    },
  },
});
