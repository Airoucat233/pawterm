#!/usr/bin/env bash
# install.sh — PawTerm one-liner installer
#
# macOS  → downloads PawTerm.app from the latest GitHub release,
#           installs it to /Applications, and opens it.
#           The Mac App manages pawterm-server automatically.
#
# Linux  → installs pawterm-server via npm, registers it as a
#           systemd service, and starts it.
#
# Usage: curl -fsSL https://raw.githubusercontent.com/Airoucat233/pawterm/main/install.sh | bash
set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
GREY='\033[0;90m'
RESET='\033[0m'

ok()   { printf "${GREEN}✓${RESET} %s\n" "$*"; }
warn() { printf "${YELLOW}!${RESET} %s\n" "$*"; }
err()  { printf "${RED}✗${RESET} %s\n" "$*" >&2; }
info() { printf "${GREY}  %s${RESET}\n" "$*"; }

printf "\n"
printf "${GREEN}╔══════════════════════════════════════╗${RESET}\n"
printf "${GREEN}║       PawTerm — auto installer       ║${RESET}\n"
printf "${GREEN}╚══════════════════════════════════════╝${RESET}\n"
printf "\n"

OS="$(uname -s)"

# ═══════════════════════════════════════════════════════════════
# macOS — install pawterm-server via npm, then install PawTerm.app
# ═══════════════════════════════════════════════════════════════
if [ "$OS" = "Darwin" ]; then
  info "Platform: macOS"
  printf "\n"

  # 1. Node 20+ check
  need_node_version=20
  node_ok() {
    if command -v node >/dev/null 2>&1; then
      local v
      v="$(node -e 'process.stdout.write(String(process.versions.node.split(".")[0]))')"
      [ "$v" -ge "$need_node_version" ] 2>/dev/null
    else
      return 1
    fi
  }

  if node_ok; then
    ok "Node $(node --version) found"
  else
    err "Node $need_node_version+ not found."
    printf "\n"
    printf "  Install Node.js via Homebrew:\n"
    printf "    ${YELLOW}brew install node@20${RESET}\n"
    printf "  Or download from: ${YELLOW}https://nodejs.org/${RESET}\n"
    printf "  Then re-run this installer.\n\n"
    exit 1
  fi

  # 2. claude CLI check
  if command -v claude >/dev/null 2>&1; then
    ok "claude CLI found: $(claude --version 2>/dev/null || true)"
  else
    warn "claude CLI not found."
    printf "\n"
    printf "  PawTerm bridges your phone to Claude Code, so the claude CLI must\n"
    printf "  be installed and logged in before the server is useful.\n"
    printf "\n"
    printf "    ${YELLOW}npm install -g @anthropic-ai/claude-code${RESET}\n"
    printf "    ${YELLOW}claude login${RESET}\n"
    printf "\n"
    printf "  Then re-run this installer.\n\n"
    exit 1
  fi

  # 3. Install / upgrade pawterm-server
  info "Installing pawterm-server@latest …"
  npm install -g pawterm-server@latest
  ok "pawterm-server installed: $(pawterm-server --version 2>/dev/null || true)"

  # 4. Register service (do not start — user starts via Mac App or CLI)
  info "Registering pawterm-server as a launchd service …"
  pawterm-server install
  ok "Service registered (auto-starts at login)"

  # 5. Install PawTerm.app
  printf "\n"
  info "Installing PawTerm.app from the latest GitHub release …"
  printf "\n"

  RELEASE_API="https://api.github.com/repos/Airoucat233/pawterm/releases/latest"
  ZIP_URL="$(curl -fsSL "$RELEASE_API" \
    | grep '"browser_download_url"' \
    | grep 'mac\.zip"' \
    | tail -1 \
    | sed 's/.*"browser_download_url": *"\([^"]*\)".*/\1/')"

  if [ -z "$ZIP_URL" ]; then
    err "Could not find a mac.zip in the latest release."
    info "Download manually: https://github.com/Airoucat233/pawterm/releases/latest"
    exit 1
  fi

  ZIP_NAME="$(basename "$ZIP_URL")"
  TMP_DIR="$(mktemp -d)"
  ZIP_PATH="$TMP_DIR/$ZIP_NAME"

  info "Downloading $ZIP_NAME …"
  curl -fsSL --progress-bar -o "$ZIP_PATH" "$ZIP_URL"
  ok "Downloaded"

  info "Extracting …"
  unzip -q "$ZIP_PATH" -d "$TMP_DIR"

  APP_SRC="$(find "$TMP_DIR" -maxdepth 2 -name "*.app" | head -1)"
  if [ -z "$APP_SRC" ]; then
    err "No .app found in $ZIP_NAME"
    exit 1
  fi

  APP_NAME="$(basename "$APP_SRC")"
  APP_DEST="/Applications/$APP_NAME"

  if [ -d "$APP_DEST" ]; then
    info "Removing existing $APP_DEST …"
    rm -rf "$APP_DEST"
  fi

  info "Installing to $APP_DEST …"
  mv "$APP_SRC" "$APP_DEST"
  xattr -d com.apple.quarantine "$APP_DEST" 2>/dev/null || true
  rm -rf "$TMP_DIR"
  ok "$APP_NAME installed"

  info "Launching $APP_NAME …"
  open "$APP_DEST"

  printf "\n"
  printf "${GREEN}═══════════════════════════════════════════${RESET}\n"
  printf "${GREEN}  PawTerm is ready!  Next steps:           ${RESET}\n"
  printf "${GREEN}═══════════════════════════════════════════${RESET}\n"
  printf "\n"
  printf "  Click the menu bar icon to start the server,\n"
  printf "  or run: ${YELLOW}pawterm-server start${RESET}\n"
  printf "\n"
  printf "  📱  ${YELLOW}Install the phone app:${RESET}\n"
  printf "      https://github.com/Airoucat233/pawterm/releases/latest\n"
  printf "      (grab the *-arm64-v8a.apk file)\n"
  printf "\n"
  printf "  🔗  Open PawTerm on your phone → tap Scan LAN → Pair\n"
  printf "\n"
  ok "Done. Enjoy PawTerm!"
  printf "\n"
  exit 0
