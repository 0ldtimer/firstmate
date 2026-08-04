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

fm_cycle_init() { mkdir -p "$FM_CYCLE_GROUPS" "$FM_CYCLE_CHILDREN" "$FM_CYCLE_INTENTS" "$FM_CYCLE_ACKS" "$FM_CYCLE_OUTBOX"; }
fm_cycle_digest() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 | awk '{print $1}'; else sha256sum | awk '{print $1}'; fi; }
fm_cycle_identity() { case "$1" in ''|*[!A-Za-z0-9._:-]*) return 1;; esac; [ "${#1}" -le 160 ]; }
fm_cycle_json() { jq -ce 'type == "object"' 2>/dev/null; }
fm_cycle_fail() { jq -cn --arg code "$1" --arg message "$2" '{accepted:false,protocolVersion:"fm-bridge.v2",schemaVersion:"cycle-execution.v1",error:{code:$code,message:$message}}'; }
fm_cycle_write() { local path=$1 value=$2 tmp="${path}.$$"; mkdir -p "$(dirname "$path")" || return 1; printf '%s\n' "$value" > "$tmp" && mv "$tmp" "$path"; }
fm_cycle_canonical_digest() { jq -cS . | fm_cycle_digest; }

fm_cycle_accept_group() {
  local input=$1 group id attempt digest path prior
  fm_cycle_init || { fm_cycle_fail durable_store "execution store unavailable"; return 2; }
  printf '%s' "$input" | fm_cycle_json >/dev/null || { fm_cycle_fail malformed_request "execution group must be a JSON object"; return 2; }
  group=$(printf '%s' "$input" | jq -r '.executionId // empty'); attempt=$(printf '%s' "$input" | jq -r '.attemptId // empty')
  fm_cycle_identity "$group" && fm_cycle_identity "$attempt" || { fm_cycle_fail malformed_identity "executionId and attemptId are invalid"; return 2; }
  printf '%s' "$input" | jq -e '.schemaVersion == "cycle-execution.v1" and (.manifestDigest|type=="string" and length>0) and (.binding.workspaceId|type=="string" and length>0) and (.binding.cycleId|type=="string" and length>0) and ((.children // [])|type=="array")' >/dev/null 2>&1 || { fm_cycle_fail malformed_group "manifest, binding, or children is invalid"; return 2; }
  digest=$(printf '%s' "$input" | fm_cycle_canonical_digest) || { fm_cycle_fail malformed_request "cannot digest execution group"; return 2; }
  path="$FM_CYCLE_GROUPS/$group.json"
  if [ -f "$path" ]; then
    prior=$(jq -c . "$path" 2>/dev/null) || { fm_cycle_fail malformed_record "stored group is unreadable"; return 2; }
    if [ "$(printf '%s' "$prior" | jq -r '.manifestDigest // empty')" != "$(printf '%s' "$input" | jq -r '.manifestDigest')" ]; then fm_cycle_fail identity_conflict "execution identity is bound to another manifest"; return 2; fi
    jq -cn --argjson group "$prior" --arg digest "$digest" '{accepted:true,protocolVersion:"fm-bridge.v2",operation:"acceptExecutionGroup",replayed:true,executionGroup:$group,receipt:{executionId:$group.executionId,manifestDigest:$group.manifestDigest,digest:$digest,authorizationReceipt:("receipt:" + $group.executionId)}}'; return 0
  fi
  local stored
  stored=$(printf '%s' "$input" | jq -c --arg digest "$digest" '. + {state:"accepted",groupDigest:$digest,acceptedAt:(now|todateiso8601),leaseExpiresAt:((now + 86400)|todateiso8601),children:((.children // []) | map(. + {state:"queued"}))}') || { fm_cycle_fail malformed_group "cannot normalize execution group"; return 2; }
  fm_cycle_write "$path" "$stored" || { fm_cycle_fail durable_store "execution group could not be stored"; return 2; }
  printf '%s' "$stored" | jq -c '.children[]? | . + {executionId: input_filename}' >/dev/null 2>&1 || true
  jq -cn --argjson group "$stored" '{accepted:true,protocolVersion:"fm-bridge.v2",operation:"acceptExecutionGroup",replayed:false,executionGroup:$group,receipt:{executionId:$group.executionId,manifestDigest:$group.manifestDigest,authorizationReceipt:("receipt:" + $group.executionId)}}'
}

fm_cycle_status() { local id=$1 path="$FM_CYCLE_GROUPS/$1.json"; [ -f "$path" ] || { fm_cycle_fail not_found "execution group not found"; return 2; }; jq -c '{accepted:true,protocolVersion:"fm-bridge.v2",operation:"executionGroupStatus",executionGroup:.}' "$path"; }

