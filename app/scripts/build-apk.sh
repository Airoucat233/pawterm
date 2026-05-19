#!/usr/bin/env zsh
# Build release APKs from current pubspec.yaml version.
# Used by CI (release-app.yml) and for local verification.
# No version bump, no git operations.
#
# Output:
#   dist/pawterm-{version}-arm64-v8a.apk
#   dist/pawterm-{version}-armeabi-v7a.apk
#
# Usage:
#   ./scripts/build-apk.sh           # release build (split-per-abi)
#   ./scripts/build-apk.sh --debug   # debug build (arm64 only)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(dirname "$SCRIPT_DIR")"
REPO_ROOT="$(dirname "$APP_DIR")"
cd "$APP_DIR"

PUBSPEC="$APP_DIR/pubspec.yaml"
OUT_DIR="$APP_DIR/build/app/outputs/flutter-apk"
DIST_DIR="$REPO_ROOT/dist"

DEBUG=0
for arg in "$@"; do
  case "$arg" in --debug|-d) DEBUG=1 ;; esac
done

# -------- Read version --------

VERSION=$(/usr/bin/awk '/^version:/ {print $2; exit}' "$PUBSPEC")
[[ -z "$VERSION" ]] && { echo "✗ Could not read version from pubspec.yaml" >&2; exit 1; }

echo
echo "  version: \033[36m$VERSION\033[0m"

# -------- Build --------

if [[ $DEBUG -eq 1 ]]; then
  echo
  echo "▶ flutter build apk --debug --target-platform android-arm64"
  flutter build apk --debug --target-platform android-arm64
  echo
  echo "\033[32m✓ debug build done\033[0m  →  $OUT_DIR/app-debug.apk"
  exit 0
fi

/bin/rm -f "$OUT_DIR"/*.apk 2>/dev/null || true

echo
echo "▶ flutter pub get"
flutter pub get

echo
echo "▶ flutter build apk --release --split-per-abi"
flutter build apk --release --split-per-abi

# -------- Collect + rename --------

mkdir -p "$DIST_DIR"

ARM64=""
for f in "$OUT_DIR"/*arm64*-release.apk; do
  DEST="$DIST_DIR/pawterm-${VERSION}-arm64-v8a.apk"
  /bin/cp "$f" "$DEST"
  ARM64="$DEST"
done
for f in "$OUT_DIR"/*armeabi*-release.apk; do
  /bin/cp "$f" "$DIST_DIR/pawterm-${VERSION}-armeabi-v7a.apk"
done

/bin/rm -f "$OUT_DIR"/*release.apk 2>/dev/null || true

[[ -z "$ARM64" ]] && { echo "✗ arm64 APK not produced" >&2; exit 1; }

echo
echo "\033[32m✓ build done\033[0m"
echo "  version: $VERSION"
echo "  output:  $DIST_DIR"
/bin/ls -1 "$DIST_DIR"/pawterm-"${VERSION}"-*.apk | /usr/bin/sed 's/^/    /'
