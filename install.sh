#!/usr/bin/env bash
# install.sh — PawTerm one-liner installer
#
# Installs pawterm-server by default. On macOS, PawTerm.app is optional
# and acts as a menu bar manager for the server.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/Airoucat233/pawterm/main/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/Airoucat233/pawterm/main/install.sh | VERSION=prerelease bash
#   curl -fsSL https://raw.githubusercontent.com/Airoucat233/pawterm/main/install.sh | INSTALL_MAC_APP=1 bash
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

SERVER_CHANNEL="${VERSION:-latest}"
INSTALL_MAC_APP="${INSTALL_MAC_APP:-ask}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --latest)
      SERVER_CHANNEL="latest"
      shift
      ;;
    --prerelease)
      SERVER_CHANNEL="prerelease"
      shift
      ;;
    --version|--channel)
      if [ "$#" -lt 2 ]; then
        err "$1 requires a value: latest or prerelease"
        exit 1
      fi
      SERVER_CHANNEL="$2"
      shift 2
      ;;
    --version=*|--channel=*)
      SERVER_CHANNEL="${1#*=}"
      shift
      ;;
    --install-mac-app)
      INSTALL_MAC_APP="1"
      shift
      ;;
    --no-mac-app)
      INSTALL_MAC_APP="0"
      shift
      ;;
    *)
      err "Unknown option: $1"
      info "Supported options: --latest, --prerelease, --version latest|prerelease, --install-mac-app, --no-mac-app"
      exit 1
      ;;
  esac
done

validate_channel() {
  local name="$1"
  local value="$2"
  case "$value" in
    latest|prerelease) ;;
    *)
      err "Unsupported $name: $value"
      info "Supported channels: latest, prerelease"
      exit 1
      ;;
  esac
}

validate_channel VERSION "$SERVER_CHANNEL"
APP_CHANNEL="${APP_VERSION:-$SERVER_CHANNEL}"
validate_channel APP_VERSION "$APP_CHANNEL"

release_page_url() {
  local channel="$1"
  if [ "$channel" = "prerelease" ]; then
    printf 'https://github.com/Airoucat233/pawterm/releases\n'
  else
    printf 'https://github.com/Airoucat233/pawterm/releases/latest\n'
  fi
}

SERVER_RELEASE_PAGE_URL="$(release_page_url "$SERVER_CHANNEL")"
APP_RELEASE_PAGE_URL="$(release_page_url "$APP_CHANNEL")"

github_release_asset() {
  local release_channel="$1"
  local asset_regex="$2"
  local release_json
  if [ "$release_channel" = "latest" ]; then
    release_json="$(curl -fsSL "https://api.github.com/repos/Airoucat233/pawterm/releases/latest")"
  else
    release_json="$(curl -fsSL "https://api.github.com/repos/Airoucat233/pawterm/releases")"
  fi

  RELEASE_CHANNEL="$release_channel" ASSET_REGEX="$asset_regex" node -e '
const fs = require("fs");
const input = fs.readFileSync(0, "utf8");
const channel = process.env.RELEASE_CHANNEL;
const assetRegex = new RegExp(process.env.ASSET_REGEX);
const data = JSON.parse(input);
const releases = Array.isArray(data) ? data : [data];
const release = releases.find((item) => {
  if (item.draft) return false;
  return channel === "prerelease" ? item.prerelease : true;
});
if (!release) process.exit(2);
const asset = (release.assets || []).find((item) => assetRegex.test(item.name));
if (!asset) process.exit(3);
process.stdout.write(`${asset.browser_download_url}\n${release.html_url}\n${release.tag_name}\n`);
' <<<"$release_json"
}

node_ok() {
  local need_node_version=20
  if command -v node >/dev/null 2>&1; then
    local v
    v="$(node -e 'process.stdout.write(String(process.versions.node.split(".")[0]))')"
    [ "$v" -ge "$need_node_version" ] 2>/dev/null
  else
    return 1
  fi
}

