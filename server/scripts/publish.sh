#!/usr/bin/env zsh
# Bump server version, commit, push, push release tag, then npm publish.
#
# --prerelease: prerelease publish from any branch (tag: prerelease-server-v*, npm tag: prerelease)
# --dev: deprecated alias for --prerelease
#
# Usage:
#   ./scripts/publish.sh               # publish to npm latest (main branch)
#   ./scripts/publish.sh --prerelease  # publish to npm prerelease tag (any branch)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVER_DIR="$(dirname "$SCRIPT_DIR")"
REPO_ROOT="$(dirname "$SERVER_DIR")"
PKG="$SERVER_DIR/package.json"

PRERELEASE=0
USED_DEV_ALIAS=0
for arg in "$@"; do
  case "$arg" in
    --prerelease|--pre) PRERELEASE=1 ;;
    --dev) PRERELEASE=1; USED_DEV_ALIAS=1 ;;
  esac
done

if [[ $USED_DEV_ALIAS -eq 1 ]]; then
  echo "warning: --dev is deprecated for server publish; use --prerelease."
fi

# -------- 0. Branch guard --------

CURRENT_BRANCH=$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
if [[ $PRERELEASE -eq 0 && "$CURRENT_BRANCH" != "main" ]]; then
  echo "✗ release must be run from main (current: $CURRENT_BRANCH)" >&2
  echo "  use --prerelease to publish from a non-main branch" >&2
  exit 1
fi

# -------- 1. Read current version --------

CURRENT=$(/usr/bin/python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['version'])" "$PKG")
SEMVER="${CURRENT%%+*}"
IFS='.' read -r MAJOR MINOR PATCH <<<"$SEMVER"

echo
printf "  current: \033[36m%s\033[0m\n" "$CURRENT"
[[ $PRERELEASE -eq 1 ]] && echo "  mode   : prerelease (tag: prerelease-server-v*, npm tag: prerelease)"
echo

# -------- 2. Bump --------

# For prerelease: extract existing pre-release counter from versions like
# 0.6.3-prerelease.2. Also migrate old 0.6.3-dev.2 versions to
# 0.6.3-prerelease.1 rather than continuing the old naming.
PRE_BASE="$CURRENT"
PRE_N=0
if [[ "$CURRENT" =~ -prerelease\.([0-9]+)$ ]]; then
  PRE_BASE="${CURRENT%%-prerelease.*}"
  PRE_N="${match[1]}"
elif [[ "$CURRENT" =~ -dev\.([0-9]+)$ ]]; then
  PRE_BASE="${CURRENT%%-dev.*}"
  PRE_N=0
fi

if [[ "$PRE_BASE" == *.*.* ]]; then
  MAJOR_P="${PRE_BASE%%.*}"; REST="${PRE_BASE#*.}"; MINOR_P="${REST%%.*}"; PATCH_P="${REST#*.}"
else
  MAJOR_P="$MAJOR"; MINOR_P="$MINOR"; PATCH_P="$PATCH"
fi

if [[ $PRERELEASE -eq 1 ]]; then
  # If already a prerelease version, offer "same" as first/default option.
  if [[ $PRE_N -gt 0 ]]; then
    cat <<MENU
  Choose bump:
    1)  same     $CURRENT  (resume / re-run)
    2)  prerelease ${PRE_BASE}-prerelease.$((PRE_N+1))
    3)  patch    $MAJOR_P.$MINOR_P.$((PATCH_P+1))-prerelease.1
    4)  minor    $MAJOR_P.$((MINOR_P+1)).0-prerelease.1
    q)  quit
MENU
    printf "  → [1-4/q, default=1]: "
    read -r CHOICE
    CHOICE="${CHOICE:-1}"
    case "$CHOICE" in
      1|same)  NEW="$CURRENT" ;;
      2|prerelease|pre) NEW="${PRE_BASE}-prerelease.$((PRE_N+1))" ;;
      3|patch) NEW="$MAJOR_P.$MINOR_P.$((PATCH_P+1))-prerelease.1" ;;
      4|minor) NEW="$MAJOR_P.$((MINOR_P+1)).0-prerelease.1" ;;
      q|quit)  echo "  aborted."; exit 0 ;;
      *)       echo "  invalid choice" >&2; exit 1 ;;
    esac
  else
    cat <<MENU
  Choose bump:
    1)  prerelease ${PRE_BASE}-prerelease.1
    2)  patch    $MAJOR_P.$MINOR_P.$((PATCH_P+1))-prerelease.1
    3)  minor    $MAJOR_P.$((MINOR_P+1)).0-prerelease.1
    4)  major    $((MAJOR_P+1)).0.0-prerelease.1
    q)  quit
