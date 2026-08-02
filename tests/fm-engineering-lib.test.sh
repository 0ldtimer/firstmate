#!/usr/bin/env bash
# Behavior tests for bin/fm-engineering-lib.sh, the shared validation and
# storage helpers every Engineering surface (fm-mission.sh, fm-report.sh,
# fm-shapeup-client.sh, fm-captains-log-projection.sh) depends on. The suite
# surfaces exercise these through their own contracts; this file pins the
# helper boundaries themselves so a shared-helper change cannot quietly widen
# identity, credential, confinement, or size limits under all four of them.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# shellcheck source=bin/fm-engineering-lib.sh
# shellcheck disable=SC1091
. "$ROOT/bin/fm-engineering-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-engineering-lib)
# Every suite materializes its own subdirectories under the temp root before
# using it; this one writes directly into the root, so create it explicitly.
mkdir -p "$TMP_ROOT"

test_identities_stay_privacy_safe() {
  local value
  for value in mission-42 task_9 build.8 A-b_c.9; do
    fm_eng_valid_identity "$value" || fail "'$value' should be a valid identity"
  done
  # Empty, whitespace, path traversal, shell metacharacters, and prose all carry
  # content that must never reach a record path or a hold identity. These stay
  # refused in every locale. Non-ASCII letters do not: the pattern's A-Za-z
  # ranges are collation-based, so 'ünïcode' is refused under LC_ALL=C and
  # accepted under a UTF-8 locale. Asserting either way here would pin a
  # locale, so this suite covers only the locale-stable boundary.
  # shellcheck disable=SC2016  # Literal command substitution is inert identity test data.
  for value in '' ' ' 'mission 42' '../escape' 'mission/42' 'mission;rm' 'mission$(id)' 'mission*'; do
    ! fm_eng_valid_identity "$value" || fail "'$value' should be refused as an identity"
  done
  fm_eng_valid_identity "$(head -c 128 /dev/zero | tr '\0' 'a')" \
    || fail "a 128-character identity is within the bound"
  ! fm_eng_valid_identity "$(head -c 129 /dev/zero | tr '\0' 'a')" \
    || fail "a 129-character identity exceeds the bound"
  pass "fm_eng_valid_identity accepts only bounded privacy-safe slugs"
}

test_credential_material_is_detected() {
  local case
  for case in \
    '{"token":"anything at all"}' \
    '{"nested":{"apiSecret":"value"}}' \
    '{"a":{"b":[{"Password":"hunter2"}]}}' \
    '{"note":"pushed with ghp_AAAAAAAAAAAAAAAAAAAA today"}' \
    '{"header":"Bearer abc.def"}' \
    '{"key":"-----BEGIN RSA PRIVATE KEY-----"}' \
    '{"awsAccessKeyId":"AKIAEXAMPLEONLY"}' \
    '{"apiKey":"value"}' \
    '{"api_key":"value"}' \
    '{"passwd":"value"}' \
    '{"privateKey":"value"}' \
    '{"summary":"the run exported SERVICE_TOKEN=fm_fake_value before failing"}' \
    '{"summary":"the run exported api_key=fm_fake_value before failing"}'
  do
    fm_eng_contains_credentials "$case" || fail "credential material was not detected: $case"
  done
  # Benign records must survive, including non-string values under names that
  # merely read like credentials and prose that only mentions the words.
  for case in \
    '{"summary":"The suite passed."}' \
    '{"tokenCount":42,"secretsScanned":true,"credentials":null}' \
    '{"judgment":"We removed the password prompt from the flow."}' \
    '{"reference":{"value":"https://example.test/report.json"}}' \
    '{"judgment":"Total tokens: 4821 in this run, so we split the Scope."}' \
    '{"judgment":"We rotated the API key: ops will hand over the new one."}'
  do
    ! fm_eng_contains_credentials "$case" || fail "benign record was rejected as credential material: $case"
  done
  pass "fm_eng_contains_credentials keys on credential-shaped names and values only"
}

