#!/usr/bin/env zsh
# Bump Flutter app version, commit, push to main, then push release tag.
#
# Default: push tag → CI builds APK + GitHub Release
# --local:  upload local dist/*.apk directly, CI skips build
#
# Usage:
#   ./scripts/release.sh           # CI build
#   ./scripts/release.sh --local   # upload local artifacts

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(dirname "$SCRIPT_DIR")"
REPO_ROOT="$(dirname "$APP_DIR")"
PUBSPEC="$APP_DIR/pubspec.yaml"

LOCAL=0
for arg in "$@"; do
  case "$arg" in --local) LOCAL=1 ;; esac
done

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

TAG="release/v${NEW%%+*}"

echo
echo "  new version : \033[32m$NEW\033[0m"
echo "  tag         : \033[1m$TAG\033[0m"
echo

# -------- 3. Check tag --------

git -C "$REPO_ROOT" tag -l | grep -qx "$TAG" && { echo "✗ Tag $TAG already exists." >&2; exit 1; }

# -------- 4. Confirm --------

if [[ $LOCAL -eq 1 ]]; then
  ARTIFACTS=("$REPO_ROOT"/dist/pawterm-*.apk "$REPO_ROOT"/dist-mac/PawTerm-*.zip)
  ARTIFACTS=(${^ARTIFACTS}(N))  # filter non-existent
  if [[ ${#ARTIFACTS[@]} -eq 0 ]]; then
    echo "✗ No artifacts found. Run build-apk.sh (and optionally mac/scripts/build.sh --release) first." >&2
    exit 1
  fi
  echo "  local artifacts:"
  for f in "${ARTIFACTS[@]}"; do echo "    + $(basename "$f")"; done
  echo
  printf "  → bump, commit, push, upload artifacts, tag? [y/N]: "
else
  printf "  → bump, commit, push, tag (CI builds)? [y/N]: "
fi
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

# -------- 7. Tag + push (+ optional local release) --------

echo
if [[ $LOCAL -eq 1 ]]; then
  SERVER_VERSION=$(/usr/bin/python3 -c "import json; print(json.load(open('$REPO_ROOT/server/package.json'))['version'])" 2>/dev/null || echo "")
  TITLE="$TAG"
  [[ -n "$SERVER_VERSION" ]] && TITLE="$TAG  ·  server v$SERVER_VERSION"

  echo "▶ gh release create $TAG (local artifacts)"
  gh release create "$TAG" \
    "${ARTIFACTS[@]}" \
    --title "$TITLE" \
    --generate-notes \
    --repo Airoucat233/pawterm

  echo "▶ git tag $TAG && git push origin $TAG"
  git -C "$REPO_ROOT" tag "$TAG"
  git -C "$REPO_ROOT" push origin "$TAG"

  echo
  echo "\033[32m✓ released with local artifacts\033[0m"
  echo "  Release: https://github.com/Airoucat233/pawterm/releases/tag/$TAG"
else
  echo "▶ git tag $TAG && git push origin $TAG"
  git -C "$REPO_ROOT" tag "$TAG"
  git -C "$REPO_ROOT" push origin "$TAG"

  echo
  echo "\033[32m✓ tag pushed\033[0m — CI is building APK"
  echo "  Watch:   https://github.com/Airoucat233/pawterm/actions"
  echo "  Release: https://github.com/Airoucat233/pawterm/releases/tag/$TAG"
fi
