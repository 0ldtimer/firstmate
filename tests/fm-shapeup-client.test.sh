#!/usr/bin/env bash
# Behavior tests for the supervisor-owned ShapeUp client boundary.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MISSION="$ROOT/bin/fm-mission.sh"
REPORT="$ROOT/bin/fm-report.sh"
CLIENT="$ROOT/bin/fm-shapeup-client.sh"
PROJECTION="$ROOT/bin/fm-captains-log-projection.sh"
TMP_ROOT=$(fm_test_tmproot fm-shapeup-client)
HOME_DIR="$TMP_ROOT/home"
WORKTREE="$HOME_DIR/projects/task-42"
mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config" "$WORKTREE"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

TRANSPORT="$TMP_ROOT/shapeup-transport"
cat > "$TRANSPORT" <<'SH'
#!/usr/bin/env bash
set -u
request=$(cat)
printf '%s\n' "$#" >> "${SHAPEUP_TEST_ARGC:?}"
if [ "${SHAPEUP_WORKSPACE_TOKEN:-}" != "${SHAPEUP_TEST_EXPECTED_TOKEN:-}" ]; then
  printf '{"accepted":false,"error":{"code":"unauthorized","message":"credential rejected"}}\n'
  exit 0
fi
operation=$(printf '%s' "$request" | jq -r '.operation')
case "$operation" in
  capabilities)
    jq -n '{accepted:true,contractVersion:"shapeup-engineering.v1",capabilities:["scope.write","hill.write"]}'
    ;;
  submit)
    printf '%s' "$request" | jq '{accepted:true,outcome:{status:"applied",authoritativeRevision:"shapeup:r9",idempotencyKey:.idempotencyKey}}'
    ;;
esac
SH
chmod +x "$TRANSPORT"
printf 'token-one\n' > "$HOME_DIR/config/shapeup-token"
chmod 600 "$HOME_DIR/config/shapeup-token"
jq -n --arg transport "$TRANSPORT" '{
  schemaVersion:"fm-shapeup-client.v1",workspaceId:"workspace-1",
  transport:{kind:"executable",path:$transport},credentialFile:"shapeup-token"
}' > "$HOME_DIR/config/shapeup-client.json"

mission=$(jq -n --arg root "$WORKTREE" '{
  schemaVersion:"fm-engineering-mission.v1",missionId:"mission-42",taskId:"task-42",crewmateId:"keiko",
  acceptedBuildRevision:"build-8:r7",evidenceRequirements:[],allowedEvidenceRoots:[$root],
  correlation:{schemaVersion:"shapeup-correlation.v1",sourceRevision:"dispatch:r1",capturedAt:"2026-08-01T12:00:00Z",
    identity:{kind:"command",id:"dispatch-42"},shapeUp:{cycleRef:"cycle-13",buildRef:"build-8",buildRevision:"build-8:r7",scopeRef:null},
    firstMate:{missionId:"mission-42",taskId:"task-42",crewmateId:"keiko",session:null}}
}')
printf '%s' "$mission" | FM_HOME="$HOME_DIR" "$MISSION" accept - >/dev/null
report=$(jq -n '{
  schemaVersion:"fm-engineering-report.v1",reportId:"report-scope-1",kind:"scope_discovery",capturedAt:"2026-08-01T12:05:00Z",
  missionId:"mission-42",taskId:"task-42",crewmateId:"keiko",scope:{title:"Context fencing",judgment:"A distinct integration risk emerged."},
  correlation:{schemaVersion:"shapeup-correlation.v1",sourceRevision:"report:r1",capturedAt:"2026-08-01T12:05:00Z",
    identity:{kind:"event",id:"report-scope-1"},shapeUp:{cycleRef:"cycle-13",buildRef:"build-8",buildRevision:"build-8:r7",scopeRef:null},
    firstMate:{missionId:"mission-42",taskId:"task-42",crewmateId:"keiko",session:null}}
}')
printf '%s' "$report" | FM_HOME="$HOME_DIR" "$REPORT" append - >/dev/null

