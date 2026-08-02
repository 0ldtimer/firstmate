#!/usr/bin/env bash
# fm-shapeup-client.sh - supervisor-owned ShapeUp Engineering client boundary.
#
# Usage:
#   fm-shapeup-client.sh capabilities
#   fm-shapeup-client.sh submit <report-id>
#
# Configuration is read from config/shapeup-client.json.
# The first release supports one closed executable transport that receives a
# JSON request on stdin with no arguments.
# A workspace credential is read fresh from the configured owner-only file and
# supplied only through SHAPEUP_WORKSPACE_TOKEN in the child environment.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
ENGINEERING="$DATA/engineering"
REPORTS="$ENGINEERING/reports"
OUTCOMES="$ENGINEERING/shapeup-outcomes"
CONFIG_FILE="$CONFIG/shapeup-client.json"
NOW="${FM_ENGINEERING_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
SCHEMA=fm-shapeup-client.v1

# shellcheck source=bin/fm-engineering-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-engineering-lib.sh"

command -v jq >/dev/null 2>&1 || { echo "fm-shapeup-client: jq not found" >&2; exit 1; }

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

client_fail() {  # <code> <message> [detail-code]
  local detail=${3:-}
  jq -cn --arg schemaVersion "$SCHEMA" --arg code "$1" --arg message "$2" --arg detail "$detail" '
    {accepted:false,schemaVersion:$schemaVersion,error:{code:$code,message:$message}}
    | if $detail == "" then . else .error.detailCode=$detail end
  '
}

file_mode() {  # <path>
  stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1" 2>/dev/null
}

load_config() {
  [ -f "$CONFIG_FILE" ] || return 1
  jq -ce '
    select(
      .schemaVersion == "fm-shapeup-client.v1"
      and (.workspaceId | type == "string" and length > 0)
      and .transport.kind == "executable"
      and (.transport.path | type == "string" and startswith("/"))
      and (.credentialFile | type == "string" and test("^[A-Za-z0-9._-]+$"))
    )
  ' "$CONFIG_FILE" 2>/dev/null
}

load_credential() {  # <config-json>
  local config=$1 credential_file mode token
  credential_file="$CONFIG/$(printf '%s' "$config" | jq -r '.credentialFile')"
  [ -f "$credential_file" ] || return 1
  mode=$(file_mode "$credential_file") || return 1
  case "$mode" in 400|600) ;; *) return 2 ;; esac
  IFS= read -r token < "$credential_file" || true
  [ -n "$token" ] || return 1
  printf '%s' "$token"
}

transport_call() {  # <config-json> <credential> <request-json>
  local config=$1 credential=$2 request=$3 transport response value
  transport=$(printf '%s' "$config" | jq -r '.transport.path')
  [ -f "$transport" ] && [ -x "$transport" ] || return 3
  response=$(printf '%s' "$request" | SHAPEUP_WORKSPACE_TOKEN="$credential" "$transport" 2>/dev/null) || return 4
  value=$(printf '%s' "$response" | jq -ce 'select(type == "object")' 2>/dev/null) || return 5
  [ -n "$value" ] || return 5
  fm_eng_contains_credentials "$value" && return 6
  printf '%s' "$value"
}

transport_fail() {  # <status> <unavailable-message>
  case "$1" in
    6) client_fail credential_material "The ShapeUp transport response carried credential material" ;;
    *) client_fail shapeup_unavailable "$2" ;;
  esac
}

report_capability() {  # <kind>
  case "$1" in
    scope_discovery|scope_revision) printf 'scope.write' ;;
    hill_judgment) printf 'hill.write' ;;
    *) printf 'report.observe' ;;
  esac
}

capabilities() {
  local config credential response request status detail
  config=$(load_config) || { client_fail shapeup_unavailable "ShapeUp client configuration is unavailable"; return 2; }
  credential=$(load_credential "$config")
  case $? in
    0) ;;
    2) client_fail credential_permissions "ShapeUp credential file must be owner-only"; return 2 ;;
    *) client_fail shapeup_unavailable "ShapeUp workspace credential is unavailable"; return 2 ;;
  esac
  request=$(jq -cn --arg workspaceId "$(printf '%s' "$config" | jq -r '.workspaceId')" \
    '{contractVersion:"shapeup-engineering.v1",operation:"capabilities",workspaceId:$workspaceId}')
  response=$(transport_call "$config" "$credential" "$request")
  status=$?
  [ "$status" -eq 0 ] || {
    transport_fail "$status" "ShapeUp capability negotiation is unavailable"
    return 2
  }
  printf '%s' "$response" | jq -e '.accepted == true and (.capabilities | type == "array")' >/dev/null 2>&1 || {
    detail=$(printf '%s' "$response" | jq -r '.error.code // "incompatible"')
    client_fail shapeup_unavailable "ShapeUp rejected capability negotiation" "$detail"
    return 2
  }
  jq -cn --arg schemaVersion "$SCHEMA" --argjson capabilities "$response" \
    '{accepted:true,schemaVersion:$schemaVersion,capabilities:$capabilities}'
}

