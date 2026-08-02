#!/usr/bin/env bash
# Behavior tests for the versioned Captain's Log machine projection.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROJECTION="$ROOT/bin/fm-captains-log-projection.sh"
TMP_ROOT=$(fm_test_tmproot fm-captains-log-projection)
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/data/engineering/missions" "$HOME_DIR/data/engineering/reports" \
  "$HOME_DIR/data/engineering/outcomes" "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/projects"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

request() {
  printf '%s' "$1" | FM_HOME="$HOME_DIR" FM_PROJECTION_NOW="2026-08-01T12:00:00Z" "$PROJECTION"
}

capabilities=$(request '{"schemaVersion":"fm-captains-log-projection.v1","operation":"capabilities"}')
printf '%s' "$capabilities" | jq -e '
  .accepted == true
  and .schemaVersion == "fm-captains-log-projection.v1"
  and .capabilities.core == "available"
  and .capabilities.sessionInspection.required == false
  and (.operations | index("snapshot") != null)
' >/dev/null || fail "projection capabilities are invalid: $capabilities"
pass "projection publishes versioned independently negotiated capabilities"

snapshot=$(request '{"schemaVersion":"fm-captains-log-projection.v1","operation":"snapshot"}')
printf '%s' "$snapshot" | jq -e '
  .accepted == true
  and .snapshot.schemaVersion == "fm-captains-log-snapshot.v1"
  and .snapshot.capturedAt == "2026-08-01T12:00:00Z"
  and (.snapshot.sourceRevision | length == 64)
  and (.snapshot.missions | length == 0)
  and (.snapshot.reports | length == 0)
  and (.snapshot.conditions | length == 0)
  and (.snapshot.shapeUpOutcomes | length == 0)
' >/dev/null || fail "empty projection snapshot is invalid: $snapshot"
pass "projection emits a deterministic empty snapshot"

set +e
bad=$(request '{"schemaVersion":"future","operation":"snapshot"}')
status=$?
set -e
[ "$status" -ne 0 ] || fail "unsupported schema must fail"
printf '%s' "$bad" | jq -e '.error.code == "unsupported_schema" and .accepted == false' >/dev/null \
  || fail "unsupported schema must return a typed error: $bad"
pass "projection rejects unsupported schemas with a typed error"

jq -n '{
  schemaVersion:"fm-engineering-report.v1",reportId:"report-condition-1",sourceRevision:"report:r1",status:"accepted",
  missionId:"mission-1",capturedAt:"2026-08-01T12:00:00Z",
  correlation:{shapeUp:{buildRef:"build-1",scopeRef:null}},
  condition:{conditionId:"condition-1",packetRevision:"packet-1",lifecycle:"raised",creationSequence:1}
}' > "$HOME_DIR/data/engineering/reports/report-condition-1.json"
intent='{"schemaVersion":"fm-captains-log-projection.v1","operation":"intent","intent":{"intentId":"intent-1","action":"acknowledgeCondition","missionId":"mission-1","conditionId":"condition-1","packetRevision":"packet-1"}}'
first=$(request "$intent")
second=$(request "$intent")
printf '%s' "$first" | jq -e '.accepted == true and .outcome.replayed == false' >/dev/null \
  || fail "first acknowledgement must be accepted: $first"
printf '%s' "$second" | jq -e '.accepted == true and .outcome.replayed == true' >/dev/null \
  || fail "exact replay must return the prior outcome: $second"

set +e
conflict=$(request "$(printf '%s' "$intent" | jq -c '.intent.packetRevision="packet-2"')")
status=$?
set -e
[ "$status" -ne 0 ] || fail "changed intent reuse must fail"
printf '%s' "$conflict" | jq -e '.error.code == "identity_conflict"' >/dev/null \
  || fail "changed intent reuse must return identity_conflict: $conflict"
pass "projection journals exact replay and rejects changed identity reuse"

LOCKS="$HOME_DIR/state/fm-projection-intent-locks"
lock_intent() {  # <intent-id> [stale-minutes] [tz]
  jq -n --arg id "$1" '{schemaVersion:"fm-captains-log-projection.v1",operation:"intent",
    intent:{intentId:$id,action:"acknowledgeCondition",missionId:"mission-1",conditionId:"condition-1",packetRevision:"packet-1"}}' |
    TZ="${3:-UTC}" FM_HOME="$HOME_DIR" FM_PROJECTION_NOW="2026-08-01T12:00:00Z" \
      FM_PROJECTION_INTENT_LOCK_STALE_MINUTES="${2:-5}" "$PROJECTION"
}

write_lock_owner() {  # <lock-dir> <pid> <started>
  mkdir -p "$1"
  printf 'host=%s\npid=%s\nstarted=%s\n' "${HOSTNAME:-$(hostname)}" "$2" "$3" > "$1/owner"
}

start_signature() {  # <pid>
  local value
  value=$(LC_ALL=C TZ=UTC ps -o lstart= -p "$1" 2>/dev/null | tr -d '[:space:]')
  [ -n "$value" ] || return 1
  printf 'lstart:%s' "$value"
}

# Capture output and status together so a regression reports its assertion
# instead of aborting the suite under errexit.
lock_attempt() {  # <intent-id> [stale-minutes] [tz]
  set +e
  lock_output=$(lock_intent "$1" "${2:-5}" "${3:-UTC}")
  lock_status=$?
  set -e
}

if ! own_started=$(start_signature "$$"); then
  echo "skip: ps -o lstart= is unavailable, so intent-lock ownership is untestable"