ARGC_LOG="$TMP_ROOT/argc.log"
: > "$ARGC_LOG"
first=$(FM_HOME="$HOME_DIR" SHAPEUP_TEST_ARGC="$ARGC_LOG" SHAPEUP_TEST_EXPECTED_TOKEN=token-one "$CLIENT" submit report-scope-1)
second=$(FM_HOME="$HOME_DIR" SHAPEUP_TEST_ARGC="$ARGC_LOG" SHAPEUP_TEST_EXPECTED_TOKEN=token-one "$CLIENT" submit report-scope-1)
printf '%s' "$first" | jq -e '.accepted == true and .outcome.status == "applied" and .outcome.replayed == false' >/dev/null \
  || fail "ShapeUp submission must be accepted: $first"
printf '%s' "$second" | jq -e '.accepted == true and .outcome.replayed == true' >/dev/null \
  || fail "ShapeUp submission must replay durably: $second"
[ "$(tr -d '\n' < "$ARGC_LOG")" = "00" ] || fail "credential boundary must not add command arguments"
assert_not_contains "$first" "token-one" "ShapeUp outcome leaked the credential"
projection=$(printf '%s' '{"schemaVersion":"fm-captains-log-projection.v1","operation":"snapshot"}' |
  FM_HOME="$HOME_DIR" "$PROJECTION")
printf '%s' "$projection" | jq -e '
  (.snapshot.shapeUpOutcomes | length) == 1
  and .snapshot.shapeUpOutcomes[0].outcome.authoritativeRevision == "shapeup:r9"
' >/dev/null || fail "projection did not retain the authoritative ShapeUp outcome: $projection"
pass "ShapeUp client submits guarded idempotent intent without argv or output secrets"

jq '.transport.path="/missing/transport"' "$HOME_DIR/config/shapeup-client.json" > "$TMP_ROOT/config-partial.json"
cp "$TMP_ROOT/config-partial.json" "$HOME_DIR/config/shapeup-client.json"
set +e
unavailable=$(FM_HOME="$HOME_DIR" "$CLIENT" submit report-scope-1)
status=$?
set -e
# A prior durable success must replay even when the transport is now absent.
[ "$status" -eq 0 ] || fail "durable replay should survive transport loss"
printf '%s' "$unavailable" | jq -e '.accepted == true and .outcome.replayed == true' >/dev/null \
  || fail "transport loss must not erase the prior outcome: $unavailable"
pass "lost-response recovery returns the durable semantic outcome"

rm -f "$HOME_DIR/data/engineering/shapeup-outcomes/report-scope-1.json"
set +e
missing=$(FM_HOME="$HOME_DIR" "$CLIENT" submit report-scope-1)
status=$?
set -e
[ "$status" -ne 0 ] || fail "missing transport without a journal must be unavailable"
printf '%s' "$missing" | jq -e '.error.code == "shapeup_unavailable"' >/dev/null \
  || fail "unavailable transport must be typed: $missing"
[ -f "$HOME_DIR/data/engineering/reports/report-scope-1.json" ] || fail "ShapeUp unavailability lost the crewmate report"
pass "ShapeUp unavailability preserves the validated report"

LEAKY_TRANSPORT="$TMP_ROOT/shapeup-transport-leaky"
cat > "$LEAKY_TRANSPORT" <<'SH'
#!/usr/bin/env bash
set -u
request=$(cat)
case "$(printf '%s' "$request" | jq -r '.operation')" in
  capabilities) jq -n '{accepted:true,capabilities:["scope.write","hill.write"]}' ;;
  submit) jq -n '{accepted:true,outcome:{status:"applied",authoritativeRevision:"shapeup:r10",workspaceToken:"ghp_leaked_from_upstream"}}' ;;
