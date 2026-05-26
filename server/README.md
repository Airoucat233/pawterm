# pawterm-server

> Bridge server for [PawTerm](https://github.com/Airoucat233/pawterm) — lets the Android app control Claude Code on your dev machine.

## Requirements

- Node 20+
- [`claude` CLI](https://docs.anthropic.com/en/docs/claude-code) installed and logged in

## Quick start (foreground)

```bash
npx pawterm-server
```

First run creates `~/.config/pawterm/config.json`. Edit it to add your project paths, then restart.

On startup the server prints the Web Admin URL. Open it to manage pairing.
If the web admin bundle is not built yet, `/admin` shows a small placeholder page.

For a local authenticated browser session, run:

```bash
pawterm-server admin
```

## Run as a background service (macOS / Linux)

```bash
npm install -g pawterm-server
pawterm-server install        # register + start; auto-starts at login
pawterm-server logs           # tail logs to find the Web Admin URL / connection info
```

Prerelease server builds use the same global package identity and replace the
installed server:

```bash
npm install -g pawterm-server@prerelease
pawterm-server restart
```

The npm package includes the built Web Admin bundle under `dist-web/`.

| Command | Description |
|---|---|
| `install` | Install and start as a background service |
| `uninstall` | Remove the background service |
| `start` | Start the service |
| `stop` | Stop the service |
| `restart` | Restart the service |
| `update` | Update to latest version and restart |
| `status` | Show whether the service is running |
| `logs [n]` | Tail service logs, default last 50 lines |
| `admin` | Open Web Admin with a short-lived login code |
| `--version` | Print installed version |
| `help` | Show all commands |

## Config

`~/.config/pawterm/config.json`:

```json
{
  "host": "0.0.0.0",
  "port": 8765,
  "projects": [
    { "name": "my-project", "path": "~/code/my-project" }
  ]
}
```

Config path resolution:

1. `PAWTERM_CONFIG=/path/to/config.json` for one-off foreground/dev/test runs.
2. `~/.config/pawterm/active-config`, managed by `pawterm-server use <path>`, for the installed background service.
3. `~/.config/pawterm/config.json` as the default.

Supported `config.json` keys:

| Key | Required | Notes |
|---|---:|---|
| `host` | no | Defaults to `0.0.0.0`. |
| `port` | no | Defaults to `8765`. |
| `projects` | no | Project allow-list. Each item is `{ "name"?: string, "path": string }`; `~` is expanded. |
| `log_level` | no | Defaults to `info`; can be overridden by `PAWTERM_LOG_LEVEL`. |
| `log_format` | no | `pretty` or `json`; can be overridden by `PAWTERM_LOG_FORMAT`. |
| `log_file` | no | File path or `null`; can be overridden by `PAWTERM_LOG_FILE`. |
| `token` | no | Admin pairing token. Generated and persisted when omitted. |
| `server_id` | no | Stable server identity. Generated and persisted when omitted. |
| `paired_devices` | no | Managed by pairing flow; do not hand-edit in normal development. |
| `admin_password_hash` | no | Hashed admin password. Managed by Web Admin or `pawterm-server password set`; do not hand-edit. |
| `admin_password_set_at` | no | Timestamp for the current admin password hash. |
| `password` | no | Legacy plaintext password key; accepted on read, replaced by `admin_password_hash` when changed. |

Minimal local development files:

`server/config.json`:

```json
{
  "port": 8765,
  "projects": [
    { "path": "/Users/you/code/my-project" }
  ]
}
```

`server/config.test.json`:

```json
{
  "port": 8766,
  "projects": [
    { "path": "/Users/you/code/my-project" }
  ]
}
```

## Connect

On startup the server prints the Web Admin URL. Opening it directly shows the
login screen. `pawterm-server admin` and the Mac app use the local root token to
create a short-lived `admin_login_code`; the browser exchanges it for an
`admin_access_token` and then sends `Authorization: Bearer <aat-...>` to admin
APIs. Web Admin renews the access token before expiry; after the maximum
session lifetime, open Admin again from the CLI or Mac app.

- **Foreground**: run `pawterm-server admin`, or open the printed `/admin` URL and enter the local admin token/password
- **Background service**: run `pawterm-server logs` to see it, or open PawTerm → Add connection → `http://<your-machine-ip>:8765`

Over Tailscale: `http://100.x.x.x:8765`

## API endpoints

| Path | Description |
|---|---|
| `GET /health` | Health check |
| `GET /projects` | Project whitelist |
| `GET /sessions?cwd=...` | List sessions |
| `GET /chat/:id/events` | SSE event stream |
| `WS  /ws/shell` | PTY byte stream |

Full protocol: [`packages/shared/src/protocol.ts`](https://github.com/Airoucat233/pawterm/blob/main/packages/shared/src/protocol.ts)
