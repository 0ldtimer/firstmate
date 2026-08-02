#!/usr/bin/env bash
# Behavior tests for Build-level Review readiness and revision-bound acceptance.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MISSION="$ROOT/bin/fm-mission.sh"
REPORT="$ROOT/bin/fm-report.sh"
PROJECTION="$ROOT/bin/fm-captains-log-projection.sh"
TMP_ROOT=$(fm_test_tmproot fm-build-review)
HOME_DIR="$TMP_ROOT/home"
WORKTREE="$HOME_DIR/projects/task-42"
mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config" "$WORKTREE/evidence"
printf 'verified\n' > "$WORKTREE/evidence/tests.txt"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

mission=$(jq -n --arg root "$WORKTREE" '{
  schemaVersion:"fm-engineering-mission.v1",missionId:"mission-42",taskId:"task-42",crewmateId:"keiko",
  acceptedBuildRevision:"build-8:r7",evidenceRequirements:["automated-tests"],allowedEvidenceRoots:[$root],
  correlation:{schemaVersion:"shapeup-correlation.v1",sourceRevision:"dispatch:r1",capturedAt:"2026-08-01T12:00:00Z",
    identity:{kind:"command",id:"dispatch-42"},shapeUp:{cycleRef:"cycle-13",buildRef:"build-8",buildRevision:"build-8:r7",scopeRef:"scope-context"},
    firstMate:{missionId:"mission-42",taskId:"task-42",crewmateId:"keiko",session:null}}
}')
printf '%s' "$mission" | FM_HOME="$HOME_DIR" "$MISSION" accept - >/dev/null

base_report() {
  jq -n --arg id "$1" --arg kind "$2" --arg at "$3" '{
    schemaVersion:"fm-engineering-report.v1",reportId:$id,kind:$kind,capturedAt:$at,
    missionId:"mission-42",taskId:"task-42",crewmateId:"keiko",
    correlation:{schemaVersion:"shapeup-correlation.v1",sourceRevision:("event:"+$id),capturedAt:$at,
      identity:{kind:"event",id:$id},shapeUp:{cycleRef:"cycle-13",buildRef:"build-8",buildRevision:"build-8:r7",scopeRef:"scope-context"},
      firstMate:{missionId:"mission-42",taskId:"task-42",crewmateId:"keiko",session:null}}
  }'
}

evidence=$(base_report report-evidence evidence "2026-08-01T12:05:00Z" | jq --arg path "$WORKTREE/evidence/tests.txt" '
  .evidence={producer:"keiko",verifier:"firstmate",contract:"automated-tests",executionRevision:"exec:r1",
    reference:{kind:"file",value:$path,mediaType:"text/plain"},verification:{status:"verified",instructions:"Run the suite."}}
')
printf '%s' "$evidence" | FM_HOME="$HOME_DIR" "$REPORT" append - >/dev/null
outcome=$(base_report report-outcome outcome "2026-08-01T12:06:00Z" | jq '.outcome={state:"completed",summary:"Accepted mission outcome is ready for Review."}')
printf '%s' "$outcome" | FM_HOME="$HOME_DIR" "$REPORT" append - >/dev/null

snapshot=$(printf '%s' '{"schemaVersion":"fm-captains-log-projection.v1","operation":"snapshot"}' |
  FM_HOME="$HOME_DIR" "$PROJECTION")
printf '%s' "$snapshot" | jq -e '
  (.snapshot.buildReviews | length) == 1
  and .snapshot.buildReviews[0].ready == true
  and .snapshot.buildReviews[0].missionSet[0].terminal == true
  and .snapshot.buildReviews[0].missionSet[0].evidenceVerified == true
' >/dev/null || fail "Build Review should be ready only after terminal outcome and verified evidence: $snapshot"
packet=$(printf '%s' "$snapshot" | jq -r '.snapshot.buildReviews[0].packetRevision')

accept=$(jq -n --arg packet "$packet" '{schemaVersion:"fm-captains-log-projection.v1",operation:"intent",
  intent:{intentId:"review-accept-1",action:"acceptBuildReview",cycleRef:"cycle-13",buildRef:"build-8",packetRevision:$packet}}' |
  FM_HOME="$HOME_DIR" "$PROJECTION")