ensure_node() {
  if node_ok; then
    ok "Node $(node --version) found"
    return 0
  fi

  if [ "$(uname -s)" = "Linux" ]; then
    warn "Node 20+ not found — attempting to install via nvm …"
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
    if node_ok; then
      ok "Node $(node --version) ready"
      return 0
    fi
  fi

  err "Node 20+ not found."
  printf "\n"
  printf "  Install Node.js via Homebrew:\n"
  printf "    ${YELLOW}brew install node@20${RESET}\n"
  printf "  Or download from: ${YELLOW}https://nodejs.org/${RESET}\n"
  printf "  Then re-run this installer.\n\n"
  exit 1
}

ensure_agent_cli() {
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
}

server_port() {
  node -e 'const fs=require("fs"), os=require("os"), path=require("path"); const p=path.join(os.homedir(), ".config", "pawterm", "config.json"); let port=18765; try { const j=JSON.parse(fs.readFileSync(p,"utf8")); if (Number.isInteger(j.port)) port=j.port; } catch {} process.stdout.write(String(port));'
}

wait_for_server() {
  local port
  port="$(server_port)"
  local health_url="http://localhost:${port}/health"
  local timeout=30
  local elapsed=0
  printf "  Waiting for server to be ready"
  while true; do
    if curl -sf "$health_url" >/dev/null 2>&1; then
      printf "\n"
      ok "Server is ready at $health_url"
      break
    fi
    if [ "$elapsed" -ge "$timeout" ]; then
      printf "\n"
      err "Server did not become ready within ${timeout}s."
      info "Check logs: pawterm-server logs"
      exit 1
    fi
    printf "."
    sleep 1
    elapsed=$((elapsed + 1))
  done
}

should_install_mac_app() {
  case "$INSTALL_MAC_APP" in
    1|true|yes|y) return 0 ;;
    0|false|no|n) return 1 ;;
    ask) ;;
    *)
      err "Unsupported INSTALL_MAC_APP: $INSTALL_MAC_APP"
      info "Use 1, 0, or ask."
      exit 1
      ;;
  esac

  if [ ! -r /dev/tty ] || [ ! -w /dev/tty ]; then
    info "Skipping PawTerm.app install. Set INSTALL_MAC_APP=1 to install it."
    return 1
  fi

  printf "\n" > /dev/tty
  printf "Install PawTerm Mac App for menu bar server management? [y/N] " > /dev/tty
  local answer
  read -r answer < /dev/tty
  case "$answer" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

install_mac_app() {
  printf "\n"
  info "Installing PawTerm.app from the $APP_CHANNEL GitHub release channel …"
  printf "\n"

  if ! RELEASE_INFO="$(github_release_asset "$APP_CHANNEL" 'mac\.zip$')"; then
    err "Could not find a mac.zip in the $APP_CHANNEL release channel."
    info "Download manually: $APP_RELEASE_PAGE_URL"
    return 1
  fi
  ZIP_URL="$(printf '%s\n' "$RELEASE_INFO" | sed -n '1p')"
  APP_RELEASE_URL="$(printf '%s\n' "$RELEASE_INFO" | sed -n '2p')"
  APP_RELEASE_TAG="$(printf '%s\n' "$RELEASE_INFO" | sed -n '3p')"

  if [ -z "$ZIP_URL" ]; then
    err "Could not find a mac.zip in the $APP_CHANNEL release channel."
    info "Download manually: $APP_RELEASE_PAGE_URL"
    return 1
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
    rm -rf "$TMP_DIR"
    return 1
  fi

  APP_NAME="$(basename "$APP_SRC")"
  APP_DEST="/Applications/$APP_NAME"

  if [ -d "$APP_DEST" ]; then
    info "Removing existing $APP_DEST …"
    pkill -f "$APP_DEST/Contents/MacOS" 2>/dev/null || true
    sleep 1
    rm -rf "$APP_DEST"
  fi

  info "Installing to $APP_DEST …"
  mv "$APP_SRC" "$APP_DEST"
  xattr -d com.apple.quarantine "$APP_DEST" 2>/dev/null || true
  rm -rf "$TMP_DIR"
  ok "$APP_NAME installed"

  if [ "$SERVER_CHANNEL" = "prerelease" ]; then
    defaults write com.airoucat.pawterm pawterm_server_prerelease_channel -bool true 2>/dev/null || true
  else
    defaults write com.airoucat.pawterm pawterm_server_prerelease_channel -bool false 2>/dev/null || true
  fi
  if [ "$APP_CHANNEL" = "prerelease" ]; then
    defaults write com.airoucat.pawterm pawterm_app_prerelease_channel -bool true 2>/dev/null || true
  else
    defaults write com.airoucat.pawterm pawterm_app_prerelease_channel -bool false 2>/dev/null || true
  fi

  info "Launching $APP_NAME …"
  open "$APP_DEST"
  INSTALLED_MAC_APP_VERSION="${APP_RELEASE_TAG:-$(echo "$ZIP_NAME" | sed 's/PawTerm-\(.*\)-mac\.zip/\1/')}"
  INSTALLED_MAC_APP_RELEASE_URL="$APP_RELEASE_URL"
}

