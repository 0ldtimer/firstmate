#!/usr/bin/env bash
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
bridge="$ROOT/bin/fm-bridge.sh"
call() { printf '%s' "$1" | FM_HOME="$TMP" "$bridge"; }
group='{"protocolVersion":"fm-bridge.v2","operation":"acceptExecutionGroup","schemaVersion":"cycle-execution.v1","executionId":"execution:cycle-1","attemptId":"attempt:1","manifestDigest":"sha256:manifest-1","binding":{"workspaceId":"workspace-1","cycleId":"cycle-1"},"children":[{"childId":"child-build","kind":"build"},{"childId":"child-issue","kind":"issue"}]}'
result=$(call "$group")
jq -e '.accepted == true and .replayed == false and (.executionGroup.children|length)==2' <<<"$result" >/dev/null
replay=$(call "$group"); jq -e '.accepted == true and .replayed == true' <<<"$replay" >/dev/null
changed=${group/manifest-1/manifest-2}; conflict=$(call "$changed"); jq -e '.accepted == false and .error.code == "identity_conflict"' <<<"$conflict" >/dev/null
delegated=$(call '{"protocolVersion":"fm-bridge.v2","operation":"delegateExecutionGroup","executionId":"execution:cycle-1"}'); jq -e '.accepted == true and .state == "delegated"' <<<"$delegated" >/dev/null
[ -f "$TMP/data/engineering/execution/children/child-build.json" ] || { echo "child was not durable" >&2; exit 1; }
intent='{"protocolVersion":"fm-bridge.v2","operation":"publishProgress","schemaVersion":"fm-progress-intent.v1","intentId":"intent-1","executionId":"execution:cycle-1","childId":"child-build","kind":"task","target":{"taskId":"task-1"},"evidence":{"reference":"evidence-1"}}'
published=$(call "$intent"); digest=$(jq -r '.intent.intentDigest' <<<"$published"); jq -e '.accepted == true and .intent.state == "pending"' <<<"$published" >/dev/null
ack=$(call "{\"protocolVersion\":\"fm-bridge.v2\",\"operation\":\"acknowledgeProgress\",\"intentId\":\"intent-1\",\"intentDigest\":\"$digest\"}"); jq -e '.accepted == true and .state == "applied"' <<<"$ack" >/dev/null
projection=$(FM_HOME="$TMP" "$ROOT/bin/fm-captains-log-execution-projection.sh" --json); jq -e '.schemaVersion == "fm-captains-log-projection.v1" and (.executionGroups|length)==1 and (.pendingIntents|length)==0' <<<"$projection" >/dev/null
printf 'ok - cycle execution ingress, Scotty delegation, replay, progress acknowledgement, and projection\n'
