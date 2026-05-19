#!/usr/bin/env zsh
# Build release APKs from current pubspec.yaml version.
# Used by CI and for local verification. No version bump, no git operations.
#
# Output:
#   build/app/outputs/flutter-apk/releases/{version}/  ← local reference
#   build/app/outputs/flutter-apk/latest.apk            ← latest arm64
#   dist/pawterm-{version}-*.apk                        ← CI / --local release
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
RELEASES_DIR="$OUT_DIR/releases"
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

# -------- Organize into versioned dir --------

VERSION_DIR="$RELEASES_DIR/$VERSION"
mkdir -p "$VERSION_DIR"

ARM64=""
for f in "$OUT_DIR"/*arm64*-release.apk; do
  TARGET="$VERSION_DIR/pawterm-${VERSION}-arm64-v8a.apk"
  /bin/cp "$f" "$TARGET"
  ARM64="$TARGET"
done
for f in "$OUT_DIR"/*armeabi*-release.apk; do
  /bin/cp "$f" "$VERSION_DIR/pawterm-${VERSION}-armeabi-v7a.apk"
done
for f in "$OUT_DIR"/*x86_64*-release.apk; do
  /bin/cp "$f" "$VERSION_DIR/pawterm-${VERSION}-x86_64.apk"
done

/bin/rm -f "$OUT_DIR"/*release.apk 2>/dev/null || true

[[ -z "$ARM64" ]] && { echo "✗ arm64 APK not produced" >&2; exit 1; }

LATEST="$OUT_DIR/latest.apk"
/bin/cp "$ARM64" "$LATEST"

# -------- Also copy to dist/ for CI + --local release --------

mkdir -p "$DIST_DIR"
for f in "$VERSION_DIR"/pawterm-"${VERSION}"-*.apk; do
  /bin/cp "$f" "$DIST_DIR/"
done

# -------- Report --------

echo
echo "\033[32m✓ build done\033[0m"
echo "  version : $VERSION"
echo "  releases: $VERSION_DIR"
/bin/ls -1 "$VERSION_DIR" | /usr/bin/sed 's/^/    /'
echo "  latest  : $LATEST"
