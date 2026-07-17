#!/usr/bin/env bash
# Launch a primary Codex session with sandbox-independent fleet-lock ownership.
# Usage: fm-primary-codex.sh [codex arguments...]
set -u
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export FM_HOME="${FM_HOME:-$FM_ROOT}"
export FM_HARNESS_OWNER_PID=$$
export FM_CODEX_SESSION_TOKEN
if ! FM_CODEX_SESSION_TOKEN=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n') \
  || [ "${#FM_CODEX_SESSION_TOKEN}" -ne 32 ]; then
  echo "error: could not create a Codex session token" >&2
  exit 1
fi

cleanup() {
  "$SCRIPT_DIR/fm-lock.sh" release >/dev/null 2>&1 || true
}

codex_bin=${FM_CODEX_BIN:-}
if [ -z "$codex_bin" ]; then
  codex_bin=$(command -v codex 2>/dev/null || true)
fi
if [ -z "$codex_bin" ] && [ -x /Applications/ChatGPT.app/Contents/Resources/codex ]; then
  codex_bin=/Applications/ChatGPT.app/Contents/Resources/codex
fi
if [ ! -x "$codex_bin" ]; then
  echo "error: Codex executable not found; install ChatGPT or set FM_CODEX_BIN" >&2
  exit 127
fi

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

"$codex_bin" "$@"
