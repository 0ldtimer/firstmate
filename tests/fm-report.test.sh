#!/usr/bin/env bash
# Behavior tests for continuous Engineering reports and evidence safety.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MISSION="$ROOT/bin/fm-mission.sh"
REPORT="$ROOT/bin/fm-report.sh"
TMP_ROOT=$(fm_test_tmproot fm-report)
HOME_DIR="$TMP_ROOT/home"
WORKTREE="$HOME_DIR/projects/task-42"
mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config" "$WORKTREE/evidence"
printf 'passing tests\n' > "$WORKTREE/evidence/tests.txt"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

mission_file="$TMP_ROOT/mission.json"
jq -n --arg root "$WORKTREE" '{
  schemaVersion:"fm-engineering-mission.v1",missionId:"mission-42",taskId:"task-42",crewmateId:"keiko",
  acceptedBuildRevision:"build-8:r7",evidenceRequirements:["automated-tests"],allowedEvidenceRoots:[$root],
  correlation:{schemaVersion:"shapeup-correlation.v1",sourceRevision:"dispatch:r1",capturedAt:"2026-08-01T12:00:00Z",
    identity:{kind:"command",id:"dispatch-42"},shapeUp:{cycleRef:"cycle-13",buildRef:"build-8",buildRevision:"build-8:r7",scopeRef:null},
    firstMate:{missionId:"mission-42",taskId:"task-42",crewmateId:"keiko",session:null}}
}' > "$mission_file"
FM_HOME="$HOME_DIR" "$MISSION" accept "$mission_file" >/dev/null

base_report() {
  jq -n --arg kind "$1" --arg id "$2" '{
    schemaVersion:"fm-engineering-report.v1",reportId:$id,kind:$kind,capturedAt:"2026-08-01T12:05:00Z",
    missionId:"mission-42",taskId:"task-42",crewmateId:"keiko",
    correlation:{schemaVersion:"shapeup-correlation.v1",sourceRevision:"report:r1",capturedAt:"2026-08-01T12:05:00Z",
      identity:{kind:"event",id:$id},shapeUp:{cycleRef:"cycle-13",buildRef:"build-8",buildRevision:"build-8:r7",scopeRef:"scope-context"},
      firstMate:{missionId:"mission-42",taskId:"task-42",crewmateId:"keiko",session:null}}
  }'
}

hill=$(base_report hill_judgment report-hill-1 | jq '.hill={phase:"uphill",judgment:"A newly discovered integration seam moved this Scope backward.",movement:"backward"}')
first=$(printf '%s' "$hill" | FM_HOME="$HOME_DIR" "$REPORT" append -)
second=$(printf '%s' "$hill" | FM_HOME="$HOME_DIR" "$REPORT" append -)
printf '%s' "$first" | jq -e '.accepted == true and .report.hill.movement == "backward"' >/dev/null \
  || fail "backward Hill judgment must be accepted: $first"
printf '%s' "$second" | jq -e '.accepted == true and .replayed == true' >/dev/null \
  || fail "duplicate report must replay"
pass "reports preserve qualitative backward Hill learning and deduplicate exact replay"

set +e
cross=$(printf '%s' "$hill" | jq '.reportId="report-cross" | .correlation.identity.id="report-cross" | .correlation.shapeUp.buildRef="build-9"' |
  FM_HOME="$HOME_DIR" "$REPORT" append -)
status=$?
set -e
[ "$status" -ne 0 ] || fail "cross-Build report must fail"
printf '%s' "$cross" | jq -e '.error.code == "cross_build" and .report.status == "rejected"' >/dev/null \
  || fail "cross-Build rejection must remain visible and typed: $cross"
pass "cross-Build reports remain visible but non-executable"

