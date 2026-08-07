#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

TMP=$(fm_test_tmproot fm-bridge-cycle-execution)
bridge="$ROOT/bin/fm-bridge.sh"
STORE="$TMP/data/engineering/execution"
call() { printf '%s' "$1" | FM_HOME="$TMP" "$bridge"; }
file_digest() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$@"; else sha256sum "$@"; fi; }
stream_digest() { if command -v shasum >/dev/null 2>&1; then shasum -a 256; else sha256sum; fi; }

group='{"protocolVersion":"fm-bridge.v2","operation":"acceptExecutionGroup","schemaVersion":"cycle-execution.v1","executionId":"execution:cycle-1","attemptId":"attempt:1","manifestDigest":"sha256:manifest-1","binding":{"workspaceId":"workspace-1","cycleId":"cycle-1"},"children":[{"childId":"child-build","kind":"build"},{"childId":"child-issue","kind":"issue"}]}'
result=$(call "$group")
printf '%s' "$result" | jq -e '.accepted == true and .replayed == false and (.executionGroup.children|length)==2' >/dev/null ||
  fail "execution group was not accepted"$'\n'"$result"
replay=$(call "$group")
printf '%s' "$replay" | jq -e '.accepted == true and .replayed == true' >/dev/null ||
  fail "exact replay did not return the original receipt"$'\n'"$replay"
changed=${group/manifest-1/manifest-2}
conflict=$(call "$changed" || true)
printf '%s' "$conflict" | jq -e '.accepted == false and .error.code == "identity_conflict"' >/dev/null ||
  fail "a changed manifest under a bound identity was not a typed conflict"$'\n'"$conflict"

delegated=$(call '{"protocolVersion":"fm-bridge.v2","operation":"delegateExecutionGroup","executionId":"execution:cycle-1"}')
printf '%s' "$delegated" | jq -e '.accepted == true and .state == "delegated"' >/dev/null ||
  fail "delegation was refused"$'\n'"$delegated"
[ -f "$STORE/children/child-build.json" ] || fail "child was not durable"

intent='{"protocolVersion":"fm-bridge.v2","operation":"publishProgress","schemaVersion":"fm-progress-intent.v1","intentId":"intent-1","executionId":"execution:cycle-1","childId":"child-build","kind":"task","target":{"taskId":"task-1"},"evidence":{"reference":"evidence-1"}}'
published=$(call "$intent")
printf '%s' "$published" | jq -e '.accepted == true and .intent.state == "pending"' >/dev/null ||
  fail "progress intent was not accepted"$'\n'"$published"
digest=$(printf '%s' "$published" | jq -r '.intent.intentDigest')
ack=$(call "{\"protocolVersion\":\"fm-bridge.v2\",\"operation\":\"acknowledgeProgress\",\"intentId\":\"intent-1\",\"intentDigest\":\"$digest\"}")
printf '%s' "$ack" | jq -e '.accepted == true and .state == "applied"' >/dev/null ||
  fail "acknowledgement was refused"$'\n'"$ack"

projection=$(FM_HOME="$TMP" "$ROOT/bin/fm-captains-log-execution-projection.sh" --json) ||
  fail "execution projection failed"
printf '%s' "$projection" | jq -e '
  .accepted == true
  and .capabilities.schemaVersion == "fm-captains-log-projection.v1"
  and .snapshot.schemaVersion == "fm-captains-log-projection.v1"
  and .snapshot.snapshot.schemaVersion == "fm-captains-log-snapshot.v1"
  and (.snapshot.snapshot.executionGroups|length)==1
  and (.snapshot.snapshot.pendingIntents|length)==0
  and (.snapshot.snapshot.invalidRecords|length)==0
' >/dev/null || fail "projection envelope did not carry the negotiated snapshot"$'\n'"$projection"

# A producer identifier never names a record outside its own store.
decoy='{"children":[{"childId":"pwned"}],"secret":"LEAK"}'
for operation in executionGroupStatus delegateExecutionGroup; do
  printf '%s\n' "$decoy" > "$TMP/leak.json"
  escaped=$(call "{\"protocolVersion\":\"fm-bridge.v2\",\"operation\":\"$operation\",\"executionId\":\"../../../../leak\"}" || true)
  printf '%s' "$escaped" | jq -e '.accepted == false and .error.code == "malformed_identity"' >/dev/null ||
    fail "$operation accepted a traversing executionId"$'\n'"$escaped"
  [ "$(cat "$TMP/leak.json")" = "$decoy" ] || fail "$operation rewrote a file outside the execution store"
  [ ! -f "$STORE/children/pwned.json" ] || fail "$operation delegated children read from outside the execution store"
done
escaped=$(call '{"protocolVersion":"fm-bridge.v2","operation":"publishProgress","schemaVersion":"fm-progress-intent.v1","intentId":"intent-escape","executionId":"../../../../leak","childId":"child-build","kind":"task","target":{"taskId":"task-1"},"evidence":{"reference":"evidence-1"}}' || true)
printf '%s' "$escaped" | jq -e '.accepted == false and .error.code == "malformed_identity"' >/dev/null ||
  fail "publishProgress accepted a traversing executionId"$'\n'"$escaped"
