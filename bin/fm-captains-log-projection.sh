#!/usr/bin/env bash
# fm-captains-log-projection.sh - bounded machine projection for Captain's Log.
#
# Reads one JSON request from stdin and prints one JSON response.
# The stable request schema is fm-captains-log-projection.v1.
#
# Supported operations:
#   {"schemaVersion":"fm-captains-log-projection.v1","operation":"capabilities"}
#   {"schemaVersion":"fm-captains-log-projection.v1","operation":"snapshot"}
#   {"schemaVersion":"fm-captains-log-projection.v1","operation":"intent","intent":{...}}
#
# Core projection data is stored below data/engineering as closed JSON records.
# Invalid records remain visible in snapshot.invalidRecords and are never used
# to derive executable conditions, review packets, or command outcomes.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
ENGINEERING="$DATA/engineering"
MISSIONS="$ENGINEERING/missions"
REPORTS="$ENGINEERING/reports"
OUTCOMES="$ENGINEERING/outcomes"
SHAPEUP_OUTCOMES="$ENGINEERING/shapeup-outcomes"
NOW="${FM_PROJECTION_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
SCHEMA=fm-captains-log-projection.v1

# shellcheck source=bin/fm-engineering-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-engineering-lib.sh"

command -v jq >/dev/null 2>&1 || {
  echo "fm-captains-log-projection: jq not found" >&2
  exit 1
}

digest() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    sha256sum | awk '{print $1}'
  fi
}

fail_json() {  # <code> <message>
  jq -n --arg schemaVersion "$SCHEMA" --arg code "$1" --arg message "$2" \
    '{accepted:false,schemaVersion:$schemaVersion,error:{code:$code,message:$message}}'
}

valid_identity() {  # <value>
  case "$1" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  [ "${#1}" -le 128 ]
}

INTENT_LOCK_DIR=''
INTENT_LOCK_HOST=${HOSTNAME:-$(hostname 2>/dev/null || printf 'unknown-host')}
INTENT_LOCK_STALE_MINUTES=5
case "${FM_PROJECTION_INTENT_LOCK_STALE_MINUTES:-}" in
  ''|*[!0-9]*) ;;
  *)
    if [ "${#FM_PROJECTION_INTENT_LOCK_STALE_MINUTES}" -le 9 ] \
      && [ "$FM_PROJECTION_INTENT_LOCK_STALE_MINUTES" -ge 1 ]; then
      INTENT_LOCK_STALE_MINUTES=$FM_PROJECTION_INTENT_LOCK_STALE_MINUTES
    fi
    ;;
esac

remove_intent_lock() {  # <lock-dir>
  rm -f "$1/owner" 2>/dev/null || true
  rmdir "$1" 2>/dev/null || true
}

release_intent_lock() {
  [ -n "$INTENT_LOCK_DIR" ] || return 0
  remove_intent_lock "$INTENT_LOCK_DIR"
  INTENT_LOCK_DIR=''
}

PROCESS_START_METHOD=lstart

# The signature is rendered in a fixed locale and timezone so the same process
# always yields the same identity whatever environment observes it. It carries
# its method so a signature produced a different way is never mistaken for a
# different process.
process_start_signature() {  # <pid>
  local value
  value=$(LC_ALL=C TZ=UTC ps -o lstart= -p "$1" 2>/dev/null | tr -d '[:space:]')
  [ -n "$value" ] || return 1
  printf '%s:%s' "$PROCESS_START_METHOD" "$value"
}

