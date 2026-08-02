#!/usr/bin/env bash
# fm-report.sh - validate and append continuous Engineering observations.
#
# Usage:
#   fm-report.sh append <report-json-file|->
#
# Reports are immutable and idempotent by reportId.
# Invalid correlated reports are retained with status=rejected and a typed
# error so Captain's Log can show them without making them executable.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
ENGINEERING="$DATA/engineering"
MISSIONS="$ENGINEERING/missions"
REPORTS="$ENGINEERING/reports"
NOW="${FM_ENGINEERING_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
SCHEMA=fm-engineering-report.v1
MAX_EVIDENCE_BYTES=${FM_EVIDENCE_MAX_BYTES:-10485760}

# shellcheck source=bin/fm-engineering-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-engineering-lib.sh"

command -v jq >/dev/null 2>&1 || { echo "fm-report: jq not found" >&2; exit 1; }

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

report_error() {  # <code> <message> <input> <digest> <report-id>
  local code=$1 message=$2 input=$3 request_digest=$4 report_id=$5 rejected
  rejected=$(printf '%s' "$input" | jq -c --arg code "$code" --arg message "$message" \
    --arg sourceRevision "$request_digest" --arg rejectedAt "$NOW" '
    . + {
      sourceRevision:$sourceRevision,
      requestDigest:$sourceRevision,
      status:"rejected",
      rejectedAt:$rejectedAt,
      error:{code:$code,message:$message}
    }
  ')
  if fm_eng_valid_identity "$report_id"; then
    fm_eng_atomic_write "$REPORTS/$report_id.json" "$rejected"
  fi
  fm_eng_fail "$SCHEMA" "$code" "$message" "$rejected"
  return 2
}

canonical_file() {  # <path>
  local path=$1 dir base
  [ -f "$path" ] || return 1
  dir=$(cd "$(dirname "$path")" 2>/dev/null && pwd -P) || return 1
  base=$(basename "$path")
  printf '%s/%s\n' "$dir" "$base"
}

evidence_root_allows() {  # <file> <mission-json>
  local file=$1 mission=$2 root canonical_root
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    canonical_root=$(cd "$root" 2>/dev/null && pwd -P) || continue
    fm_eng_relative_to "$file" "$canonical_root" && return 0
  done < <(printf '%s' "$mission" | jq -r '.allowedEvidenceRoots[]?')
  return 1
}

CONDITION_SCAN_EMPTY='{"latest":null,"nextSequence":1}'

condition_scan_filter() {  # <mission-id> <condition-id> <file>...
  local mission_id=$1 condition_id=$2
  shift 2
  printf '%s\0' "$@" | xargs -0 cat 2>/dev/null \
    | jq -cn --arg missionId "$mission_id" --arg conditionId "$condition_id" '
    [inputs] as $read
    | ($read | map(select(type == "object"))) as $records
    | {
        latest:([ $records[]
          | select(.status == "accepted" and .missionId == $missionId
            and .condition.conditionId == $conditionId) ]
          | sort_by(.acceptedAt // "",.capturedAt // "",.reportId) | last // null),
        nextSequence:(([ $records[] | .condition.creationSequence? | numbers ] | max // 0) + 1),
        readCount:($read | length)
      }
  '
}

condition_scan_complete() {  # <scan-json> <expected-count>
  [ -n "$1" ] || return 1
  [ "$(printf '%s' "$1" | jq -r '.readCount // "invalid"')" = "$2" ]
}

# One pass over stored reports yields both the authoritative prior packet for a
# condition and the next unused creation sequence. Every expected record must be
# read: a store that cannot be read in full is a typed failure, never a silently
# truncated history that would re-raise an existing condition and collide its
# creation sequence.
condition_scan() {  # <mission-id> <condition-id>
  local mission_id=$1 condition_id=$2 file result
  local -a files=() valid=()
  if [ -d "$REPORTS" ]; then
    while IFS= read -r file; do
      [ -n "$file" ] || continue
      files[${#files[@]}]=$file
    done < <(find "$REPORTS" -maxdepth 1 -type f -name '*.json' -print 2>/dev/null | LC_ALL=C sort)
  fi
  if [ "${#files[@]}" -eq 0 ]; then
    printf '%s' "$CONDITION_SCAN_EMPTY"
    return 0
  fi
  if result=$(condition_scan_filter "$mission_id" "$condition_id" "${files[@]}" 2>/dev/null) \
    && condition_scan_complete "$result" "${#files[@]}"; then
    printf '%s' "$result"
    return 0
  fi
  for file in "${files[@]}"; do
    [ -r "$file" ] || return 1
    jq -e 'type == "object"' "$file" >/dev/null 2>&1 && valid[${#valid[@]}]=$file
  done
  if [ "${#valid[@]}" -eq 0 ]; then
    printf '%s' "$CONDITION_SCAN_EMPTY"
    return 0
  fi
  result=$(condition_scan_filter "$mission_id" "$condition_id" "${valid[@]}") || return 1
  condition_scan_complete "$result" "${#valid[@]}" || return 1
  printf '%s' "$result"
}

validate_evidence() {  # <input> <mission>
  local input=$1 mission=$2 kind value canonical size
  printf '%s' "$input" | jq -e '
    .evidence.producer == .crewmateId
    and .evidence.verifier == "firstmate"
    and (.evidence.contract | type == "string" and length > 0)
    and (.evidence.executionRevision | type == "string" and length > 0)
    and (.evidence.verification.status | IN("missing","present","failed","stale","unavailable","not-applicable","verified"))
    and (.evidence.verification.instructions | type == "string" and length > 0)
    and (.evidence.reference.kind | IN("file","url"))
    and (.evidence.reference.value | type == "string" and length > 0)
    and (.evidence.reference.mediaType | IN("text/plain","application/json","image/png","image/jpeg","application/pdf"))
  ' >/dev/null 2>&1 || return 3
  kind=$(printf '%s' "$input" | jq -r '.evidence.reference.kind')
  value=$(printf '%s' "$input" | jq -r '.evidence.reference.value')
  case "$kind" in
    file)
      canonical=$(canonical_file "$value") || return 4
      evidence_root_allows "$canonical" "$mission" || return 5
      size=$(wc -c < "$canonical" | tr -d '[:space:]')
      case "$size" in ''|*[!0-9]*) return 3 ;; esac
      [ "$size" -le "$MAX_EVIDENCE_BYTES" ] || return 6
      ;;
    url)
      case "$value" in https://*) ;; *) return 7 ;; esac
      printf '%s' "$input" | jq -e '.evidence.reference.requiresConfirmation == true' >/dev/null 2>&1 || return 8
      ;;
  esac
  return 0
}

# Projection is a separate durable step from acceptance: an accepted report keeps
# a typed projection state so an exact replay can retry and heal it. A retry that
# fails again leaves the existing state untouched so replay stays free of writes.
project_condition_packet() {  # <report-path> <mission-id> <condition-id> <lifecycle> <report-json>
  local path=$1 mission_id=$2 condition_id=$3 lifecycle=$4 report=$5 updated
  if "$SCRIPT_DIR/fm-decision-hold.sh" project "$mission_id" "$condition_id" \
    --packet-file "$path" --lifecycle "$lifecycle" >/dev/null; then
    updated=$(printf '%s' "$report" | jq -c --arg at "$NOW" \
      '.condition.projection={status:"projected",projectedAt:$at}')
  else
    updated=$(printf '%s' "$report" | jq -c --arg at "$NOW" '
      if (.condition.projection.status? // "") == "degraded" then .
      else
        .condition.projection={
          status:"degraded",
          attemptedAt:$at,
          error:{
            code:"captain_call_projection_failed",
            message:"Captain Call is held durably but its packet could not be projected"
          }
        }
      end')
  fi
  [ "$updated" = "$report" ] || fm_eng_atomic_write "$path" "$updated"
  printf '%s' "$updated"
}

condition_hold_state() {  # <mission-id> <condition-id>
  local status
  status=$("$SCRIPT_DIR/fm-decision-hold.sh" status "$1" "$2" --json 2>/dev/null) || {
    printf 'unknown'
    return 0
  }
  printf '%s' "$status" | jq -e 'type == "object"' >/dev/null 2>&1 || {
    printf 'unknown'
    return 0
  }
  if printf '%s' "$status" | jq -e '.durableState.held == true and .durableState.state == "queued"' >/dev/null 2>&1; then
    printf 'active'
  else
    printf 'inactive'
  fi
}

# Healing only makes sense while the Captain Call is still held. Once the durable
# hold is closed the packet can never land, so the record records that terminally
# instead of retrying and rewriting itself on every replay.
heal_condition_projection() {  # <report-path> <report-json>
  local path=$1 report=$2 mission_id condition_id lifecycle updated
  mission_id=$(printf '%s' "$report" | jq -r '.missionId // empty')
  condition_id=$(printf '%s' "$report" | jq -r '.condition.conditionId // empty')
  lifecycle=$(printf '%s' "$report" | jq -r '.condition.lifecycle // "raised"')
  if [ "$(condition_hold_state "$mission_id" "$condition_id")" = inactive ]; then
    updated=$(printf '%s' "$report" | jq -c --arg at "$NOW" '
      .condition.projection={
        status:"abandoned",
        abandonedAt:$at,
        error:{
          code:"captain_call_not_active",
          message:"The Captain Call is no longer actively held, so its packet can no longer be projected"
        }
      }')
    [ "$updated" = "$report" ] || fm_eng_atomic_write "$path" "$updated"
    printf '%s' "$updated"
    return 0
  fi
  project_condition_packet "$path" "$mission_id" "$condition_id" "$lifecycle" "$report"
}

accepted_report_response() {  # <report-json> <replayed>
  printf '%s' "$1" | jq -c --arg schemaVersion "$SCHEMA" --argjson replayed "$2" '
    . as $report
    | ($report.condition.projection? // null) as $projection
    | {accepted:true,schemaVersion:$schemaVersion,replayed:$replayed,report:$report}
    | if ($projection != null and $projection.status != "projected")
      then . + {captainCall:{projection:$projection.status,error:$projection.error}}
      else . end'
}

append_report() {  # <path-or-dash>
  local input report_id kind mission_id task_id crewmate request_digest path prior prior_digest mission correlation validation stored
  local shapeup_submission condition_scan_result
  local condition_id condition_title condition_packet condition_revision condition_previous condition_sequence condition_lifecycle hold_id
  input=$(fm_eng_read_json "$1") || {
    case $? in
      2) fm_eng_fail "$SCHEMA" request_too_large "Report records are limited to 256 KiB" ;;
      *) fm_eng_fail "$SCHEMA" malformed_report "Report input must be a readable JSON object" ;;
    esac
    return 2
  }
  fm_eng_contains_credentials "$input" && {
    fm_eng_fail "$SCHEMA" credential_material "Credentials must never enter reports or evidence"
    return 2
  }
  report_id=$(printf '%s' "$input" | jq -r '.reportId // empty')
  kind=$(printf '%s' "$input" | jq -r '.kind // empty')
  mission_id=$(printf '%s' "$input" | jq -r '.missionId // empty')
  task_id=$(printf '%s' "$input" | jq -r '.taskId // empty')
  crewmate=$(printf '%s' "$input" | jq -r '.crewmateId // empty')
  if ! fm_eng_valid_identity "$report_id" \
    || ! fm_eng_valid_identity "$mission_id" \
    || ! fm_eng_valid_identity "$task_id" \
    || ! fm_eng_valid_identity "$crewmate"; then
    fm_eng_fail "$SCHEMA" malformed_identity "Report and FirstMate identities must be privacy-safe"
    return 2
  fi
  request_digest=$(fm_eng_canonical "$input" | fm_eng_digest)
  path="$REPORTS/$report_id.json"
  if [ -f "$path" ]; then
    prior=$(jq -c . "$path" 2>/dev/null) || { fm_eng_fail "$SCHEMA" malformed_record "Existing report is unreadable"; return 2; }
    prior_digest=$(printf '%s' "$prior" | jq -r '.requestDigest // empty')
    [ "$prior_digest" = "$request_digest" ] || {
      fm_eng_fail "$SCHEMA" identity_conflict "reportId was already used with different content"
      return 2
    }
    if [ "$(printf '%s' "$prior" | jq -r '.status')" = rejected ]; then
      fm_eng_fail "$SCHEMA" "$(printf '%s' "$prior" | jq -r '.error.code')" \
        "$(printf '%s' "$prior" | jq -r '.error.message')" "$prior"
      return 2
    fi
    if [ "$(printf '%s' "$prior" | jq -r '.condition.projection.status? // empty')" = degraded ]; then
      prior=$(heal_condition_projection "$path" "$prior")
    fi
    accepted_report_response "$prior" true
    return 0
  fi
  printf '%s' "$input" | jq -e '
    .schemaVersion == "fm-engineering-report.v1"
    and (.capturedAt | type == "string" and length > 0)
  ' >/dev/null 2>&1 || {
    report_error malformed_report "Report schema or capture time is invalid" "$input" "$request_digest" "$report_id"
    return 2
  }
  case "$kind" in
    scope_discovery|scope_revision|hill_judgment|blocker|evidence|verification_instructions|outcome) ;;
    *) report_error unsupported_report_kind "Report kind is not accepted" "$input" "$request_digest" "$report_id"; return 2 ;;
  esac
  [ -f "$MISSIONS/$mission_id.json" ] || {
    report_error mission_not_found "Report mission is not accepted" "$input" "$request_digest" "$report_id"
    return 2
  }
  mission=$(jq -c . "$MISSIONS/$mission_id.json" 2>/dev/null) || {
    report_error malformed_record "Mission record is unreadable" "$input" "$request_digest" "$report_id"
    return 2
  }
  [ "$(printf '%s' "$mission" | jq -r '.taskId')" = "$task_id" ] \
    && [ "$(printf '%s' "$mission" | jq -r '.crewmateId')" = "$crewmate" ] || {
      report_error identity_drift "Report task or crewmate differs from the accepted mission" "$input" "$request_digest" "$report_id"
      return 2
    }
  correlation=$(printf '%s' "$input" | jq -c '.correlation // null')
  fm_eng_validate_correlation "$correlation" "$mission_id" "$task_id" "$crewmate" || {
    report_error malformed_correlation "Report correlation is malformed or identity-drifted" "$input" "$request_digest" "$report_id"
    return 2
  }
  printf '%s' "$correlation" | jq -e --argjson mission "$mission" '
    .shapeUp.cycleRef == $mission.correlation.shapeUp.cycleRef
    and .shapeUp.buildRef == $mission.correlation.shapeUp.buildRef
    and .shapeUp.buildRevision == $mission.correlation.shapeUp.buildRevision
  ' >/dev/null 2>&1 || {
    report_error cross_build "Report correlation does not match the accepted Build" "$input" "$request_digest" "$report_id"
    return 2
  }
  case "$kind" in
    hill_judgment)
      printf '%s' "$input" | jq -e '
        (.hill.phase | IN("uphill","crest","downhill"))
        and (.hill.judgment | type == "string" and length > 0)
        and ((.hill.movement // "unchanged") | IN("forward","backward","unchanged"))
        and (.hill | has("value") | not)
        and (.hill | has("progress") | not)
      ' >/dev/null 2>&1 || {
        report_error invalid_hill "Hill reports must be qualitative judgments and may move backward" "$input" "$request_digest" "$report_id"
        return 2
      }
      ;;
    evidence)
      validate_evidence "$input" "$mission"
      validation=$?
      case "$validation" in
        0) ;;
        4) report_error evidence_missing "Evidence file is missing" "$input" "$request_digest" "$report_id"; return 2 ;;
        5) report_error evidence_outside_roots "Evidence file is outside approved roots" "$input" "$request_digest" "$report_id"; return 2 ;;
        6) report_error evidence_too_large "Evidence exceeds the configured size bound" "$input" "$request_digest" "$report_id"; return 2 ;;
        7) report_error evidence_scheme "Hosted evidence must use https" "$input" "$request_digest" "$report_id"; return 2 ;;
        8) report_error evidence_confirmation "Hosted evidence requires explicit navigation confirmation" "$input" "$request_digest" "$report_id"; return 2 ;;
        *) report_error invalid_evidence "Evidence contract, media type, or verification is invalid" "$input" "$request_digest" "$report_id"; return 2 ;;
      esac
      ;;
    outcome)
      printf '%s' "$input" | jq -e '.outcome.state | IN("completed","failed","cancelled")' >/dev/null 2>&1 || {
        report_error invalid_outcome "Outcome state must be completed, failed, or cancelled" "$input" "$request_digest" "$report_id"
        return 2
      }
      ;;
  esac
  if printf '%s' "$input" | jq -e '.condition? | type == "object"' >/dev/null 2>&1; then
    printf '%s' "$input" | jq -e '
      (.condition.conditionId | type == "string" and length > 0)
      and (.condition.title | type == "string" and length > 0)
      and (.condition.explanation | type == "string" and length > 0)
      and (.condition.recommendation | type == "string" and length > 0)
      and (.condition.choices | type == "array" and length > 0)
      and (.condition.consequenceOfDelay | type == "string" and length > 0)
      and (.condition.affectedObjects | type == "array")
      and (.condition.evidence | type == "array")
      and (.condition.boundRevisions | type == "object")
    ' >/dev/null 2>&1 || {
      report_error malformed_condition "Consequential reports require a complete Captain Call packet" "$input" "$request_digest" "$report_id"
      return 2
    }
    condition_id=$(printf '%s' "$input" | jq -r '.condition.conditionId')
    condition_title=$(printf '%s' "$input" | jq -r '.condition.title')
    fm_eng_valid_identity "$condition_id" || {
      report_error malformed_condition "conditionId must be a privacy-safe identity" "$input" "$request_digest" "$report_id"
      return 2
    }
    condition_scan_result=$(condition_scan "$mission_id" "$condition_id") || {
      fm_eng_fail "$SCHEMA" condition_history_unavailable \
        "Stored condition history could not be read, so the Captain Call was not raised"
      return 2
    }
    condition_previous=$(printf '%s' "$condition_scan_result" | jq -c '.latest')
    if [ "$condition_previous" != null ]; then
      condition_lifecycle=updated
      condition_sequence=$(printf '%s' "$condition_previous" | jq -r '.condition.creationSequence')
    else
      condition_lifecycle=raised
      condition_sequence=$(printf '%s' "$condition_scan_result" | jq -r '.nextSequence')
    fi
    condition_packet=$(printf '%s' "$input" | jq -cS \
      --arg reportRevision "$request_digest" --arg missionRevision "$(printf '%s' "$mission" | jq -r '.sourceRevision')" '
      {condition:.condition,correlation:.correlation,reportRevision:$reportRevision,missionRevision:$missionRevision}
    ')
    condition_revision=$(printf '%s' "$condition_packet" | fm_eng_digest)
    hold_id="$mission_id-decision-$condition_id"
    stored=$(printf '%s' "$input" | jq -c \
      --arg sourceRevision "$request_digest" --arg acceptedAt "$NOW" \
      --arg holdId "$hold_id" --arg packetRevision "$condition_revision" \
      --arg lifecycle "$condition_lifecycle" --argjson creationSequence "$condition_sequence" '
      . + {sourceRevision:$sourceRevision,requestDigest:$sourceRevision,status:"accepted",acceptedAt:$acceptedAt}
      | .condition += {
          holdId:$holdId,
          packetRevision:$packetRevision,
          lifecycle:$lifecycle,
          creationSequence:$creationSequence
        }
    ')
    if ! "$SCRIPT_DIR/fm-decision-hold.sh" hold "$mission_id" "$condition_id" \
      --title "$condition_title" --reason "captain decision pending for $condition_id" >/dev/null; then
      report_error captain_call_unavailable "Consequential report could not enter the durable Captain Call lifecycle" \
        "$input" "$request_digest" "$report_id"
      return 2
    fi
    fm_eng_atomic_write "$path" "$stored"
    stored=$(project_condition_packet "$path" "$mission_id" "$condition_id" "$condition_lifecycle" "$stored")
    accepted_report_response "$stored" false
    return 0
  fi
  stored=$(printf '%s' "$input" | jq -c --arg sourceRevision "$request_digest" --arg acceptedAt "$NOW" '
    . + {sourceRevision:$sourceRevision,requestDigest:$sourceRevision,status:"accepted",acceptedAt:$acceptedAt}
  ')
  fm_eng_atomic_write "$path" "$stored"
  shapeup_submission=null
  if [ -f "${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/shapeup-client.json" ]; then
    case "$kind" in
      scope_discovery|scope_revision|hill_judgment)
        shapeup_submission=$("$SCRIPT_DIR/fm-shapeup-client.sh" submit "$report_id") || true
        printf '%s' "$shapeup_submission" | jq -e 'type == "object"' >/dev/null 2>&1 || {
          shapeup_submission=$(jq -cn '{
            accepted:false,
            schemaVersion:"fm-shapeup-client.v1",
            error:{
              code:"shapeup_unavailable",
              message:"The ShapeUp client produced no structured submission result"
            }
          }')
        }
        ;;
    esac
  fi
  jq -cn --arg schemaVersion "$SCHEMA" --argjson report "$stored" \
    --argjson shapeUpSubmission "$shapeup_submission" '
    {accepted:true,schemaVersion:$schemaVersion,replayed:false,report:$report}
    | if $shapeUpSubmission == null then . else .shapeUpSubmission=$shapeUpSubmission end
  '
}

case "${1:-}" in
  append)
    [ "$#" -eq 2 ] || { usage >&2; exit 2; }
    append_report "$2"
    ;;
  -h|--help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
