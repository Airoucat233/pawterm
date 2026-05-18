#!/usr/bin/env zsh
# Build a release IPA with version bumping support.
#
# Output layout:
#   build/ios/ipa/
#     ├─ latest.ipa                          # always the newest build
#     └─ releases/
#         └─ <version>/
#             └─ pawterm-<version>.ipa
#
# Prerequisites: Mac + Xcode + valid signing config in ios/Runner.xcodeproj

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(dirname "$SCRIPT_DIR")"
cd "$APP_DIR"

PUBSPEC="$APP_DIR/pubspec.yaml"
OUT_DIR="$APP_DIR/build/ios/ipa"
RELEASES_DIR="$OUT_DIR/releases"

# -------- 0. Platform check --------

if [[ "$(uname)" != "Darwin" ]]; then
  echo "✗ iOS builds require macOS." >&2
  exit 1
fi

# -------- 1. Read current version --------

CURRENT=$(/usr/bin/awk '/^version:/ {print $2; exit}' "$PUBSPEC")
if [[ -z "$CURRENT" ]]; then
  echo "✗ Could not read version from $PUBSPEC" >&2
  exit 1
fi

SEMVER="${CURRENT%%+*}"
BUILD="${CURRENT#*+}"
[[ "$BUILD" == "$CURRENT" ]] && BUILD="1"

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

# -------- 4. Build --------

echo
echo "▶ flutter build ipa --release"
flutter build ipa --release

# -------- 5. Organize outputs --------

VERSION_DIR="$RELEASES_DIR/$VERSION"
/bin/mkdir -p "$VERSION_DIR"

SRC_IPA="$APP_DIR/build/ios/ipa/pawterm.ipa"
if [[ ! -f "$SRC_IPA" ]]; then
  # flutter may name it after the scheme; try a glob
  SRC_IPA=""
  for f in "$APP_DIR/build/ios/ipa/"*.ipa; do
    SRC_IPA="$f"
    break
  done
fi

if [[ -z "$SRC_IPA" || ! -f "$SRC_IPA" ]]; then
  echo "✗ IPA not found in build/ios/ipa/" >&2
  exit 1
fi

DEST_IPA="$VERSION_DIR/pawterm-${VERSION}.ipa"
/bin/cp "$SRC_IPA" "$DEST_IPA"

# -------- 6. latest.ipa --------

LATEST="$OUT_DIR/latest.ipa"
/bin/cp "$DEST_IPA" "$LATEST"

# -------- 7. Report --------

echo
echo "\033[32m✓ build done\033[0m"
echo "  version:  $VERSION"
echo "  ipa →     $DEST_IPA"
echo "  size:     $(/usr/bin/du -h "$DEST_IPA" | /usr/bin/awk '{print $1}')"
echo "  latest →  $LATEST"
echo
echo "  run ./scripts/release.sh to create a GitHub Release."

/usr/bin/open -R "$DEST_IPA"
