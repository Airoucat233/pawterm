#!/usr/bin/env zsh
# Bump Flutter app version, commit, push, then push release tag.
#
# Default: bump version → push tag → CI builds APK + Mac + GitHub Release
# --local:  verify exact artifacts in dist/, create GH Release, push tag (no bump)
#           if tag already exists, prompts whether to replace artifacts
# --dev:    prerelease build from any branch (tag: dev/v*, GH Release: prerelease)
#           can be combined with --local
#
# Usage:
#   ./scripts/release.sh               # CI build (main branch, release/v*)
#   ./scripts/release.sh --local       # upload local artifacts (main branch)
#   ./scripts/release.sh --dev         # CI build (any branch, dev/v*, prerelease)
#   ./scripts/release.sh --dev --local # upload local artifacts (any branch, prerelease)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
APP_DIR="$REPO_ROOT/app"
PUBSPEC="$APP_DIR/pubspec.yaml"

LOCAL=0
DEV=0
for arg in "$@"; do
  case "$arg" in
    --local) LOCAL=1 ;;
    --dev)   DEV=1 ;;
  esac
done

# -------- 0. Branch guard --------

CURRENT_BRANCH=$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
if [[ $DEV -eq 0 && "$CURRENT_BRANCH" != "main" ]]; then
  echo "✗ release must be run from main (current: $CURRENT_BRANCH)" >&2
  echo "  use --dev to release from a non-main branch" >&2
  exit 1
fi

# -------- Read current version --------

CURRENT=$(/usr/bin/awk '/^version:/ {print $2; exit}' "$PUBSPEC")
[[ -z "$CURRENT" ]] && { echo "✗ Could not read version from pubspec.yaml" >&2; exit 1; }
SEMVER="${CURRENT%%+*}"

# ══════════════════════════════════════════════════════════════
# --local: verify artifacts exist for current version, then release
# ══════════════════════════════════════════════════════════════

