#!/usr/bin/env zsh
# Create a GitHub Release for the current version.
#
# Collects artifacts built by build-apk.sh and build-ipa.sh, then runs:
#   gh release create <tag> <files...>
#
# Run AFTER both build scripts have produced artifacts for the same version.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(dirname "$SCRIPT_DIR")"
REPO_ROOT="$(dirname "$APP_DIR")"
cd "$APP_DIR"

PUBSPEC="$APP_DIR/pubspec.yaml"

# -------- 1. Read version --------

CURRENT=$(/usr/bin/awk '/^version:/ {print $2; exit}' "$PUBSPEC")
if [[ -z "$CURRENT" ]]; then
  echo "✗ Could not read version from $PUBSPEC" >&2
  exit 1
fi

TAG="v${CURRENT%%+*}"

echo
echo "  version: \033[36m$CURRENT\033[0m  →  tag: \033[1m$TAG\033[0m"
echo

# -------- 2. Collect artifacts --------

APK_DIR="$APP_DIR/build/app/outputs/flutter-apk/releases/$CURRENT"
IPA_DIR="$APP_DIR/build/ios/ipa/releases/$CURRENT"

RELEASE_FILES=()

# Android
for abi in arm64-v8a armeabi-v7a x86_64; do
  f="$APK_DIR/pawterm-${CURRENT}-${abi}.apk"
  if [[ -f "$f" ]]; then
    RELEASE_FILES+=("$f")
    echo "  + $(basename "$f")"
  fi
done

# iOS
IPA="$IPA_DIR/pawterm-${CURRENT}.ipa"
if [[ -f "$IPA" ]]; then
  RELEASE_FILES+=("$IPA")
  echo "  + $(basename "$IPA")"
fi

if [[ ${#RELEASE_FILES[@]} -eq 0 ]]; then
  echo "✗ No artifacts found for version $CURRENT." >&2
  echo "  Run build-apk.sh and/or build-ipa.sh first." >&2
  exit 1
fi

echo

# -------- 3. Confirm --------

printf "  → create GitHub Release $TAG with ${#RELEASE_FILES[@]} file(s)? [y/N]: "
read -r CONFIRM
if [[ "${CONFIRM:-N}" != "y" && "${CONFIRM:-N}" != "Y" ]]; then
  echo "  aborted."
  exit 0
fi

# -------- 4. Release title --------

SERVER_VERSION=$(python3 -c "import json; print(json.load(open('$REPO_ROOT/server/package.json'))['version'])" 2>/dev/null || echo "")
RELEASE_TITLE="$TAG"
[[ -n "$SERVER_VERSION" ]] && RELEASE_TITLE="$TAG  ·  server v$SERVER_VERSION"

# -------- 5. gh release create --------

echo
echo "▶ gh release create $TAG  (title: $RELEASE_TITLE)"
gh release create "$TAG" \
  "${RELEASE_FILES[@]}" \
  --title "$RELEASE_TITLE" \
  --generate-notes

echo
echo "\033[32m✓ released\033[0m  https://github.com/Airoucat233/pawterm/releases/tag/$TAG"