test_credential_vocabulary_is_shared() {
  local ere regex name
  ere=$(fm_eng_credential_name_ere)
  regex=$(fm_eng_credential_name_regex)
  # One vocabulary owns both forms, so pane redaction and record scanning cannot
  # drift apart on which names carry secrets.
  for name in token secret password passwd credential api key access private; do
    case "$regex" in
      *"$name"*) ;;
      *) fail "the jq credential vocabulary lost $name: $regex" ;;
    esac
  done
  for name in SERVICE_TOKEN aws_secret_access_key API-KEY passwd MyPassword; do
    printf '%s=x\n' "$name" | LC_ALL=C grep -Eq "^($ere)=" \
      || fail "the ERE credential vocabulary does not match $name: $ere"
  done
  for name in Authorization progress lifecycle; do
    ! printf '%s=x\n' "$name" | LC_ALL=C grep -Eq "^($ere)=" \
      || fail "the ERE credential vocabulary matched the benign name $name"
  done
  pass "fm_eng_credential_name_ere and fm_eng_credential_name_regex share one vocabulary"
}

test_credential_label_form_is_whole_token() {
  local labels name
  labels=$(fm_eng_credential_label_ere)
  # The colon form has to accept a real credential label whatever vendor prefix or
  # suffix surrounds the credential word.
  # The colon form has to accept a real credential label whatever vendor prefix or
  # suffix surrounds the credential word, including a glued lowercase prefix of the
  # kind YAML, .env, and config dumps echo.
  for name in SERVICE_TOKEN X-Api-Key aws_access_key_id AWS_SECRET_ACCESS_KEY Password access-key api_key \
    apitoken dbpassword myapikey clientsecret; do
    printf '%s:x\n' "$name" | LC_ALL=C grep -Eq "^($labels):" \
      || fail "the credential label vocabulary does not match $name: $labels"
  done
  # A credential word glued to a trailing run is an inert telemetry label, not a
  # credential name, and must not become a colon-form introducer.
  for name in tokens secrets passwords credentials keys tokenized secretive; do
    ! printf '%s:x\n' "$name" | LC_ALL=C grep -Eq "^($labels):" \
      || fail "the credential label vocabulary matched the inert plural label $name"
  done
  pass "fm_eng_credential_label_ere matches whole credential labels, not inert plurals"
}

test_credential_label_anchor_admits_delimiters() {
  local anchor labels
  anchor=$(fm_eng_credential_label_anchor)
  labels=$(fm_eng_credential_label_ere)
  # A pane echoing JSON or a config fragment quotes and brackets its labels, so the
  # boundary has to admit those delimiters rather than only whitespace.
  local case quotes='["'"'"']*'
  for case in '{"api_key": "x"}' " \"password\": \"x\"" '[access-key: x]' '(dbpassword: x)'; do
    printf '%s\n' "$case" | LC_ALL=C grep -Eq "(^|$anchor)($labels$quotes)[[:space:]]*:" \
      || fail "the label boundary does not admit the delimiter in: $case"
  done
  # The boundary must not turn an inert plural into a label just because a
  # delimiter sits in front of it.
  for case in '{"tokens": 4821}' '(secrets: none)'; do
    ! printf '%s\n' "$case" | LC_ALL=C grep -Eq "(^|$anchor)($labels$quotes)[[:space:]]*:" \
      || fail "the label boundary admitted an inert plural in: $case"
  done
  pass "fm_eng_credential_label_anchor admits quoted and bracketed credential labels"
}

