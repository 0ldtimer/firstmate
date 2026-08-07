#!/usr/bin/env bash
# Durable Cycle execution-group boundary used by the maintained FirstMate fork.
# The library deliberately owns execution state only; Shape Up lifecycle state
# remains in Captain's Log/Shape Up.
set -u

FM_CYCLE_ROOT="${FM_CYCLE_ROOT:-${FM_DATA_OVERRIDE:-${FM_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/data}/engineering/execution}"
FM_CYCLE_GROUPS="$FM_CYCLE_ROOT/groups"
FM_CYCLE_CHILDREN="$FM_CYCLE_ROOT/children"
FM_CYCLE_INTENTS="$FM_CYCLE_ROOT/intents"
FM_CYCLE_ACKS="$FM_CYCLE_ROOT/acks"
FM_CYCLE_OUTBOX="$FM_CYCLE_ROOT/outbox"
FM_CYCLE_LIAISON="$FM_CYCLE_ROOT/liaison"

fm_cycle_init() { mkdir -p "$FM_CYCLE_GROUPS" "$FM_CYCLE_CHILDREN" "$FM_CYCLE_INTENTS" "$FM_CYCLE_ACKS" "$FM_CYCLE_OUTBOX" "$FM_CYCLE_LIAISON"; }
fm_cycle_digest() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 | awk '{print $1}'; else sha256sum | awk '{print $1}'; fi; }
fm_cycle_identity() { case "${1:-}" in ''|.*|*[!A-Za-z0-9._:-]*) return 1;; esac; [ "${#1}" -le 160 ]; }
fm_cycle_json() { jq -ce 'type == "object"' 2>/dev/null; }
fm_cycle_fail() { jq -cn --arg code "$1" --arg message "$2" '{accepted:false,protocolVersion:"fm-bridge.v2",schemaVersion:"cycle-execution.v1",error:{code:$code,message:$message}}'; }

# Every durable path in this store is derived through one of these builders, so a
# producer-supplied identifier can never name a file outside its own store.
fm_cycle_group_path() { fm_cycle_identity "${1:-}" || return 1; printf '%s\n' "$FM_CYCLE_GROUPS/$1.json"; }
fm_cycle_child_path() { fm_cycle_identity "${1:-}" || return 1; printf '%s\n' "$FM_CYCLE_CHILDREN/$1.json"; }
fm_cycle_intent_path() { fm_cycle_identity "${1:-}" || return 1; printf '%s\n' "$FM_CYCLE_INTENTS/$1.json"; }

fm_cycle_write() {
  local path value tmp
  path=$1; value=$2; tmp="${path}.$$"
  mkdir -p "$(dirname "$path")" || return 1
  printf '%s\n' "$value" > "$tmp" && mv "$tmp" "$path"
}

# Read-modify-write of one durable record. A failed or empty transform leaves the
# stored record untouched and refuses, so no caller can report an applied effect
# the store does not hold.
fm_cycle_update() {  # <path> [jq options...] <filter>
  local path=$1 updated
  shift
  updated=$(jq -c "$@" "$path") || return 1
  case "$updated" in '') return 1 ;; esac
  printf '%s' "$updated" | fm_cycle_json >/dev/null || return 1
  fm_cycle_write "$path" "$updated"
}

# Single owner of lease expiry for the whole execution boundary. The lease is a
# UTC instant, so it is compared as one: a host's local zone never moves it, and
# a lease this boundary cannot read is spent rather than unbounded.
fm_cycle_lease_expired() {  # <iso8601>
  local lease=${1:-} epoch
  [ -n "$lease" ] || return 1
  epoch=$(jq -rn --arg lease "$lease" 'try ($lease | fromdateiso8601) catch "invalid"' 2>/dev/null) || epoch=invalid
  case "$epoch" in ''|*[!0-9]*) return 0 ;; esac
  [ "$epoch" -le "$(date -u +%s)" ]
}

