#!/usr/bin/env zsh
# Bump version, build, and publish pawterm-server to npm.
#
# Usage: ./scripts/publish.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVER_DIR="$(dirname "$SCRIPT_DIR")"
REPO_ROOT="$(dirname "$SERVER_DIR")"
PKG="$SERVER_DIR/package.json"

# -------- 0. Branch guard --------

CURRENT_BRANCH=$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
if [[ "$CURRENT_BRANCH" != "main" ]]; then
  echo "✗ stable release must be run from main (current: $CURRENT_BRANCH)" >&2
  echo "  Switch to main before releasing." >&2
  exit 1
fi

# -------- 1. Read current version --------

CURRENT=$(/usr/bin/python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['version'])" "$PKG")

SEMVER="${CURRENT%%+*}"
IFS='.' read -r MAJOR MINOR PATCH <<<"$SEMVER"

echo
echo "  current version: \033[36m$CURRENT\033[0m"
echo

# -------- 2. Pick bump strategy --------

cat <<MENU
  Choose bump strategy:
    1)  same     keep $CURRENT, re-publish (e.g. README only)
    2)  patch    $MAJOR.$MINOR.$((PATCH+1))    (bugfix)
    3)  minor    $MAJOR.$((MINOR+1)).0         (feature)
    4)  major    $((MAJOR+1)).0.0              (breaking)
    q)  quit

MENU

printf "  → choice [1-4/q, default=2]: "
read -r CHOICE
CHOICE="${CHOICE:-2}"

case "$CHOICE" in
  1|same)  NEW_VERSION="$CURRENT" ;;
  2|patch) NEW_VERSION="$MAJOR.$MINOR.$((PATCH+1))" ;;
  3|minor) NEW_VERSION="$MAJOR.$((MINOR+1)).0" ;;
  4|major) NEW_VERSION="$((MAJOR+1)).0.0" ;;
  q|quit)  echo "  aborted."; exit 0 ;;
  *)       echo "  invalid choice: $CHOICE" >&2; exit 1 ;;
esac

# -------- 3. Update package.json if needed --------

if [[ "$NEW_VERSION" != "$CURRENT" ]]; then
  echo "  bumping package.json: $CURRENT → \033[32m$NEW_VERSION\033[0m"
  /usr/bin/python3 - "$PKG" "$NEW_VERSION" <<'PY'
import json, sys, pathlib
path, new = sys.argv[1], sys.argv[2]
p = pathlib.Path(path)
data = json.loads(p.read_text())
data['version'] = new
p.write_text(json.dumps(data, indent=2) + '\n')
PY
else
  echo "  keeping version: $NEW_VERSION"
fi

VERSION="$NEW_VERSION"

# -------- 4. Build --------

echo
echo "▶ pnpm build"
cd "$SERVER_DIR"
pnpm build

# -------- 5. Commit version bump --------

if [[ "$VERSION" != "$CURRENT" ]]; then
  git -C "$REPO_ROOT" add server/package.json
  git -C "$REPO_ROOT" commit -m "chore(server): bump version to $VERSION"
  git -C "$REPO_ROOT" push origin main
  echo
  echo "  committed and pushed version bump"
fi

# -------- 6. Publish --------

echo
echo "▶ npm publish --registry https://registry.npmjs.org"
npm publish --registry https://registry.npmjs.org

# -------- 7. Tag --------

REPO_ROOT="$(dirname "$SERVER_DIR")"
TAG="release/server-v$VERSION"
git -C "$REPO_ROOT" tag "$TAG"
git -C "$REPO_ROOT" push origin "$TAG"

echo
echo "\033[32m✓ published pawterm-server@$VERSION\033[0m"
echo "  npm:  https://www.npmjs.com/package/pawterm-server"
echo "  tag:  $TAG"
