#!/usr/bin/env zsh
# Build Mac app. Prompts for version bump unless --dev or CI=true.
#
# Usage:
#   ./scripts/build.sh         # build PawTerm.app (arm64 release)
#   ./scripts/build.sh --dev   # build + install PawTermDev.app

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MAC_DIR="$(dirname "$SCRIPT_DIR")"
REPO_ROOT="$(dirname "$MAC_DIR")"
PLIST="$MAC_DIR/Info.plist"
DIST_DIR="$REPO_ROOT/dist"

DEV=0
for arg in "$@"; do
  case "$arg" in --dev) DEV=1 ;; esac
done

# -------- Read version --------

VERSION=$(/usr/bin/python3 -c "
import plistlib
with open('$PLIST', 'rb') as f: pl = plistlib.load(f)
print(pl.get('CFBundleShortVersionString', '0.0.0'))
")

echo
echo "  current: \033[36m$VERSION\033[0m"

# -------- Bump (release only, skip in CI) --------

if [[ $DEV -eq 0 && "${CI:-}" != "true" ]]; then
  IFS='.' read -r MAJOR MINOR PATCH <<<"$VERSION"

  echo
  cat <<MENU
  Choose bump:
    1)  same     $VERSION
    2)  patch    $MAJOR.$MINOR.$((PATCH+1))
    3)  minor    $MAJOR.$((MINOR+1)).0
    4)  major    $((MAJOR+1)).0.0
    q)  quit
MENU

  printf "  → [1-4/q, default=1]: "
  read -r CHOICE
  CHOICE="${CHOICE:-1}"

  case "$CHOICE" in
    1|same)  NEW="$VERSION" ;;
    2|patch) NEW="$MAJOR.$MINOR.$((PATCH+1))" ;;
    3|minor) NEW="$MAJOR.$((MINOR+1)).0" ;;
    4|major) NEW="$((MAJOR+1)).0.0" ;;
    q|quit)  echo "  aborted."; exit 0 ;;
    *)       echo "  invalid choice" >&2; exit 1 ;;
  esac

  if [[ "$NEW" != "$VERSION" ]]; then
    /usr/bin/python3 - <<PY
import plistlib, pathlib
p = pathlib.Path("$PLIST")
with open(p, "rb") as f: pl = plistlib.load(f)
pl["CFBundleShortVersionString"] = "$NEW"
with open(p, "wb") as f: plistlib.dump(pl, f)
PY
    echo "  bumped  → \033[32m$NEW\033[0m"
  fi
  VERSION="$NEW"
fi

echo

# -------- Build --------

cd "$MAC_DIR"

if [[ $DEV -eq 0 ]]; then
  find "$DIST_DIR" -maxdepth 1 -name "PawTerm-*-mac.zip" -delete 2>/dev/null || true
fi

if [[ $DEV -eq 1 ]]; then
  echo "▶ bash build.sh --dev --install --version=$VERSION"
  bash build.sh --dev --install --version="$VERSION"
else
  echo "▶ bash build.sh --version=$VERSION"
  bash build.sh --version="$VERSION"
fi

if [[ $DEV -eq 0 ]]; then
  mkdir -p "$DIST_DIR"
  ditto -c -k --keepParent "$MAC_DIR/PawTerm.app" "$DIST_DIR/PawTerm-${VERSION}-mac.zip"
  echo
  echo "\033[32m✓ build done\033[0m  v$VERSION  →  dist/PawTerm-${VERSION}-mac.zip"
else
  echo
  echo "\033[32m✓ build done\033[0m  v$VERSION"
fi