test_locks_are_liveness_safe() {
  local dir="$TMP_ROOT/locks/alpha" other="$TMP_ROOT/locks/beta" status
  fm_eng_lock_acquire "$dir" 5 "2026-08-02T00:00:00Z" || fail "a free lock must be acquirable"
  [ -d "$dir" ] || fail "acquiring the lock did not create its directory"
  grep -q "^pid=$$\$" "$dir/owner" || fail "the lock owner record does not identify this process"

  set +e
  ( fm_eng_lock_acquire "$dir" 5 "2026-08-02T00:00:00Z" )
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "a lock held by a live owner must not be re-acquirable"

  fm_eng_lock_acquire "$other" 5 "2026-08-02T00:00:00Z" || fail "an unrelated lock must stay acquirable"
  fm_eng_lock_release "$dir"
  [ ! -d "$dir" ] || fail "releasing the lock did not remove its directory"
  [ -d "$other" ] || fail "releasing one lock must not release another"
  fm_eng_lock_release_all
  [ ! -d "$other" ] || fail "releasing all locks left one behind"

  # An owner that is provably gone is reclaimed at once rather than waiting out
  # the age window, so a crash cannot wedge the mutex.
  mkdir -p "$dir"
  printf 'host=%s\npid=%s\nstarted=%s\n' "${HOSTNAME:-$(hostname)}" 999999 "lstart:ThuJan100:00:001970" > "$dir/owner"
  fm_eng_lock_acquire "$dir" 5 "2026-08-02T00:00:00Z" \
    || fail "a lock whose owner is provably gone must be reclaimed"
  fm_eng_lock_release_all
  pass "fm_eng_lock_acquire serializes live owners and reclaims provably dead ones"
}

test_locks_survive_paths_with_spaces() {
  local base="$TMP_ROOT/My Locks/state" one two
  one="$base/first lock"
  two="$base/second lock"
  mkdir -p "$base"
  # A home whose path contains a space must still release the directory it holds,
  # or every run leaks one lock per identity under state/.
  fm_eng_lock_acquire "$one" 5 "2026-08-02T00:00:00Z" || fail "a spaced lock path must be acquirable"
  fm_eng_lock_release_all
  [ ! -d "$one" ] || fail "release_all left a lock whose path contains a space behind"

  fm_eng_lock_acquire "$one" 5 "2026-08-02T00:00:00Z" || fail "a spaced lock path must be re-acquirable"
  fm_eng_lock_acquire "$two" 5 "2026-08-02T00:00:00Z" || fail "a second spaced lock path must be acquirable"
  fm_eng_lock_release "$one"
  [ ! -d "$one" ] || fail "release did not remove the spaced lock it was given"
  [ -d "$two" ] || fail "releasing one spaced lock must not release another"
  fm_eng_lock_release_all
  [ ! -d "$two" ] || fail "release_all left a second spaced lock behind"
  pass "held-lock bookkeeping releases every lock whose path contains a space"
}

test_lock_wait_fails_fast_on_permanent_failure() {
  local sealed="$TMP_ROOT/sealed" status started elapsed
  if [ "$(id -u)" -eq 0 ]; then
    echo "skip: permanent lock-failure coverage needs a non-root user"
    return 0
  fi
  mkdir -p "$sealed"
  chmod 500 "$sealed"
  # A store that can never hold the lock is not contention, so the wait must refuse
  # at once instead of burning its whole bound on a condition that cannot change.
  started=$(date +%s)
  set +e
  fm_eng_lock_acquire_wait "$sealed/nested/lock" 5 "2026-08-02T00:00:00Z" 5
  status=$?
  set -e
  elapsed=$(( $(date +%s) - started ))
  chmod 700 "$sealed"
  [ "$status" -ne 0 ] || fail "an un-creatable lock parent must not report success"
  [ "$elapsed" -le 2 ] || fail "a permanent lock failure waited ${elapsed}s instead of refusing at once"

  local contended="$TMP_ROOT/contended/lock"
  fm_eng_lock_acquire "$contended" 5 "2026-08-02T00:00:00Z" || fail "the contention fixture could not be set up"
  started=$(date +%s)
  set +e
  ( fm_eng_lock_acquire_wait "$contended" 5 "2026-08-02T00:00:00Z" 2 )
  status=$?
  set -e
  elapsed=$(( $(date +%s) - started ))
  fm_eng_lock_release_all
  [ "$status" -ne 0 ] || fail "a lock held by a live owner must not be handed to a waiter"
  [ "$elapsed" -ge 1 ] || fail "contention must actually be waited out, not refused at once"
  [ "$elapsed" -le 6 ] || fail "the contention wait ran ${elapsed}s past its 2s bound"
  pass "fm_eng_lock_acquire_wait waits out contention and refuses a permanent failure at once"
}

