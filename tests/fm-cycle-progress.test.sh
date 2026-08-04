#!/usr/bin/env bash
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
call() { printf '%s' "$1" | FM_HOME="$TMP" "$ROOT/bin/fm-bridge.sh"; }
call '{"protocolVersion":"fm-bridge.v2","operation":"acceptExecutionGroup","schemaVersion":"cycle-execution.v1","executionId":"execution-1","attemptId":"attempt-1","manifestDigest":"manifest-1","binding":{"workspaceId":"workspace-1","cycleId":"cycle-1"},"children":[{"childId":"child-1","kind":"build"}]}' >/dev/null
intent='{"protocolVersion":"fm-bridge.v2","operation":"publishProgress","schemaVersion":"fm-progress-intent.v1","intentId":"intent-1","executionId":"execution-1","childId":"child-1","kind":"hill","target":{"scopeId":"scope-1","position":2},"evidence":{"reference":"evidence-1"}}'
one=$(call "$intent"); two=$(call "$intent"); jq -e '.accepted and (.intent.state == "pending")' <<<"$one" >/dev/null; jq -e '.accepted and .replayed' <<<"$two" >/dev/null
digest=$(jq -r '.intent.intentDigest' <<<"$one"); bad=$(call "{\"protocolVersion\":\"fm-bridge.v2\",\"operation\":\"acknowledgeProgress\",\"intentId\":\"intent-1\",\"intentDigest\":\"wrong\"}"); jq -e '.accepted == false and .error.code == "acknowledgement_mismatch"' <<<"$bad" >/dev/null
printf 'ok - progress intent is durable, replay-safe, and requires exact acknowledgement\n'