# A lock whose recorded owner is provably gone - exited, or its pid recycled by a
# process that started later - is reclaimed at once. An owner that cannot be
# compared, including one recorded by another identity method, falls back to the
# bounded age window, so no lock can wedge forever and none is reclaimed merely
# because its identity is presented differently. A confirmed live owner is never
# reclaimed, however long it runs and whoever owns it.
intent_lock_owner_state() {  # <lock-dir>
  local dir=$1 owner_host owner_pid owner_started current_started
  if [ ! -f "$dir/owner" ]; then
    printf 'unknown'
    return 0
  fi
  owner_host=$(sed -n 's/^host=//p' "$dir/owner" 2>/dev/null | head -1)
  owner_pid=$(sed -n 's/^pid=//p' "$dir/owner" 2>/dev/null | head -1)
  owner_started=$(sed -n 's/^started=//p' "$dir/owner" 2>/dev/null | head -1)
  if [ "$owner_host" != "$INTENT_LOCK_HOST" ]; then
    printf 'unknown'
    return 0
  fi
  case "$owner_pid" in
    ''|*[!0-9]*) printf 'unknown'; return 0 ;;
  esac
  current_started=$(process_start_signature "$owner_pid") || current_started=''
  if [ -z "$current_started" ]; then
    if kill -0 "$owner_pid" 2>/dev/null; then
      printf 'unknown'
    else
      printf 'dead'
    fi
    return 0
  fi
  case "$owner_started" in
    "$PROCESS_START_METHOD":?*) ;;
    *) printf 'unknown'; return 0 ;;
  esac
  if [ "$owner_started" = "$current_started" ]; then
    printf 'alive'
  else
    printf 'dead'
  fi
}

reclaim_stale_intent_lock() {  # <lock-dir>
  local dir=$1
  [ -d "$dir" ] || return 0
  case "$(intent_lock_owner_state "$dir")" in
    alive) return 0 ;;
    dead) ;;
    *)
      [ -n "$(find "$dir" -maxdepth 0 -mmin "+$INTENT_LOCK_STALE_MINUTES" -print 2>/dev/null)" ] || return 0
      ;;
  esac
  remove_intent_lock "$dir"
}

trap release_intent_lock EXIT
trap 'release_intent_lock; exit 130' INT
trap 'release_intent_lock; exit 143' TERM
trap 'release_intent_lock; exit 129' HUP