evidence=$(base_report evidence report-evidence-1 | jq --arg path "$WORKTREE/evidence/tests.txt" '
  .evidence={producer:"keiko",verifier:"firstmate",contract:"automated-tests",executionRevision:"exec:r4",
    reference:{kind:"file",value:$path,mediaType:"text/plain"},verification:{status:"verified",instructions:"Run the focused suite."}}
')
verified=$(printf '%s' "$evidence" | FM_HOME="$HOME_DIR" "$REPORT" append -)
printf '%s' "$verified" | jq -e '.accepted == true and .report.evidence.verification.status == "verified"' >/dev/null \
  || fail "confined verified evidence must be accepted: $verified"

set +e
outside=$(printf '%s' "$evidence" | jq '.reportId="report-evidence-outside" | .correlation.identity.id="report-evidence-outside" | .evidence.reference.value="/etc/hosts"' |
  FM_HOME="$HOME_DIR" "$REPORT" append -)
status=$?
set -e
[ "$status" -ne 0 ] || fail "outside evidence must fail"
printf '%s' "$outside" | jq -e '.error.code == "evidence_outside_roots"' >/dev/null \
  || fail "outside evidence rejection must be typed: $outside"
pass "evidence references are confined and verified explicitly"

snapshot=$(printf '%s' '{"schemaVersion":"fm-captains-log-projection.v1","operation":"snapshot"}' |
  FM_HOME="$HOME_DIR" FM_PROJECTION_NOW="2026-08-01T12:10:00Z" "$ROOT/bin/fm-captains-log-projection.sh")
printf '%s' "$snapshot" | jq -e '
  (.snapshot.missions | length) == 1
  and ([.snapshot.reports[] | select(.status == "accepted")] | length) == 2
  and ([.snapshot.reports[] | select(.status == "rejected" and .error.code == "cross_build")] | length) == 1
  and .snapshot.evidence[0].missionId == "mission-42"
  and .snapshot.evidence[0].taskId == "task-42"
  and .snapshot.evidence[0].correlation.shapeUp.buildRef == "build-8"
' >/dev/null || fail "projection must retain accepted and rejected reports: $snapshot"
pass "projection preserves accepted and rejected execution truth"

# A stubbed decision-hold owner lets the degraded projection lifecycle be driven
# deterministically without a live tasks-axi backlog.
STUB_BIN="$TMP_ROOT/stub-bin"
mkdir -p "$STUB_BIN"
for script in "$ROOT"/bin/*; do
  ln -s "$script" "$STUB_BIN/$(basename "$script")"
done
rm -f "$STUB_BIN/fm-decision-hold.sh"
HOLD_STATE="$TMP_ROOT/hold-state"
printf 'fail\n' > "$HOLD_STATE"
cat > "$STUB_BIN/fm-decision-hold.sh" <<'SH'
#!/usr/bin/env bash
set -u
state=$(cat "${FM_TEST_HOLD_STATE:?}")
case "${1:-}" in
  hold) printf '%s-decision-%s\n' "$2" "$3"; exit 0 ;;
  project)
    [ "$state" = project-ok ] || exit 1
    printf 'projected\n'; exit 0 ;;
  status)
    case "$state" in
      hold-gone) printf '{"schemaVersion":"fm-captain-call-status.v1","durableState":{"state":"done","held":false}}\n' ;;
      *) printf '{"schemaVersion":"fm-captain-call-status.v1","durableState":{"state":"queued","held":true}}\n' ;;
    esac
    exit 0 ;;
esac
exit 2
SH
chmod +x "$STUB_BIN/fm-decision-hold.sh"

condition_report=$(base_report scope_revision report-condition-1 | jq '
  .condition={conditionId:"scope-drop",title:"Choose scope-drop",explanation:"Dropping the Scope changes the Build outcome.",
    recommendation:"Defer the Scope explicitly.",choices:["defer","retain"],consequenceOfDelay:"Execution stays blocked.",
    affectedObjects:["build-8"],evidence:[],boundRevisions:{build:"build-8:r7"}}
  | .scope={change:"drop",reason:"The accepted Build no longer fits the appetite."}
')
report_path="$HOME_DIR/data/engineering/reports/report-condition-1.json"

set +e
degraded=$(printf '%s' "$condition_report" |
  FM_HOME="$HOME_DIR" FM_TEST_HOLD_STATE="$HOLD_STATE" "$STUB_BIN/fm-report.sh" append -)
status=$?
set -e
[ "$status" -eq 0 ] || fail "a report whose packet cannot be projected must still be accepted: $degraded"
printf '%s' "$degraded" | jq -e '
  .accepted == true
  and .report.status == "accepted"
  and .report.condition.projection.status == "degraded"
  and .captainCall.projection == "degraded"
  and .captainCall.error.code == "captain_call_projection_failed"
' >/dev/null || fail "failed packet projection must stay accepted and typed degraded: $degraded"
jq -e '.status == "accepted" and .condition.projection.status == "degraded"' "$report_path" >/dev/null \
  || fail "the degraded projection state must be durable"

before=$(cat "$report_path")
retry=$(printf '%s' "$condition_report" |
  FM_HOME="$HOME_DIR" FM_TEST_HOLD_STATE="$HOLD_STATE" "$STUB_BIN/fm-report.sh" append -)
printf '%s' "$retry" | jq -e '.accepted == true and .replayed == true and .captainCall.projection == "degraded"' >/dev/null \
  || fail "a still-degraded replay must report the degraded state: $retry"
[ "$before" = "$(cat "$report_path")" ] || fail "a replay that cannot heal must not rewrite the durable record"

printf 'project-ok\n' > "$HOLD_STATE"
healed=$(printf '%s' "$condition_report" |
  FM_HOME="$HOME_DIR" FM_TEST_HOLD_STATE="$HOLD_STATE" "$STUB_BIN/fm-report.sh" append -)
printf '%s' "$healed" | jq -e '
  .accepted == true and .replayed == true
  and (.captainCall? // null) == null
  and .report.condition.projection.status == "projected"
' >/dev/null || fail "exact replay must heal a degraded packet projection: $healed"
jq -e '.condition.projection.status == "projected"' "$report_path" >/dev/null \
  || fail "the healed projection state must be durable"
pass "a Captain Call packet that cannot be projected stays accepted, typed, and heals on exact replay"

conditions=$(printf '%s' '{"schemaVersion":"fm-captains-log-projection.v1","operation":"snapshot"}' |
  FM_HOME="$HOME_DIR" "$ROOT/bin/fm-captains-log-projection.sh")
printf '%s' "$conditions" | jq -e '
  (.snapshot.conditions | length) == 1
  and .snapshot.conditions[0].projection.status == "projected"
' >/dev/null || fail "the Captain surface must show whether a condition received its packet: $conditions"

second_condition=$(printf '%s' "$condition_report" | jq '
  .reportId="report-condition-2" | .correlation.identity.id="report-condition-2"
  | .condition.conditionId="scope-hold" | .condition.title="Choose scope-hold"')
printf 'fail\n' > "$HOLD_STATE"
printf '%s' "$second_condition" |
  FM_HOME="$HOME_DIR" FM_TEST_HOLD_STATE="$HOLD_STATE" "$STUB_BIN/fm-report.sh" append - >/dev/null
second_path="$HOME_DIR/data/engineering/reports/report-condition-2.json"
jq -e '.condition.projection.status == "degraded"' "$second_path" >/dev/null \
  || fail "the second Captain Call must start degraded"

printf 'hold-gone\n' > "$HOLD_STATE"
abandoned=$(printf '%s' "$second_condition" |
  FM_HOME="$HOME_DIR" FM_TEST_HOLD_STATE="$HOLD_STATE" "$STUB_BIN/fm-report.sh" append -)
printf '%s' "$abandoned" | jq -e '
  .accepted == true and .replayed == true
  and .captainCall.projection == "abandoned"
  and .captainCall.error.code == "captain_call_not_active"
' >/dev/null || fail "healing must stop once the Captain Call is no longer held: $abandoned"
settled=$(cat "$second_path")
again=$(printf '%s' "$second_condition" |
  FM_HOME="$HOME_DIR" FM_TEST_HOLD_STATE="$HOLD_STATE" "$STUB_BIN/fm-report.sh" append -)
printf '%s' "$again" | jq -e '.accepted == true and .captainCall.projection == "abandoned"' >/dev/null \
  || fail "an abandoned packet must stay abandoned: $again"
[ "$settled" = "$(cat "$second_path")" ] || fail "an abandoned packet must not be rewritten on every replay"
pass "packet healing terminates once its durable Captain Call is closed"

if [ "$(id -u)" -eq 0 ]; then
  echo "skip: unreadable-record coverage needs a non-root user"
else
  third_condition=$(printf '%s' "$condition_report" | jq '
    .reportId="report-condition-3" | .correlation.identity.id="report-condition-3"
    | .condition.conditionId="scope-widen" | .condition.title="Choose scope-widen"')
  chmod 000 "$report_path"
  set +e
  truncated=$(printf '%s' "$third_condition" |
    FM_HOME="$HOME_DIR" FM_TEST_HOLD_STATE="$HOLD_STATE" "$STUB_BIN/fm-report.sh" append -)
  status=$?
  set -e
  chmod 644 "$report_path"
  [ "$status" -ne 0 ] || fail "a partially readable condition history must not be treated as complete"
  printf '%s' "$truncated" | jq -e '
    .accepted == false and .error.code == "condition_history_unavailable"
  ' >/dev/null || fail "an unreadable stored report must be typed, not a silently truncated history: $truncated"
  assert_absent "$HOME_DIR/data/engineering/reports/report-condition-3.json" \
    "an unreadable history must not durably reject the new report"
  set +e
  retried=$(printf '%s' "$third_condition" |
    FM_HOME="$HOME_DIR" FM_TEST_HOLD_STATE="$HOLD_STATE" "$STUB_BIN/fm-report.sh" append -)
  set -e
  printf '%s' "$retried" | jq -e '
    .accepted == true and .report.condition.lifecycle == "raised"
    and .report.condition.creationSequence == 3
  ' >/dev/null || fail "a retry once the history is readable must resume with an uncolliding sequence: $retried"
  pass "a condition history that cannot be read in full is typed, never silently truncated"
fi
