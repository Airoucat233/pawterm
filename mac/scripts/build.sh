#!/usr/bin/env zsh
# Build Mac app locally for verification.
# Used by CI (release-mac.yml) and for local testing.
# No version bump, no git operations.
#
# Usage:
#   ./scripts/build.sh           # build + install PawTermDev.app
#   ./scripts/build.sh --release # build PawTerm.app (stable, no install)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MAC_DIR="$(dirname "$SCRIPT_DIR")"
PLIST="$MAC_DIR/Info.plist"

RELEASE=0
for arg in "$@"; do
  case "$arg" in --release) RELEASE=1 ;; esac
done

# -------- Read version --------

VERSION=$(/usr/bin/python3 -c "
import plistlib
with open('$PLIST', 'rb') as f: pl = plistlib.load(f)
print(pl.get('CFBundleShortVersionString', '0.0.0'))
")

echo
echo "  version: \033[36m$VERSION\033[0m"
echo

# -------- Build --------

cd "$MAC_DIR"

if [[ $RELEASE -eq 1 ]]; then
  echo "▶ bash build.sh --universal --version=$VERSION"
  bash build.sh --universal --version="$VERSION"
else
  echo "▶ bash build.sh --dev --install --version=$VERSION"
  bash build.sh --dev --install --version="$VERSION"
fi

echo
echo "\033[32m✓ build done\033[0m  v$VERSION"
