#!/usr/bin/env bash
# Behavior tests for Engineering mission acceptance and correlation binding.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MISSION="$ROOT/bin/fm-mission.sh"
TMP_ROOT=$(fm_test_tmproot fm-mission-shapeup)
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/projects/task-42"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

mission_file="$TMP_ROOT/mission.json"
jq -n --arg root "$HOME_DIR/projects/task-42" '{
  schemaVersion:"fm-engineering-mission.v1",
  missionId:"mission-42",
  taskId:"task-42",
  crewmateId:"keiko",
  acceptedBuildRevision:"build-8:r7",
  evidenceRequirements:["automated-tests"],
  allowedEvidenceRoots:[$root],
  correlation:{
    schemaVersion:"shapeup-correlation.v1",
    sourceRevision:"dispatch:r1",
    capturedAt:"2026-08-01T12:00:00Z",
    identity:{kind:"command",id:"dispatch-42"},
    shapeUp:{cycleRef:"cycle-13",buildRef:"build-8",buildRevision:"build-8:r7",scopeRef:null},
    firstMate:{missionId:"mission-42",taskId:"task-42",crewmateId:"keiko",session:null}
  }
}' > "$mission_file"

accepted=$(FM_HOME="$HOME_DIR" FM_ENGINEERING_NOW="2026-08-01T12:01:00Z" "$MISSION" accept "$mission_file")
printf '%s' "$accepted" | jq -e '
  .accepted == true
  and .mission.state == "accepted"
  and .mission.reporting.establishInitialScopes == true
  and .mission.reporting.continueUntilTerminal == true
  and (.mission.sourceRevision | length == 64)
' >/dev/null || fail "mission acceptance contract is invalid: $accepted"

replayed=$(FM_HOME="$HOME_DIR" "$MISSION" accept "$mission_file")
printf '%s' "$replayed" | jq -e '.accepted == true and .replayed == true' >/dev/null \
  || fail "exact mission replay must return the original mission"
pass "Engineering missions bind correlation and continuous reporting instructions"

set +e
conflict=$(jq '.correlation.shapeUp.buildRef="build-9"' "$mission_file" | FM_HOME="$HOME_DIR" "$MISSION" accept -)
status=$?
set -e
[ "$status" -ne 0 ] || fail "mission identity drift must fail"
printf '%s' "$conflict" | jq -e '.error.code == "identity_conflict"' >/dev/null \
  || fail "mission drift must return identity_conflict: $conflict"
pass "mission identity reuse cannot drift across Builds"

set +e
secret=$(jq '.shapeUpToken="ghp_not_allowed" | .missionId="mission-secret" | .correlation.firstMate.missionId="mission-secret"' "$mission_file" |
  FM_HOME="$HOME_DIR" "$MISSION" accept -)
status=$?
set -e
[ "$status" -ne 0 ] || fail "credentials in mission data must fail"
printf '%s' "$secret" | jq -e '.error.code == "credential_material"' >/dev/null \
  || fail "credential rejection must be typed: $secret"
pass "mission data rejects credential material"

# A state change stores an identity, so free-form prose must never reach the
# durable mission record the projection republishes verbatim.
mission_path="$HOME_DIR/data/engineering/missions/mission-42.json"
for bad in 'customer@example.test wants this dropped' '' 'mission 43' '../escape'; do
  set +e
  refused=$(FM_HOME="$HOME_DIR" "$MISSION" supersede mission-42 --replacement "$bad" 2>/dev/null)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "supersede must refuse the non-identity replacement '$bad'"
  printf '%s' "$refused" | jq -e '.accepted == false and .error.code == "malformed_identity"' >/dev/null \
    || fail "a non-identity replacement must be typed: $refused"
done
jq -e '.state == "accepted" and (has("replacementMissionId") | not)' "$mission_path" >/dev/null \
  || fail "a refused state change must not touch the durable mission record"

for bad in 'ask ops which decision' 'decision;rm -rf'; do
  set +e
  refused=$(FM_HOME="$HOME_DIR" "$MISSION" defer mission-42 --decision-id "$bad" --build-revision "build-8:r7" 2>/dev/null)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "defer must refuse the non-identity decision '$bad'"
  printf '%s' "$refused" | jq -e '.accepted == false and .error.code == "malformed_identity"' >/dev/null \
    || fail "a non-identity deferring decision must be typed: $refused"
done

superseded=$(FM_HOME="$HOME_DIR" "$MISSION" supersede mission-42 --replacement mission-43)
printf '%s' "$superseded" | jq -e '
  .accepted == true and .mission.state == "superseded" and .mission.replacementMissionId == "mission-43"
' >/dev/null || fail "a privacy-safe replacement identity must still be accepted: $superseded"
pass "mission state changes only store privacy-safe identities"