fi

# ═══════════════════════════════════════════════════════════════
# Linux — install pawterm-server as a systemd service via npm
# ═══════════════════════════════════════════════════════════════
if [ "$OS" = "Linux" ]; then
  info "Platform: Linux"
  printf "\n"

  # 1. Node 20+ check
  need_node_version=20
  node_ok() {
    if command -v node >/dev/null 2>&1; then
      local v
      v="$(node -e 'process.stdout.write(String(process.versions.node.split(".")[0]))')"
      [ "$v" -ge "$need_node_version" ] 2>/dev/null
    else
      return 1
    fi
  }

  if node_ok; then
    ok "Node $(node --version) found"
  else
    warn "Node $need_node_version+ not found — attempting to install via nvm …"
    if [ -z "${NVM_DIR:-}" ] && ! command -v nvm >/dev/null 2>&1; then
      curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
      export NVM_DIR="$HOME/.nvm"
      # shellcheck disable=SC1091
      [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
    else
      export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
      # shellcheck disable=SC1091
      [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
    fi
    nvm install 20 && nvm use 20
    if ! node_ok; then
      err "Node $need_node_version+ still not available."
      info "Install manually: https://nodejs.org"
      exit 1
    fi
    ok "Node $(node --version) ready"
  fi

  # 2. claude CLI check
  if command -v claude >/dev/null 2>&1; then
    ok "claude CLI found: $(claude --version 2>/dev/null || true)"
  else
    warn "claude CLI not found."
    printf "\n"
    printf "  PawTerm bridges your phone to Claude Code, so the claude CLI must\n"
    printf "  be installed and logged in before the server is useful.\n"
    printf "\n"
    printf "    ${YELLOW}npm install -g @anthropic-ai/claude-code${RESET}\n"
    printf "    ${YELLOW}claude login${RESET}\n"
    printf "\n"
    printf "  Then re-run this installer.\n\n"
    exit 1
  fi

  # 3. Install pawterm-server
  info "Installing pawterm-server@latest …"
  npm install -g pawterm-server@latest
  ok "pawterm-server installed: $(pawterm-server --version 2>/dev/null || true)"

  # 4. Register + start service
  info "Registering pawterm-server as a systemd service …"
  pawterm-server install
  ok "Service registered (auto-starts at login)"
  info "Starting pawterm-server …"
  pawterm-server start
  ok "Service started"

  # 5. Wait for /health
  HEALTH_URL="http://localhost:8765/health"
  TIMEOUT=30
  elapsed=0
  printf "  Waiting for server to be ready"
  while true; do
    if curl -sf "$HEALTH_URL" >/dev/null 2>&1; then
      printf "\n"
      ok "Server is ready at $HEALTH_URL"
      break
    fi
    if [ "$elapsed" -ge "$TIMEOUT" ]; then
      printf "\n"
      err "Server did not become ready within ${TIMEOUT}s."
      info "Check logs: pawterm-server logs"
      exit 1
    fi
    printf "."
    sleep 1
    elapsed=$((elapsed + 1))
  done

  printf "\n"
  printf "${GREEN}═══════════════════════════════════════════${RESET}\n"
  printf "${GREEN}  PawTerm server is up!  Next steps:       ${RESET}\n"
  printf "${GREEN}═══════════════════════════════════════════${RESET}\n"
  printf "\n"
  printf "  📱  ${YELLOW}Install the phone app:${RESET}\n"
  printf "      https://github.com/Airoucat233/pawterm/releases/latest\n"
  printf "      (grab the *-arm64-v8a.apk file)\n"
  printf "\n"
  printf "  🔗  Open PawTerm on your phone → tap Scan LAN → Pair\n"
  printf "\n"
  printf "  ℹ️   Server commands: start / stop / restart / logs / status\n"
  printf "      Run ${GREY}pawterm-server help${RESET} for the full list.\n"
  printf "\n"
  ok "Done. Enjoy PawTerm!"
  printf "\n"
  exit 0
fi

err "Unsupported OS: $OS"
info "PawTerm supports macOS and Linux. For Windows see install.bat."
exit 1
