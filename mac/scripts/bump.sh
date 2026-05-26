#!/usr/bin/env zsh
# Bump Mac app version in Info.plist, commit, push to main.
# Mac .app is bundled automatically in every app release (release-v* tag).
# Run this before scripts/release.sh when Mac has changes to ship.
#
# Usage: ./scripts/release.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MAC_DIR="$(dirname "$SCRIPT_DIR")"
REPO_ROOT="$(dirname "$MAC_DIR")"
PLIST="$MAC_DIR/Info.plist"

# -------- 0. Branch guard --------

CURRENT_BRANCH=$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
if [[ "$CURRENT_BRANCH" != "main" ]]; then
  echo "✗ must be run from main (current: $CURRENT_BRANCH)" >&2
  exit 1
fi

# -------- 1. Read current version --------

CURRENT=$(/usr/bin/python3 -c "
import plistlib
with open('$PLIST', 'rb') as f: pl = plistlib.load(f)
print(pl.get('CFBundleShortVersionString', '0.0.0'))
")

IFS='.' read -r MAJOR MINOR PATCH <<<"$CURRENT"

echo
echo "  current: \033[36m$CURRENT\033[0m"
echo

# -------- 2. Bump --------

cat <<MENU
  Choose bump:
    1)  same     $CURRENT
    2)  patch    $MAJOR.$MINOR.$((PATCH+1))
    3)  minor    $MAJOR.$((MINOR+1)).0
    4)  major    $((MAJOR+1)).0.0
    q)  quit
MENU

printf "  → [1-4/q, default=2]: "
read -r CHOICE
CHOICE="${CHOICE:-2}"

case "$CHOICE" in
  1|same)  NEW="$CURRENT" ;;
  2|patch) NEW="$MAJOR.$MINOR.$((PATCH+1))" ;;
  3|minor) NEW="$MAJOR.$((MINOR+1)).0" ;;
  4|major) NEW="$((MAJOR+1)).0.0" ;;
  q|quit)  echo "  aborted."; exit 0 ;;
  *)       echo "  invalid choice" >&2; exit 1 ;;
esac

[[ "$NEW" == "$CURRENT" ]] && { echo "  no change."; exit 0; }

echo
printf "  → bump Info.plist to %s and push? [y/N]: " "$NEW"
read -r CONFIRM
[[ "${CONFIRM:-N}" != [yY] ]] && { echo "  aborted."; exit 0; }

# -------- 3. Update Info.plist --------

/usr/bin/python3 - "$PLIST" "$NEW" <<'PY'
import plistlib, pathlib, sys
path, ver = sys.argv[1], sys.argv[2]
p = pathlib.Path(path)
with open(p, 'rb') as f: pl = plistlib.load(f)
pl['CFBundleShortVersionString'] = ver
with open(p, 'wb') as f: plistlib.dump(pl, f)
PY

# -------- 4. Commit + push --------

git -C "$REPO_ROOT" add mac/Info.plist
git -C "$REPO_ROOT" commit -m "chore(mac): bump version to $NEW"
git -C "$REPO_ROOT" push origin main

echo
echo "\033[32m✓ Mac version bumped to $NEW\033[0m"
echo "  Now run scripts/release.sh to ship a release."
