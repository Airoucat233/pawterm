#!/bin/bash
# PawTerm — macOS status bar indicator for SwiftBar.
#
# Install:
#   brew install --cask swiftbar
#   mkdir -p ~/SwiftBar/plugins
#   ln -s "$(pwd)/scripts/swiftbar/pawterm.5s.sh" ~/SwiftBar/plugins/pawterm.5s.sh
#   chmod +x ~/SwiftBar/plugins/pawterm.5s.sh
#
# Filename convention `<name>.<interval>.sh` — SwiftBar refreshes every 5s.
#
# What it shows:
#   🐾⚫           — server offline
#   🐾 N devices  — server running, N paired devices
#
# Submenu links open the web admin (with token) directly in the default browser.

set -u

CONFIG="${PAWTERM_CONFIG:-$HOME/.config/pawterm/config.json}"

# Probe localhost — server-side discovery starts at 127.0.0.1:<port>
PORT=$(/usr/bin/grep -m1 '"port"' "$CONFIG" 2>/dev/null | /usr/bin/awk -F'[:,]' '{gsub(/ /,"",$2); print $2}')
PORT="${PORT:-8765}"
TOKEN=$(/usr/bin/grep -m1 '"token"' "$CONFIG" 2>/dev/null | /usr/bin/sed -E 's/.*"token": *"([^"]+)".*/\1/')

if [ -z "$TOKEN" ]; then
  echo "🐾⚫"
  echo "---"
  echo "Config missing | color=red"
  echo "Expected: $CONFIG"
  exit 0
fi

HEALTH=$(/usr/bin/curl -sf --max-time 1 "http://127.0.0.1:$PORT/health" 2>/dev/null)
if [ -z "$HEALTH" ]; then
  echo "🐾⚫"
  echo "---"
  echo "Server offline | color=#888"
  echo "Port: $PORT"
  exit 0
fi

DEVICES_JSON=$(/usr/bin/curl -sf --max-time 1 -H "Authorization: Bearer $TOKEN" \
  "http://127.0.0.1:$PORT/admin/devices" 2>/dev/null)
DEVICE_COUNT=$(echo "$DEVICES_JSON" | /usr/bin/grep -c '"deviceId"' 2>/dev/null)
DEVICE_COUNT="${DEVICE_COUNT:-0}"

ADMIN_URL="http://127.0.0.1:$PORT/admin?token=$TOKEN"

if [ "$DEVICE_COUNT" -gt 0 ]; then
  echo "🐾 $DEVICE_COUNT"
else
  echo "🐾"
fi
echo "---"
echo "PawTerm — :$PORT | color=#7dd3fc"
echo "$DEVICE_COUNT paired devices"
echo "---"
echo "Open admin… | href=$ADMIN_URL"
echo "Show QR | href=$ADMIN_URL#qr"
echo "---"
echo "Refresh | refresh=true"