fm_cycle_delegate() {
  local id=$1 path="$FM_CYCLE_GROUPS/$1.json" group child child_id child_path
  [ -f "$path" ] || { fm_cycle_fail not_found "execution group not found"; return 2; }
  group=$(jq -c . "$path") || { fm_cycle_fail malformed_record "execution group unreadable"; return 2; }
  if jq -e '.leaseExpiresAt? and ((.leaseExpiresAt|fromdateiso8601) <= now)' "$path" >/dev/null 2>&1; then
    fm_cycle_fail lease_expired "delegation lease has expired"; return 2
  fi
  while IFS= read -r child; do
    child_id=$(printf '%s' "$child" | jq -r '.childId // .workItemId // empty'); fm_cycle_identity "$child_id" || continue
    child_path="$FM_CYCLE_CHILDREN/$child_id.json"
    [ -f "$child_path" ] || fm_cycle_write "$child_path" "$(printf '%s' "$child" | jq -c --arg executionId "$id" '. + {executionId:$executionId,state:"queued",delegatedAt:(now|todateiso8601)}')" || { fm_cycle_fail durable_store "child could not be stored"; return 2; }
  done < <(printf '%s' "$group" | jq -c '.children[]?')
  jq -c --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.state="delegated" | .delegatedAt=$at' "$path" | { read -r updated; fm_cycle_write "$path" "$updated"; }
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

fm_cycle_emit_intent() {
  local input=$1 id path existing digest
  fm_cycle_init || { fm_cycle_fail durable_store "execution store unavailable"; return 2; }
  id=$(printf '%s' "$input" | jq -r '.intentId // empty'); fm_cycle_identity "$id" || { fm_cycle_fail malformed_identity "intentId is invalid"; return 2; }
  printf '%s' "$input" | jq -e '.schemaVersion == "fm-progress-intent.v1" and (.executionId|type=="string") and (.childId|type=="string") and (.kind|IN("task","hill","evidence")) and (.evidence.reference|type=="string" and length>0) and (if .kind == "hill" then (.target.position|type == "number" and .target.position >= 0 and .target.position <= 5) else true end) and (if .kind == "task" then (.target.taskId|type == "string" and length > 0) else true end)' >/dev/null 2>&1 || { fm_cycle_fail malformed_intent "typed intent is invalid"; return 2; }
  local group_path="$FM_CYCLE_GROUPS/$(printf '%s' "$input" | jq -r '.executionId').json"
  [ -f "$group_path" ] || { fm_cycle_fail execution_not_found "execution group is not accepted"; return 2; }
  printf '%s' "$input" | jq -r '.childId' | while IFS= read -r child_ref; do
    jq -e --arg child "$child_ref" '.children[]? | select((.childId // .workItemId) == $child)' "$group_path" >/dev/null 2>&1 || exit 1
  done || { fm_cycle_fail child_not_in_group "intent child is outside the accepted execution group"; return 2; }
  digest=$(printf '%s' "$input" | fm_cycle_canonical_digest); path="$FM_CYCLE_INTENTS/$id.json"
  if [ -f "$path" ]; then existing=$(jq -c . "$path"); [ "$(printf '%s' "$existing" | jq -r '.intentDigest')" = "$digest" ] || { fm_cycle_fail identity_conflict "intentId is bound to changed content"; return 2; }; jq -cn --argjson intent "$existing" '{accepted:true,protocolVersion:"fm-bridge.v2",operation:"publishProgress",replayed:true,intent:$intent}'; return 0; fi
  local stored; stored=$(printf '%s' "$input" | jq -c --arg digest "$digest" '. + {intentDigest:$digest,state:"pending",acceptedAt:(now|todateiso8601)}'); fm_cycle_write "$path" "$stored" || { fm_cycle_fail durable_store "intent could not be stored"; return 2; }; fm_cycle_write "$FM_CYCLE_OUTBOX/$id.json" "$stored" || { fm_cycle_fail durable_store "intent outbox could not be stored"; return 2; }
  jq -cn --argjson intent "$stored" '{accepted:true,protocolVersion:"fm-bridge.v2",operation:"publishProgress",replayed:false,intent:$intent}'
}

fm_cycle_ack() { local id=$1 digest=$2 path="$FM_CYCLE_INTENTS/$1.json"; [ -f "$path" ] || { fm_cycle_fail not_found "intent not found"; return 2; }; [ "$(jq -r '.intentDigest' "$path")" = "$digest" ] || { fm_cycle_fail acknowledgement_mismatch "intent digest does not match"; return 2; }; jq -c --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.state="applied" | .acknowledgedAt=$at' "$path" | { read -r updated; fm_cycle_write "$path" "$updated"; rm -f "$FM_CYCLE_OUTBOX/$id.json"; }; jq -cn --arg id "$id" --arg digest "$digest" '{accepted:true,protocolVersion:"fm-bridge.v2",operation:"acknowledgeProgress",intentId:$id,intentDigest:$digest,state:"applied"}'; }

fm_cycle_projection() {
  fm_cycle_init || return 1
  jq -cn --arg capturedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --slurpfile groups <(for f in "$FM_CYCLE_GROUPS"/*.json; do [ -f "$f" ] && cat "$f"; done) --slurpfile children <(for f in "$FM_CYCLE_CHILDREN"/*.json; do [ -f "$f" ] && cat "$f"; done) --slurpfile intents <(for f in "$FM_CYCLE_INTENTS"/*.json; do [ -f "$f" ] && cat "$f"; done) '{schemaVersion:"fm-captains-log-projection.v1",capturedAt:$capturedAt,freshness:"fresh",executionGroups:$groups,children:$children,progressIntents:$intents,pendingIntents:[$intents[]|select(.state=="pending")]}'
}
