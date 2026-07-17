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

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

codex "$@"
