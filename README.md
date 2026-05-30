# PawTerm

> Control AI coding assistants from your phone.  
> Drive Claude Code (and more) while your dev machine does the actual work.

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
![Flutter](https://img.shields.io/badge/Flutter-Android%20%7C%20iOS-02569B?logo=flutter&logoColor=white)
![Node](https://img.shields.io/badge/node-%E2%89%A520-339933?logo=node.js&logoColor=white)

A bridge server runs on your dev machine (where `claude` CLI is installed). The phone app connects over LAN or Tailscale and gives you a full mobile interface: chat, real terminal, session history, file browser.

---

## Quick Start

### Install the Server

**One-liner (macOS / Linux)**

```bash
curl -fsSL https://raw.githubusercontent.com/Airoucat233/pawterm/main/install.sh | bash
```

Or download [`install.sh`](install.sh), inspect it, then `bash install.sh`.

The installer checks Node 20+ and the `claude` CLI, installs `pawterm-server` from npm, registers it as a background service, starts it, and waits for `/health` to become ready.

| Platform | Service manager |
|----------|-----------------|
| **macOS** | `launchd`, auto-starts at login |
| **Linux** | `systemd`, auto-starts at login |

After installation, open the local Web Admin with:

```bash
pawterm-server admin
```

Run `pawterm-server help` for service commands: `start` / `stop` / `restart` / `update` / `logs` / `status`.

### Optional Mac App

On macOS, the installer can also install `PawTerm.app`, a menu bar manager for starting, stopping, and opening the server. The server does not require the Mac App.

Interactive installs ask whether to install it. For scripted installs:

```bash
curl -fsSL https://raw.githubusercontent.com/Airoucat233/pawterm/main/install.sh |
  INSTALL_MAC_APP=1 bash
```

If `APP_VERSION` is not set, the first Mac App install follows the server channel selected by `VERSION`. After that, the Mac App controls its own update channel.

### Prerelease Server

Use the prerelease channel when you want the newest test build:

```bash
curl -fsSL https://raw.githubusercontent.com/Airoucat233/pawterm/main/install.sh |
  VERSION=prerelease bash
```

To install the prerelease server and also install the matching prerelease Mac App on first setup:

```bash
curl -fsSL https://raw.githubusercontent.com/Airoucat233/pawterm/main/install.sh |
  VERSION=prerelease INSTALL_MAC_APP=1 bash
```

You can override only the Mac App channel with `APP_VERSION=latest` or `APP_VERSION=prerelease`.

**Windows (experimental)**

Download [`install.bat`](install.bat) and double-click. **Not tested** — the shell tab feature requires `node-pty` which needs `windows-build-tools`.

**Manual install (Linux / headless)**

Requires Node 20+ and `claude` CLI logged in.

Quick test (no install needed):
```bash
npx pawterm-server
```

Background service that auto-starts at login:
```bash
npm install -g pawterm-server
pawterm-server install
pawterm-server start
```

First run creates `~/.config/pawterm/config.json` — edit it to add your project paths, then restart.

### Get the Phone App

Grab the latest APK from [**Releases**](../../releases/latest) and install it on your Android phone.

> Enable **"Install unknown apps"** in Android settings if prompted.

iOS support is planned.

### Connect

Open the app → tap **Scan LAN** → select your computer → tap **Pair** → done.

| Network | How to connect |
|---------|----------------|
| Same LAN | Auto-discovered via **Scan LAN** |
| Tailscale | `http://100.x.x.x:18765` |
| Android emulator | `http://10.0.2.2:18765` |

---

## Features

- **Chat** — full Claude conversation with streaming, thinking blocks, tool cards (Edit / Bash / Read / TodoWrite / …)
- **Terminal** — real PTY shell via node-pty + xterm; virtual keyboard bar with common keys
- **Sessions** — browse, resume, or start new Claude Code sessions per project
- **File browser** — view, open, share files from your project directories
- **Model switch** — swap between Opus / Sonnet / Haiku at runtime
- **Todo tracking** — live task progress chip with fireworks on completion 🎉

---

## Server Config

`~/.config/pawterm/config.json`:

```json
{
  "host": "0.0.0.0",
  "port": 18765,
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
| `port` | no | Defaults to `18765` for installed/stable server builds. Local `pnpm dev` uses `server/config.json` on `8765`. |
| `projects` | no | Project allow-list. Each item is `{ "name"?: string, "path": string }`; `~` is expanded. |
| `log_level` | no | Defaults to `info`; can be overridden by `PAWTERM_LOG_LEVEL`. |
| `log_format` | no | `pretty` or `json`; can be overridden by `PAWTERM_LOG_FORMAT`. |
| `log_file` | no | File path or `null`; can be overridden by `PAWTERM_LOG_FILE`. |
| `token` | no | Admin pairing token. Generated and persisted when omitted. |
| `server_id` | no | Stable server identity. Generated and persisted when omitted. |
| `admin_access_tokens` | no | Active Web Admin Bearer tokens. Managed automatically; do not hand-edit. |
| `paired_devices` | no | Managed by pairing flow; do not hand-edit in normal development. |
| `admin_password_hash` | no | Hashed admin password. Managed by Web Admin or `pawterm-server password set`; do not hand-edit. |
| `admin_password_set_at` | no | Timestamp for the current admin password hash. |
| `password` | no | Legacy plaintext password key; accepted on read, replaced by `admin_password_hash` when changed. |

Open Web Admin locally with:

```bash
pawterm-server admin
```

This creates a short-lived `admin_login_code` and opens
`/admin?admin_login_code=...`; the browser exchanges it for an
`admin_access_token` and uses Bearer auth for admin APIs. The Web Admin renews
that access token before expiry; after the maximum session lifetime, reopen via
`pawterm-server admin` or the Mac app.

Minimal local development files:

`server/config.json`:

```json
{
  "port": 8765,
  "log_file": "../local/pawterm-server-dev.log",
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

---

## Build from Source

```bash
git clone https://github.com/Airoucat233/pawterm.git
cd pawterm && pnpm install
cp server/config.dev.example.json server/config.json
```

Common root workspace commands:

```bash
pnpm dev              # run pnpm dev:server + pnpm dev:web; asks before killing 8765 conflicts
pnpm dev:restart      # stop this repo's local dev server/web, then run pnpm dev again
pnpm dev:server       # run pawterm-server from server/config.json on 8765
pnpm dev:web          # run Vite web dev server; proxies to localhost:8765 by default
pnpm build            # build web, then package it into server/dist-web
pnpm build:all        # build server bundle, dev Android APK, and dev Mac app
pnpm build:web        # build only @pawterm/web
pnpm build:server     # build web, then build pawterm-server package
pnpm build:app        # build local dev Android APK
pnpm build:app:prod   # release APK; may prompt for version bump
pnpm build:ios        # release IPA; requires macOS/Xcode/signing
pnpm build:mac                # build local PawTermDev.app
pnpm build:mac:install        # build and install PawTermDev.app to /Applications
pnpm build:mac:prod           # release Mac zip; may prompt for version bump
pnpm release          # bump/tag; CI builds release artifacts
pnpm release:local    # create/upload GH release from local dist artifacts
pnpm release:pre      # prerelease tag flow
pnpm start:server     # run server/dist/index.js after build
pnpm typecheck        # typecheck all workspace packages
pnpm test:server      # run server tests
```

```bash
# Phone app
cd app && flutter pub get
flutter run                  # Android debug on connected device, defaults to prod flavor
bash scripts/build-apk.sh --prod  # versioned release APK

# Mac app
cd mac && bash scripts/build.sh --prod
```

---

## License

[MIT](LICENSE)
