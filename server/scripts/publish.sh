#!/usr/bin/env zsh
# Bump server version, commit, push, push release tag, then npm publish.
#
# --dev:  prerelease publish from any branch (tag: dev/server-v*, npm tag: dev)
#
# Usage:
#   ./scripts/publish.sh        # publish to npm latest (main branch)
#   ./scripts/publish.sh --dev  # publish to npm dev tag (any branch)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVER_DIR="$(dirname "$SCRIPT_DIR")"
REPO_ROOT="$(dirname "$SERVER_DIR")"
PKG="$SERVER_DIR/package.json"

DEV=0
for arg in "$@"; do
  case "$arg" in
    --dev) DEV=1 ;;
  esac
done

# -------- 0. Branch guard --------

CURRENT_BRANCH=$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
if [[ $DEV -eq 0 && "$CURRENT_BRANCH" != "main" ]]; then
  echo "✗ release must be run from main (current: $CURRENT_BRANCH)" >&2
  echo "  use --dev to publish from a non-main branch" >&2
  exit 1
fi

# -------- 1. Read current version --------

CURRENT=$(/usr/bin/python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['version'])" "$PKG")
SEMVER="${CURRENT%%+*}"
IFS='.' read -r MAJOR MINOR PATCH <<<"$SEMVER"

echo
printf "  current: \033[36m%s\033[0m\n" "$CURRENT"
[[ $DEV -eq 1 ]] && echo "  mode   : dev (tag: dev-server-v*, npm tag: dev)"
echo

# -------- 2. Bump --------

# For dev: extract existing pre-release counter from version like 0.6.3-dev.2
DEV_BASE="${CURRENT%%-dev.*}"   # strip -dev.N suffix if present
DEV_N=0
if [[ "$CURRENT" =~ -dev\.([0-9]+)$ ]]; then
  DEV_N="${BASH_REMATCH[1]}"
  MAJOR_D="${DEV_BASE%%.*}"; REST="${DEV_BASE#*.}"; MINOR_D="${REST%%.*}"; PATCH_D="${REST#*.}"
else
  MAJOR_D="$MAJOR"; MINOR_D="$MINOR"; PATCH_D="$PATCH"
fi

if [[ $DEV -eq 1 ]]; then
  # If already a dev version, offer "same" as first/default option (resume interrupted run)
  if [[ $DEV_N -gt 0 ]]; then
    cat <<MENU
  Choose bump:
    1)  same     $CURRENT  (resume / re-run)
    2)  dev      ${DEV_BASE}-dev.$((DEV_N+1))  (new dev version)
    3)  patch    $MAJOR_D.$MINOR_D.$((PATCH_D+1))-dev.1
    4)  minor    $MAJOR_D.$((MINOR_D+1)).0-dev.1
    q)  quit
MENU
    printf "  → [1-4/q, default=1]: "
    read -r CHOICE
    CHOICE="${CHOICE:-1}"
    case "$CHOICE" in
      1|same)  NEW="$CURRENT" ;;
      2|dev)   NEW="${DEV_BASE}-dev.$((DEV_N+1))" ;;
      3|patch) NEW="$MAJOR_D.$MINOR_D.$((PATCH_D+1))-dev.1" ;;
      4|minor) NEW="$MAJOR_D.$((MINOR_D+1)).0-dev.1" ;;
      q|quit)  echo "  aborted."; exit 0 ;;
      *)       echo "  invalid choice" >&2; exit 1 ;;
    esac
  else
    cat <<MENU
  Choose bump:
    1)  dev      ${DEV_BASE}-dev.1
    2)  patch    $MAJOR_D.$MINOR_D.$((PATCH_D+1))-dev.1
    3)  minor    $MAJOR_D.$((MINOR_D+1)).0-dev.1
    4)  major    $((MAJOR_D+1)).0.0-dev.1
    q)  quit
MENU
    printf "  → [1-4/q, default=1]: "
    read -r CHOICE
    CHOICE="${CHOICE:-1}"
    case "$CHOICE" in
      1|dev)   NEW="${DEV_BASE}-dev.1" ;;
      2|patch) NEW="$MAJOR_D.$MINOR_D.$((PATCH_D+1))-dev.1" ;;
      3|minor) NEW="$MAJOR_D.$((MINOR_D+1)).0-dev.1" ;;
      4|major) NEW="$((MAJOR_D+1)).0.0-dev.1" ;;
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

if [[ $DEV -eq 1 ]]; then
  TAG="dev-server-v$NEW"
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

if [[ $DEV -eq 1 ]]; then
  printf "  → bump, commit, push, tag, npm publish --tag dev? [y/N]: "
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
  if [[ $DEV -eq 1 ]]; then
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
  echo "▶ pnpm build"
  cd "$SERVER_DIR"
  pnpm build

  echo
  if [[ $DEV -eq 1 ]]; then
    echo "▶ npm publish --tag dev --registry https://registry.npmjs.org"
    npm publish --tag dev --registry https://registry.npmjs.org
  else
    echo "▶ npm publish --registry https://registry.npmjs.org"
    npm publish --registry https://registry.npmjs.org
  fi
fi

echo
printf "\033[32m✓ published pawterm-server@%s\033[0m\n" "$NEW"
echo "  npm:  https://www.npmjs.com/package/pawterm-server"
echo "  tag:  $TAG"
