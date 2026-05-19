#!/usr/bin/env zsh
# Bump Mac app version, commit, push to main, then push release tag.
#
# Default: push tag → CI builds .app + GitHub Release
# --local:  zip local PawTerm.app and upload directly, CI skips build
#
# Usage:
#   ./scripts/release.sh           # CI build
#   ./scripts/release.sh --local   # upload local app (run build.sh --release first)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MAC_DIR="$(dirname "$SCRIPT_DIR")"
REPO_ROOT="$(dirname "$MAC_DIR")"
PLIST="$MAC_DIR/Info.plist"

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

CURRENT=$(/usr/bin/python3 -c "
import plistlib
with open('$PLIST', 'rb') as f: pl = plistlib.load(f)
print(pl.get('CFBundleShortVersionString', '0.0.0'))
")

IFS='.' read -r MAJOR MINOR PATCH <<<"$CURRENT"

echo
echo "  current: \033[36m$CURRENT\033[0m"
echo

# -------- 2. Bump --------

cat <<MENU
  Choose bump:
    1)  same     $CURRENT  (re-release)
    2)  patch    $MAJOR.$MINOR.$((PATCH+1))
    3)  minor    $MAJOR.$((MINOR+1)).0
    4)  major    $((MAJOR+1)).0.0
    q)  quit
MENU

printf "  → [1-4/q, default=2]: "
read -r CHOICE
CHOICE="${CHOICE:-2}"

case "$CHOICE" in
  1|same)  NEW="$CURRENT" ;;
  2|patch) NEW="$MAJOR.$MINOR.$((PATCH+1))" ;;
  3|minor) NEW="$MAJOR.$((MINOR+1)).0" ;;
  4|major) NEW="$((MAJOR+1)).0.0" ;;
  q|quit)  echo "  aborted."; exit 0 ;;
  *)       echo "  invalid choice" >&2; exit 1 ;;
esac

TAG="release/mac-v$NEW"

echo
echo "  new version : \033[32m$NEW\033[0m"
echo "  tag         : \033[1m$TAG\033[0m"
echo

# -------- 3. Check tag --------

git -C "$REPO_ROOT" tag -l | grep -qx "$TAG" && { echo "✗ Tag $TAG already exists." >&2; exit 1; }

# -------- 4. Confirm --------

if [[ $LOCAL -eq 1 ]]; then
  APP="$MAC_DIR/PawTerm.app"
  if [[ ! -d "$APP" ]]; then
    echo "✗ PawTerm.app not found. Run mac/scripts/build.sh --release first." >&2
    exit 1
  fi
  echo "  local artifact: PawTerm.app"
  echo
  printf "  → bump, commit, push, upload artifact, tag? [y/N]: "
else
  printf "  → bump, commit, push, tag (CI builds)? [y/N]: "
fi
read -r CONFIRM
[[ "${CONFIRM:-N}" != [yY] ]] && { echo "  aborted."; exit 0; }

# -------- 5. Update Info.plist --------

if [[ "$NEW" != "$CURRENT" ]]; then
  /usr/bin/python3 - "$PLIST" "$NEW" <<'PY'
import plistlib, pathlib, sys
path, ver = sys.argv[1], sys.argv[2]
p = pathlib.Path(path)
with open(p, 'rb') as f: pl = plistlib.load(f)
pl['CFBundleShortVersionString'] = ver
with open(p, 'wb') as f: plistlib.dump(pl, f)
PY
fi

# -------- 6. Commit + push main --------

git -C "$REPO_ROOT" add mac/Info.plist
git -C "$REPO_ROOT" diff --cached --quiet || git -C "$REPO_ROOT" commit -m "chore(mac): bump version to $NEW"
git -C "$REPO_ROOT" push origin main

# -------- 7. Tag + push (+ optional local release) --------

echo
if [[ $LOCAL -eq 1 ]]; then
  DIST="$REPO_ROOT/dist-mac"
  mkdir -p "$DIST"
  ZIP="$DIST/PawTerm-${NEW}-mac.zip"
  echo "▶ zipping PawTerm.app"
  ditto -c -k --keepParent "$MAC_DIR/PawTerm.app" "$ZIP"

  SERVER_VERSION=$(/usr/bin/python3 -c "import json; print(json.load(open('$REPO_ROOT/server/package.json'))['version'])" 2>/dev/null || echo "")
  TITLE="$TAG"
  [[ -n "$SERVER_VERSION" ]] && TITLE="$TAG  ·  server v$SERVER_VERSION"

  echo "▶ gh release create $TAG (local artifact)"
  gh release create "$TAG" \
    "$ZIP" \
    --title "$TITLE" \
    --generate-notes \
    --repo Airoucat233/pawterm

  echo "▶ git tag $TAG && git push origin $TAG"
  git -C "$REPO_ROOT" tag "$TAG"
  git -C "$REPO_ROOT" push origin "$TAG"

  echo
  echo "\033[32m✓ released with local artifact\033[0m"
  echo "  Release: https://github.com/Airoucat233/pawterm/releases/tag/$TAG"
else
  echo "▶ git tag $TAG && git push origin $TAG"
  git -C "$REPO_ROOT" tag "$TAG"
  git -C "$REPO_ROOT" push origin "$TAG"

  echo
  echo "\033[32m✓ tag pushed\033[0m — CI is building Mac .app"
  echo "  Watch:   https://github.com/Airoucat233/pawterm/actions"
  echo "  Release: https://github.com/Airoucat233/pawterm/releases/tag/$TAG"
fi