submit() {  # <report-id>
  local report_id=$1 report report_digest record prior prior_digest config credential capability caps request response outcome tmp detail status
  fm_eng_valid_identity "$report_id" || { client_fail malformed_identity "Invalid reportId"; return 2; }
  [ -f "$REPORTS/$report_id.json" ] || { client_fail report_not_found "Validated report is absent"; return 2; }
  report=$(jq -c . "$REPORTS/$report_id.json" 2>/dev/null) || { client_fail malformed_record "Report record is unreadable"; return 2; }
  [ "$(printf '%s' "$report" | jq -r '.status')" = accepted ] || {
    client_fail report_rejected "Rejected reports cannot be submitted"
    return 2
  }
  report_digest=$(printf '%s' "$report" | jq -r '.sourceRevision')
  record="$OUTCOMES/$report_id.json"
  if [ -f "$record" ]; then
    prior=$(jq -c . "$record" 2>/dev/null) || { client_fail malformed_record "Prior ShapeUp outcome is unreadable"; return 2; }
    prior_digest=$(printf '%s' "$prior" | jq -r '.requestDigest // empty')
    [ "$prior_digest" = "$report_digest" ] || {
      client_fail identity_conflict "Report revision changed after ShapeUp submission"
      return 2
    }
    printf '%s' "$prior" | jq -c --arg schemaVersion "$SCHEMA" '
      {accepted:true,schemaVersion:$schemaVersion,outcome:(.outcome + {replayed:true})}'
    return 0
  fi
  config=$(load_config) || { client_fail shapeup_unavailable "ShapeUp client configuration is unavailable"; return 2; }
  credential=$(load_credential "$config")
  case $? in
    0) ;;
    2) client_fail credential_permissions "ShapeUp credential file must be owner-only"; return 2 ;;
    *) client_fail shapeup_unavailable "ShapeUp workspace credential is unavailable"; return 2 ;;
  esac
  caps=$(transport_call "$config" "$credential" "$(jq -cn \
    --arg workspaceId "$(printf '%s' "$config" | jq -r '.workspaceId')" \
    '{contractVersion:"shapeup-engineering.v1",operation:"capabilities",workspaceId:$workspaceId}')")
  status=$?
  [ "$status" -eq 0 ] || {
    transport_fail "$status" "ShapeUp capability negotiation is unavailable"
    return 2
  }
  printf '%s' "$caps" | jq -e '.accepted == true and (.capabilities | type == "array")' >/dev/null 2>&1 || {
    detail=$(printf '%s' "$caps" | jq -r '.error.code // "incompatible"')
    client_fail shapeup_unavailable "ShapeUp rejected capability negotiation" "$detail"
    return 2
  }
  capability=$(report_capability "$(printf '%s' "$report" | jq -r '.kind')")
  printf '%s' "$caps" | jq -e --arg capability "$capability" '.capabilities | index($capability) != null' >/dev/null || {
    client_fail capability_unavailable "ShapeUp does not advertise the capability required for this report" "$capability"
    return 2
  }
  request=$(jq -cn \
    --arg workspaceId "$(printf '%s' "$config" | jq -r '.workspaceId')" \
    --arg idempotencyKey "fm-report:$report_id:$report_digest" \
    --arg expectedBuildRevision "$(printf '%s' "$report" | jq -r '.correlation.shapeUp.buildRevision')" \
    --argjson report "$report" '
    {
      contractVersion:"shapeup-engineering.v1",
      operation:"submit",
      workspaceId:$workspaceId,
      idempotencyKey:$idempotencyKey,
      guard:{
        cycleRef:$report.correlation.shapeUp.cycleRef,
        buildRef:$report.correlation.shapeUp.buildRef,
        expectedBuildRevision:$expectedBuildRevision
      },
      intent:{
        kind:$report.kind,
        scopeRef:$report.correlation.shapeUp.scopeRef,
        observation:($report | del(.requestDigest,.status,.acceptedAt))
      }
    }
  ')
  response=$(transport_call "$config" "$credential" "$request")
  status=$?
  [ "$status" -eq 0 ] || {
    transport_fail "$status" "ShapeUp submission is unavailable"
    return 2
  }
  printf '%s' "$response" | jq -e '.accepted == true and (.outcome | type == "object")' >/dev/null 2>&1 || {
    detail=$(printf '%s' "$response" | jq -r '.error.code // "unknown"')
    case "$detail" in stale_revision) code=shapeup_stale ;; proposal_required) code=proposal_required ;; *) code=shapeup_unavailable ;; esac
    client_fail "$code" "ShapeUp did not accept the guarded report intent" "$detail"
    return 2
  }
  outcome=$(printf '%s' "$response" | jq -c --arg reportId "$report_id" --arg reportRevision "$report_digest" --arg recordedAt "$NOW" '
    .outcome + {reportId:$reportId,reportRevision:$reportRevision,recordedAt:$recordedAt,replayed:false}
  ')
  mkdir -p "$OUTCOMES"
  tmp="$record.$$"
  jq -cn --arg requestDigest "$report_digest" --argjson outcome "$outcome" \
    '{requestDigest:$requestDigest,outcome:$outcome}' > "$tmp" && mv "$tmp" "$record"
  jq -cn --arg schemaVersion "$SCHEMA" --argjson outcome "$outcome" \
    '{accepted:true,schemaVersion:$schemaVersion,outcome:$outcome}'
}

case "${1:-}" in
  capabilities)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    capabilities
    ;;
  submit)
    [ "$#" -eq 2 ] || { usage >&2; exit 2; }
    submit "$2"
    ;;
  -h|--help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
