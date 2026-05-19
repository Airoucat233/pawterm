#!/usr/bin/env zsh
# Bump Mac app version, commit, push tag mac/v{version} → CI builds + GitHub Release.
#
# Usage: ./scripts/release.sh
#
# What this script does:
#   1. Reads current version from Info.plist
#   2. Prompts for bump strategy
#   3. Writes new version to Info.plist and commits
#   4. Pushes tag mac/v{version} → triggers release-mac.yml CI

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MAC_DIR="$(dirname "$SCRIPT_DIR")"
REPO_ROOT="$(dirname "$MAC_DIR")"
PLIST="$MAC_DIR/Info.plist"

# -------- 0. Branch guard --------

CURRENT_BRANCH=$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
if [[ "$CURRENT_BRANCH" != "main" ]]; then
  echo "✗ stable release must be run from main (current: $CURRENT_BRANCH)" >&2
  echo "  Switch to main before releasing." >&2
  exit 1
fi

# -------- 1. Read current version --------

CURRENT=$(/usr/bin/python3 -c "
import plistlib, pathlib
p = pathlib.Path('$PLIST')
with open(p, 'rb') as f:
    pl = plistlib.load(f)
print(pl.get('CFBundleShortVersionString', '0.0.0'))
")

IFS='.' read -r MAJOR MINOR PATCH <<<"$CURRENT"

echo
echo "  current version: \033[36m$CURRENT\033[0m"
echo

# -------- 2. Pick bump strategy --------

cat <<MENU
  Choose bump strategy:
    1)  same     keep $CURRENT (re-release)
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

TAG="mac/v$NEW_VERSION"

echo
echo "  new version: \033[32m$NEW_VERSION\033[0m  →  tag: \033[1m$TAG\033[0m"
echo

# -------- 3. Check tag doesn't already exist --------

if git -C "$REPO_ROOT" tag -l | grep -qx "$TAG"; then
  echo "✗ Tag $TAG already exists." >&2
  exit 1
fi

# -------- 4. Check all commits are pushed --------

LOCAL=$(git -C "$REPO_ROOT" rev-parse HEAD)
REMOTE=$(git -C "$REPO_ROOT" rev-parse origin/main 2>/dev/null || echo "")
if [[ "$LOCAL" != "$REMOTE" ]]; then
  echo "✗ Local commits are ahead of origin/main. Push first:" >&2
  echo "  git push origin main" >&2
  exit 1
fi

# -------- 5. Confirm --------

printf "  → bump Info.plist to %s, commit, push tag %s? [y/N]: " "$NEW_VERSION" "$TAG"
read -r CONFIRM
if [[ "${CONFIRM:-N}" != "y" && "${CONFIRM:-N}" != "Y" ]]; then
  echo "  aborted."
  exit 0
fi

# -------- 6. Update Info.plist --------

if [[ "$NEW_VERSION" != "$CURRENT" ]]; then
  /usr/bin/python3 - "$PLIST" "$NEW_VERSION" <<'PY'
import plistlib, pathlib, sys
path, new_ver = sys.argv[1], sys.argv[2]
p = pathlib.Path(path)
with open(p, 'rb') as f:
    pl = plistlib.load(f)
pl['CFBundleShortVersionString'] = new_ver
with open(p, 'wb') as f:
    plistlib.dump(pl, f)
PY
  git -C "$REPO_ROOT" add mac/Info.plist
  git -C "$REPO_ROOT" commit -m "chore(mac): bump version to $NEW_VERSION"
  echo "  committed version bump"

  # Push the commit before tagging
  git -C "$REPO_ROOT" push origin main
fi

# -------- 7. Tag + push --------

echo
echo "▶ git tag $TAG && git push origin $TAG"
git -C "$REPO_ROOT" tag "$TAG"
git -C "$REPO_ROOT" push origin "$TAG"

echo
echo "\033[32m✓ tag pushed\033[0m — CI is building Mac .app"
echo "  Watch: https://github.com/Airoucat233/pawterm/actions"
echo "  Release: https://github.com/Airoucat233/pawterm/releases/tag/$TAG"