printf '%s' "$accept" | jq -e '.accepted == true and .outcome.status == "captainAccepted"' >/dev/null \
  || fail "revision-bound Build Review acceptance failed: $accept"

stale_evidence=$(base_report report-evidence-stale evidence "2026-08-01T12:07:00Z" | jq --arg path "$WORKTREE/evidence/tests.txt" '
  .evidence={producer:"keiko",verifier:"firstmate",contract:"automated-tests",executionRevision:"exec:r2",
    reference:{kind:"file",value:$path,mediaType:"text/plain"},verification:{status:"stale",instructions:"Re-run the suite."}}
')
printf '%s' "$stale_evidence" | FM_HOME="$HOME_DIR" "$REPORT" append - >/dev/null
evidence_changed=$(printf '%s' '{"schemaVersion":"fm-captains-log-projection.v1","operation":"snapshot"}' |
  FM_HOME="$HOME_DIR" "$PROJECTION")
printf '%s' "$evidence_changed" | jq -e '
  .snapshot.buildReviews[0].ready == false
  and .snapshot.buildReviews[0].missionSet[0].evidenceVerified == false
' >/dev/null || fail "latest stale evidence did not invalidate Review readiness: $evidence_changed"

reverified=$(base_report report-evidence-reverified evidence "2026-08-01T12:08:00Z" | jq --arg path "$WORKTREE/evidence/tests.txt" '
  .evidence={producer:"keiko",verifier:"firstmate",contract:"automated-tests",executionRevision:"exec:r3",
    reference:{kind:"file",value:$path,mediaType:"text/plain"},verification:{status:"verified",instructions:"Run the suite."}}
')
printf '%s' "$reverified" | FM_HOME="$HOME_DIR" "$REPORT" append - >/dev/null

new_execution=$(base_report report-new-execution scope_discovery "2026-08-01T12:09:00Z" |
  jq '.scope={title:"A new Scope",judgment:"Execution discovered more work."}')
printf '%s' "$new_execution" | FM_HOME="$HOME_DIR" "$REPORT" append - >/dev/null
changed=$(printf '%s' '{"schemaVersion":"fm-captains-log-projection.v1","operation":"snapshot"}' |
  FM_HOME="$HOME_DIR" "$PROJECTION")
new_packet=$(printf '%s' "$changed" | jq -r '.snapshot.buildReviews[0].packetRevision')
[ "$new_packet" != "$packet" ] || fail "new execution did not invalidate the pending Review packet"
printf '%s' "$changed" | jq -e '.snapshot.buildReviews[0].ready == false and .snapshot.buildReviews[0].missionSet[0].terminal == false' >/dev/null \
  || fail "new execution after a terminal outcome must reopen mission readiness: $changed"

replay=$(jq -n --arg packet "$packet" '{schemaVersion:"fm-captains-log-projection.v1",operation:"intent",
  intent:{intentId:"review-accept-1",action:"acceptBuildReview",cycleRef:"cycle-13",buildRef:"build-8",packetRevision:$packet}}' |
  FM_HOME="$HOME_DIR" "$PROJECTION")
printf '%s' "$replay" | jq -e '.accepted == true and .outcome.status == "captainAccepted" and .outcome.replayed == true' >/dev/null \
  || fail "exact Build Review replay must return the prior outcome after packet drift: $replay"

set +e
stale=$(jq -n --arg packet "$packet" '{schemaVersion:"fm-captains-log-projection.v1",operation:"intent",
  intent:{intentId:"review-accept-2",action:"acceptBuildReview",cycleRef:"cycle-13",buildRef:"build-8",packetRevision:$packet}}' |
  FM_HOME="$HOME_DIR" "$PROJECTION")
status=$?
set -e
[ "$status" -ne 0 ] || fail "stale Build Review packet must fail"
printf '%s' "$stale" | jq -e '.error.code == "stale_packet"' >/dev/null \
  || fail "stale Build Review must return a typed error: $stale"
pass "Build Review binds the active mission/evidence revision and acceptance is not closeout"

