#!/usr/bin/env bash
# install.sh — PawTerm one-liner installer (macOS + Linux)
# Usage: curl -fsSL https://raw.githubusercontent.com/Airoucat233/pawterm/main/install.sh | bash
set -euo pipefail

# ---------------------------------------------------------------------------
# ANSI colours
# ---------------------------------------------------------------------------
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
GREY='\033[0;90m'
RESET='\033[0m'

ok()   { printf "${GREEN}✓${RESET} %s\n" "$*"; }
warn() { printf "${YELLOW}!${RESET} %s\n" "$*"; }
err()  { printf "${RED}✗${RESET} %s\n" "$*" >&2; }
info() { printf "${GREY}  %s${RESET}\n" "$*"; }

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
printf "\n"
printf "${GREEN}╔══════════════════════════════════════╗${RESET}\n"
printf "${GREEN}║       PawTerm — auto installer       ║${RESET}\n"
printf "${GREEN}╚══════════════════════════════════════╝${RESET}\n"
printf "\n"

# ---------------------------------------------------------------------------
# 1. OS + arch detection
# ---------------------------------------------------------------------------
OS="$(uname -s)"
ARCH="$(uname -m)"

case "$OS" in
  Darwin) PLATFORM="macOS" ;;
  Linux)  PLATFORM="Linux" ;;
  *)
    err "Unsupported OS: $OS"
    info "PawTerm supports macOS and Linux. For Windows see install.bat."
    exit 1
    ;;
esac

info "Platform: $PLATFORM ($ARCH)"

# ---------------------------------------------------------------------------
# 2. Node 20+ detection / installation
# ---------------------------------------------------------------------------
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
  NODE_VERSION="$(node --version)"
  ok "Node $NODE_VERSION found"
else
  warn "Node $need_node_version+ not found — attempting to install"

  if [ "$PLATFORM" = "macOS" ]; then
    if command -v brew >/dev/null 2>&1; then
      info "Installing node@20 via Homebrew …"
      brew install node@20
      # brew links node@20 as keg-only; add it to PATH for this session
      BREW_NODE_BIN="$(brew --prefix node@20)/bin"
      export PATH="$BREW_NODE_BIN:$PATH"
    else
      err "Homebrew not found."
      warn "Install Homebrew first:"
      info '  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
      info "Then re-run this installer."
      exit 1
    fi
  else
    # Linux — use nvm
    if [ -z "${NVM_DIR:-}" ] && ! command -v nvm >/dev/null 2>&1; then
      warn "nvm not found — installing nvm …"
      NVM_INSTALL_URL="https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh"
      curl -fsSL "$NVM_INSTALL_URL" | bash
      # Source nvm for this session
      export NVM_DIR="$HOME/.nvm"
      # shellcheck disable=SC1091
      [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
    else
      export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
      # shellcheck disable=SC1091
      [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
    fi
    info "Installing Node 20 via nvm …"
    nvm install 20
    nvm use 20
  fi

  if ! node_ok; then
    err "Node $need_node_version+ still not available after install attempt."
    info "Please install Node 20+ manually: https://nodejs.org"
    exit 1
  fi
  ok "Node $(node --version) ready"
fi

# ---------------------------------------------------------------------------
# 3. claude CLI check
# ---------------------------------------------------------------------------
if command -v claude >/dev/null 2>&1; then
  ok "claude CLI found: $(claude --version 2>/dev/null || true)"
else
  warn "claude CLI not found."
  printf "\n"
  printf "  PawTerm bridges your phone to Claude Code, so the claude CLI must\n"
  printf "  be installed and logged in before the server is useful.\n"
  printf "\n"
  printf "  Install and log in:\n"
  printf "    ${YELLOW}npm install -g @anthropic-ai/claude-code${RESET}\n"
  printf "    ${YELLOW}claude login${RESET}\n"
  printf "\n"
  printf "  Then re-run this installer.\n"
  printf "\n"
  exit 1
fi

# ---------------------------------------------------------------------------
# 4. Install pawterm-server
# ---------------------------------------------------------------------------
info "Installing pawterm-server@latest …"
npm install -g pawterm-server@latest
ok "pawterm-server installed: $(pawterm-server --version 2>/dev/null || true)"

# ---------------------------------------------------------------------------
# 5. Register as a system service
# ---------------------------------------------------------------------------
info "Registering pawterm-server as a system service …"
pawterm-server install
ok "Service registered (auto-starts at login)"

# ---------------------------------------------------------------------------
# 6. Start the service
# ---------------------------------------------------------------------------
info "Starting pawterm-server …"
pawterm-server start
ok "Service started"

# ---------------------------------------------------------------------------
# 7. Wait for /health (30 s timeout)
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# 8. Open admin panel
# ---------------------------------------------------------------------------
CONFIG_FILE="$HOME/.config/pawterm/config.json"
ADMIN_TOKEN=""

if [ -f "$CONFIG_FILE" ]; then
  # Extract "token": "VALUE" without jq (grep + sed)
  ADMIN_TOKEN="$(grep -o '"token"[[:space:]]*:[[:space:]]*"[^"]*"' "$CONFIG_FILE" \
    | sed 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' \
    | head -1 || true)"
fi

if [ -n "$ADMIN_TOKEN" ]; then
  ADMIN_URL="http://localhost:8765/admin?token=${ADMIN_TOKEN}"
else
  ADMIN_URL="http://localhost:8765/admin"
fi

info "Opening admin panel: $ADMIN_URL"

case "$PLATFORM" in
  macOS) open "$ADMIN_URL" 2>/dev/null || true ;;
  Linux) xdg-open "$ADMIN_URL" 2>/dev/null || true ;;
esac

# ---------------------------------------------------------------------------
# 9. Next steps
# ---------------------------------------------------------------------------
printf "\n"
printf "${GREEN}═══════════════════════════════════════════${RESET}\n"
printf "${GREEN}  PawTerm server is up!  Next steps:       ${RESET}\n"
printf "${GREEN}═══════════════════════════════════════════${RESET}\n"
printf "\n"
printf "  📱  ${YELLOW}Install the Android app on your phone:${RESET}\n"
printf "      https://github.com/Airoucat233/pawterm/releases/latest\n"
printf "      (grab the *-arm64-v8a.apk file)\n"
printf "\n"
printf "  🔗  ${YELLOW}Pair your phone:${RESET}\n"
printf "      Open PawTerm → tap Scan LAN → select your computer\n"
printf "      → tap Pair → approve in the browser window that just opened\n"
printf "\n"
printf "  🔑  ${YELLOW}Admin panel:${RESET} $ADMIN_URL\n"
printf "\n"
printf "  ℹ️   Server commands: start / stop / restart / logs / status\n"
printf "      Run ${GREY}pawterm-server help${RESET} for the full list.\n"
printf "\n"
ok "Done. Enjoy PawTerm!"
printf "\n"
