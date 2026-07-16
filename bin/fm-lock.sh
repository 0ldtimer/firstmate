#!/usr/bin/env bash
# Acquire or inspect the per-home firstmate session lock.
# Writes the harness (agent) process PID found by walking the shell's ancestry,
# which lives as long as the firstmate session - unlike the transient subshell
# PID of any one tool call, which is dead moments after it is written.
# Usage: fm-lock.sh           acquire; exit 2 if another live session holds it,
#                            or exit 1 for another acquisition failure
#        fm-lock.sh status    print holder and liveness; always exits 0
# FM_HARNESS_OWNER_PID may name an explicit long-lived harness process when
# the harness runs tools outside its process ancestry. The process must be
# alive and its command must still identify a verified harness. For Codex,
# launch with `FM_HARNESS_OWNER_PID=$$ exec codex` so exec preserves the PID.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOCK="$STATE/.lock"
mkdir -p "$STATE"

# Known harness command names; extend when a new adapter is verified.
HARNESS_RE='claude|codex|opencode|grok|^pi$'

process_is_harness() {
  local pid=$1 expected=${2:-$HARNESS_RE} comm args
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  if printf '%s' "$(basename -- "$comm")" | grep -qE "$expected"; then
    return 0
  fi
  case "$comm" in
    *node*|*python*)
      args=$(ps -o args= -p "$pid" 2>/dev/null)
      printf '%s' "$args" | grep -qE "$expected"
      ;;
    *) return 1 ;;
  esac
}

harness_pid() {
  local pid=$$ comm args
  if [ -n "${FM_HARNESS_OWNER_PID:-}" ]; then
    case "$FM_HARNESS_OWNER_PID" in
      *[!0-9]*|'') echo "error: FM_HARNESS_OWNER_PID must be a process id" >&2; return 1 ;;
    esac
    if [ "$FM_HARNESS_OWNER_PID" -le 1 ] || ! process_is_harness "$FM_HARNESS_OWNER_PID" codex; then
      echo "error: FM_HARNESS_OWNER_PID is not a live Codex harness process" >&2
      return 1
    fi
    echo "$FM_HARNESS_OWNER_PID"
    return 0
  fi
  for _ in 1 2 3 4 5 6 7 8; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    if printf '%s' "$(basename -- "$comm")" | grep -qE "$HARNESS_RE"; then
      echo "$pid"; return 0
    fi
    # Bare interpreter (e.g. node): match the harness name in its script path.
    case "$comm" in
      *node*|*python*) printf '%s' "$args" | grep -qE "$HARNESS_RE" && { echo "$pid"; return 0; } ;;
    esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || return 1
  done
  return 1
}

if [ "${1:-}" = "status" ]; then
  if [ ! -f "$LOCK" ]; then echo "lock: free"; exit 0; fi
  old=$(cat "$LOCK")
  if process_is_harness "$old"; then echo "lock: held by live harness pid $old"; else echo "lock: stale (pid $old dead or not a harness)"; fi
  exit 0
fi

if ! me=$(harness_pid); then
  [ -z "${FM_HARNESS_OWNER_PID:-}" ] && echo "error: cannot locate harness process in ancestry" >&2
  exit 1
fi
if [ -f "$LOCK" ]; then
  old=$(cat "$LOCK")
  if process_is_harness "$old" \
    && { [ "$old" != "$me" ] || [ -n "${FM_HARNESS_OWNER_PID:-}" ]; }; then
    echo "error: another live firstmate session holds the lock (pid $old); operate read-only until resolved" >&2
    exit 2
  fi
fi
echo "$me" > "$LOCK"
echo "lock acquired: harness pid $me"
