import react from '@vitejs/plugin-react';
import { defineConfig } from 'vite';

export default defineConfig({
  plugins: [
    react(),
    {
      name: 'pawterm-spa-dev-route',
      configureServer(server) {
        server.middlewares.use((req, res, next) => {
          if (req.url === '/' || req.url?.startsWith('/?')) {
            res.statusCode = 302;
            res.setHeader('Location', '/admin');
            res.end();
            return;
          }
          next();
        });
      },
    },
  ],
  server: {
    port: 5173,
    host: '0.0.0.0',
    proxy: {
      '/api': {
        target: 'http://localhost:8765',
      },
      '/ws': {
        target: 'ws://localhost:8765',
        ws: true,
      },
    },
  },
});
