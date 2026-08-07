#!/usr/bin/env bash
# fm-mission.sh - accept and manage revision-bound Engineering missions.
#
# Usage:
#   fm-mission.sh accept <mission-json-file|->
#   fm-mission.sh supersede <mission-id> --replacement <mission-id>
#   fm-mission.sh defer <mission-id> --decision-id <intent-id> --build-revision <revision>
#
# Accepted missions always carry reporting instructions that require initial
# Scope discovery when possible and continuous observations until terminal.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
ENGINEERING="$DATA/engineering"
MISSIONS="$ENGINEERING/missions"
NOW="${FM_ENGINEERING_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
SCHEMA=fm-engineering-mission.v1

# shellcheck source=bin/fm-engineering-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-engineering-lib.sh"

command -v jq >/dev/null 2>&1 || { echo "fm-mission: jq not found" >&2; exit 1; }

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

accept_mission() {  # <path-or-dash>
  local input mission_id task_id crewmate correlation canonical revision path prior prior_revision stored
  input=$(fm_eng_read_json "$1") || {
    case $? in
      2) fm_eng_fail "$SCHEMA" request_too_large "Mission records are limited to 256 KiB" ;;
      *) fm_eng_fail "$SCHEMA" malformed_mission "Mission input must be a readable JSON object" ;;
    esac
    return 2
  }
  fm_eng_contains_credentials "$input" && {
    fm_eng_fail "$SCHEMA" credential_material "Credentials must never enter mission data"
    return 2
  }
  mission_id=$(printf '%s' "$input" | jq -r '.missionId // empty')
  task_id=$(printf '%s' "$input" | jq -r '.taskId // empty')
  crewmate=$(printf '%s' "$input" | jq -r '.crewmateId // empty')
  if ! fm_eng_valid_identity "$mission_id" \
    || ! fm_eng_valid_identity "$task_id" \
    || ! fm_eng_valid_identity "$crewmate"; then
    fm_eng_fail "$SCHEMA" malformed_identity "missionId, taskId, and crewmateId must be privacy-safe identities"
    return 2
  fi
  printf '%s' "$input" | jq -e '
    .schemaVersion == "fm-engineering-mission.v1"
    and (.acceptedBuildRevision | type == "string" and length > 0)
    and ((.evidenceRequirements // []) | type == "array")
    and ((.allowedEvidenceRoots // []) | type == "array")
  ' >/dev/null 2>&1 || {
    fm_eng_fail "$SCHEMA" malformed_mission "Mission schema, Build revision, or evidence contract is invalid"
    return 2
  }
  correlation=$(printf '%s' "$input" | jq -c '.correlation // null')
  fm_eng_validate_correlation "$correlation" "$mission_id" "$task_id" "$crewmate" || {
    fm_eng_fail "$SCHEMA" malformed_correlation "Mission correlation is malformed or identity-drifted"
    return 2
  }
  printf '%s' "$correlation" | jq -e --arg revision "$(printf '%s' "$input" | jq -r '.acceptedBuildRevision')" \
    '.shapeUp.buildRevision == $revision' >/dev/null 2>&1 || {
    fm_eng_fail "$SCHEMA" stale_build "acceptedBuildRevision must match the correlation Build revision"
    return 2
  }
  canonical=$(fm_eng_canonical "$input")
  revision=$(printf '%s' "$canonical" | fm_eng_digest)
  path="$MISSIONS/$mission_id.json"
  if [ -f "$path" ]; then
    prior=$(jq -c . "$path" 2>/dev/null) || {
      fm_eng_fail "$SCHEMA" malformed_record "The existing mission record is unreadable"
      return 2
    }
    prior_revision=$(printf '%s' "$prior" | jq -r '.requestRevision // empty')
    [ "$prior_revision" = "$revision" ] || {
      fm_eng_fail "$SCHEMA" identity_conflict "missionId was already used with different content"
      return 2
    }
    jq -cn --arg schemaVersion "$SCHEMA" --argjson mission "$prior" \
      '{accepted:true,schemaVersion:$schemaVersion,replayed:true,mission:$mission}'
    return 0
  fi
  stored=$(printf '%s' "$input" | jq -c \
    --arg sourceRevision "$revision" --arg requestRevision "$revision" --arg acceptedAt "$NOW" '
    . + {
      sourceRevision:$sourceRevision,
      requestRevision:$requestRevision,
      state:"accepted",
      acceptedAt:$acceptedAt,
      reporting:{
        establishInitialScopes:true,
        continueUntilTerminal:true,
        acceptedKinds:["scope_discovery","scope_revision","hill_judgment","blocker","evidence","verification_instructions","outcome"]
      }
    }
  ')
  fm_eng_atomic_write "$path" "$stored" || {
    fm_eng_fail "$SCHEMA" record_not_durable "The accepted mission could not be stored durably"
    return 2
  }
  jq -cn --arg schemaVersion "$SCHEMA" --argjson mission "$stored" \
    '{accepted:true,schemaVersion:$schemaVersion,replayed:false,mission:$mission}'
}

# Every identity this surface stores stays a privacy-safe slug, including the
# replacement mission and deferring decision a state change binds itself to.
change_state() {  # <state> <mission-id> <flag> <value> <field> <expected-flag>
  local state=$1 mission_id=$2 flag=$3 value=$4 field=$5 path current updated
  fm_eng_valid_identity "$mission_id" || { fm_eng_fail "$SCHEMA" malformed_identity "Invalid missionId"; return 2; }
  [ "$flag" = "$6" ] || { usage >&2; return 2; }
  fm_eng_valid_identity "$value" || {
    fm_eng_fail "$SCHEMA" malformed_identity "$flag must be a privacy-safe identity"
    return 2
  }
  path="$MISSIONS/$mission_id.json"
  [ -f "$path" ] || { fm_eng_fail "$SCHEMA" mission_not_found "Mission is not accepted"; return 2; }
  current=$(jq -c . "$path") || { fm_eng_fail "$SCHEMA" malformed_record "Mission record is unreadable"; return 2; }
  updated=$(printf '%s' "$current" | jq -c --arg state "$state" --arg field "$field" --arg value "$value" --arg at "$NOW" \
    '.state=$state | .[$field]=$value | .stateChangedAt=$at')
  fm_eng_atomic_write "$path" "$updated" || {
    fm_eng_fail "$SCHEMA" record_not_durable "The mission state change could not be stored durably"
    return 2
  }
  jq -cn --arg schemaVersion "$SCHEMA" --argjson mission "$updated" \
    '{accepted:true,schemaVersion:$schemaVersion,mission:$mission}'
}

case "${1:-}" in
  accept)
    [ "$#" -eq 2 ] || { usage >&2; exit 2; }
    accept_mission "$2"
    ;;
  supersede)
    [ "$#" -eq 4 ] || { usage >&2; exit 2; }
    change_state superseded "$2" "$3" "$4" replacementMissionId --replacement
    ;;
  defer)
    [ "$#" -eq 6 ] || { usage >&2; exit 2; }
    [ "$3" = --decision-id ] && [ "$5" = --build-revision ] || { usage >&2; exit 2; }
    fm_eng_valid_identity "$2" || { fm_eng_fail "$SCHEMA" malformed_identity "Invalid missionId"; exit 2; }
    path="$MISSIONS/$2.json"
    [ -f "$path" ] || { fm_eng_fail "$SCHEMA" mission_not_found "Mission is not accepted"; exit 2; }
    current_revision=$(jq -r '.acceptedBuildRevision // empty' "$path")
    [ "$current_revision" = "$6" ] || { fm_eng_fail "$SCHEMA" stale_build "Deferred decision is bound to another Build revision"; exit 2; }
    change_state deferred "$2" "$3" "$4" deferredDecisionId --decision-id
    ;;
  -h|--help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
