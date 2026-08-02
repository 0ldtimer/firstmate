#!/usr/bin/env bash
# Behavior tests for Engineering Captain Call packets over durable holds.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MISSION="$ROOT/bin/fm-mission.sh"
REPORT="$ROOT/bin/fm-report.sh"
DECISIONS="$ROOT/bin/fm-decision-hold.sh"
PROJECTION="$ROOT/bin/fm-captains-log-projection.sh"
TMP_ROOT=$(fm_test_tmproot fm-engineering-decisions)
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/projects/task-42"
cp "$ROOT/.tasks.toml" "$HOME_DIR/.tasks.toml"
cat > "$HOME_DIR/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

mission=$(jq -n --arg root "$HOME_DIR/projects/task-42" '{
  schemaVersion:"fm-engineering-mission.v1",missionId:"mission-42",taskId:"task-42",crewmateId:"keiko",
  acceptedBuildRevision:"build-8:r7",evidenceRequirements:[],allowedEvidenceRoots:[$root],
  correlation:{schemaVersion:"shapeup-correlation.v1",sourceRevision:"dispatch:r1",capturedAt:"2026-08-01T12:00:00Z",
    identity:{kind:"command",id:"dispatch-42"},shapeUp:{cycleRef:"cycle-13",buildRef:"build-8",buildRevision:"build-8:r7",scopeRef:"scope-context"},
    firstMate:{missionId:"mission-42",taskId:"task-42",crewmateId:"keiko",session:null}}
}')
printf '%s' "$mission" | FM_HOME="$HOME_DIR" "$MISSION" accept - >/dev/null

condition_report() {
  jq -n --arg id "$1" --arg condition "$2" --arg at "$3" '{
    schemaVersion:"fm-engineering-report.v1",reportId:$id,kind:"scope_revision",capturedAt:$at,
    missionId:"mission-42",taskId:"task-42",crewmateId:"keiko",scope:{change:"drop",reason:"The accepted Build no longer fits the appetite."},
    correlation:{schemaVersion:"shapeup-correlation.v1",sourceRevision:("event:"+$id),capturedAt:$at,
      identity:{kind:"event",id:$id},shapeUp:{cycleRef:"cycle-13",buildRef:"build-8",buildRevision:"build-8:r7",scopeRef:"scope-context"},
      firstMate:{missionId:"mission-42",taskId:"task-42",crewmateId:"keiko",session:null}},
    condition:{conditionId:$condition,title:("Choose "+$condition),explanation:"Dropping the Scope changes the accepted Build outcome.",
      recommendation:"Defer the Scope explicitly.",choices:["defer","retain"],consequenceOfDelay:"Execution remains blocked.",
      affectedObjects:["build-8","scope-context"],evidence:[],boundRevisions:{build:"build-8:r7"}}
  }'
}

first=$(condition_report report-condition-1 scope-drop "2026-08-01T12:05:00Z" |
  FM_HOME="$HOME_DIR" "$REPORT" append -)
printf '%s' "$first" | jq -e '
  .accepted == true
  and .report.condition.lifecycle == "raised"
  and .report.condition.holdId == "mission-42-decision-scope-drop"
  and (.report.condition.packetRevision | length == 64)
' >/dev/null || fail "consequential report did not raise a durable packet: $first"

status=$(FM_HOME="$HOME_DIR" "$DECISIONS" status mission-42 scope-drop --json)
printf '%s' "$status" | jq -e '.lifecycle == "raised" and .durableState.held == true' >/dev/null \
  || fail "durable hold status is invalid: $status"

updated=$(condition_report report-condition-2 scope-drop "2026-08-01T12:06:00Z" |
  jq '.condition.explanation="New evidence sharpens the same condition."' |
  FM_HOME="$HOME_DIR" "$REPORT" append -)
printf '%s' "$updated" | jq -e '.accepted == true and .report.condition.lifecycle == "updated"' >/dev/null \
  || fail "same condition did not update independently: $updated"

snapshot=$(printf '%s' '{"schemaVersion":"fm-captains-log-projection.v1","operation":"snapshot"}' |
  FM_HOME="$HOME_DIR" "$PROJECTION")
printf '%s' "$snapshot" | jq -e '
  (.snapshot.conditions | length) == 1
  and .snapshot.conditions[0].conditionId == "scope-drop"
  and .snapshot.conditions[0].lifecycle == "updated"
