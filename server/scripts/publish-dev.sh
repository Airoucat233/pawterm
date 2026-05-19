#!/usr/bin/env zsh
# Publish a dev pre-release to npm (@dev tag) and push a GitHub pre-release.
#
# Version format: {semver}-dev.{N}  e.g. 0.5.5-dev.3
# npm install -g pawterm-server@dev  → installs latest dev
# npm install -g pawterm-server      → still installs @latest (stable)
#
# Usage: ./scripts/publish-dev.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVER_DIR="$(dirname "$SCRIPT_DIR")"
REPO_ROOT="$(dirname "$SERVER_DIR")"
PKG="$SERVER_DIR/package.json"

# -------- 0. Branch guard (dev only, not main) --------

CURRENT_BRANCH=$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
if [[ "$CURRENT_BRANCH" == "main" ]]; then
  echo "✗ cannot publish a dev build from main." >&2
  echo "  Use publish.sh for stable releases." >&2
  exit 1
fi

# -------- 1. Read stable version --------

STABLE=$(/usr/bin/python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['version'])" "$PKG")
# Strip any existing pre-release suffix to get clean semver base
BASE="${STABLE%%-*}"

echo
echo "  stable base: \033[36m$BASE\033[0m"

# -------- 2. Auto-increment dev build number --------

CURRENT_DEV=$(npm view "pawterm-server@dev" version 2>/dev/null || echo "")
N=1
if [[ -n "$CURRENT_DEV" ]]; then
  DEV_BASE="${CURRENT_DEV%%-*}"
  if [[ "$DEV_BASE" == "$BASE" ]]; then
    PREV_N="${CURRENT_DEV##*-dev.}"
    N=$((PREV_N + 1))
  fi
fi

NEW_VERSION="${BASE}-dev.${N}"

echo "  new version: \033[32m$NEW_VERSION\033[0m  (npm tag: dev)"
echo

printf "  → publish %s to npm@dev and push GitHub pre-release? [y/N]: " "$NEW_VERSION"
read -r CONFIRM
if [[ "${CONFIRM:-N}" != "y" && "${CONFIRM:-N}" != "Y" ]]; then
  echo "  aborted."
  exit 0
fi

# -------- 3. Write version to package.json (temp, not committed) --------

/usr/bin/python3 - "$PKG" "$NEW_VERSION" <<'PY'
import json, sys, pathlib
path, new = sys.argv[1], sys.argv[2]
p = pathlib.Path(path)
data = json.loads(p.read_text())
data['version'] = new
p.write_text(json.dumps(data, indent=2) + '\n')
PY

# -------- 4. Build --------

echo
echo "▶ pnpm build"
cd "$SERVER_DIR"
pnpm build

# -------- 5. Publish to npm with @dev tag --------

echo
echo "▶ npm publish --tag dev"
npm publish --tag dev --registry https://registry.npmjs.org

# -------- 6. Restore package.json (version bump not committed) --------

/usr/bin/python3 - "$PKG" "$STABLE" <<'PY'
import json, sys, pathlib
path, ver = sys.argv[1], sys.argv[2]
p = pathlib.Path(path)
data = json.loads(p.read_text())
data['version'] = ver
p.write_text(json.dumps(data, indent=2) + '\n')
PY

# -------- 7. Push GitHub pre-release --------

echo
echo "▶ updating GitHub pre-release 'dev-server'"
gh release delete dev-server --yes 2>/dev/null || true
git -C "$REPO_ROOT" tag -d dev-server 2>/dev/null || true
git -C "$REPO_ROOT" push origin :refs/tags/dev-server 2>/dev/null || true

gh release create dev-server \
  --title "dev-server · $NEW_VERSION" \
  --notes "Dev build \`$NEW_VERSION\` from branch \`$CURRENT_BRANCH\`.\n\n\`\`\`\nnpm install -g pawterm-server@dev\n\`\`\`" \
  --prerelease \
  --repo Airoucat233/pawterm

echo
echo "\033[32m✓ published pawterm-server@$NEW_VERSION (npm tag: dev)\033[0m"
echo "  Install: npm install -g pawterm-server@dev"
