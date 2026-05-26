# Web Admin — Server Integration Notes

## Build output

`pnpm --filter @pawterm/web build` produces:

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

`pawterm-server admin` and the Mac app open Web Admin by first asking the
server for an `admin_login_code`, then opening:

```
http://localhost:<port>/admin?admin_login_code=<alc-...>
```

The SPA exchanges that one-time code for an `admin_access_token` and uses it
as `Authorization: Bearer <aat-...>` for admin APIs. The SPA schedules
`POST /admin/access-token/renew` 10 minutes before expiry and replaces the
stored token when renewal succeeds.

## Dev proxy

During development (`pnpm --filter @pawterm/web dev`), Vite proxies `/admin/*`, `/health`, and `/pair/*` to `localhost:8765`. You can run `pnpm dev:server` + `pnpm --filter @pawterm/web dev`, open `/admin`, and enter the local admin token or password in the login screen.