' >/dev/null || fail "projection did not select the newest condition packet: $snapshot"

packet=$(printf '%s' "$snapshot" | jq -r '.snapshot.conditions[0].packetRevision')
ack=$(jq -n --arg packet "$packet" '{schemaVersion:"fm-captains-log-projection.v1",operation:"intent",
  intent:{intentId:"ack-1",action:"acknowledgeCondition",missionId:"mission-42",conditionId:"scope-drop",packetRevision:$packet}}' |
  FM_HOME="$HOME_DIR" "$PROJECTION")
printf '%s' "$ack" | jq -e '.accepted == true and .outcome.status == "acknowledged"' >/dev/null \
  || fail "acknowledgement failed: $ack"
status=$(FM_HOME="$HOME_DIR" "$DECISIONS" status mission-42 scope-drop --json)
printf '%s' "$status" | jq -e '.lifecycle == "updated" and .durableState.held == true' >/dev/null \
  || fail "viewing or acknowledgement resolved the hold"

(cd "$HOME_DIR" && tasks-axi add routed-scope-work "Route the chosen Scope" --kind ship --repo firstmate >/dev/null)
(cd "$HOME_DIR" && tasks-axi block routed-scope-work --by mission-42-decision-scope-drop >/dev/null)
resolved=$(jq -n --arg packet "$packet" '{schemaVersion:"fm-captains-log-projection.v1",operation:"intent",
  intent:{intentId:"resolve-1",action:"resolveCondition",missionId:"mission-42",conditionId:"scope-drop",packetRevision:$packet,
    decision:"Defer the Scope from this accepted Build outcome.",routedTo:["routed-scope-work"]}}' |
  FM_HOME="$HOME_DIR" "$PROJECTION")
printf '%s' "$resolved" | jq -e '.accepted == true and .outcome.status == "resolved"' >/dev/null \
  || fail "Captain Call resolution was not routed through the durable completion owner: $resolved"
snapshot=$(printf '%s' '{"schemaVersion":"fm-captains-log-projection.v1","operation":"snapshot"}' |
  FM_HOME="$HOME_DIR" "$PROJECTION")
printf '%s' "$snapshot" | jq -e '.snapshot.conditions[0].lifecycle == "resolved"' >/dev/null \
  || fail "resolved Captain Call lifecycle was not projected: $snapshot"
pass "Captain Call packets update independently and resolve through one durable completion owner"

# A resolution that fails after recording the decision leaves the retry identity
# in the hold body. Re-projecting a packet over it would erase the record an exact
# retry needs, leaving the hold permanently unresolvable.
widen=$(condition_report report-condition-3 scope-widen "2026-08-01T12:07:00Z" |
  FM_HOME="$HOME_DIR" "$REPORT" append -)
printf '%s' "$widen" | jq -e '.accepted == true and .report.condition.holdId == "mission-42-decision-scope-widen"' >/dev/null \
  || fail "the widening Captain Call did not raise its own hold: $widen"
partial=$(printf 'Resolution recorded by fm-decision-hold.\nDecision digest: %s\nRouted identities: routed-widen-work\n\nCaptain decision:\nWiden the Scope.\n\nRouted work:\n- routed-widen-work\n' \
  "0000000000000000000000000000000000000000000000000000000000000000")
(cd "$HOME_DIR" && tasks-axi update mission-42-decision-scope-widen --body "$partial" >/dev/null)
projected=$(FM_HOME="$HOME_DIR" "$DECISIONS" project mission-42 scope-widen \
  --packet-file "$HOME_DIR/data/engineering/reports/report-condition-3.json" --lifecycle resolving)
case "$projected" in
  retained:*) ;;
  *) fail "projecting over a partial resolution must report the retained record: $projected" ;;
esac
retained_body=$(cd "$HOME_DIR" && tasks-axi show mission-42-decision-scope-widen --full |
  sed -n 's/^  body: //p' | head -1)
case "$retained_body" in
  *"Resolution recorded by fm-decision-hold."*"routed-widen-work"*) ;;
  *) fail "re-projection erased the retry identity a partial resolution depends on: $retained_body" ;;
esac
pass "projecting a packet never erases a hold's in-flight resolution record"
