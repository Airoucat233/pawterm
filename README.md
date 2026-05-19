# PawTerm

> Control AI coding assistants from your phone.  
> Drive Claude Code (and more) while your dev machine does the actual work.

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
![Flutter](https://img.shields.io/badge/Flutter-Android%20%7C%20iOS-02569B?logo=flutter&logoColor=white)
![Node](https://img.shields.io/badge/node-%E2%89%A520-339933?logo=node.js&logoColor=white)

A bridge server runs on your dev machine (where `claude` CLI is installed). The phone app connects over LAN or Tailscale and gives you a full mobile interface: chat, real terminal, session history, file browser.

---

## Quick Start

### 🖥️ Install the Server

**🍎 macOS — Mac App (recommended)**

Download `PawTerm.app` from [**Releases**](../../releases/latest) and open it. It automatically installs and starts `pawterm-server` in the background. The menu bar icon shows server status and version at a glance.

**⌨️ Without Mac App**

Quick test (no install needed):
```bash
npx pawterm-server
```

Background service that auto-starts at login:
```bash
npm install -g pawterm-server
pawterm-server install   # register as system service (launchd / systemd)
pawterm-server start
```

> Run `pawterm-server help` for all service commands: `start` / `stop` / `restart` / `update` / `logs` / `status`

First run creates `~/.config/pawterm/config.json` — edit it to add your project paths, then restart.

---

### 📱 Get the Phone App

Grab the latest APK from [**Releases**](../../releases/latest) and install it on your Android phone.

> Enable **"Install unknown apps"** in Android settings if prompted.

iOS support is planned.

---

### 🔗 Connect

Open the app → tap **Scan LAN** → select your computer → tap **Pair** → done.

| Network | How to connect |
|---------|----------------|
| Same LAN | Auto-discovered via **Scan LAN** |
| Tailscale | `http://100.x.x.x:8765` |
| Android emulator | `http://10.0.2.2:8765` |

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
  "port": 8765,
  "permission_mode": "acceptEdits",
  "projects": [
    { "name": "my-project", "path": "~/code/my-project" }
  ]
}
```

---

## Build from Source

```bash
# Server
git clone https://github.com/Airoucat233/pawterm.git
cd pawterm && pnpm install
cp server/config.example.json server/config.json
pnpm dev:server

# Phone app
cd app && flutter pub get
flutter run                  # debug on connected device
bash scripts/build-apk.sh   # versioned release APK

# Mac app
cd mac && bash build.sh --install
```

---

## License

[MIT](LICENSE)