printf "\n"
printf "${GREEN}╔══════════════════════════════════════╗${RESET}\n"
printf "${GREEN}║       PawTerm — auto installer       ║${RESET}\n"
printf "${GREEN}╚══════════════════════════════════════╝${RESET}\n"
printf "\n"

OS="$(uname -s)"
case "$OS" in
  Darwin|Linux) ;;
  *)
    err "Unsupported OS: $OS"
    info "PawTerm supports macOS and Linux. For Windows see install.bat."
    exit 1
    ;;
esac

info "Platform: $OS"
info "Server channel: $SERVER_CHANNEL"
if [ "$OS" = "Darwin" ]; then
  info "Mac App channel: $APP_CHANNEL"
fi
printf "\n"

ensure_node
ensure_agent_cli

info "Installing pawterm-server@$SERVER_CHANNEL …"
npm install -g "pawterm-server@$SERVER_CHANNEL"
ok "pawterm-server installed: $(pawterm-server --version 2>/dev/null || true)"

if [ "$OS" = "Darwin" ]; then
  info "Registering pawterm-server as a launchd service …"
else
  info "Registering pawterm-server as a systemd service …"
fi
pawterm-server install
ok "Service registered (auto-starts at login)"

info "Starting pawterm-server …"
pawterm-server start
ok "Service started"
wait_for_server

INSTALLED_MAC_APP_VERSION=""
INSTALLED_MAC_APP_RELEASE_URL=""
if [ "$OS" = "Darwin" ] && should_install_mac_app; then
  install_mac_app
fi

SERVER_VER="$(pawterm-server --version 2>/dev/null | sed 's/pawterm-server //' || echo 'unknown')"
printf "\n"
printf "${GREEN}═══════════════════════════════════════════${RESET}\n"
printf "${GREEN}  PawTerm server is ready!                 ${RESET}\n"
printf "${GREEN}═══════════════════════════════════════════${RESET}\n"
printf "\n"
printf "  Installed:\n"
printf "    pawterm-server  ${GREEN}%s${RESET}\n" "$SERVER_VER"
if [ -n "$INSTALLED_MAC_APP_VERSION" ]; then
  printf "    PawTerm.app     ${GREEN}%s${RESET}\n" "$INSTALLED_MAC_APP_VERSION"
elif [ "$OS" = "Darwin" ]; then
  printf "    PawTerm.app     ${GREY}skipped${RESET}\n"
fi
printf "\n"
printf "  Open Web Admin:\n"
printf "    ${YELLOW}pawterm-server admin${RESET}\n"
printf "\n"
printf "  📱  ${YELLOW}Install the phone app:${RESET}\n"
printf "      %s\n" "$SERVER_RELEASE_PAGE_URL"
printf "      (grab the *-arm64-v8a.apk file)\n"
if [ "$OS" = "Darwin" ] && [ -z "$INSTALLED_MAC_APP_VERSION" ]; then
  printf "\n"
  printf "  Optional Mac App manager:\n"
  printf "    ${YELLOW}INSTALL_MAC_APP=1 bash install.sh${RESET}\n"
fi
printf "\n"
printf "  🔗  Open PawTerm on your phone → tap Scan LAN → Pair\n"
printf "\n"
printf "  ℹ️   Server commands: start / stop / restart / logs / status\n"
printf "      Run ${GREY}pawterm-server help${RESET} for the full list.\n"
printf "\n"
ok "Done. Enjoy PawTerm!"
printf "\n"
