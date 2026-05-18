#!/usr/bin/env zsh
# Build a release APK with version bumping support.
#
# Output layout:
#   build/app/outputs/flutter-apk/
#     ├─ latest.apk                                       # always the newest arm64 build
#     └─ releases/
#         └─ <version>/
#             ├─ pawterm-<version>-arm64-v8a.apk    # the one your phone wants
#             ├─ pawterm-<version>-armeabi-v7a.apk
#             └─ pawterm-<version>-x86_64.apk

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(dirname "$SCRIPT_DIR")"
cd "$APP_DIR"

PUBSPEC="$APP_DIR/pubspec.yaml"
OUT_DIR="$APP_DIR/build/app/outputs/flutter-apk"
RELEASES_DIR="$OUT_DIR/releases"

# -------- 0. Debug shortcut --------
# Pass --debug (or -d) to skip version bump and build a debug APK instantly.

DEBUG=0
for arg in "$@"; do
  case "$arg" in
    --debug|-d) DEBUG=1 ;;
  esac
done

if [[ $DEBUG -eq 1 ]]; then
  echo
  echo "▶ flutter build apk --debug --target-platform android-arm64"
  flutter build apk --debug --target-platform android-arm64
  APK="$OUT_DIR/app-debug.apk"
  echo
  echo "\033[32m✓ debug build done\033[0m"
  echo "  output: $APK"
  echo "  size:   $(/usr/bin/du -h "$APK" | /usr/bin/awk '{print $1}')"
  /usr/bin/open -R "$APK"
  exit 0
fi

# -------- 1. Read current version --------

CURRENT=$(/usr/bin/awk '/^version:/ {print $2; exit}' "$PUBSPEC")
if [[ -z "$CURRENT" ]]; then
  echo "✗ Could not read version from $PUBSPEC" >&2
  exit 1
fi

# version is "X.Y.Z+N"; split into semver and build number
SEMVER="${CURRENT%%+*}"
BUILD="${CURRENT#*+}"
[[ "$BUILD" == "$CURRENT" ]] && BUILD="1"  # missing +N

IFS='.' read -r MAJOR MINOR PATCH <<<"$SEMVER"

echo
echo "  current version: \033[36m$CURRENT\033[0m"
echo

# -------- 2. Pick bump strategy --------

cat <<MENU
  Choose bump strategy:
    1)  same     keep $CURRENT, overwrite (re-build)
    2)  build    $SEMVER+$((BUILD+1))                (only build number, fastest)
    3)  patch    $MAJOR.$MINOR.$((PATCH+1))+1        (bugfix)
    4)  minor    $MAJOR.$((MINOR+1)).0+1             (feature)
    5)  major    $((MAJOR+1)).0.0+1                  (breaking)
    q)  quit

MENU

printf "  → choice [1-5/q, default=1]: "
read -r CHOICE
CHOICE="${CHOICE:-1}"

case "$CHOICE" in
  1|same)   NEW_VERSION="$CURRENT" ;;
  2|build)  NEW_VERSION="$SEMVER+$((BUILD+1))" ;;
  3|patch)  NEW_VERSION="$MAJOR.$MINOR.$((PATCH+1))+1" ;;
  4|minor)  NEW_VERSION="$MAJOR.$((MINOR+1)).0+1" ;;
  5|major)  NEW_VERSION="$((MAJOR+1)).0.0+1" ;;
  q|quit)   echo "  aborted."; exit 0 ;;
  *)        echo "  invalid choice: $CHOICE" >&2; exit 1 ;;
esac

# -------- 3. Update pubspec if needed --------

if [[ "$NEW_VERSION" != "$CURRENT" ]]; then
  echo "  bumping pubspec.yaml: $CURRENT → \033[32m$NEW_VERSION\033[0m"
  /usr/bin/python3 - "$PUBSPEC" "$NEW_VERSION" <<'PY'
import sys, re, pathlib
path, new = sys.argv[1], sys.argv[2]
p = pathlib.Path(path)
text = p.read_text()
text = re.sub(r'^version: .*$', f'version: {new}', text, flags=re.MULTILINE, count=1)
p.write_text(text)
PY
else
  echo "  keeping version: $NEW_VERSION (overwriting existing)"
fi

VERSION="$NEW_VERSION"
SAFE_VERSION="${VERSION//+/_}"  # filesystem-friendly variant (not used now, kept for reference)

# -------- 4. Build --------

# clean previous flutter outputs in the top-level flutter-apk dir (not in releases/)
/bin/rm -f "$OUT_DIR"/*.apk 2>/dev/null || true

echo
echo "▶ flutter build apk --release --split-per-abi"
flutter build apk --release --split-per-abi

# -------- 5. Organize outputs --------

VERSION_DIR="$RELEASES_DIR/$VERSION"
/bin/mkdir -p "$VERSION_DIR"

# Find the freshly built APKs (named via archivesName=pawterm + abi + buildType)
shopt -s nullglob 2>/dev/null || setopt nullglob
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

if [[ -z "$ARM64" ]]; then
  echo "✗ arm64 apk not produced" >&2
  exit 1
fi

# -------- 6. latest.apk (always arm64) --------

LATEST="$OUT_DIR/latest.apk"
/bin/cp "$ARM64" "$LATEST"

# Clean up the temporary top-level apks now that they're moved into versioned dir
/bin/rm -f "$OUT_DIR"/*release.apk 2>/dev/null || true

# -------- 7. Report --------

echo
echo "\033[32m✓ build done\033[0m"
echo "  version:   $VERSION"
echo "  arm64 →    $ARM64"
echo "  size:      $(/usr/bin/du -h "$ARM64" | /usr/bin/awk '{print $1}')"
echo "  latest →   $LATEST"
echo
echo "  all builds: $VERSION_DIR"
/bin/ls -1 "$VERSION_DIR" | /usr/bin/sed 's/^/    /'

# Open Finder selecting arm64
/usr/bin/open -R "$ARM64"

echo "  run ./scripts/release.sh to create a GitHub Release."