collect_records() {  # <dir> <kind>
  local dir=$1 kind=$2 file records invalid
  local -a files=() valid=() malformed=()
  if [ -d "$dir" ]; then
    while IFS= read -r file; do
      [ -n "$file" ] || continue
      files[${#files[@]}]=$file
    done < <(find "$dir" -type f -name '*.json' -print 2>/dev/null | LC_ALL=C sort)
  fi
  if [ "${#files[@]}" -eq 0 ]; then
    printf '{"records":[],"invalid":[]}'
    return 0
  fi
  if records=$(printf '%s\0' "${files[@]}" | xargs -0 cat 2>/dev/null | jq -cn '[inputs]' 2>/dev/null) \
    && [ "$(printf '%s' "$records" | jq -r 'length')" = "${#files[@]}" ] \
    && [ "$(printf '%s' "$records" | jq -r 'all(type == "object")')" = true ]; then
    jq -cn --argjson records "$records" '{records:$records,invalid:[]}'
    return 0
  fi
  for file in "${files[@]}"; do
    if jq -e 'type == "object"' "$file" >/dev/null 2>&1; then
      valid[${#valid[@]}]=$file
    else
      malformed[${#malformed[@]}]=$(basename "$file" .json)
    fi
  done
  records='[]'
  if [ "${#valid[@]}" -gt 0 ]; then
    records=$(printf '%s\0' "${valid[@]}" | xargs -0 cat 2>/dev/null \
      | jq -cn '[inputs | select(type == "object")]') || return 1
    [ -n "$records" ] || return 1
    [ "$(printf '%s' "$records" | jq -r 'length')" = "${#valid[@]}" ] || return 1
  fi
  invalid='[]'
  if [ "${#malformed[@]}" -gt 0 ]; then
    invalid=$(jq -cn --arg kind "$kind" '
      [ $ARGS.positional[]
        | {kind:$kind,recordId:.,error:{code:"malformed_record",message:"Record is not a valid JSON object"}} ]
    ' --args "${malformed[@]}") || return 1
  fi
  jq -cn --argjson records "$records" --argjson invalid "$invalid" '{records:$records,invalid:$invalid}'
}

condition_projection() {  # <reports-json> <outcomes-json>
  jq -cn --argjson reports "$1" --argjson outcomes "$2" '
    [ $reports[]
      | select(.condition? and (.condition | type == "object"))
      | select(.status? == "accepted")
      | {
          reportId:.reportId,
          missionId:.missionId,
          conditionId:.condition.conditionId,
          holdId:(.condition.holdId // null),
          packetRevision:(.condition.packetRevision // .sourceRevision),
          lifecycle:(.condition.lifecycle // "raised"),
          affectedObjects:(.condition.affectedObjects // []),
          explanation:(.condition.explanation // ""),
          recommendation:(.condition.recommendation // ""),
          choices:(.condition.choices // []),
          consequenceOfDelay:(.condition.consequenceOfDelay // ""),
          evidence:(.condition.evidence // []),
          boundRevisions:(.condition.boundRevisions // {}),
          creationSequence:(.condition.creationSequence // 0),
          projection:(.condition.projection // null),
          cycleRef:(.correlation.shapeUp.cycleRef // ""),
          buildRef:(.correlation.shapeUp.buildRef // ""),
          scopeRef:(.correlation.shapeUp.scopeRef // null),
          capturedAt:(.capturedAt // ""),
          acceptedAt:(.acceptedAt // "")
        }
    ]
    | sort_by(.missionId,.conditionId,.acceptedAt,.capturedAt,.reportId)
    | group_by([.missionId,.conditionId])
    | map(last)
    | map(. as $condition
      | .lifecycle = (
          [ $outcomes[]
            | select(.intent.action == "resolveCondition")
            | select(.intent.missionId == $condition.missionId)
            | select(.intent.conditionId == $condition.conditionId)
            | select(.outcome.status == "resolved")
          ]
          | if length > 0 then "resolved" else $condition.lifecycle end))
    | sort_by(.cycleRef,.buildRef,(.scopeRef // ""),.creationSequence,.missionId,.conditionId)
  '
}

build_reviews() {  # <missions-json> <reports-json> <outcomes-json>
  local missions=$1 reports=$2 outcomes=$3
  jq -cn --argjson missions "$missions" --argjson reports "$reports" --argjson outcomes "$outcomes" '
    def authoritative: sort_by(.acceptedAt // "",.capturedAt // "",.reportId) | last // null;
    def terminal($missionId):
      ([ $reports[]
        | select(.status == "accepted" and .missionId == $missionId)
        | select(.kind == "scope_discovery" or .kind == "scope_revision" or .kind == "hill_judgment" or .kind == "blocker" or .kind == "outcome")
      ] | authoritative) as $latest
      | ($latest != null
        and $latest.kind == "outcome"
        and ($latest.outcome.state == "completed" or $latest.outcome.state == "failed" or $latest.outcome.state == "cancelled"));
    def required_evidence_verified($mission):
      (($mission.evidenceRequirements // []) | all(. as $requirement |
        ([ $reports[]
          | select(.status == "accepted")
          | select(.missionId == $mission.missionId and .kind == "evidence")
          | select(.evidence.contract == $requirement)
        ] | authoritative) as $latest
        | ($latest != null and $latest.evidence.verification.status == "verified")));
    [ $missions[]
      | select((.state // "accepted") == "accepted")
      | select(.correlation.shapeUp.buildRef? != null)
    ]
    | sort_by(.correlation.shapeUp.cycleRef,.correlation.shapeUp.buildRef,.missionId)
    | group_by([.correlation.shapeUp.cycleRef,.correlation.shapeUp.buildRef])
    | map(
        . as $group
        | ($group[0].correlation.shapeUp) as $shape
        | ($group | map(.correlation.shapeUp.buildRevision // "") | unique) as $buildRevisions
        | (($buildRevisions | length) > 1) as $revisionConflict
        | ($group | map(. as $mission | {
            missionId:$mission.missionId,
            missionRevision:($mission.sourceRevision // ""),
            buildRevision:($mission.correlation.shapeUp.buildRevision // ""),
            terminal:terminal($mission.missionId),
            evidenceVerified:required_evidence_verified($mission),
            reportRevisions:([ $reports[]
              | select(.status == "accepted" and .missionId == $mission.missionId)
              | .sourceRevision ] | sort),
            evidenceRevisions:([ $reports[]
              | select(.status == "accepted" and .missionId == $mission.missionId and .kind == "evidence")
              | .sourceRevision ] | sort)
          })) as $missionSet
        | {
            cycleRef:$shape.cycleRef,
            buildRef:$shape.buildRef,
            buildRevision:(if $revisionConflict then null else ($buildRevisions[0] // "") end),
            buildRevisions:$buildRevisions,
            revisionConflict:$revisionConflict,
            missionSet:$missionSet,
            ready:(($revisionConflict | not) and ($missionSet | all(.terminal and .evidenceVerified))),
            packetMaterial:({
              cycleRef:$shape.cycleRef,
              buildRef:$shape.buildRef,
              buildRevisions:$buildRevisions,
              revisionConflict:$revisionConflict,
              missionSet:$missionSet
            } | @json)
          }
      )
  '
}

review_revisions() {  # <reviews-json>
  local reviews=$1 count index material revision result='[]'
  count=$(printf '%s' "$reviews" | jq -r 'if type == "array" then length else "invalid" end') || return 1
  case "$count" in
    ''|*[!0-9]*) return 1 ;;
  esac
  index=0
  while [ "$index" -lt "$count" ]; do
    material=$(printf '%s' "$reviews" | jq -r --argjson index "$index" '.[$index].packetMaterial') || return 1
    revision=$(printf '%s' "$material" | digest) || return 1
    [ -n "$revision" ] || return 1
    result=$(jq -cn --argjson result "$result" --argjson reviews "$reviews" \
      --argjson index "$index" --arg revision "$revision" '
      $result + [$reviews[$index] | del(.packetMaterial) | . + {packetRevision:$revision}]') || return 1
    index=$((index + 1))
  done
  printf '%s' "$result"
}

snapshot_json() {
  local mission_bundle report_bundle outcome_bundle shapeup_bundle missions reports outcomes shapeup_outcomes invalid conditions material source_revision reviews
  mission_bundle=$(collect_records "$MISSIONS" mission) || return 1
  report_bundle=$(collect_records "$REPORTS" report) || return 1
  outcome_bundle=$(collect_records "$OUTCOMES" outcome) || return 1
  shapeup_bundle=$(collect_records "$SHAPEUP_OUTCOMES" shapeup-outcome) || return 1
  missions=$(printf '%s' "$mission_bundle" | jq -c '.records | sort_by(.missionId // "")') || return 1
  reports=$(printf '%s' "$report_bundle" | jq -c '.records | sort_by(.capturedAt // "",.reportId // "")') || return 1
  outcomes=$(printf '%s' "$outcome_bundle" | jq -c '.records | sort_by(.recordedAt // "",.intentId // "")') || return 1
  shapeup_outcomes=$(printf '%s' "$shapeup_bundle" | jq -c '.records | sort_by(.outcome.recordedAt // "",.outcome.reportId // "")') || return 1
  invalid=$(jq -cn \
    --argjson a "$(printf '%s' "$mission_bundle" | jq -c '.invalid')" \
    --argjson b "$(printf '%s' "$report_bundle" | jq -c '.invalid')" \
    --argjson c "$(printf '%s' "$outcome_bundle" | jq -c '.invalid')" \
    --argjson d "$(printf '%s' "$shapeup_bundle" | jq -c '.invalid')" \
    '$a + $b + $c + $d') || return 1
  conditions=$(condition_projection "$reports" "$outcomes") || return 1
  [ -n "$conditions" ] || return 1
  material=$(jq -cS -n --argjson missions "$missions" --argjson reports "$reports" \
    --argjson outcomes "$outcomes" --argjson shapeUpOutcomes "$shapeup_outcomes" --argjson invalid "$invalid" \
    '{missions:$missions,reports:$reports,outcomes:$outcomes,shapeUpOutcomes:$shapeUpOutcomes,invalidRecords:$invalid}') || return 1
  source_revision=$(printf '%s' "$material" | digest) || return 1
  [ -n "$source_revision" ] || return 1
  reviews=$(build_reviews "$missions" "$reports" "$outcomes") || return 1
  [ -n "$reviews" ] || return 1
  reviews=$(review_revisions "$reviews") || return 1
  reviews=$(jq -cn --argjson reviews "$reviews" --argjson outcomes "$outcomes" '
    $reviews
    | map(. as $review
      | .acceptance = (
          [ $outcomes[]
            | select(.intent.action == "acceptBuildReview")
            | select(.intent.cycleRef == $review.cycleRef)
            | select(.intent.buildRef == $review.buildRef)
            | select(.intent.packetRevision == $review.packetRevision)
            | .outcome
          ] | last // null))
  ') || return 1
  jq -cn --arg capturedAt "$NOW" --arg sourceRevision "$source_revision" \
    --argjson missions "$missions" --argjson reports "$reports" \
    --argjson conditions "$conditions" --argjson outcomes "$outcomes" \
    --argjson shapeUpOutcomes "$shapeup_outcomes" \
    --argjson buildReviews "$reviews" --argjson invalidRecords "$invalid" '
    {
      schemaVersion:"fm-captains-log-snapshot.v1",
      sourceRevision:$sourceRevision,
      capturedAt:$capturedAt,
      freshness:"fresh",
      missions:$missions,
      reports:$reports,
      evidence:[$reports[]
        | select(.status == "accepted" and .kind == "evidence")
        | {reportId,sourceRevision,capturedAt,missionId,taskId,crewmateId,correlation,evidence}],
      conditions:$conditions,
      buildReviews:$buildReviews,
      outcomes:$outcomes,
      shapeUpOutcomes:$shapeUpOutcomes,
      invalidRecords:$invalidRecords
    }
  '
}

capabilities_response() {
  jq -n --arg schemaVersion "$SCHEMA" --arg capturedAt "$NOW" '
    {
      accepted:true,
      schemaVersion:$schemaVersion,
      sourceRevision:"capabilities-v1",
      capturedAt:$capturedAt,
      operations:["capabilities","snapshot","intent","inspectSession"],
      capabilities:{
        core:"available",
        shapeUp:{status:"negotiated",required:false},
        sessionInspection:{status:"negotiated",required:false,mode:"bounded-read-only",preferredBackend:"herdr"}
      },
      acceptedIntents:["acknowledgeCondition","acceptBuildReview","resolveCondition"]
    }
  '
}

replay_prior_outcome() {  # <record-path> <request-digest>
  local record=$1 digest_value=$2 prior prior_digest
  [ -f "$record" ] || return 1
  prior=$(jq -c . "$record" 2>/dev/null) || {
    fail_json malformed_record "The prior intent outcome is unreadable"
    return 2
  }
  prior_digest=$(printf '%s' "$prior" | jq -r '.requestDigest // empty')
  [ "$prior_digest" = "$digest_value" ] || {
    fail_json identity_conflict "intentId was already used with different content"
    return 2
  }
  printf '%s' "$prior" | jq -c --arg schemaVersion "$SCHEMA" '
    {accepted:true,schemaVersion:$schemaVersion,outcome:(.outcome + {replayed:true})}'
  return 0
}

intent_response() {  # <intent-json>
  local intent=$1 intent_id action digest_value record outcome tmp snapshot review build_ref packet_revision
  local cycle_ref condition_id condition mission_id report_id decision decision_file route resolution_status lock_dir lock_started
  local -a route_args=()
  intent_id=$(printf '%s' "$intent" | jq -r '.intentId // empty')
  action=$(printf '%s' "$intent" | jq -r '.action // empty')
  valid_identity "$intent_id" || {
    fail_json malformed_intent "intentId must be a privacy-safe identity"
    return 2
  }
  case "$action" in
    acknowledgeCondition|acceptBuildReview|resolveCondition) ;;
    *) fail_json unsupported_intent "The requested intent is not advertised"; return 2 ;;
  esac
  fm_eng_contains_credentials "$intent" && {
    fail_json credential_material "Credentials must never enter Captain intents"
    return 2
  }
  mkdir -p "$OUTCOMES" "$STATE/fm-projection-intent-locks"
  record="$OUTCOMES/$intent_id.json"
  digest_value=$(printf '%s' "$intent" | jq -cS . | digest)
  replay_prior_outcome "$record" "$digest_value"
  case $? in
    0) return 0 ;;
    2) return 2 ;;
  esac
  lock_dir="$STATE/fm-projection-intent-locks/$intent_id"
  if ! mkdir "$lock_dir" 2>/dev/null; then
    reclaim_stale_intent_lock "$lock_dir"
    if ! mkdir "$lock_dir" 2>/dev/null; then
      fail_json intent_busy "The intent is already being processed"
      return 2
    fi
  fi
  INTENT_LOCK_DIR="$lock_dir"
  lock_started=$(process_start_signature "$$") || lock_started=unknown
  printf 'host=%s\npid=%s\nstarted=%s\nacquiredAt=%s\n' \
    "$INTENT_LOCK_HOST" "$$" "$lock_started" "$NOW" > "$lock_dir/owner" 2>/dev/null || true
  trap release_intent_lock RETURN
  replay_prior_outcome "$record" "$digest_value"
  case $? in
    0) return 0 ;;
    2) return 2 ;;
  esac
  if [ "$action" = acceptBuildReview ]; then
    cycle_ref=$(printf '%s' "$intent" | jq -r '.cycleRef // empty')
    build_ref=$(printf '%s' "$intent" | jq -r '.buildRef // empty')
    packet_revision=$(printf '%s' "$intent" | jq -r '.packetRevision // empty')
    [ -n "$cycle_ref" ] && [ -n "$build_ref" ] && [ -n "$packet_revision" ] || {
      fail_json malformed_intent "Build Review acceptance requires cycleRef, buildRef, and packetRevision"
      return 2
    }
    snapshot=$(snapshot_json) || {
      fail_json projection_unavailable "The projection record store could not be read"
      return 2
    }
    review=$(printf '%s' "$snapshot" | jq -c --arg cycleRef "$cycle_ref" --arg buildRef "$build_ref" \
      '[.buildReviews[] | select(.cycleRef == $cycleRef and .buildRef == $buildRef)] | first // empty')
    [ -n "$review" ] || { fail_json review_not_found "Build Review packet is unavailable"; return 2; }
    [ "$(printf '%s' "$review" | jq -r '.packetRevision')" = "$packet_revision" ] || {
      fail_json stale_packet "Build Review packet changed before Captain acceptance"
      return 2
    }
    [ "$(printf '%s' "$review" | jq -r '.revisionConflict')" = false ] || {
      fail_json review_revision_conflict "Active missions in this Build are bound to conflicting Build revisions"
      return 2
    }
    [ "$(printf '%s' "$review" | jq -r '.ready')" = true ] || {
      fail_json review_not_ready "Every active mission and required evidence revision must be ready"
      return 2
    }
  fi
  if [ "$action" = acknowledgeCondition ] || [ "$action" = resolveCondition ]; then
    mission_id=$(printf '%s' "$intent" | jq -r '.missionId // empty')
    condition_id=$(printf '%s' "$intent" | jq -r '.conditionId // empty')
    packet_revision=$(printf '%s' "$intent" | jq -r '.packetRevision // empty')
    valid_identity "$mission_id" && valid_identity "$condition_id" && [ -n "$packet_revision" ] || {
      fail_json malformed_intent "Condition intent requires missionId, conditionId, and packetRevision"
      return 2
    }
    snapshot=$(snapshot_json) || {
      fail_json projection_unavailable "The projection record store could not be read"
      return 2
    }
    condition=$(printf '%s' "$snapshot" | jq -c --arg missionId "$mission_id" --arg conditionId "$condition_id" \
      '.conditions[] | select(.missionId == $missionId and .conditionId == $conditionId)')
    [ -n "$condition" ] || { fail_json condition_not_found "Captain Call condition is unavailable"; return 2; }
    [ "$(printf '%s' "$condition" | jq -r '.packetRevision')" = "$packet_revision" ] || {
      fail_json stale_packet "Captain Call packet changed before the intent was applied"
      return 2
    }
  fi
  resolution_status=accepted
  if [ "$action" = resolveCondition ]; then
    decision=$(printf '%s' "$intent" | jq -r '.decision // empty')
    printf '%s' "$intent" | jq -e '
      (.decision | type == "string" and length > 0 and length <= 8192)
      and (.routedTo | type == "array" and length > 0)
      and all(.routedTo[]; type == "string")
    ' >/dev/null 2>&1 || {
      fail_json malformed_intent "Resolution requires a bounded decision and routedTo identities"
      return 2
    }
    while IFS= read -r route; do
      valid_identity "$route" || {
        fail_json malformed_identity "routedTo identities must be privacy-safe"
        return 2
      }
      route_args+=(--routed-to "$route")
    done < <(printf '%s' "$intent" | jq -r '.routedTo[]' | LC_ALL=C sort -u)
    report_id=$(printf '%s' "$condition" | jq -r '.reportId')
    "$SCRIPT_DIR/fm-decision-hold.sh" project "$mission_id" "$condition_id" \
      --packet-file "$REPORTS/$report_id.json" --lifecycle resolving >/dev/null || {
      fail_json decision_resolution_failed "Captain Call could not enter resolving state"
      return 2
    }
    mkdir -p "$ENGINEERING/decisions"
    decision_file="$ENGINEERING/decisions/$intent_id.txt"
    tmp="$decision_file.$$"
    printf '%s\n' "$decision" > "$tmp" && mv "$tmp" "$decision_file"
    "$SCRIPT_DIR/fm-decision-hold.sh" resolve "$mission_id" "$condition_id" \
      --decision-file "$decision_file" "${route_args[@]}" >/dev/null || {
      fail_json decision_resolution_failed "Captain decision could not be routed durably"
      return 2
    }
    resolution_status=resolved
  fi
  outcome=$(jq -cn --arg intentId "$intent_id" --arg action "$action" --arg recordedAt "$NOW" \
    --arg resolutionStatus "$resolution_status" '
    {
      intentId:$intentId,
      action:$action,
      status:(
        if $action == "acknowledgeCondition" then "acknowledged"
        elif $action == "acceptBuildReview" then "captainAccepted"
        else $resolutionStatus end),
      recordedAt:$recordedAt,
      replayed:false,
      implications:{delivery:false,buildCloseout:false,cycleClose:false}
    }
  ')
  tmp="$record.$$"
  jq -cn --arg requestDigest "$digest_value" --argjson intent "$intent" --argjson outcome "$outcome" \
    '{requestDigest:$requestDigest,intent:$intent,outcome:$outcome}' > "$tmp" && mv "$tmp" "$record"
  jq -cn --arg schemaVersion "$SCHEMA" --argjson outcome "$outcome" \
    '{accepted:true,schemaVersion:$schemaVersion,outcome:$outcome}'
}

inspect_session_response() {  # <request-json>
  local value=$1 mission_id task_id expected lines mission session inspection status
  mission_id=$(printf '%s' "$value" | jq -r '.missionId // empty')
  task_id=$(printf '%s' "$value" | jq -r '.taskId // empty')
  expected=$(printf '%s' "$value" | jq -r '.expectedMissionRevision // empty')
  lines=$(printf '%s' "$value" | jq -r 'if (.lines // null) == null then "40" else (.lines | tostring) end')
  case "$lines" in
    ''|*[!0-9]*) fail_json malformed_request "lines must be a positive integer of at most 200"; return 2 ;;
  esac
  [ "${#lines}" -le 18 ] || {
    fail_json malformed_request "lines must be a positive integer of at most 200"
    return 2
  }
  lines=$((10#$lines))
  [ "$lines" -ge 1 ] && [ "$lines" -le 200 ] || {
    fail_json malformed_request "lines must be a positive integer of at most 200"
    return 2
  }
  if ! valid_identity "$mission_id" || ! valid_identity "$task_id"; then
    fail_json malformed_identity "missionId and taskId must be privacy-safe identities"
    return 2
  fi
  [ -f "$MISSIONS/$mission_id.json" ] || {
    fail_json mission_not_found "Mission is not present in the projection"
    return 2
  }
  mission=$(jq -c . "$MISSIONS/$mission_id.json" 2>/dev/null) || {
    fail_json malformed_record "Mission record is unreadable"
    return 2
  }
  [ "$(printf '%s' "$mission" | jq -r '.taskId')" = "$task_id" ] || {
    fail_json identity_drift "Task identity does not match the mission"
    return 2
  }
  [ "$(printf '%s' "$mission" | jq -r '.sourceRevision')" = "$expected" ] || {
    fail_json stale_revision "Mission revision changed before session inspection"
    return 2
  }
  session=$(printf '%s' "$mission" | jq -c '.correlation.firstMate.session // null')
  [ "$session" != null ] || {
    fail_json capability_unavailable "Mission has no negotiated session descriptor"
    return 2
  }
  inspection=$(FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA" FM_STATE_OVERRIDE="$STATE" \
    "$SCRIPT_DIR/fm-peek.sh" --json "$task_id" "$lines" 2>/dev/null)
  status=$?
  printf '%s' "$inspection" | jq -e 'type == "object"' >/dev/null 2>&1 || {
    fail_json inspection_unavailable "Session inspection produced no structured result"
    return 2
  }
  if [ "$status" -ne 0 ]; then
    printf '%s' "$inspection" | jq -c --arg schemaVersion "$SCHEMA" '
      {
        accepted:false,
        schemaVersion:$schemaVersion,
        error:(.error // {code:"inspection_unavailable",message:"Session inspection failed without a typed error"})
      }'
    return 2
  fi
  printf '%s' "$inspection" | jq -e --argjson session "$session" '
    .descriptor.backend == $session.backend and .descriptor.targetId == $session.targetId
  ' >/dev/null 2>&1 || {
    fail_json session_identity_drift "Live session descriptor differs from the mission correlation"
    return 2
  }
  printf '%s' "$inspection" | jq -c --arg schemaVersion "$SCHEMA" '
    {accepted:true,schemaVersion:$schemaVersion,inspection:.}'
}

request=$(head -c 262145)
[ "${#request}" -le 262144 ] || {
  fail_json request_too_large "Projection requests are limited to 256 KiB"
  exit 2
}
printf '%s' "$request" | jq -e 'type == "object"' >/dev/null 2>&1 || {
  fail_json malformed_request "Request must be a JSON object"
  exit 2
}
version=$(printf '%s' "$request" | jq -r '.schemaVersion // empty')
[ "$version" = "$SCHEMA" ] || {
  fail_json unsupported_schema "Only fm-captains-log-projection.v1 is supported"
  exit 2
}
operation=$(printf '%s' "$request" | jq -r '.operation // empty')
case "$operation" in
  capabilities)
    capabilities_response
    ;;
  snapshot)
    snapshot=$(snapshot_json) || {
      fail_json projection_unavailable "The projection record store could not be read"
      exit 2
    }
    jq -cn --arg schemaVersion "$SCHEMA" --argjson snapshot "$snapshot" \
      '{accepted:true,schemaVersion:$schemaVersion,snapshot:$snapshot}'
    ;;
  intent)
    intent=$(printf '%s' "$request" | jq -c '.intent // empty')
    [ -n "$intent" ] || { fail_json malformed_intent "intent is required"; exit 2; }
    intent_response "$intent"
    ;;
  inspectSession)
    inspect_session_response "$request"
    ;;
  *)
    fail_json unsupported_operation "The requested operation is not advertised"
    exit 2
    ;;
esac
