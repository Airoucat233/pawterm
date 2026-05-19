#!/usr/bin/env zsh
# Build PawTermDev.app and push to GitHub pre-release tagged 'dev-mac'.
#
# Auto-increments CFBundleVersion (build number). Semver stays as-is.
# Does NOT install — just zips and uploads.
#
# Usage:
#   ./scripts/build-dev.sh              # build + push
#   ./scripts/build-dev.sh --skip-push  # build only

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MAC_DIR="$(dirname "$SCRIPT_DIR")"
REPO_ROOT="$(dirname "$MAC_DIR")"
PLIST="$MAC_DIR/Info.plist"

SKIP_PUSH=0
for arg in "$@"; do
  case "$arg" in --skip-push|-s) SKIP_PUSH=1 ;; esac
done

# -------- 0. Branch guard (dev only, not main) --------

CURRENT_BRANCH=$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
if [[ "$CURRENT_BRANCH" == "main" ]]; then
  echo "✗ cannot publish a dev build from main." >&2
  echo "  Use mac/scripts/build.sh + release.sh for stable releases." >&2
  exit 1
fi

# -------- 1. Read + auto-bump build number --------

read_plist() {
  /usr/bin/python3 -c "
import plistlib, pathlib, sys
with open(sys.argv[1], 'rb') as f:
    pl = plistlib.load(f)
print(pl.get(sys.argv[2], ''))
" "$PLIST" "$1"
}

SHORT_VER=$(read_plist CFBundleShortVersionString)
BUILD=$(read_plist CFBundleVersion)
[[ -z "$BUILD" ]] && BUILD="0"
NEW_BUILD=$((BUILD + 1))

echo
echo "  \033[2m${SHORT_VER}+${BUILD}\033[0m → \033[32m${SHORT_VER}+${NEW_BUILD}\033[0m  (dev build)"

# Patch CFBundleVersion in Info.plist (temp, not committed)
/usr/bin/python3 - "$PLIST" "$NEW_BUILD" <<'PY'
import plistlib, pathlib, sys
path, build = sys.argv[1], sys.argv[2]
p = pathlib.Path(path)
with open(p, 'rb') as f:
    pl = plistlib.load(f)
pl['CFBundleVersion'] = build
with open(p, 'wb') as f:
    plistlib.dump(pl, f)
PY

# -------- 2. Build --------

echo
echo "▶ bash build.sh --dev --version=$SHORT_VER"
cd "$MAC_DIR"
bash build.sh --dev --version="$SHORT_VER"

# -------- 3. Restore Info.plist --------

/usr/bin/python3 - "$PLIST" "$BUILD" <<'PY'
import plistlib, pathlib, sys
path, build = sys.argv[1], sys.argv[2]
p = pathlib.Path(path)
with open(p, 'rb') as f:
    pl = plistlib.load(f)
pl['CFBundleVersion'] = build
with open(p, 'wb') as f:
    plistlib.dump(pl, f)
PY

echo
echo "\033[32m✓ built PawTermDev.app  v${SHORT_VER}+${NEW_BUILD}\033[0m"

if [[ $SKIP_PUSH -eq 1 ]]; then
  echo "  (skipped GitHub push)"
  exit 0
fi

# -------- 4. Zip --------

DIST="$MAC_DIR/dist-dev"
mkdir -p "$DIST"
ZIP="$DIST/PawTermDev-${SHORT_VER}-build${NEW_BUILD}.zip"
ditto -c -k --keepParent "$MAC_DIR/PawTermDev.app" "$ZIP"
echo "  zipped: $(basename "$ZIP")"

# -------- 5. Push GitHub pre-release --------

echo
echo "▶ updating GitHub pre-release 'dev-mac'"
gh release delete dev-mac --yes 2>/dev/null || true
git -C "$REPO_ROOT" tag -d dev-mac 2>/dev/null || true
git -C "$REPO_ROOT" push origin :refs/tags/dev-mac 2>/dev/null || true

gh release create dev-mac \
  "$ZIP" \
  --title "dev-mac · v${SHORT_VER}+${NEW_BUILD}" \
  --notes "Dev build \`v${SHORT_VER}+${NEW_BUILD}\` from branch \`$CURRENT_BRANCH\`.\n\nAfter download:\n\`\`\`\nunzip PawTermDev-*.zip\nxattr -d com.apple.quarantine PawTermDev.app\n\`\`\`" \
  --prerelease \
  --repo Airoucat233/pawterm

echo
echo "\033[32m✓ dev-mac release updated\033[0m"
echo "  https://github.com/Airoucat233/pawterm/releases/tag/dev-mac"