test_reads_are_bounded_and_closed() {
  local file="$TMP_ROOT/record.json" big value status
  printf '{"missionId":"mission-42"}\n' > "$file"
  value=$(fm_eng_read_json "$file") || fail "a readable JSON object must be accepted"
  printf '%s' "$value" | jq -e '.missionId == "mission-42"' >/dev/null \
    || fail "the read record lost its content: $value"

  set +e
  fm_eng_read_json "$TMP_ROOT/absent.json" >/dev/null 2>&1
  status=$?
  set -e
  [ "$status" -eq 1 ] || fail "a missing file must report status 1, got $status"

  printf '[1,2,3]\n' > "$file"
  set +e
  fm_eng_read_json "$file" >/dev/null 2>&1
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "a non-object document must be refused"

  big=$(head -c 300000 /dev/zero | tr '\0' 'a')
  set +e
  printf '{"blob":"%s"}' "$big" | fm_eng_read_json - >/dev/null 2>&1
  status=$?
  set -e
  [ "$status" -eq 2 ] || fail "an oversized record must report the distinct status 2, got $status"

  set +e
  printf '{"blob":"%s"}' "$big" | fm_eng_read_json - 500000 >/dev/null 2>&1
  status=$?
  set -e
  [ "$status" -eq 0 ] || fail "an explicit larger bound must admit the same record, got $status"
  pass "fm_eng_read_json admits only bounded JSON objects and types its refusals"
}

test_canonical_form_is_revision_stable() {
  local a b
  a=$(fm_eng_canonical '{"b":1,"a":{"d":2,"c":3}}')
  b=$(fm_eng_canonical '{"a":{"c":3,"d":2},"b":1}')
  [ "$a" = "$b" ] || fail "canonical form is not key-order stable: '$a' vs '$b'"
  [ "$(printf '%s' "$a" | fm_eng_digest)" = "$(printf '%s' "$b" | fm_eng_digest)" ] \
    || fail "reordered identical content produced different revisions"
  [ "$(printf '%s' "$a" | fm_eng_digest)" != "$(fm_eng_canonical '{"b":2,"a":{"d":2,"c":3}}' | fm_eng_digest)" ] \
    || fail "different content produced the same revision"
  [ "${#a}" -gt 0 ] && [ "$(printf '%s' "$a" | fm_eng_digest | wc -c | tr -d '[:space:]')" = 65 ] \
    || fail "revision digest is not a 64-character hex digest"
  pass "fm_eng_canonical and fm_eng_digest give content-addressed revisions"
}

test_writes_are_atomic_and_leave_no_residue() {
  local path="$TMP_ROOT/nested/deeper/record.json"
  fm_eng_atomic_write "$path" '{"state":"accepted"}'
  jq -e '.state == "accepted"' "$path" >/dev/null || fail "atomic write did not store the record"
  [ "$(find "$TMP_ROOT/nested/deeper" -type f | wc -l | tr -d '[:space:]')" = 1 ] \
    || fail "atomic write left a temporary file behind: $(find "$TMP_ROOT/nested/deeper" -type f)"
  fm_eng_atomic_write "$path" '{"state":"superseded"}'
  jq -e '.state == "superseded"' "$path" >/dev/null || fail "atomic rewrite did not replace the record"
  # A store that cannot accept the record must say so: every caller publishes an
  # outcome only after this returns success.
  local status
  set +e
  fm_eng_atomic_write "$path/child.json" '{"state":"accepted"}' 2>/dev/null
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "a write that cannot land must report failure"
  [ "$(find "$TMP_ROOT/nested/deeper" -type f | wc -l | tr -d '[:space:]')" = 1 ] \
    || fail "a failed atomic write left residue behind: $(find "$TMP_ROOT/nested/deeper" -type f)"
  pass "fm_eng_atomic_write creates its parent, replaces records, and types its failures"
}

