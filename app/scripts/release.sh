#!/usr/bin/env zsh
# Push a release tag to trigger CI build + GitHub Release.
#
# Prerequisites:
#   1. Run build-apk.sh first to bump pubspec version and verify the build locally.
#   2. All commits must be pushed to origin/main.
#
# What this script does:
#   - Reads version from pubspec.yaml
#   - Creates and pushes tag v{semver} → triggers release.yml CI
#   - CI builds APK + Mac .app and creates the GitHub Release automatically

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(dirname "$SCRIPT_DIR")"
REPO_ROOT="$(dirname "$APP_DIR")"
cd "$APP_DIR"

PUBSPEC="$APP_DIR/pubspec.yaml"

# -------- 0. Branch guard --------

CURRENT_BRANCH=$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
if [[ "$CURRENT_BRANCH" != "main" ]]; then
  echo "✗ stable release must be run from main (current: $CURRENT_BRANCH)" >&2
  echo "  Switch to main before releasing." >&2
  exit 1
fi

# -------- 1. Read version --------

CURRENT=$(/usr/bin/awk '/^version:/ {print $2; exit}' "$PUBSPEC")
if [[ -z "$CURRENT" ]]; then
  echo "✗ Could not read version from $PUBSPEC" >&2
  exit 1
fi

TAG="release/app-v${CURRENT%%+*}"
SERVER_VERSION=$(python3 -c "import json; print(json.load(open('$REPO_ROOT/server/package.json'))['version'])" 2>/dev/null || echo "")

echo
echo "  app version : \033[36m$CURRENT\033[0m  →  tag: \033[1m$TAG\033[0m"
[[ -n "$SERVER_VERSION" ]] && echo "  server ver  : $SERVER_VERSION"
echo

# -------- 2. Check tag doesn't already exist --------

if git -C "$REPO_ROOT" tag -l | grep -qx "$TAG"; then
  echo "✗ Tag $TAG already exists. Did you forget to bump the version?" >&2
  exit 1
fi

# -------- 3. Check all commits are pushed --------

LOCAL=$(git -C "$REPO_ROOT" rev-parse HEAD)
REMOTE=$(git -C "$REPO_ROOT" rev-parse origin/main 2>/dev/null || echo "")
if [[ "$LOCAL" != "$REMOTE" ]]; then
  echo "✗ Local commits are ahead of origin/main. Push first:" >&2
  echo "  git push origin main" >&2
  exit 1
fi

# -------- 4. Confirm --------

printf "  → push tag %s and trigger CI release? [y/N]: " "$TAG"
read -r CONFIRM
if [[ "${CONFIRM:-N}" != "y" && "${CONFIRM:-N}" != "Y" ]]; then
  echo "  aborted."
  exit 0
fi

# -------- 5. Tag + push --------

echo
echo "▶ git tag $TAG && git push origin $TAG"
git -C "$REPO_ROOT" tag "$TAG"
git -C "$REPO_ROOT" push origin "$TAG"

echo
echo "\033[32m✓ tag pushed\033[0m — CI is building APK + Mac app"
echo "  Watch: https://github.com/Airoucat233/pawterm/actions"
echo "  Release will appear at: https://github.com/Airoucat233/pawterm/releases/tag/$TAG"
