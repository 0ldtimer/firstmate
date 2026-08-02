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
    '{"key":"-----BEGIN RSA PRIVATE KEY-----"}'
  do
    fm_eng_contains_credentials "$case" || fail "credential material was not detected: $case"
  done
  # Benign records must survive, including non-string values under names that
  # merely read like credentials and prose that only mentions the words.
  for case in \
    '{"summary":"The suite passed."}' \
    '{"tokenCount":42,"secretsScanned":true,"credentials":null}' \
    '{"judgment":"We removed the password prompt from the flow."}' \
    '{"reference":{"value":"https://example.test/report.json"}}'
  do
    ! fm_eng_contains_credentials "$case" || fail "benign record was rejected as credential material: $case"
  done
  pass "fm_eng_contains_credentials keys on credential-shaped names and values only"
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
  pass "fm_eng_atomic_write creates its parent and replaces records without residue"
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
test_reads_are_bounded_and_closed
test_canonical_form_is_revision_stable
test_writes_are_atomic_and_leave_no_residue
test_confinement_rejects_sibling_prefixes
test_correlation_envelope_is_closed
test_failures_are_typed_json