test_confinement_rejects_sibling_prefixes() {
  fm_eng_relative_to /approved/root/file.txt /approved/root || fail "a file under the root must be allowed"
  fm_eng_relative_to /approved/root /approved/root || fail "the root itself must be allowed"
  # The classic prefix trap: /approved/root-evil shares a string prefix with
  # /approved/root but is a different directory.
  ! fm_eng_relative_to /approved/root-evil/file.txt /approved/root \
    || fail "a sibling directory sharing the root's prefix must be refused"
  ! fm_eng_relative_to /etc/hosts /approved/root || fail "an unrelated path must be refused"
  pass "fm_eng_relative_to confines paths without falling for sibling prefixes"
}

test_correlation_envelope_is_closed() {
  local envelope
  envelope=$(jq -cn '{schemaVersion:"shapeup-correlation.v1",sourceRevision:"dispatch:r1",
    capturedAt:"2026-08-01T12:00:00Z",identity:{kind:"command",id:"dispatch-42"},
    shapeUp:{cycleRef:"cycle-13",buildRef:"build-8",buildRevision:"build-8:r7",scopeRef:null},
    firstMate:{missionId:"mission-42",taskId:"task-42",crewmateId:"keiko",session:null}}')
  fm_eng_validate_correlation "$envelope" mission-42 task-42 keiko \
    || fail "the canonical correlation envelope must validate"

  fm_eng_validate_correlation "$(printf '%s' "$envelope" | jq -c '
    .firstMate.session={backend:"herdr",targetId:"fm-task-42",lifecycle:"running"}')" \
    mission-42 task-42 keiko || fail "a closed session descriptor must validate"

  local case
  # Each case drifts exactly one thing that must not be tolerated.
  for case in \
    '.schemaVersion="shapeup-correlation.v2"' \
    '.identity.kind="prose"' \
    '.identity.id=""' \
    '.shapeUp.cycleRef=""' \
    '.shapeUp.buildRef=null' \
    '.firstMate.session={backend:"screen",targetId:"x",lifecycle:"running"}' \
    '.firstMate.session={backend:"herdr",targetId:"x",lifecycle:"thinking"}' \
    '.firstMate.session={backend:"herdr",targetId:"x",lifecycle:"running",command:"claude --dangerously"}'
  do
    ! fm_eng_validate_correlation "$(printf '%s' "$envelope" | jq -c "$case")" mission-42 task-42 keiko \
      || fail "correlation drift was tolerated: $case"
  done

  ! fm_eng_validate_correlation "$envelope" mission-43 task-42 keiko \
    || fail "a mission identity mismatch must be refused"
  ! fm_eng_validate_correlation "$envelope" mission-42 task-43 keiko \
    || fail "a task identity mismatch must be refused"
  ! fm_eng_validate_correlation "$envelope" mission-42 task-42 hoshi \
    || fail "a crewmate identity mismatch must be refused"
  pass "fm_eng_validate_correlation keeps the envelope closed and identity-bound"
}

test_failures_are_typed_json() {
  local out
  out=$(fm_eng_fail fm-engineering-report.v1 cross_build "Report correlation does not match the accepted Build")
  printf '%s' "$out" | jq -e '
    .accepted == false
    and .schemaVersion == "fm-engineering-report.v1"
    and .error.code == "cross_build"
    and (. | has("report") | not)
  ' >/dev/null || fail "typed failure shape is invalid: $out"
  out=$(fm_eng_fail fm-engineering-report.v1 cross_build "message" '{"reportId":"report-1","status":"rejected"}')
  printf '%s' "$out" | jq -e '.report.reportId == "report-1" and .report.status == "rejected"' >/dev/null \
    || fail "a rejected record must ride along with its typed failure: $out"
  pass "fm_eng_fail emits one typed JSON refusal, with the rejected record when given"
}

test_identities_stay_privacy_safe
test_credential_material_is_detected
test_credential_vocabulary_is_shared
test_credential_label_form_is_whole_token
test_credential_label_anchor_admits_delimiters
test_locks_are_liveness_safe
test_locks_survive_paths_with_spaces
test_lock_wait_fails_fast_on_permanent_failure
test_reads_are_bounded_and_closed
test_canonical_form_is_revision_stable
test_writes_are_atomic_and_leave_no_residue
test_confinement_rejects_sibling_prefixes
test_correlation_envelope_is_closed
test_failures_are_typed_json