esac
SH
chmod +x "$LEAKY_TRANSPORT"
jq --arg t "$LEAKY_TRANSPORT" '.transport.path=$t' "$TMP_ROOT/config-partial.json" > "$HOME_DIR/config/shapeup-client.json"
set +e
leaked=$(FM_HOME="$HOME_DIR" "$CLIENT" submit report-scope-1)
status=$?
set -e
[ "$status" -ne 0 ] || fail "a transport response carrying credential material must be refused"
printf '%s' "$leaked" | jq -e '.accepted == false and .error.code == "credential_material"' >/dev/null \
  || fail "leaked transport credentials must be typed: $leaked"
assert_not_contains "$leaked" "ghp_leaked_from_upstream" "the refusal echoed the leaked credential"
assert_absent "$HOME_DIR/data/engineering/shapeup-outcomes/report-scope-1.json" \
  "a credential-bearing outcome must never be persisted"
leak_projection=$(printf '%s' '{"schemaVersion":"fm-captains-log-projection.v1","operation":"snapshot"}' |
  FM_HOME="$HOME_DIR" "$PROJECTION")
assert_not_contains "$leak_projection" "ghp_leaked_from_upstream" "the projection republished the leaked credential"
pass "transport responses carrying credential material never become durable projection state"

# A wedged endpoint must not hold the reporting crewmate open: the transport runs
# under a hard wall-clock bound and its expiry is the ordinary typed unavailable
# submission, with the validated report left intact.
HANGING_TRANSPORT="$TMP_ROOT/shapeup-transport-hanging"
cat > "$HANGING_TRANSPORT" <<'SH'
#!/usr/bin/env bash
set -u
cat >/dev/null
exec sleep 120
SH
chmod +x "$HANGING_TRANSPORT"
jq --arg t "$HANGING_TRANSPORT" '.transport.path=$t' "$TMP_ROOT/config-partial.json" > "$HOME_DIR/config/shapeup-client.json"
started=$(date +%s)
set +e
hung=$(FM_HOME="$HOME_DIR" FM_SHAPEUP_TRANSPORT_TIMEOUT=2 "$CLIENT" submit report-scope-1)
status=$?
set -e
elapsed=$(( $(date +%s) - started ))
[ "$status" -ne 0 ] || fail "a transport that never answers must not look like a submission"
printf '%s' "$hung" | jq -e '
  .accepted == false
  and .error.code == "shapeup_unavailable"
  and (.error.detailCode | IN("transport_timeout","transport_unbounded"))
' >/dev/null || fail "a wedged transport must be typed unavailable: $hung"
[ "$elapsed" -lt 60 ] || fail "the transport call was not bounded; it ran for ${elapsed}s"
[ -f "$HOME_DIR/data/engineering/reports/report-scope-1.json" ] || fail "a wedged transport lost the crewmate report"
assert_absent "$HOME_DIR/data/engineering/shapeup-outcomes/report-scope-1.json" \
  "a wedged transport must not journal an outcome"
pass "a transport that never answers expires into a typed unavailable submission"

BENIGN_TRANSPORT="$TMP_ROOT/shapeup-transport-benign"
cat > "$BENIGN_TRANSPORT" <<'SH'
#!/usr/bin/env bash
set -u
request=$(cat)
case "$(printf '%s' "$request" | jq -r '.operation')" in
  capabilities) jq -n '{accepted:true,capabilities:["scope.write","hill.write"]}' ;;
  submit)
    jq -n '{accepted:true,outcome:{status:"applied",authoritativeRevision:"shapeup:r11",
      credentialRotationRequired:false,secretsScanned:0,passwordPolicyVersion:3}}' ;;
esac
SH
chmod +x "$BENIGN_TRANSPORT"
jq --arg t "$BENIGN_TRANSPORT" '.transport.path=$t' "$TMP_ROOT/config-partial.json" > "$HOME_DIR/config/shapeup-client.json"
benign=$(FM_HOME="$HOME_DIR" "$CLIENT" submit report-scope-1)
printf '%s' "$benign" | jq -e '
  .accepted == true
  and .outcome.status == "applied"
  and .outcome.credentialRotationRequired == false
  and .outcome.secretsScanned == 0
' >/dev/null || fail "benign credential-named non-string fields must not fail a submission: $benign"
pass "credential scanning of transport responses does not reject benign non-string fields"
