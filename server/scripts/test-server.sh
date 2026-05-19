#!/usr/bin/env bash
# 独立测试 server 控制脚本（端口 8766）。
#
# 跟 `pnpm dev` 的主 server（端口 8765）完全隔离 —— 各自一份 config.json，
# 各自一份 SDK session map。改源码不会自动 reload（避免热重载链断流）。
#
#   ./scripts/test-server.sh start    # 后台起 → /tmp/pawterm-test-server.log
#   ./scripts/test-server.sh stop     # 杀进程
#   ./scripts/test-server.sh restart  # 停 → 起
#   ./scripts/test-server.sh status   # 看是否在跑
#   ./scripts/test-server.sh logs     # tail -f 日志
#   ./scripts/test-server.sh logs -n  # tail -n 100 退出
#
# 进程脱离 shell（nohup + disown），关掉终端 / 重启 claude code 都不影响。
# 仅在重启电脑、显式 stop、或进程自己崩溃时才停。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVER_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="$SERVER_DIR/config.test.json"
LOG_FILE="/tmp/pawterm-test-server.log"
PID_FILE="/tmp/pawterm-test-server.pid"
PORT=8766

# ── colors ────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_RED=$'\033[31m'
  C_DIM=$'\033[2m'
  C_BOLD=$'\033[1m'
else
  C_RESET= C_GREEN= C_YELLOW= C_RED= C_DIM= C_BOLD=
fi

info()  { echo "${C_DIM}›${C_RESET} $*"; }
ok()    { echo "${C_GREEN}✓${C_RESET} $*"; }
warn()  { echo "${C_YELLOW}!${C_RESET} $*"; }
err()   { echo "${C_RED}✗${C_RESET} $*" >&2; }

# ── pid helpers ───────────────────────────────────────────────────────
get_pid() {
  # 优先看 pid 文件，再 fallback 到 lsof（万一 pid 文件丢了）
  if [[ -f "$PID_FILE" ]]; then
    local pid
    pid=$(cat "$PID_FILE" 2>/dev/null || true)
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      echo "$pid"
      return 0
    fi
    # stale pid 文件
    rm -f "$PID_FILE"
  fi
  # fallback：lsof
  local lsof_pid
  lsof_pid=$(lsof -ti :$PORT -sTCP:LISTEN 2>/dev/null | head -1 || true)
  if [[ -n "$lsof_pid" ]]; then
    echo "$lsof_pid"
    return 0
  fi
  return 1
}

# ── commands ──────────────────────────────────────────────────────────
cmd_status() {
  if pid=$(get_pid); then
    ok "test server running ${C_BOLD}port $PORT${C_RESET}  pid=$pid  log=$LOG_FILE"
    return 0
  else
    info "test server not running"
    return 1
  fi
}

cmd_start() {
  if pid=$(get_pid); then
    warn "already running (pid=$pid). Use \`restart\` to swap in latest code."
    return 0
  fi
  if [[ ! -f "$CONFIG_FILE" ]]; then
    err "config not found: $CONFIG_FILE"
    err "Create it first (copy of config.json with port=$PORT)."
    return 1
  fi

  info "starting on port $PORT, config=$CONFIG_FILE"
  cd "$SERVER_DIR"
  # nohup + disown：彻底脱离 controlling terminal、shell job table、父进程组。
  # 这样 claude code 重启 / 终端关 / shell 退出，都不会发 SIGHUP/SIGTERM 把它带走。
  # PID 文件存 root pnpm 进程，stop 时杀 root 会级联到 tsx/node 全部子进程。
  nohup env PAWTERM_CONFIG="$CONFIG_FILE" pnpm exec tsx src/index.ts \
    > "$LOG_FILE" 2>&1 &
  local started=$!
  disown "$started" 2>/dev/null || true
  echo "$started" > "$PID_FILE"

  # 等端口绑定，确认真正起来了
  for i in 1 2 3 4 5 6 7 8 9 10; do
    sleep 0.4
    if lsof -ti :$PORT -sTCP:LISTEN 2>/dev/null | grep -q .; then
      ok "started pid=$started"
      info "log: tail -f $LOG_FILE"
      return 0
    fi
  done

  err "didn't bind port $PORT within 4s. Check $LOG_FILE for errors:"
  echo "${C_DIM}-----${C_RESET}"
  tail -20 "$LOG_FILE" 2>/dev/null || true
  echo "${C_DIM}-----${C_RESET}"
  return 1
}

cmd_stop() {
  local file_pid=""
  [[ -f "$PID_FILE" ]] && file_pid=$(cat "$PID_FILE" 2>/dev/null || true)
  local port_pids
  port_pids=$(lsof -ti :$PORT -sTCP:LISTEN 2>/dev/null || true)

  if [[ -z "$file_pid" ]] && [[ -z "$port_pids" ]]; then
    info "not running"
    return 0
  fi

  # 杀 root 进程（级联到 tsx/node 所有子进程）
  if [[ -n "$file_pid" ]] && kill -0 "$file_pid" 2>/dev/null; then
    info "stopping root pid=$file_pid"
    kill "$file_pid" 2>/dev/null || true
  fi
  # 同时直接杀掉端口上的监听进程（兜底）
  for p in $port_pids; do
    kill "$p" 2>/dev/null || true
  done

  # 等端口真正释放
  for i in $(seq 1 10); do
    sleep 0.3
    if ! lsof -ti :$PORT -sTCP:LISTEN 2>/dev/null | grep -q .; then
      rm -f "$PID_FILE"
      ok "stopped"
      return 0
    fi
  done

  # 还没走就 SIGKILL 全部残留
  warn "didn't exit on SIGTERM, sending SIGKILL"
  port_pids=$(lsof -ti :$PORT -sTCP:LISTEN 2>/dev/null || true)
  for p in $port_pids; do kill -9 "$p" 2>/dev/null || true; done
  [[ -n "$file_pid" ]] && kill -9 "$file_pid" 2>/dev/null || true
  rm -f "$PID_FILE"
  ok "killed"
}

cmd_restart() {
  cmd_stop
  cmd_start
}

cmd_logs() {
  if [[ ! -f "$LOG_FILE" ]]; then
    warn "no log file yet ($LOG_FILE)"
    return 1
  fi
  if [[ "${1:-}" == "-n" ]]; then
    tail -n "${2:-100}" "$LOG_FILE"
  else
    tail -f "$LOG_FILE"
  fi
}

# ── dispatch ──────────────────────────────────────────────────────────
cmd="${1:-}"
shift || true
case "$cmd" in
  start)   cmd_start  "$@" ;;
  stop)    cmd_stop   "$@" ;;
  restart) cmd_restart "$@" ;;
  status)  cmd_status "$@" ;;
  logs)    cmd_logs   "$@" ;;
  ""|help|-h|--help)
    cat <<EOF
Usage: ./scripts/test-server.sh <command>

Commands:
  start     Launch detached test server on port $PORT
  stop      Kill it (TERM, then KILL after 1.5s)
  restart   stop + start
  status    Show pid + port if running
  logs      tail -f $LOG_FILE
  logs -n   tail -n 100 $LOG_FILE (one-shot)
EOF
    ;;
  *)
    err "unknown command: $cmd"
    err "run with no args to see usage"
    exit 2
    ;;
esac