# One unreadable record is isolated exactly as bin/fm-captains-log-projection.sh
# isolates it: it lands in snapshot.invalidRecords and never blanks the rest of
# the projection.
fm_cycle_collect() {  # <kind> <dir> <records-file> <invalid-file>
  local kind=$1 dir=$2 records=$3 invalid=$4 file record
  for file in "$dir"/*.json; do
    [ -f "$file" ] || continue
    if record=$(jq -c 'select(type == "object")' "$file" 2>/dev/null) && [ -n "$record" ]; then
      printf '%s\n' "$record" >> "$records" || return 1
    else
      jq -cn --arg kind "$kind" --arg recordId "$(basename "$file")" \
        '{kind:$kind,recordId:$recordId,error:{code:"schema_invalid_record",message:"Record does not match the projection record shape"}}' >> "$invalid" || return 1
    fi
  done
}

# Captain's Log consumes the negotiated projection envelope: capabilities and
# snapshot are separate validated responses inside one bridge result.
fm_cycle_projection() {
  local captured_at source_revision work status
  fm_cycle_init || return 1
  work=$(mktemp -d "${TMPDIR:-/tmp}/fm-cycle-projection.XXXXXX") || return 1
  if ! { : > "$work/groups"; } || ! { : > "$work/children"; } || ! { : > "$work/intents"; } || ! { : > "$work/invalid"; }; then
    rm -rf "$work"
    return 1
  fi
  if ! fm_cycle_collect executionGroup "$FM_CYCLE_GROUPS" "$work/groups" "$work/invalid" ||
    ! fm_cycle_collect executionChild "$FM_CYCLE_CHILDREN" "$work/children" "$work/invalid" ||
    ! fm_cycle_collect progressIntent "$FM_CYCLE_INTENTS" "$work/intents" "$work/invalid"; then
    rm -rf "$work"
    return 1
  fi
  captured_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  source_revision=$(cat "$work/groups" "$work/children" "$work/intents" "$work/invalid" | fm_cycle_digest)
  jq -cn --arg capturedAt "$captured_at" --arg sourceRevision "fm-execution:$source_revision" \
    --slurpfile groups "$work/groups" \
    --slurpfile children "$work/children" \
    --slurpfile intents "$work/intents" \
    --slurpfile invalidRecords "$work/invalid" \
    '{accepted:true,protocolVersion:"fm-bridge.v2",operation:"captainsLogProjection",capabilities:{accepted:true,schemaVersion:"fm-captains-log-projection.v1",operation:"capabilities",capabilities:{core:"available",shapeUp:{status:"negotiated",required:false},sessionInspection:{status:"negotiated",required:false,mode:"bounded-read-only",preferredBackend:"herdr"}},acceptedIntents:["acknowledgeCondition","acceptBuildReview","resolveCondition"]},snapshot:{accepted:true,schemaVersion:"fm-captains-log-projection.v1",operation:"snapshot",snapshot:{schemaVersion:"fm-captains-log-snapshot.v1",sourceRevision:$sourceRevision,capturedAt:$capturedAt,freshness:"fresh",reports:[],evidence:[],conditions:[],buildReviews:[],invalidRecords:$invalidRecords,missions:[],executionGroups:$groups,children:$children,progressIntents:$intents,pendingIntents:[$intents[]|select(.state=="pending")]}}}'
  status=$?
  rm -rf "$work"
  return "$status"
}
fm_cycle_canonical_digest() { jq -cS . | fm_cycle_digest; }

fm_cycle_accept_group() {
  local input=$1 group id attempt digest path prior
  fm_cycle_init || { fm_cycle_fail durable_store "execution store unavailable"; return 2; }
  printf '%s' "$input" | fm_cycle_json >/dev/null || { fm_cycle_fail malformed_request "execution group must be a JSON object"; return 2; }
  group=$(printf '%s' "$input" | jq -r '.executionId // empty'); attempt=$(printf '%s' "$input" | jq -r '.attemptId // empty')
  if ! fm_cycle_identity "$group" || ! fm_cycle_identity "$attempt"; then fm_cycle_fail malformed_identity "executionId and attemptId are invalid"; return 2; fi
  printf '%s' "$input" | jq -e '.schemaVersion == "cycle-execution.v1" and (.manifestDigest|type=="string" and length>0) and (.binding.workspaceId|type=="string" and length>0) and (.binding.cycleId|type=="string" and length>0) and ((.children // [])|type=="array" and all(.[]; type=="object"))' >/dev/null 2>&1 || { fm_cycle_fail malformed_group "manifest, binding, or children is invalid"; return 2; }
  digest=$(printf '%s' "$input" | fm_cycle_canonical_digest) || { fm_cycle_fail malformed_request "cannot digest execution group"; return 2; }
  path=$(fm_cycle_group_path "$group") || { fm_cycle_fail malformed_identity "executionId is invalid"; return 2; }
  if [ -f "$path" ]; then
    prior=$(jq -c . "$path" 2>/dev/null) || { fm_cycle_fail malformed_record "stored group is unreadable"; return 2; }
    if [ "$(printf '%s' "$prior" | jq -r '.manifestDigest // empty')" != "$(printf '%s' "$input" | jq -r '.manifestDigest')" ]; then fm_cycle_fail identity_conflict "execution identity is bound to another manifest"; return 2; fi
    jq -cn --argjson group "$prior" --arg digest "$digest" '{accepted:true,protocolVersion:"fm-bridge.v2",operation:"acceptExecutionGroup",replayed:true,executionGroup:$group,receipt:{executionId:$group.executionId,manifestDigest:$group.manifestDigest,digest:$digest,authorizationReceipt:("receipt:" + $group.executionId)}}'; return 0
  fi
  local stored
  # Acceptance never hands out more fan-out lease than the bound cycle owns, so a
  # cycle that ends before the 24-hour bound is never delegated past its end.
  stored=$(printf '%s' "$input" | jq -c --arg digest "$digest" '
    ((now + 86400)|todateiso8601) as $bound
    | (.binding.cycleEndsAt // "") as $end
    | . + {state:"accepted",groupDigest:$digest,acceptedAt:(now|todateiso8601),
           leaseExpiresAt:(if ($end|type) == "string" and $end != "" and $end < $bound then $end else $bound end),
           children:((.children // []) | map(. + {state:"queued"}))}') || { fm_cycle_fail malformed_group "cannot normalize execution group"; return 2; }
  fm_cycle_write "$path" "$stored" || { fm_cycle_fail durable_store "execution group could not be stored"; return 2; }
  jq -cn --argjson group "$stored" '{accepted:true,protocolVersion:"fm-bridge.v2",operation:"acceptExecutionGroup",replayed:false,executionGroup:$group,receipt:{executionId:$group.executionId,manifestDigest:$group.manifestDigest,authorizationReceipt:("receipt:" + $group.executionId)}}'
}

fm_cycle_status() {
  local path
  path=$(fm_cycle_group_path "${1:-}") || { fm_cycle_fail malformed_identity "executionId is invalid"; return 2; }
  [ -f "$path" ] || { fm_cycle_fail not_found "execution group not found"; return 2; }
  jq -ce '{accepted:true,protocolVersion:"fm-bridge.v2",operation:"executionGroupStatus",executionGroup:.}' "$path" 2>/dev/null || { fm_cycle_fail malformed_record "execution group unreadable"; return 2; }
}

fm_cycle_delegate() {
  local id=${1:-} path group child child_id child_path
  path=$(fm_cycle_group_path "$id") || { fm_cycle_fail malformed_identity "executionId is invalid"; return 2; }
  [ -f "$path" ] || { fm_cycle_fail not_found "execution group not found"; return 2; }
  group=$(jq -c . "$path") || { fm_cycle_fail malformed_record "execution group unreadable"; return 2; }
  if fm_cycle_lease_expired "$(printf '%s' "$group" | jq -r '.leaseExpiresAt // empty')"; then
    fm_cycle_fail lease_expired "delegation lease has expired"; return 2
  fi
  while IFS= read -r child; do
    child_id=$(printf '%s' "$child" | jq -r '.childId // .workItemId // empty')
    child_path=$(fm_cycle_child_path "$child_id") || continue
    [ -f "$child_path" ] || fm_cycle_write "$child_path" "$(printf '%s' "$child" | jq -c --arg executionId "$id" '. + {executionId:$executionId,state:"queued",delegatedAt:(now|todateiso8601)}')" || { fm_cycle_fail durable_store "child could not be stored"; return 2; }
  done < <(printf '%s' "$group" | jq -c '.children[]? | select(type == "object")')
  # shellcheck disable=SC2016 # jq owns every $ in this filter; the shell must not expand it.
  fm_cycle_update "$path" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.state="delegated" | .delegatedAt=$at' || { fm_cycle_fail durable_store "delegation state could not be stored"; return 2; }
  # Scotty remains the only fan-out owner. A durable wake tells the existing
  # FirstMate primary liaison to drain this group; Captain's Log never spawns
  # or steers a crewmate directly.
  if [ -f "$(dirname "${BASH_SOURCE[0]}")/fm-wake-lib.sh" ]; then
    # shellcheck source=bin/fm-wake-lib.sh
    . "$(dirname "${BASH_SOURCE[0]}")/fm-wake-lib.sh"
    fm_wake_append signal "execution:$id" "Scotty delegation queued for execution group $id" >/dev/null 2>&1 || true
  fi
  jq -cn --arg id "$id" '{accepted:true,protocolVersion:"fm-bridge.v2",operation:"delegateExecutionGroup",executionId:$id,state:"delegated"}'
}

# Renew the FirstMate-owned fan-out lease from a current producer cursor.  The
# cursor is deliberately opaque to FirstMate: Captain's Log obtains it from
# Shape Up and this boundary only records that a fresh, non-empty cursor was
# presented.  Renewal is bounded to 24 hours and never revives a cycle marked
# ended/quiesced/cancelled.
fm_cycle_renew() {
  local input=$1 id path group cursor now expires cycle_end
  id=$(printf '%s' "$input" | jq -r '.executionId // empty')
  cursor=$(printf '%s' "$input" | jq -r '.executionChangeCursor // .shapeUp.executionChangeCursor // empty')
  path=$(fm_cycle_group_path "$id") || { fm_cycle_fail malformed_identity "executionId is invalid"; return 2; }
  [ -n "$cursor" ] || { fm_cycle_fail malformed_renewal "current execution-change cursor is required"; return 2; }
  [ -f "$path" ] || { fm_cycle_fail not_found "execution group not found"; return 2; }
  group=$(jq -c . "$path") || { fm_cycle_fail malformed_record "execution group unreadable"; return 2; }
  jq -e '.state | IN("quiesced","cancelled","ended") | not' "$path" >/dev/null 2>&1 || { fm_cycle_fail lease_quiesced "execution group is not accepting new delegation"; return 2; }
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  expires=$(date -u -v+24H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '+24 hours' +%Y-%m-%dT%H:%M:%SZ)
  cycle_end=$(printf '%s' "$group" | jq -r '.binding.cycleEndsAt // empty')
  if [ -n "$cycle_end" ] && [[ "$cycle_end" < "$expires" ]]; then expires=$cycle_end; fi
  # shellcheck disable=SC2016 # jq owns every $ in this filter; the shell must not expand it.
  fm_cycle_update "$path" --arg now "$now" --arg expires "$expires" --arg cursor "$cursor" \
    '.leaseExpiresAt=$expires | .leaseRenewedAt=$now | .executionChangeCursor=$cursor | .leaseState="active" | (if .state == "lease_expired" then .state="delegated" else . end)' \
    || { fm_cycle_fail durable_store "renewed lease could not be stored"; return 2; }
  jq -cn --arg id "$id" --arg expires "$expires" --arg cursor "$cursor" \
    '{accepted:true,protocolVersion:"fm-bridge.v2",operation:"renewExecutionLease",executionId:$id,leaseExpiresAt:$expires,executionChangeCursor:$cursor}'
}

# Ordered amendment is intentionally small here: Captain's Log remains the
# producer of the amendment digest and parent receipt.  FirstMate records the
# immutable amendment and queues newly eligible children; removals become
# paused records and are never torn down automatically.
#
# Order is enforced rather than assumed.  A sequence that does not advance past
# the recorded one is refused, and each accepted amendment chains the group
# digest as digest({parentGroupDigest, amendmentDigest, amendmentSequence}), so
# the next amendment must present the digest this one produced.  Replay is
# answered before either check, so a redelivered amendment stays idempotent.
fm_cycle_amend() {
  local input=$1 id path group parent sequence prior_sequence chained amendment amendment_path child child_id child_path
  id=$(printf '%s' "$input" | jq -r '.executionId // empty')
  parent=$(printf '%s' "$input" | jq -r '.parentGroupDigest // .parentDigest // empty')
  sequence=$(printf '%s' "$input" | jq -r '.amendmentSequence // empty')
  path=$(fm_cycle_group_path "$id") || { fm_cycle_fail malformed_identity "executionId is invalid"; return 2; }
  case "$sequence" in ''|*[!0-9]*) fm_cycle_fail malformed_amendment "amendmentSequence is required"; return 2;; esac
  [ -n "$parent" ] || { fm_cycle_fail malformed_amendment "parent group digest is required"; return 2; }
  printf '%s' "$input" | jq -e '((.addedChildren // [])|type=="array" and all(.[]; type=="object")) and ((.removedChildren // [])|type=="array" and all(.[]; type=="object"))' >/dev/null 2>&1 || { fm_cycle_fail malformed_amendment "amended children must be objects"; return 2; }
  fm_cycle_init || { fm_cycle_fail durable_store "execution store unavailable"; return 2; }
  [ -f "$path" ] || { fm_cycle_fail not_found "execution group not found"; return 2; }
  group=$(jq -c . "$path") || { fm_cycle_fail malformed_record "execution group unreadable"; return 2; }
  amendment_path="$FM_CYCLE_LIAISON/amendments/$id.$sequence.json"
  if [ -f "$amendment_path" ]; then
    amendment=$(jq -c . "$amendment_path") || { fm_cycle_fail malformed_record "stored amendment is unreadable"; return 2; }
    jq -cn --argjson amendment "$amendment" --arg digest "$(printf '%s' "$group" | jq -r '.groupDigest // empty')" \
      '{accepted:true,replayed:true,amendment:$amendment,groupDigest:$digest}'
    return 0
  fi
  prior_sequence=$(printf '%s' "$group" | jq -r '.amendmentSequence // 0')
  case "$prior_sequence" in ''|*[!0-9]*) prior_sequence=0 ;; esac
  [ "$sequence" -gt "$prior_sequence" ] || { fm_cycle_fail amendment_out_of_order "amendmentSequence must advance beyond the recorded amendment"; return 2; }
  [ "$(printf '%s' "$group" | jq -r '.groupDigest // empty')" = "$parent" ] || { fm_cycle_fail parent_digest_mismatch "amendment parent does not match execution group"; return 2; }
  if fm_cycle_lease_expired "$(printf '%s' "$group" | jq -r '.leaseExpiresAt // empty')"; then
    fm_cycle_fail lease_expired "delegation lease has expired"; return 2
  fi
  amendment=$(printf '%s' "$input" | jq -c --arg digest "$(printf '%s' "$input" | fm_cycle_canonical_digest)" '. + {state:"accepted",amendmentDigest:$digest,acceptedAt:(now|todateiso8601)}') || { fm_cycle_fail malformed_amendment "amendment is invalid"; return 2; }
  chained=$(jq -cn --arg parent "$parent" --arg amendment "$(printf '%s' "$amendment" | jq -r '.amendmentDigest')" --argjson sequence "$sequence" \
    '{parentGroupDigest:$parent,amendmentDigest:$amendment,amendmentSequence:$sequence}' | fm_cycle_canonical_digest) || { fm_cycle_fail malformed_amendment "amendment digest could not be chained"; return 2; }
  fm_cycle_write "$amendment_path" "$amendment" || { fm_cycle_fail durable_store "amendment could not be stored"; return 2; }
  while IFS= read -r child; do
    child_id=$(printf '%s' "$child" | jq -r '.childId // .workItemId // empty')
    child_path=$(fm_cycle_child_path "$child_id") || continue
    if [ -f "$child_path" ]; then fm_cycle_update "$child_path" '.state="paused" | .pauseReason="removed_by_amendment"' || { fm_cycle_fail durable_store "removed child could not be paused"; return 2; }; fi
  done < <(printf '%s' "$input" | jq -c '.removedChildren[]?')
  while IFS= read -r child; do
    child_id=$(printf '%s' "$child" | jq -r '.childId // .workItemId // empty')
    child_path=$(fm_cycle_child_path "$child_id") || continue
    [ -f "$child_path" ] || fm_cycle_write "$child_path" "$(printf '%s' "$child" | jq -c --arg executionId "$id" --arg seq "$sequence" '. + {executionId:$executionId,amendmentSequence:($seq|tonumber),state:"queued"}')" || { fm_cycle_fail durable_store "amended child could not be stored"; return 2; }
  done < <(printf '%s' "$input" | jq -c '.addedChildren[]?')
  local added_children
  added_children=$(printf '%s' "$input" | jq -c '.addedChildren // []')
  # shellcheck disable=SC2016 # jq owns every $ in this filter; the shell must not expand it.
  fm_cycle_update "$path" --argjson amendment "$amendment" --argjson added "$added_children" --argjson seq "$sequence" --arg digest "$chained" \
    '.amendmentSequence=$seq | .previousGroupDigest=(.groupDigest // null) | .groupDigest=$digest | .amendments=((.amendments // []) + [$amendment]) | .children=((.children // []) + $added)' \
    || { fm_cycle_fail durable_store "amendment index could not be stored"; return 2; }
  if [ -f "$(dirname "${BASH_SOURCE[0]}")/fm-wake-lib.sh" ]; then
    # shellcheck source=bin/fm-wake-lib.sh
    # shellcheck disable=SC1091
    . "$(dirname "${BASH_SOURCE[0]}")/fm-wake-lib.sh"
    fm_wake_append signal "execution:$id" "Scotty amendment queued for execution group $id" >/dev/null 2>&1 || true
  fi
  jq -cn --argjson amendment "$amendment" --arg digest "$chained" '{accepted:true,replayed:false,amendment:$amendment,groupDigest:$digest}'
}

fm_cycle_emit_intent() {
  local input=$1 id path existing digest
  fm_cycle_init || { fm_cycle_fail durable_store "execution store unavailable"; return 2; }
  id=$(printf '%s' "$input" | jq -r '.intentId // empty'); fm_cycle_identity "$id" || { fm_cycle_fail malformed_identity "intentId is invalid"; return 2; }
  printf '%s' "$input" | jq -e '.schemaVersion == "fm-progress-intent.v1" and ((.executionId | type) == "string") and ((.childId | type) == "string") and (.kind|IN("task","hill","evidence")) and (((.evidence.reference | type) == "string") and (.evidence.reference|length>0)) and (if .kind == "hill" then (((.target.position | type) == "number") and .target.position >= 0 and .target.position <= 5) else true end) and (if .kind == "task" then (((.target.taskId | type) == "string") and (.target.taskId|length > 0)) else true end)' >/dev/null 2>&1 || { fm_cycle_fail malformed_intent "typed intent is invalid"; return 2; }
  local group_path
  group_path=$(fm_cycle_group_path "$(printf '%s' "$input" | jq -r '.executionId')") || { fm_cycle_fail malformed_identity "executionId is invalid"; return 2; }
  [ -f "$group_path" ] || { fm_cycle_fail execution_not_found "execution group is not accepted"; return 2; }
  jq -e --arg child "$(printf '%s' "$input" | jq -r '.childId')" 'any(.children[]? | select(type == "object"); (.childId // .workItemId) == $child)' "$group_path" >/dev/null 2>&1 || { fm_cycle_fail child_not_in_group "intent child is outside the accepted execution group"; return 2; }
  digest=$(printf '%s' "$input" | fm_cycle_canonical_digest); path=$(fm_cycle_intent_path "$id") || { fm_cycle_fail malformed_identity "intentId is invalid"; return 2; }
  if [ -f "$path" ]; then existing=$(jq -c . "$path") || { fm_cycle_fail malformed_record "stored intent is unreadable"; return 2; }; [ "$(printf '%s' "$existing" | jq -r '.intentDigest')" = "$digest" ] || { fm_cycle_fail identity_conflict "intentId is bound to changed content"; return 2; }; jq -cn --argjson intent "$existing" '{accepted:true,protocolVersion:"fm-bridge.v2",operation:"publishProgress",replayed:true,intent:$intent}'; return 0; fi
  local stored; stored=$(printf '%s' "$input" | jq -c --arg digest "$digest" '. + {intentDigest:$digest,state:"pending",acceptedAt:(now|todateiso8601)}') || { fm_cycle_fail malformed_intent "intent could not be normalized"; return 2; }; fm_cycle_write "$path" "$stored" || { fm_cycle_fail durable_store "intent could not be stored"; return 2; }; fm_cycle_write "$FM_CYCLE_OUTBOX/$id.json" "$stored" || { fm_cycle_fail durable_store "intent outbox could not be stored"; return 2; }
  jq -cn --argjson intent "$stored" '{accepted:true,protocolVersion:"fm-bridge.v2",operation:"publishProgress",replayed:false,intent:$intent}'
}

# The outbox replay copy is dropped only once the applied state is durable, so a
# failed acknowledgement never reports an effect the store did not keep.
fm_cycle_ack() {
  local id=${1:-} digest=${2:-} path
  path=$(fm_cycle_intent_path "$id") || { fm_cycle_fail malformed_identity "intentId is invalid"; return 2; }
  [ -f "$path" ] || { fm_cycle_fail not_found "intent not found"; return 2; }
  [ -n "$digest" ] || { fm_cycle_fail acknowledgement_mismatch "intent digest is required"; return 2; }
  [ "$(jq -r '.intentDigest // empty' "$path" 2>/dev/null)" = "$digest" ] || { fm_cycle_fail acknowledgement_mismatch "intent digest does not match"; return 2; }
  # shellcheck disable=SC2016 # jq owns every $ in this filter; the shell must not expand it.
  fm_cycle_update "$path" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.state="applied" | .acknowledgedAt=$at' || { fm_cycle_fail durable_store "acknowledgement could not be stored"; return 2; }
  rm -f "$FM_CYCLE_OUTBOX/$id.json"
  jq -cn --arg id "$id" --arg digest "$digest" '{accepted:true,protocolVersion:"fm-bridge.v2",operation:"acknowledgeProgress",intentId:$id,intentDigest:$digest,state:"applied"}'
}
