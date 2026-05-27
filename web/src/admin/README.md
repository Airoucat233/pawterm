# Web Admin — Server Integration Notes

## Build output

`pnpm --filter @pawterm/web build` produces:

```
web/dist/
  index.html          ← admin SPA entry
  assets/
    index-<hash>.js
    index-<hash>.css
```

## Server wiring

`pawterm-server admin` and the Mac app open Web Admin by first asking the
server for an `admin_login_code`, then opening:

```
http://localhost:<port>/admin?admin_login_code=<alc-...>
```

The SPA exchanges that one-time code for an `admin_access_token` and uses it
as `Authorization: Bearer <aat-...>` for admin APIs. The SPA schedules
`POST /api/admin/access-token/renew` 10 minutes before expiry and replaces the
stored token when renewal succeeds.

## Dev proxy

During development (`pnpm dev:web` or `pnpm --filter @pawterm/web dev`), the Admin page is served by Vite at `/admin`, and Admin API calls use `/api/admin/*`. Vite proxies `/api/*` to `localhost:8765` without rewriting the path.

From the repo root, `pnpm dev` starts `pnpm dev:server` and `pnpm dev:web`. If port 8765 is already occupied, it lists the listener and asks before killing it.
