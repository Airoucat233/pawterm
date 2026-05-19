# Web Admin — Server Integration Notes

## Build output

`pnpm --filter @cc/web build` produces:

```
web/dist/
  index.html          ← chat client (existing)
  assets/…
  admin.html          ← admin SPA entry
  admin/
    admin-<hash>.js
    assets/…
```

## Server wiring (to do in server/src/index.ts)

Replace the placeholder `/admin` HTML response with:

```ts
import { readFileSync } from 'fs';
import { join } from 'path';

const adminHtml = readFileSync(
  join(__dirname, '../../web/dist/admin.html'),
  'utf8'
);

fastify.get('/admin', (req, reply) => {
  reply.type('text/html').send(adminHtml);
});

// Serve admin static assets
fastify.register(import('@fastify/static'), {
  root: join(__dirname, '../../web/dist/admin'),
  prefix: '/admin/',
  decorateReply: false,
});
```

Then the server's auto-open already points to `http://localhost:<port>/admin?token=<adminToken>` — it will just work.

## Dev proxy

During development (`pnpm --filter @cc/web dev`), Vite proxies `/admin/*`, `/health`, and `/pair/*` to `localhost:8765` — so you can run `pnpm dev:server` + `pnpm --filter @cc/web dev` and open `http://localhost:5173/admin.html?token=<adminToken>` directly.