mkdir -p "$HOME_DIR/projects/task-43"
second_mission=$(jq -n --arg root "$HOME_DIR/projects/task-43" '{
  schemaVersion:"fm-engineering-mission.v1",missionId:"mission-43",taskId:"task-43",crewmateId:"hoshi",
  acceptedBuildRevision:"build-8:r8",evidenceRequirements:[],allowedEvidenceRoots:[$root],
  correlation:{schemaVersion:"shapeup-correlation.v1",sourceRevision:"dispatch:r2",capturedAt:"2026-08-01T12:10:00Z",
    identity:{kind:"command",id:"dispatch-43"},shapeUp:{cycleRef:"cycle-13",buildRef:"build-8",buildRevision:"build-8:r8",scopeRef:"scope-context"},
    firstMate:{missionId:"mission-43",taskId:"task-43",crewmateId:"hoshi",session:null}}
}')
printf '%s' "$second_mission" | FM_HOME="$HOME_DIR" "$MISSION" accept - >/dev/null

conflicted=$(printf '%s' '{"schemaVersion":"fm-captains-log-projection.v1","operation":"snapshot"}' |
  FM_HOME="$HOME_DIR" "$PROJECTION")
printf '%s' "$conflicted" | jq -e '
  (.snapshot.buildReviews | length) == 1
  and .snapshot.buildReviews[0].revisionConflict == true
  and .snapshot.buildReviews[0].buildRevision == null
  and .snapshot.buildReviews[0].buildRevisions == ["build-8:r7","build-8:r8"]
  and ([.snapshot.buildReviews[0].missionSet[].missionId] | sort) == ["mission-42","mission-43"]
  and .snapshot.buildReviews[0].ready == false
' >/dev/null || fail "one Build packet must span every active mission and mark revision conflict: $conflicted"

conflict_packet=$(printf '%s' "$conflicted" | jq -r '.snapshot.buildReviews[0].packetRevision')
[ "${#conflict_packet}" -eq 64 ] || fail "Build Review packet revision must be a digest: $conflict_packet"
set +e
conflict_accept=$(jq -n --arg packet "$conflict_packet" '{schemaVersion:"fm-captains-log-projection.v1",operation:"intent",
  intent:{intentId:"review-accept-conflict",action:"acceptBuildReview",cycleRef:"cycle-13",buildRef:"build-8",packetRevision:$packet}}' |
  FM_HOME="$HOME_DIR" "$PROJECTION")
status=$?
set -e
[ "$status" -ne 0 ] || fail "conflicting Build revisions must refuse acceptance"
printf '%s' "$conflict_accept" | jq -e '.error.code == "review_revision_conflict"' >/dev/null \
  || fail "conflicting Build revisions must be typed, not a misleading stale packet: $conflict_accept"
pass "one Build Review packet spans every active mission and refuses conflicting revisions"

jq -n '{
  schemaVersion:"fm-engineering-mission.v1",missionId:"mission-44",taskId:"task-44",crewmateId:"malcolm",
  state:"accepted",sourceRevision:"hand-edited",acceptedBuildRevision:"build-8:r7",
  evidenceRequirements:"automated-tests",allowedEvidenceRoots:[],
  correlation:{shapeUp:{cycleRef:"cycle-13",buildRef:"build-8",buildRevision:"build-8:r7",scopeRef:null}}
}' > "$HOME_DIR/data/engineering/missions/mission-44.json"
set +e
uncomputable=$(printf '%s' '{"schemaVersion":"fm-captains-log-projection.v1","operation":"snapshot"}' |
  FM_HOME="$HOME_DIR" "$PROJECTION" 2>/dev/null)
status=$?
set -e
[ "$status" -ne 0 ] || fail "an uncomputable Build Review set must not look like a fresh snapshot"
printf '%s' "$uncomputable" | jq -e '.accepted == false and .error.code == "projection_unavailable"' >/dev/null \
  || fail "a failed Build Review computation must be typed unavailable, not an empty review set: $uncomputable"
rm -f "$HOME_DIR/data/engineering/missions/mission-44.json"
set +e
recovered=$(printf '%s' '{"schemaVersion":"fm-captains-log-projection.v1","operation":"snapshot"}' |
  FM_HOME="$HOME_DIR" "$PROJECTION")
set -e
printf '%s' "$recovered" | jq -e '.accepted == true and (.snapshot.buildReviews | length) == 1' >/dev/null \
  || fail "the projection must recover once the uncomputable record is gone: $recovered"
pass "a Build Review set that cannot be computed degrades to a typed unavailable projection"