else
  write_lock_owner "$LOCKS/live-owner" "$$" "$own_started"
  touch -t 200001010000 "$LOCKS/live-owner"
  lock_attempt live-owner
  [ "$lock_status" -ne 0 ] || fail "a lock held by a live owner must not be reclaimed: $lock_output"
  printf '%s' "$lock_output" | jq -e '.error.code == "intent_busy"' >/dev/null \
    || fail "a live intent owner keeps the mutex however long it runs: $lock_output"
  [ -d "$LOCKS/live-owner" ] || fail "the live owner's lock was removed"

  write_lock_owner "$LOCKS/tz-owner" "$$" "$own_started"
  touch -t 200001010000 "$LOCKS/tz-owner"
  lock_attempt tz-owner 5 Asia/Tokyo
  [ "$lock_status" -ne 0 ] \
    || fail "a live owner must not be reclaimed just because the reader's timezone differs: $lock_output"
  printf '%s' "$lock_output" | jq -e '.error.code == "intent_busy"' >/dev/null \
    || fail "owner identity must not depend on the observing timezone: $lock_output"
  [ -d "$LOCKS/tz-owner" ] || fail "a differing reader timezone reclaimed a live owner's lock"

  if [ -n "$(start_signature 1)" ] && ! kill -0 1 2>/dev/null; then
    write_lock_owner "$LOCKS/foreign-owner" 1 "$(start_signature 1)"
    touch -t 200001010000 "$LOCKS/foreign-owner"
    lock_attempt foreign-owner
    [ "$lock_status" -ne 0 ] \
      || fail "a live owner owned by another user must not be reclaimed: $lock_output"
    printf '%s' "$lock_output" | jq -e '.error.code == "intent_busy"' >/dev/null \
      || fail "an unsignalable but live owner must keep the mutex: $lock_output"
  fi

  write_lock_owner "$LOCKS/recycled-pid" "$$" "lstart:ThuJan100:00:001970"
  lock_attempt recycled-pid
  printf '%s' "$lock_output" | jq -e '.accepted == true and .outcome.status == "acknowledged"' >/dev/null \
    || fail "a lock whose pid was recycled by a later process must be reclaimed: $lock_output"
  [ ! -d "$LOCKS/recycled-pid" ] || fail "the recycled-pid lock was not released after the intent completed"

  sh -c 'exit 0' &
  dead_pid=$!
  wait "$dead_pid" 2>/dev/null || true
  write_lock_owner "$LOCKS/dead-owner" "$dead_pid" "$own_started"
  lock_attempt dead-owner
  printf '%s' "$lock_output" | jq -e '.accepted == true and .outcome.status == "acknowledged"' >/dev/null \
    || fail "a lock whose owner is gone must be reclaimed at once: $lock_output"
  [ ! -d "$LOCKS/dead-owner" ] || fail "the reclaimed lock was not released after the intent completed"

  mkdir -p "$LOCKS/unowned"
  lock_attempt unowned
  [ "$lock_status" -ne 0 ] || fail "a fresh ownerless lock must still be honoured: $lock_output"
  printf '%s' "$lock_output" | jq -e '.error.code == "intent_busy"' >/dev/null \
    || fail "an ownerless lock inside its age window stays busy: $lock_output"

  write_lock_owner "$LOCKS/foreign-method" "$$" "epoch:1754000000"
  touch -t 200001010000 "$LOCKS/foreign-method"
  lock_attempt foreign-method
  printf '%s' "$lock_output" | jq -e '.accepted == true' >/dev/null \
    || fail "an owner recorded by another identity method must age out, not be trusted forever: $lock_output"

  write_lock_owner "$LOCKS/legacy-owner" "$$" ""
  touch -t 200001010000 "$LOCKS/legacy-owner"
  lock_attempt legacy-owner
  printf '%s' "$lock_output" | jq -e '.accepted == true' >/dev/null \
    || fail "an owner that cannot be verified must still age out instead of wedging: $lock_output"

  mkdir -p "$LOCKS/aged-window"
  touch -t 200001010000 "$LOCKS/aged-window"
  lock_attempt aged-window 999999999
  [ "$lock_status" -ne 0 ] || fail "a valid wide stale window must still honour an old lock: $lock_output"
  printf '%s' "$lock_output" | jq -e '.error.code == "intent_busy"' >/dev/null \
    || fail "a valid stale-window override must be honoured: $lock_output"
  lock_attempt aged-window 0
  printf '%s' "$lock_output" | jq -e '.accepted == true' >/dev/null \
    || fail "an out-of-range stale window must fall back to the bounded default: $lock_output"
  pass "the intent mutex recovers from crashes without ever reclaiming a live owner"
fi

jq -e '
  .schemaVersion == "shapeup-correlation.v1"
  and .shapeUp.cycleRef == "cycle-13"
  and .shapeUp.buildRef == "build-8"
  and .firstMate.missionId == "mission-42"
  and .firstMate.session.backend == "herdr"
' "$ROOT/tests/fixtures/captains-log/correlation-envelope-v1.json" >/dev/null \
  || fail "correlation fixture is invalid"
jq -e '.cases | map(.name) == ["complete","core-only","shapeup-partial","unsupported"]' \
  "$ROOT/tests/fixtures/captains-log/compatibility-matrix-v1.json" >/dev/null \
  || fail "compatibility fixture is invalid"
pass "portable fixtures freeze the correlation and compatibility contract"
