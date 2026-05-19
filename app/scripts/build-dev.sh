#!/usr/bin/env zsh
# Fast dev build: auto-bump build number, build arm64 APK, push to GitHub
# pre-release tagged 'dev'. No interactive prompts.
#
# The app's "Dev channel" setting will find this release and offer the install.
#
# Usage:
#   ./scripts/build-dev.sh           # bump build number + build + push
#   ./scripts/build-dev.sh --skip-push  # build only, don't touch GitHub

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(dirname "$SCRIPT_DIR")"
cd "$APP_DIR"

PUBSPEC="$APP_DIR/pubspec.yaml"
OUT_DIR="$APP_DIR/build/app/outputs/flutter-apk"

SKIP_PUSH=0
for arg in "$@"; do
  case "$arg" in --skip-push|-s) SKIP_PUSH=1 ;; esac
done

# -------- 0. Branch guard --------

CURRENT_BRANCH=$(git -C "$APP_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
if [[ "$CURRENT_BRANCH" == "main" ]]; then
  echo "✗ cannot publish a dev build from main." >&2
  echo "  Use build-apk.sh + release.sh for stable releases." >&2
  exit 1
fi

# -------- 1. Auto-bump build number --------

CURRENT=$(/usr/bin/awk '/^version:/ {print $2; exit}' "$PUBSPEC")
SEMVER="${CURRENT%%+*}"
BUILD="${CURRENT#*+}"
[[ "$BUILD" == "$CURRENT" ]] && BUILD="0"
NEW_BUILD=$((BUILD + 1))
NEW_VERSION="$SEMVER+$NEW_BUILD"

echo
echo "  \033[2m$CURRENT\033[0m → \033[32m$NEW_VERSION\033[0m  (dev build)"

/usr/bin/python3 - "$PUBSPEC" "$NEW_VERSION" <<'PY'
import sys, re, pathlib
path, new = sys.argv[1], sys.argv[2]
p = pathlib.Path(path)
text = p.read_text()
text = re.sub(r'^version: .*$', f'version: {new}', text, flags=re.MULTILINE, count=1)
p.write_text(text)
PY

# -------- 2. Build arm64 only (fastest) --------

echo
echo "▶ flutter build apk --release --target-platform android-arm64"
flutter build apk --release --target-platform android-arm64

APK="$OUT_DIR/app-release.apk"
if [[ ! -f "$APK" ]]; then
  echo "✗ APK not found: $APK" >&2
  exit 1
fi

DEST="$OUT_DIR/pawterm-dev-arm64.apk"
/bin/cp "$APK" "$DEST"
/bin/rm -f "$APK"

echo
echo "\033[32m✓ build done\033[0m"
echo "  output: $DEST"
echo "  size:   $(/usr/bin/du -h "$DEST" | /usr/bin/awk '{print $1}')"

if [[ $SKIP_PUSH -eq 1 ]]; then
  echo "  (skipped GitHub push)"
  exit 0
fi

# -------- 3. Push to GitHub pre-release tagged 'dev' --------

echo
echo "▶ updating GitHub pre-release 'dev'"

# Delete existing dev release + tag (ignore errors if not exists)
gh release delete dev --yes 2>/dev/null || true
git tag -d dev 2>/dev/null || true
git push origin :refs/tags/dev 2>/dev/null || true

gh release create dev \
  "$DEST" \
  --title "dev  ·  $NEW_VERSION" \
  --notes "Development build $NEW_VERSION — not stable." \
  --prerelease

echo
echo "\033[32m✓ dev release updated\033[0m"
echo "  Enable 'Dev channel' in app settings → Check for updates to install."
