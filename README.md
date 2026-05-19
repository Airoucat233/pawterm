# PawTerm

> Control AI coding assistants from your phone.  
> Drive Claude Code (and more) while your dev machine does the actual work.

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
![Flutter](https://img.shields.io/badge/Flutter-Android-02569B?logo=flutter&logoColor=white)
![Node](https://img.shields.io/badge/node-%E2%89%A520-339933?logo=node.js&logoColor=white)

A small bridge server runs on your dev machine (where `claude` CLI is installed). The Android app connects over LAN or Tailscale and gives you a full mobile interface: chat, real terminal, session history, file browser.

## Install

### 🍎 macOS / 🐧 Linux — One-liner

```bash
curl -fsSL https://raw.githubusercontent.com/Airoucat233/pawterm/main/install.sh | bash
```

Or download `install.sh`, inspect it, then `bash install.sh`.

The script checks for Node 20+ and the `claude` CLI, installs `pawterm-server`, registers it as a system service (launchd on macOS, systemd on Linux), waits for it to be ready, and opens the admin panel in your browser automatically.

### 🪟 Windows (experimental)

Download [`install.bat`](install.bat) and double-click. **Not tested** — the shell tab feature requires `node-pty` which needs `windows-build-tools`.

### 🛡️ Manual (advanced)

Requires Node 20+ and `claude` CLI logged in.

```bash
npm install -g pawterm-server
pawterm-server install    # register as a system service (auto-starts at login)
pawterm-server start
```

First run creates `~/.config/pawterm/config.json` — edit it to add your project paths, then restart.

> Other service commands: `start` / `stop` / `restart` / `update` / `logs` / `status` — run `pawterm-server help` for the full list.

### 📱 Phone app

Grab the latest `pawterm-*-arm64-v8a.apk` from [**Releases**](../../releases/latest) and install it on your Android phone.

> Enable **"Install unknown apps"** in Android settings if prompted.

Open the app → tap **Scan LAN** → select your computer → tap **Pair** → approve in the browser window that pops up on your computer.

Or add the connection manually:

| Network | Address |
|---------|---------|
| Same LAN | `http://192.168.x.x:8765` |
| Tailscale | `http://100.x.x.x:8765` |
| Android emulator | `http://10.0.2.2:8765` |

## Features

- **Chat** — full Claude conversation with streaming, thinking blocks, tool cards (Edit / Bash / Read / TodoWrite / …)
- **Terminal** — real PTY shell via node-pty + xterm; virtual keyboard bar with common keys
- **Sessions** — browse, resume, or start new Claude Code sessions per project
- **File browser** — view, open, share files from your project directories
- **Model switch** — swap between Opus / Sonnet / Haiku at runtime
- **Todo tracking** — live task progress chip with fireworks on completion 🎉

## Server config

`~/.config/pawterm/config.json` whitelists which directories the app can access:

```json
{
  "host": "0.0.0.0",
  "port": 8765,
  "permission_mode": "acceptEdits",
  "projects": [
    { "name": "my-project", "path": "~/code/my-project" }
  ]
}
```

## Build from source

```bash
# Server
git clone https://github.com/Airoucat233/pawterm.git
cd pawterm && pnpm install
cp server/config.example.json server/config.json
pnpm dev:server

# Android app
cd app
flutter pub get
flutter run                  # debug on connected device
./scripts/build-apk.sh       # versioned release APK
```

## License

[MIT](LICENSE)
