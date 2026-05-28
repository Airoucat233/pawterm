#!/usr/bin/env zsh
# Build release APKs. Prompts for version bump for prod builds unless CI=true.
#
# Output:
#   build/app/outputs/flutter-apk/releases/{version}/  ← local reference
#   build/app/outputs/flutter-apk/latest.apk            ← latest arm64
#   dist/pawterm-{version}-*.apk                        ← release artifacts
#
# Usage:
#   ./scripts/build-apk.sh           # prod release build (split-per-abi)
#   ./scripts/build-apk.sh --prod    # prod release build (split-per-abi)
#   ./scripts/build-apk.sh --dev     # local dev release build, arm64 only, app id com.airoucat.pawterm.dev
#   ./scripts/build-apk.sh --dev --all-abi # local dev release build, split-per-abi
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
FLAVOR="prod"
NAME_PREFIX="pawterm"
ALL_ABI=0
for arg in "$@"; do
  case "$arg" in
    --debug|-d) DEBUG=1 ;;
    --prod) FLAVOR="prod"; NAME_PREFIX="pawterm" ;;
    --dev) FLAVOR="dev"; NAME_PREFIX="pawterm-dev" ;;
    --all-abi) ALL_ABI=1 ;;
    *) echo "Unknown argument: $arg" >&2; exit 1 ;;
  esac
done

SPLIT_PER_ABI=1
if [[ "$FLAVOR" == "dev" && $ALL_ABI -eq 0 ]]; then
  SPLIT_PER_ABI=0
fi

# -------- Read version --------

VERSION=$(/usr/bin/awk '/^version:/ {print $2; exit}' "$PUBSPEC")
[[ -z "$VERSION" ]] && { echo "✗ Could not read version from pubspec.yaml" >&2; exit 1; }

echo
echo "  current: \033[36m$VERSION\033[0m"
echo "  flavor : \033[36m$FLAVOR\033[0m"

# -------- Debug build (no bump) --------

if [[ $DEBUG -eq 1 ]]; then
  echo
  echo "▶ flutter build apk --debug --flavor $FLAVOR --target-platform android-arm64 --android-project-arg=pawtermAbiFilter=arm64-v8a"
  flutter build apk --debug --flavor "$FLAVOR" --target-platform android-arm64 --android-project-arg=pawtermAbiFilter=arm64-v8a
  echo
  echo "\033[32m✓ debug build done\033[0m  →  $OUT_DIR"
  exit 0
fi

# -------- Bump (prod only, skip in CI) --------

if [[ "$FLAVOR" == "prod" && "${CI:-}" != "true" ]]; then
  SEMVER="${VERSION%%+*}"
  BUILD="${VERSION#*+}"
  [[ "$BUILD" == "$VERSION" ]] && BUILD="1"
  IFS='.' read -r MAJOR MINOR PATCH <<<"$SEMVER"

  echo
  cat <<MENU
  Choose bump:
    1)  same     $VERSION
    2)  build    ${SEMVER}+$((BUILD+1))
    3)  patch    $MAJOR.$MINOR.$((PATCH+1))+1
    4)  minor    $MAJOR.$((MINOR+1)).0+1
    5)  major    $((MAJOR+1)).0.0+1
    q)  quit
MENU

  printf "  → [1-5/q, default=3]: "
  read -r CHOICE
  CHOICE="${CHOICE:-3}"

  case "$CHOICE" in
    1|same)  NEW="$VERSION" ;;
    2|build) NEW="${SEMVER}+$((BUILD+1))" ;;
    3|patch) NEW="$MAJOR.$MINOR.$((PATCH+1))+1" ;;
    4|minor) NEW="$MAJOR.$((MINOR+1)).0+1" ;;
    5|major) NEW="$((MAJOR+1)).0.0+1" ;;
    q|quit)  echo "  aborted."; exit 0 ;;
    *)       echo "  invalid choice" >&2; exit 1 ;;
  esac

  if [[ "$NEW" != "$VERSION" ]]; then
    /usr/bin/python3 - "$PUBSPEC" "$NEW" <<'PY'
import sys, re, pathlib
path, new = sys.argv[1], sys.argv[2]
p = pathlib.Path(path)
p.write_text(re.sub(r'^version: .*$', f'version: {new}', p.read_text(), flags=re.MULTILINE, count=1))
PY
    echo "  bumped  → \033[32m$NEW\033[0m"
  fi
  VERSION="$NEW"
