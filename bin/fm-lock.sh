#!/usr/bin/env bash
# Acquire or inspect the per-home firstmate session lock.
# Writes the harness (agent) process PID found by walking the shell's ancestry,
# which lives as long as the firstmate session - unlike the transient subshell
# PID of any one tool call, which is dead moments after it is written.
# Usage: fm-lock.sh           acquire; exit 1 unless ownership is verified
#        fm-lock.sh status    print holder and liveness; always exits 0
set -u
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOCK="$STATE/.lock"
TOKEN_LOCK="$STATE/.lock-token"
mkdir -p "$STATE" 2>/dev/null || {
  echo "error: cannot create session-lock state directory $STATE; operate read-only until resolved" >&2
  exit 1
}

# Harness identity (FM_HARNESS_RE, ancestry walk, holder liveness) is owned by
# the shared session-lock lib so the Claude Stop auto-arm applies the exact
# same identity contract.
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

valid_codex_token() {
  case "${FM_CODEX_SESSION_TOKEN:-}" in
    ''|*[!0-9a-f]*) return 1 ;;
  esac
  [ "${#FM_CODEX_SESSION_TOKEN}" -eq 32 ]
}

codex_owner_pid() {
  valid_codex_token || { echo "error: invalid Codex session token" >&2; return 1; }
  case "${FM_HARNESS_OWNER_PID:-}" in
    ''|*[!0-9]*) echo "error: Codex launcher PID must be a process id" >&2; return 1 ;;
  esac
  [ "$FM_HARNESS_OWNER_PID" -gt 1 ] \
    || { echo "error: Codex launcher PID must be greater than one" >&2; return 1; }
  printf '%s\n' "$FM_HARNESS_OWNER_PID"
}

if [ "${1:-}" = release ]; then
  me=$(codex_owner_pid) || exit 1
  [ -f "$TOKEN_LOCK" ] && [ "$(cat "$TOKEN_LOCK" 2>/dev/null)" = "$FM_CODEX_SESSION_TOKEN" ] \
    || { echo "error: Codex session token does not own the fleet lock" >&2; exit 1; }
  [ -f "$LOCK" ] && [ "$(cat "$LOCK" 2>/dev/null)" = "$me" ] \
    || { echo "error: Codex launcher PID does not own the fleet lock" >&2; exit 1; }
  rm -f "$LOCK" "$TOKEN_LOCK"
  echo "lock released: Codex launcher pid $me"
  exit 0
fi

if [ "${1:-}" = "status" ]; then
  if [ ! -f "$LOCK" ]; then echo "lock: free"; exit 0; fi
  old=$(cat "$LOCK" 2>/dev/null) || {
    echo "lock: unreadable"
    exit 0
  }
  if [ -f "$TOKEN_LOCK" ] && kill -0 "$old" 2>/dev/null; then
    echo "lock: held by Codex launcher pid $old"
  elif fm_harness_pid_alive "$old"; then
    echo "lock: held by live harness pid $old"
  else
    echo "lock: stale (pid $old dead or not a harness)"
  fi
  exit 0
fi

codex_mode=0
if [ -n "${FM_CODEX_SESSION_TOKEN:-}" ]; then
  me=$(codex_owner_pid) || exit 1
  codex_mode=1
else
  me=$(fm_harness_ancestry_pid) || { echo "error: cannot locate harness process in ancestry" >&2; exit 1; }
fi
probe=$(mktemp "$STATE/.lock-write.XXXXXX" 2>/dev/null) || {
  echo "error: cannot write session lock; operate read-only until resolved" >&2
  exit 1
}
rm -f "$probe" 2>/dev/null || {
  echo "error: cannot clean session-lock publication probe; operate read-only until resolved" >&2
  exit 1
}
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
CLAIM_LOCK="$STATE/.lock.acquire"
CLAIM_LOCK_HELD=0
release_claim_lock() {
  if [ "$CLAIM_LOCK_HELD" -eq 1 ]; then
    fm_lock_release "$CLAIM_LOCK"
    CLAIM_LOCK_HELD=0
  fi
}
trap release_claim_lock EXIT
trap 'exit 1' HUP INT TERM

if [ -f "$LOCK" ] && [ ! -L "$LOCK" ]; then
  old=$(cat "$LOCK" 2>/dev/null || true)
  if [ "$old" = "$me" ]; then
    if [ "$codex_mode" -eq 0 ] || { [ -f "$TOKEN_LOCK" ] && [ "$(cat "$TOKEN_LOCK" 2>/dev/null)" = "$FM_CODEX_SESSION_TOKEN" ]; }; then
      if [ "$codex_mode" -eq 1 ]; then echo "lock acquired: Codex launcher pid $me"; else echo "lock acquired: harness pid $me"; fi
      exit 0
    fi
    echo "error: Codex session token does not own the fleet lock" >&2
    exit 1
  fi
  if { [ -f "$TOKEN_LOCK" ] && kill -0 "$old" 2>/dev/null; } || fm_harness_pid_alive "$old"; then
    echo "error: another live firstmate session holds the lock (pid $old); operate read-only until resolved" >&2
    exit 1
  fi
fi

if ! fm_lock_try_acquire "$CLAIM_LOCK"; then
  sweep_pid=$(sed -n 's/^pid=//p' "$STATE/.startup-network.status" 2>/dev/null | tail -1)
  if [ -n "${FM_LOCK_HELD_PID:-}" ] && [ "$FM_LOCK_HELD_PID" = "$sweep_pid" ]; then
    echo "error: the prior session's bounded startup sweep is finishing; operate read-only until it releases the fleet lock" >&2
    exit 1
  fi
  fm_lock_acquire_wait "$CLAIM_LOCK"
fi
CLAIM_LOCK_HELD=1

if [ -e "$LOCK" ] || [ -L "$LOCK" ]; then
  if [ ! -f "$LOCK" ] || [ -L "$LOCK" ]; then
    echo "error: session lock is not a regular file; operate read-only until resolved" >&2
    exit 1
  fi
  old=$(cat "$LOCK" 2>/dev/null) || {
    echo "error: session lock is unreadable; operate read-only until resolved" >&2
    exit 1
  }
  if [ "$old" != "$me" ] && { { [ -f "$TOKEN_LOCK" ] && kill -0 "$old" 2>/dev/null; } || fm_harness_pid_alive "$old"; }; then
    echo "error: another live firstmate session holds the lock (pid $old); operate read-only until resolved" >&2
    exit 1
  fi
fi
if ! { printf '%s\n' "$me" > "$LOCK"; } 2>/dev/null; then
  echo "error: cannot write session lock; operate read-only until resolved" >&2
  exit 1
fi
if [ "$codex_mode" -eq 1 ]; then
  if ! { printf '%s\n' "$FM_CODEX_SESSION_TOKEN" > "$TOKEN_LOCK"; } 2>/dev/null; then
    rm -f "$LOCK" "$TOKEN_LOCK"
    echo "error: cannot write Codex session-token lock; operate read-only until resolved" >&2
    exit 1
  fi
else
  rm -f "$TOKEN_LOCK"
fi
written=$(cat "$LOCK" 2>/dev/null) || {
  echo "error: cannot verify session lock ownership; operate read-only until resolved" >&2
  exit 1
}
if [ ! -f "$LOCK" ] || [ -L "$LOCK" ] || [ "$written" != "$me" ]; then
  echo "error: session lock ownership verification failed; operate read-only until resolved" >&2
  exit 1
fi
release_claim_lock
if [ "$codex_mode" -eq 1 ]; then echo "lock acquired: Codex launcher pid $me"; else echo "lock acquired: harness pid $me"; fi
