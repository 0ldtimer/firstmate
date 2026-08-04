#!/usr/bin/env bash
# Read-only execution projection. The legacy fm-captains-log-projection.sh
# contract remains unchanged; this additive producer projects cycle groups.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
. "$SCRIPT_DIR/fm-cycle-execution-lib.sh"
case "${1:---json}" in
  --json) fm_cycle_projection ;;
  *) printf '%s\n' 'usage: fm-captains-log-execution-projection.sh --json' >&2; exit 2 ;;
esac
