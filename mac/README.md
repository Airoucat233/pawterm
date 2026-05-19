# PawTerm Mac App

A native macOS menu-bar app that manages your local `pawterm-server` and shows connection status at a glance.

## Prerequisites

`pawterm-server` must be installed first:

```bash
bash install.sh   # from the repo root
```

## Build

```bash
cd mac
bash build.sh
```

Requires Xcode Command Line Tools (`xcode-select --install`). Produces `PawTerm.app` in the `mac/` directory.

## Install

```bash
mv PawTerm.app /Applications/
xattr -d com.apple.quarantine /Applications/PawTerm.app
open /Applications/PawTerm.app
```

## Gatekeeper (unsigned app)

If macOS blocks the app on first launch:

1. Right-click `PawTerm.app` in Finder
2. Choose **Open**
3. Click **Open** in the dialog

Or run the `xattr` command above before opening.

## What it does

- Shows a `pawprint.fill` icon in the menu bar
  - Green — server running, at least one paired device
  - Blue — server running, no paired devices
  - Grey — server not running
- Menu lets you start/stop/restart the server
- "Open Admin…" and "Show QR…" open the web admin in your browser

## Uninstall

Drag `PawTerm.app` from `/Applications` to the Trash. No background services are installed.

## Distributing

Zip the app for sharing:

```bash
cd mac
zip -r PawTerm.zip PawTerm.app
```

Recipients need to run the `xattr` command or use the right-click → Open flow.