fi

echo

# -------- Build --------

find "$OUT_DIR" -maxdepth 1 -name "*.apk" -delete 2>/dev/null || true
find "$DIST_DIR" -maxdepth 1 -name "$NAME_PREFIX-*.apk" -delete 2>/dev/null || true

echo "▶ flutter pub get"
flutter pub get

echo
if [[ $SPLIT_PER_ABI -eq 1 ]]; then
  echo "▶ flutter build apk --release --flavor $FLAVOR --split-per-abi"
  flutter build apk --release --flavor "$FLAVOR" --split-per-abi
else
  echo "▶ flutter build apk --release --flavor $FLAVOR --target-platform android-arm64 --android-project-arg=pawtermAbiFilter=arm64-v8a"
  flutter build apk --release --flavor "$FLAVOR" --target-platform android-arm64 --android-project-arg=pawtermAbiFilter=arm64-v8a
fi

# -------- Organize into versioned dir --------

VERSION_DIR="$RELEASES_DIR/$VERSION"
mkdir -p "$VERSION_DIR"
find "$VERSION_DIR" -maxdepth 1 -type f -name "${NAME_PREFIX}-${VERSION}-*.apk" -delete 2>/dev/null || true

ARM64=""
if [[ $SPLIT_PER_ABI -eq 1 ]]; then
  while IFS= read -r f; do
    TARGET="$VERSION_DIR/${NAME_PREFIX}-${VERSION}-arm64-v8a.apk"
    /bin/cp "$f" "$TARGET"
    ARM64="$TARGET"
  done < <(find "$OUT_DIR" -maxdepth 1 -type f -name "*arm64*-release.apk")
  while IFS= read -r f; do
    /bin/cp "$f" "$VERSION_DIR/${NAME_PREFIX}-${VERSION}-armeabi-v7a.apk"
  done < <(find "$OUT_DIR" -maxdepth 1 -type f -name "*armeabi*-release.apk")
  while IFS= read -r f; do
    /bin/cp "$f" "$VERSION_DIR/${NAME_PREFIX}-${VERSION}-x86_64.apk"
  done < <(find "$OUT_DIR" -maxdepth 1 -type f -name "*x86_64*-release.apk")
else
  RELEASE_APK="$OUT_DIR/app-${FLAVOR}-release.apk"
  [[ -f "$RELEASE_APK" ]] || RELEASE_APK="$OUT_DIR/app-release.apk"
  [[ -f "$RELEASE_APK" ]] || RELEASE_APK="$(find "$OUT_DIR" -maxdepth 1 -type f -name "*release.apk" | head -n 1)"
  TARGET="$VERSION_DIR/${NAME_PREFIX}-${VERSION}-arm64-v8a.apk"
  /bin/cp "$RELEASE_APK" "$TARGET"
  ARM64="$TARGET"
fi

find "$OUT_DIR" -maxdepth 1 -name "*release.apk" -delete 2>/dev/null || true

[[ -z "$ARM64" ]] && { echo "✗ arm64 APK not produced" >&2; exit 1; }

LATEST="$OUT_DIR/latest-$FLAVOR.apk"
/bin/cp "$ARM64" "$LATEST"
if [[ "$FLAVOR" == "prod" ]]; then
  /bin/cp "$ARM64" "$OUT_DIR/latest.apk"
fi

# -------- Copy to dist/ --------

mkdir -p "$DIST_DIR"
if [[ "$FLAVOR" == "prod" ]]; then
  while IFS= read -r f; do
    /bin/cp "$f" "$DIST_DIR/"
  done < <(find "$VERSION_DIR" -maxdepth 1 -type f -name "${NAME_PREFIX}-${VERSION}-*.apk")
fi

# -------- Report --------

echo
echo "\033[32m✓ build done\033[0m"
echo "  version : $VERSION"
echo "  flavor  : $FLAVOR"
echo "  abi     : $([[ $SPLIT_PER_ABI -eq 1 ]] && echo split || echo arm64)"
echo "  releases: $VERSION_DIR"
/bin/ls -1 "$VERSION_DIR" | /usr/bin/sed 's/^/    /'
echo "  latest  : $LATEST"
if [[ "$FLAVOR" == "dev" ]]; then
  echo "  dist    : skipped for local dev build"
fi
