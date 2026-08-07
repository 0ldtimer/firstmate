#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

TMP=$(fm_test_tmproot fm-cycle-progress)
STORE="$TMP/data/engineering/execution"
call() { printf '%s' "$1" | FM_HOME="$TMP" "$ROOT/bin/fm-bridge.sh"; }

call '{"protocolVersion":"fm-bridge.v2","operation":"acceptExecutionGroup","schemaVersion":"cycle-execution.v1","executionId":"execution-1","attemptId":"attempt-1","manifestDigest":"manifest-1","binding":{"workspaceId":"workspace-1","cycleId":"cycle-1"},"children":[{"childId":"child-1","kind":"build"}]}' >/dev/null ||
  fail "execution group was not accepted"

intent='{"protocolVersion":"fm-bridge.v2","operation":"publishProgress","schemaVersion":"fm-progress-intent.v1","intentId":"intent-1","executionId":"execution-1","childId":"child-1","kind":"hill","target":{"scopeId":"scope-1","position":2},"evidence":{"reference":"evidence-1"}}'
one=$(call "$intent")
printf '%s' "$one" | jq -e '.accepted and .intent.state == "pending" and (.replayed|not)' >/dev/null ||
  fail "hill intent was not accepted as pending"$'\n'"$one"
two=$(call "$intent")
printf '%s' "$two" | jq -e '.accepted and .replayed' >/dev/null ||
  fail "a redelivered intent was not replayed"$'\n'"$two"
[ -f "$STORE/outbox/intent-1.json" ] || fail "the intent outbox replay copy is missing"

digest=$(printf '%s' "$one" | jq -r '.intent.intentDigest')
bad=$(call '{"protocolVersion":"fm-bridge.v2","operation":"acknowledgeProgress","intentId":"intent-1","intentDigest":"wrong"}' || true)
printf '%s' "$bad" | jq -e '.accepted == false and .error.code == "acknowledgement_mismatch"' >/dev/null ||
  fail "a wrong acknowledgement digest was accepted"$'\n'"$bad"
missing=$(call '{"protocolVersion":"fm-bridge.v2","operation":"acknowledgeProgress","intentId":"intent-1"}' || true)
printf '%s' "$missing" | jq -e '.accepted == false and .error.code == "acknowledgement_mismatch"' >/dev/null ||
  fail "an acknowledgement without a digest was accepted"$'\n'"$missing"

# A refused acknowledgement leaves the record pending and keeps the replay copy.
jq -e '.state == "pending"' "$STORE/intents/intent-1.json" >/dev/null ||
  fail "a refused acknowledgement changed the durable intent state"
[ -f "$STORE/outbox/intent-1.json" ] || fail "a refused acknowledgement dropped the outbox replay copy"

applied=$(call "{\"protocolVersion\":\"fm-bridge.v2\",\"operation\":\"acknowledgeProgress\",\"intentId\":\"intent-1\",\"intentDigest\":\"$digest\"}")
printf '%s' "$applied" | jq -e '.accepted == true and .state == "applied"' >/dev/null ||
  fail "the exact acknowledgement was refused"$'\n'"$applied"
jq -e '.state == "applied" and (.acknowledgedAt|type == "string")' "$STORE/intents/intent-1.json" >/dev/null ||
  fail "the applied state is not durable"
[ ! -f "$STORE/outbox/intent-1.json" ] || fail "an applied intent stayed in the outbox"

for position in 6 -1 '"2"'; do
  invalid=$(call "{\"protocolVersion\":\"fm-bridge.v2\",\"operation\":\"publishProgress\",\"schemaVersion\":\"fm-progress-intent.v1\",\"intentId\":\"intent-$RANDOM-invalid\",\"executionId\":\"execution-1\",\"childId\":\"child-1\",\"kind\":\"hill\",\"target\":{\"scopeId\":\"scope-1\",\"position\":$position},\"evidence\":{\"reference\":\"evidence-invalid\"}}" || true)
  printf '%s' "$invalid" | jq -e '.accepted == false and .error.code == "malformed_intent"' >/dev/null ||
    fail "a hill position outside the documented 0..5 scale was accepted: $position"$'\n'"$invalid"
done
outside=$(call '{"protocolVersion":"fm-bridge.v2","operation":"publishProgress","schemaVersion":"fm-progress-intent.v1","intentId":"intent-outside","executionId":"execution-1","childId":"child-unknown","kind":"task","target":{"taskId":"task-1"},"evidence":{"reference":"evidence-1"}}' || true)
printf '%s' "$outside" | jq -e '.accepted == false and .error.code == "child_not_in_group"' >/dev/null ||
  fail "an intent for a child outside the group was accepted"$'\n'"$outside"

pass "progress intent is durable, replay-safe, hill-scale bound, and requires an exact acknowledgement before the outbox is cleared"