if [[ $LOCAL -eq 1 ]]; then
  if [[ $DEV -eq 1 ]]; then
    TAG="dev/v$SEMVER"
  else
    TAG="release/v$SEMVER"
  fi
  echo
  printf "  version : \033[36m%s\033[0m  →  tag: \033[1m%s\033[0m\n" "$CURRENT" "$TAG"
  [[ $DEV -eq 1 ]] && echo "  mode    : dev (prerelease)"
  echo

  # ---- Check artifacts (exact filenames) ----
  ARM64="$REPO_ROOT/dist/pawterm-${CURRENT}-arm64-v8a.apk"
  ARMEABI="$REPO_ROOT/dist/pawterm-${CURRENT}-armeabi-v7a.apk"

  ARTIFACTS=()
  MISSING=()

  [[ -f "$ARM64"   ]] && ARTIFACTS+=("$ARM64")   || MISSING+=("$(basename "$ARM64")")
  [[ -f "$ARMEABI" ]] && ARTIFACTS+=("$ARMEABI") || true   # optional

  # Mac zip only for non-dev
  if [[ $DEV -eq 0 ]]; then
    MAC_VER=$(/usr/bin/python3 -c "
import plistlib
with open('$REPO_ROOT/mac/Info.plist', 'rb') as f: pl = plistlib.load(f)
print(pl.get('CFBundleShortVersionString', ''))
" 2>/dev/null || echo "")
    MAC_ZIP="$REPO_ROOT/dist/PawTerm-${MAC_VER}-mac.zip"
    [[ -n "$MAC_VER" && -f "$MAC_ZIP" ]] && ARTIFACTS+=("$MAC_ZIP") || true  # optional
  fi

  if [[ ${#ARTIFACTS[@]} -eq 0 ]]; then
    echo "✗ No artifacts found. Run app/scripts/build-apk.sh first." >&2
    exit 1
  fi
  if [[ ${#MISSING[@]} -gt 0 ]]; then
    echo "✗ Required artifact missing:" >&2
    for f in "${MISSING[@]}"; do echo "    $f" >&2; done
    exit 1
  fi

  echo "  artifacts:"
  for f in "${ARTIFACTS[@]}"; do echo "    + $(basename "$f")"; done
  echo

  # ---- Check tag ----
  TAG_EXISTS=0
  git -C "$REPO_ROOT" tag -l | grep -qx "$TAG" && TAG_EXISTS=1

  if [[ $TAG_EXISTS -eq 1 ]]; then
    printf "  Tag $TAG already exists. Replace artifacts in existing release? [y/N]: "
    read -r CONFIRM
    [[ "${CONFIRM:-N}" != [yY] ]] && { echo "  aborted."; exit 0; }

    echo
    echo "▶ removing old APK assets from $TAG …"
    existing=$(gh release view "$TAG" --repo Airoucat233/pawterm --json assets --jq '.assets[].name' 2>/dev/null || true)
    while IFS= read -r asset; do
      case "$asset" in
        pawterm-*-arm64*.apk|pawterm-*-armeabi*.apk|pawterm-*-x86*.apk|PawTerm-*-mac.zip)
          echo "  - $asset"
          gh release delete-asset "$TAG" "$asset" --yes --repo Airoucat233/pawterm 2>/dev/null || true
          ;;
      esac
    done <<< "$existing"

    echo "▶ gh release upload $TAG"
    gh release upload "$TAG" "${ARTIFACTS[@]}" --repo Airoucat233/pawterm

    echo
    printf "\033[32m✓ artifacts updated\033[0m  https://github.com/Airoucat233/pawterm/releases/tag/%s\n" "$TAG"
    exit 0
  fi

  # ---- Confirm ----
  printf "  → create GH Release, push tag? [y/N]: "
  read -r CONFIRM
  [[ "${CONFIRM:-N}" != [yY] ]] && { echo "  aborted."; exit 0; }

  # ---- Commit version bumps (only for non-dev full release) ----
  if [[ $DEV -eq 0 ]]; then
    git -C "$REPO_ROOT" add app/pubspec.yaml mac/Info.plist
    git -C "$REPO_ROOT" diff --cached --quiet || git -C "$REPO_ROOT" commit -m "chore: bump version to $SEMVER"
    git -C "$REPO_ROOT" push origin main
  fi

  # ---- Release ----
  SERVER_VERSION=$(/usr/bin/python3 -c "import json; print(json.load(open('$REPO_ROOT/server/package.json'))['version'])" 2>/dev/null || echo "")
  if [[ $DEV -eq 1 ]]; then
    TITLE="[dev] v$SEMVER"
    [[ -n "$SERVER_VERSION" ]] && TITLE="[dev] v$SEMVER  ·  server v$SERVER_VERSION"
  else
    TITLE="v$SEMVER"
    [[ -n "$SERVER_VERSION" ]] && TITLE="v$SEMVER  ·  server v$SERVER_VERSION"
  fi

  PRERELEASE_FLAG=""
  [[ $DEV -eq 1 ]] && PRERELEASE_FLAG="--prerelease"

  echo
  echo "▶ gh release create $TAG"
  gh release create "$TAG" \
    "${ARTIFACTS[@]}" \
    --title "$TITLE" \
    --generate-notes \
    $PRERELEASE_FLAG \
    --repo Airoucat233/pawterm

  echo "▶ git tag $TAG && git push origin $TAG"
  git -C "$REPO_ROOT" tag "$TAG"
  git -C "$REPO_ROOT" push origin "$TAG"

  echo
  printf "\033[32m✓ released\033[0m  https://github.com/Airoucat233/pawterm/releases/tag/%s\n" "$TAG"
  exit 0
fi

# ══════════════════════════════════════════════════════════════
# Default: bump → commit → push → push tag → CI builds
# ══════════════════════════════════════════════════════════════

BUILD="${CURRENT#*+}"
[[ "$BUILD" == "$CURRENT" ]] && BUILD="1"
IFS='.' read -r MAJOR MINOR PATCH <<<"$SEMVER"

echo
printf "  current: \033[36m%s\033[0m\n" "$CURRENT"
[[ $DEV -eq 1 ]] && echo "  mode   : dev (prerelease, tag: dev/v*)"
echo

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

if [[ $DEV -eq 1 ]]; then
  TAG="dev/v${NEW%%+*}"
else
  TAG="release/v${NEW%%+*}"
fi

echo
printf "  new version : \033[32m%s\033[0m\n" "$NEW"
printf "  tag         : \033[1m%s\033[0m\n" "$TAG"
echo

git -C "$REPO_ROOT" tag -l | grep -qx "$TAG" && { echo "✗ Tag $TAG already exists." >&2; exit 1; }

printf "  → bump, commit, push, tag (CI builds)? [y/N]: "
read -r CONFIRM
[[ "${CONFIRM:-N}" != [yY] ]] && { echo "  aborted."; exit 0; }

if [[ "$NEW" != "$CURRENT" ]]; then
  /usr/bin/python3 - "$PUBSPEC" "$NEW" <<'PY'
import sys, re, pathlib
path, new = sys.argv[1], sys.argv[2]
p = pathlib.Path(path)
p.write_text(re.sub(r'^version: .*$', f'version: {new}', p.read_text(), flags=re.MULTILINE, count=1))
PY
fi

git -C "$REPO_ROOT" add app/pubspec.yaml
git -C "$REPO_ROOT" diff --cached --quiet || git -C "$REPO_ROOT" commit -m "chore(app): bump version to $NEW"

if [[ $DEV -eq 1 ]]; then
  git -C "$REPO_ROOT" push origin "$CURRENT_BRANCH"
else
  git -C "$REPO_ROOT" push origin main
fi

echo
echo "▶ git tag $TAG && git push origin $TAG"
git -C "$REPO_ROOT" tag "$TAG"
git -C "$REPO_ROOT" push origin "$TAG"

echo
printf "\033[32m✓ tag pushed\033[0m — CI is building\n"
echo "  Watch:   https://github.com/Airoucat233/pawterm/actions"
echo "  Release: https://github.com/Airoucat233/pawterm/releases/tag/$TAG"