MENU
    printf "  → [1-4/q, default=1]: "
    read -r CHOICE
    CHOICE="${CHOICE:-1}"
    case "$CHOICE" in
      1|prerelease|pre) NEW="${PRE_BASE}-prerelease.1" ;;
      2|patch) NEW="$MAJOR_P.$MINOR_P.$((PATCH_P+1))-prerelease.1" ;;
      3|minor) NEW="$MAJOR_P.$((MINOR_P+1)).0-prerelease.1" ;;
      4|major) NEW="$((MAJOR_P+1)).0.0-prerelease.1" ;;
      q|quit)  echo "  aborted."; exit 0 ;;
      *)       echo "  invalid choice" >&2; exit 1 ;;
    esac
  fi
else
  cat <<MENU
  Choose bump:
    1)  same     $CURRENT  (re-publish)
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
fi

if [[ $PRERELEASE -eq 1 ]]; then
  TAG="prerelease-server-v$NEW"
else
  TAG="release-server-v$NEW"
fi

echo
printf "  new version : \033[32m%s\033[0m\n" "$NEW"
printf "  tag         : \033[1m%s\033[0m\n" "$TAG"
echo

# -------- 3. Check tag --------

TAG_EXISTS=0
git -C "$REPO_ROOT" tag -l | grep -qx "$TAG" && TAG_EXISTS=1

# -------- 4. Confirm --------

if [[ $PRERELEASE -eq 1 ]]; then
  printf "  → bump, commit, push, tag, npm publish --tag prerelease? [y/N]: "
else
  printf "  → bump, commit, push, tag, npm publish? [y/N]: "
fi
read -r CONFIRM
[[ "${CONFIRM:-N}" != [yY] ]] && { echo "  aborted."; exit 0; }

# -------- 5. Update package.json --------

if [[ "$NEW" != "$CURRENT" ]]; then
  /usr/bin/python3 - "$PKG" "$NEW" <<'PY'
import json, sys, pathlib
path, new = sys.argv[1], sys.argv[2]
p = pathlib.Path(path)
data = json.loads(p.read_text())
data['version'] = new
p.write_text(json.dumps(data, indent=2) + '\n')
PY
fi

# -------- 6. Commit + push --------

git -C "$REPO_ROOT" add server/package.json
if git -C "$REPO_ROOT" diff --cached --quiet; then
  echo "  (commit already done — skipping)"
else
  git -C "$REPO_ROOT" commit -m "chore(server): bump version to $NEW"
fi

REMOTE_BRANCH=$(git -C "$REPO_ROOT" rev-parse --abbrev-ref --symbolic-full-name @{u} 2>/dev/null || echo "")
LOCAL_SHA=$(git -C "$REPO_ROOT" rev-parse HEAD)
REMOTE_SHA=$(git -C "$REPO_ROOT" rev-parse "@{u}" 2>/dev/null || echo "")
if [[ "$LOCAL_SHA" == "$REMOTE_SHA" ]]; then
  echo "  (push already done — skipping)"
else
  if [[ $PRERELEASE -eq 1 ]]; then
    git -C "$REPO_ROOT" push origin "$CURRENT_BRANCH"
  else
    git -C "$REPO_ROOT" push origin main
  fi
fi

# -------- 7. Tag + push --------

if [[ $TAG_EXISTS -eq 0 ]]; then
  echo
  echo "▶ git tag $TAG && git push origin $TAG"
  git -C "$REPO_ROOT" tag "$TAG"
  git -C "$REPO_ROOT" push origin "$TAG"
else
  echo "  tag $TAG already exists, skipping"
fi

# -------- 8. Build + npm publish --------

# Check if this version is already published
NPM_PUBLISHED=$(npm view "pawterm-server@$NEW" version 2>/dev/null || echo "")
if [[ "$NPM_PUBLISHED" == "$NEW" ]]; then
  echo "  (npm pawterm-server@$NEW already published — skipping)"
else
  echo
  echo "▶ pnpm --filter @pawterm/web run build"
  cd "$REPO_ROOT"
  pnpm --filter @pawterm/web run build

  echo
  echo "▶ pnpm --filter pawterm-server run build"
  cd "$SERVER_DIR"
  pnpm build

  echo
  if [[ $PRERELEASE -eq 1 ]]; then
    echo "▶ npm publish --tag prerelease --registry https://registry.npmjs.org"
    npm publish --tag prerelease --registry https://registry.npmjs.org
  else
    echo "▶ npm publish --registry https://registry.npmjs.org"
    npm publish --registry https://registry.npmjs.org
  fi
fi

echo
printf "\033[32m✓ published pawterm-server@%s\033[0m\n" "$NEW"
echo "  npm:  https://www.npmjs.com/package/pawterm-server"
echo "  tag:  $TAG"
