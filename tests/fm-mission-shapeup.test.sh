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
