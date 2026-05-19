#!/usr/bin/env zsh
# Bump Flutter app version, commit, push to main, then push release tag.
# CI picks up the tag and builds APK + GitHub Release.
#
# Usage: ./scripts/release.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(dirname "$SCRIPT_DIR")"
REPO_ROOT="$(dirname "$APP_DIR")"
PUBSPEC="$APP_DIR/pubspec.yaml"

# -------- 0. Branch guard --------

CURRENT_BRANCH=$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
if [[ "$CURRENT_BRANCH" != "main" ]]; then
  echo "✗ release must be run from main (current: $CURRENT_BRANCH)" >&2
  exit 1
fi

# -------- 1. Read current version --------

CURRENT=$(/usr/bin/awk '/^version:/ {print $2; exit}' "$PUBSPEC")
[[ -z "$CURRENT" ]] && { echo "✗ Could not read version from pubspec.yaml" >&2; exit 1; }

SEMVER="${CURRENT%%+*}"
BUILD="${CURRENT#*+}"
[[ "$BUILD" == "$CURRENT" ]] && BUILD="1"
IFS='.' read -r MAJOR MINOR PATCH <<<"$SEMVER"

echo
echo "  current: \033[36m$CURRENT\033[0m"
echo

# -------- 2. Bump --------

cat <<MENU
  Choose bump:
    1)  same     $CURRENT  (re-release)
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
  1|same)  NEW="$CURRENT" ;;
  2|build) NEW="${SEMVER}+$((BUILD+1))" ;;
  3|patch) NEW="$MAJOR.$MINOR.$((PATCH+1))+1" ;;
  4|minor) NEW="$MAJOR.$((MINOR+1)).0+1" ;;
  5|major) NEW="$((MAJOR+1)).0.0+1" ;;
  q|quit)  echo "  aborted."; exit 0 ;;
  *)       echo "  invalid choice" >&2; exit 1 ;;
esac

TAG="release/app-v${NEW%%+*}"

echo
echo "  new version : \033[32m$NEW\033[0m"
echo "  tag         : \033[1m$TAG\033[0m"
echo

# -------- 3. Check tag --------

git -C "$REPO_ROOT" tag -l | grep -qx "$TAG" && { echo "✗ Tag $TAG already exists." >&2; exit 1; }

# -------- 4. Confirm --------

printf "  → bump, commit, push, tag? [y/N]: "
read -r CONFIRM
[[ "${CONFIRM:-N}" != [yY] ]] && { echo "  aborted."; exit 0; }

# -------- 5. Update pubspec --------

if [[ "$NEW" != "$CURRENT" ]]; then
  /usr/bin/python3 - "$PUBSPEC" "$NEW" <<'PY'
import sys, re, pathlib
path, new = sys.argv[1], sys.argv[2]
p = pathlib.Path(path)
p.write_text(re.sub(r'^version: .*$', f'version: {new}', p.read_text(), flags=re.MULTILINE, count=1))
PY
fi

# -------- 6. Commit + push main --------

git -C "$REPO_ROOT" add app/pubspec.yaml
git -C "$REPO_ROOT" diff --cached --quiet || git -C "$REPO_ROOT" commit -m "chore(app): bump version to $NEW"
git -C "$REPO_ROOT" push origin main

# -------- 7. Tag + push --------

echo
echo "▶ git tag $TAG && git push origin $TAG"
git -C "$REPO_ROOT" tag "$TAG"
git -C "$REPO_ROOT" push origin "$TAG"

echo
echo "\033[32m✓ tag pushed\033[0m — CI is building APK"
echo "  Watch:   https://github.com/Airoucat233/pawterm/actions"
echo "  Release: https://github.com/Airoucat233/pawterm/releases/tag/$TAG"
