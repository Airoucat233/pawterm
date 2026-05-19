#!/usr/bin/env zsh
# Bump Mac app version and build locally for verification.
#
# Usage: ./scripts/build.sh
#
# Run this before release.sh to verify the build is good.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MAC_DIR="$(dirname "$SCRIPT_DIR")"
REPO_ROOT="$(dirname "$MAC_DIR")"
PLIST="$MAC_DIR/Info.plist"

# -------- 1. Read current version --------

CURRENT=$(/usr/bin/python3 -c "
import plistlib, pathlib
with open('$PLIST', 'rb') as f:
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
    1)  same     keep $CURRENT (rebuild only)
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

# -------- 3. Update Info.plist --------

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
  echo "  bumped Info.plist: $CURRENT → \033[32m$NEW_VERSION\033[0m"
fi

# -------- 4. Build & install --------

echo
echo "▶ bash build.sh --dev --install --version=$NEW_VERSION"
cd "$MAC_DIR"
bash build.sh --dev --install --version="$NEW_VERSION"

# -------- 5. Commit version bump --------

if [[ "$NEW_VERSION" != "$CURRENT" ]]; then
  git -C "$REPO_ROOT" add mac/Info.plist
  git -C "$REPO_ROOT" commit -m "chore(mac): bump version to $NEW_VERSION"
  echo
  echo "  committed version bump"
fi

echo
echo "\033[32m✓ built v$NEW_VERSION\033[0m — run mac/scripts/release.sh to publish"