escaped=$(call '{"protocolVersion":"fm-bridge.v2","operation":"acknowledgeProgress","intentId":"../../../../leak","intentDigest":"whatever"}' || true)
printf '%s' "$escaped" | jq -e '.accepted == false and .error.code == "malformed_identity"' >/dev/null ||
  fail "acknowledgeProgress accepted a traversing intentId"$'\n'"$escaped"

# One unreadable record is isolated, never blanks the projection.
printf 'not json\n' > "$STORE/groups/hand-edited.json"
degraded=$(FM_HOME="$TMP" "$ROOT/bin/fm-captains-log-execution-projection.sh" --json) ||
  fail "one unreadable record blanked the whole projection"
printf '%s' "$degraded" | jq -e '
  .accepted == true
  and (.snapshot.snapshot.executionGroups|length)==1
  and (.snapshot.snapshot.invalidRecords|length)==1
  and .snapshot.snapshot.invalidRecords[0].kind == "executionGroup"
  and .snapshot.snapshot.invalidRecords[0].recordId == "hand-edited.json"
  and .snapshot.snapshot.invalidRecords[0].error.code == "schema_invalid_record"
' >/dev/null || fail "an unreadable record was not isolated in invalidRecords"$'\n'"$degraded"
rm -f "$STORE/groups/hand-edited.json"

# fm-bridge.v1 clients keep the bare error envelope they were written against.
v1_error=$(printf '%s' '{"protocolVersion":"fm-bridge.v1","operation":"nope"}' | FM_HOME="$TMP" "$bridge" || true)
printf '%s' "$v1_error" | jq -e '.accepted == false and .error.code == "unsupported_operation" and (has("protocolVersion")|not)' >/dev/null ||
  fail "a v1 operation refusal was relabelled"$'\n'"$v1_error"
v1_malformed=$(printf '%s' 'not json at all' | FM_HOME="$TMP" "$bridge" || true)
printf '%s' "$v1_malformed" | jq -e '.accepted == false and .error.code == "malformed_request" and (has("protocolVersion")|not)' >/dev/null ||
  fail "an undeclared malformed request was answered in the v2 envelope"$'\n'"$v1_malformed"
v2_malformed=$(printf '%s' '["fm-bridge.v2"]' | FM_HOME="$TMP" "$bridge" || true)
printf '%s' "$v2_malformed" | jq -e '.accepted == false and .error.code == "malformed_request" and .protocolVersion == "fm-bridge.v2"' >/dev/null ||
  fail "a declared v2 malformed request lost the v2 envelope"$'\n'"$v2_malformed"

# The frozen engineering-scotty fixture set is byte-pinned and reaches the real
# validators through the mapping docs/fm-bridge-v2.md publishes.
FIXTURES="$ROOT/contracts/fm-bridge/fixtures/engineering-scotty"
frozen=$(awk '{print $1}' "$FIXTURES/fixture-set.sha256")
manifest=()
while IFS= read -r name; do
  [ -n "$name" ] || continue
  manifest[${#manifest[@]}]=$name
done < <(jq -r '.fixtures[]' "$FIXTURES/protocol-manifest.v1.json")
[ "${#manifest[@]}" -gt 0 ] || fail "the frozen fixture manifest named no fixtures"
recomputed=$( (cd "$FIXTURES" && file_digest "${manifest[@]}") | stream_digest | awk '{print $1}')
[ "$recomputed" = "$frozen" ] ||
  fail "engineering-scotty fixture set drifted from its frozen digest ($recomputed != $frozen)"
for name in "${manifest[@]}"; do
  if [ -f "$ROOT/contracts/fm-bridge/fixtures/$name" ]; then
    cmp -s "$FIXTURES/$name" "$ROOT/contracts/fm-bridge/fixtures/$name" ||
      fail "the unversioned fixture copy drifted from the frozen set: $name"
  fi
done

fixture_group=$(jq -c '{
  protocolVersion:"fm-bridge.v2",
  operation:"acceptExecutionGroup",
  schemaVersion:"cycle-execution.v1",
  executionId:.executionId,
  attemptId:.attemptId,
  manifestDigest:.manifestDigest,
  binding:.binding,
  children:[{childId:"task-42",taskId:"task-42",kind:"build"}]
}' "$FIXTURES/execution-group-acceptance.v1.json")
accepted=$(call "$fixture_group")
printf '%s' "$accepted" | jq -e '.accepted == true and .receipt.executionId == "execution:cycle-13"' >/dev/null ||
  fail "the frozen acceptance fixture was refused by the shipped validators"$'\n'"$accepted"
fixture_intent=$(jq -c '{
  protocolVersion:"fm-bridge.v2",
  operation:"publishProgress",
  schemaVersion:"fm-progress-intent.v1",
  intentId:.intentId,
  executionId:.executionId,
  childId:.taskId,
  kind:"hill",
  target:{scopeId:.shapeUp.scopeId,position:.shapeUp.hillPosition},
  evidence:{kind:.evidence[0].kind,reference:.evidence[0].reference,verification:.evidence[0].verification}
}' "$FIXTURES/progress-intent.v1.json")
fixture_published=$(call "$fixture_intent")
printf '%s' "$fixture_published" | jq -e '.accepted == true and .intent.state == "pending" and .intent.target.position == 2' >/dev/null ||
  fail "the frozen progress-intent fixture was refused by the shipped validators"$'\n'"$fixture_published"

pass "cycle execution ingress, identity-bound paths, replay, acknowledgement, projection isolation, v1 envelopes, and the frozen fixture set"
