#!/usr/bin/env bash
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
out=$(printf '%s' '{"protocolVersion":"fm-bridge.v2","operation":"capabilities"}' | FM_HOME="$TMP" "$ROOT/bin/fm-bridge.sh")
jq -e '.accepted == true and (.capabilities|index("cycle-execution.v1")) and (.capabilities|index("progress.publish"))' <<<"$out" >/dev/null
printf 'ok - fm-bridge.v2 advertises execution and progress capabilities\n'
