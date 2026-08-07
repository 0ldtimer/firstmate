#!/usr/bin/env bash
# fm-bridge.sh - versioned machine boundary for Captain's Log and local clients.
#
# Reads one JSON request from stdin. v1 preserves the fleet snapshot and guarded
# command contract; v2 owns Captain's Log Engineering execution and projection.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-bridge-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-bridge-lib.sh"
# shellcheck source=bin/fm-cycle-execution-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-cycle-execution-lib.sh"

command -v jq >/dev/null 2>&1 || {
  echo "fm-bridge: jq not found" >&2
  exit 1
}

request=$(head -c 1048577)

# A pre-dispatch refusal answers in the envelope the caller declared, so a v1
# client keeps the bare fm-bridge.v1 error shape it was written against and only
# a request that declares fm-bridge.v2 receives the v2 envelope. The declared
# version is read from the parsed request when it parses, and from the raw bytes
# when it does not, so an oversized or malformed v2 request is still answered in
# v2's shape.
bridge_declared_version() {
  local declared
  declared=$(printf '%s' "$request" | jq -r 'if type == "object" then (.protocolVersion // empty) else empty end' 2>/dev/null) || declared=
  if [ -n "$declared" ]; then
    printf '%s\n' "$declared"
    return 0
  fi
  case "$request" in
    *'"fm-bridge.v2"'*) printf '%s\n' 'fm-bridge.v2' ;;
    *) printf '%s\n' '' ;;
  esac
}

bridge_pre_dispatch_fail() { # <code> <message>
  if [ "$(bridge_declared_version)" = "fm-bridge.v2" ]; then
    fm_cycle_fail "$1" "$2"
  else
    fm_bridge_fail "$1" "$2"
  fi
}

[ "${#request}" -le 1048576 ] || {
  bridge_pre_dispatch_fail request_too_large "request exceeds 1 MiB"
  exit 2
}
printf '%s' "$request" | jq -e 'type == "object"' >/dev/null 2>&1 || {
  bridge_pre_dispatch_fail malformed_request "request must be a JSON object"
  exit 2
}
protocol=$(printf '%s' "$request" | jq -r '.protocolVersion // empty')
operation=$(printf '%s' "$request" | jq -r '.operation // empty')

if [ "$protocol" = "fm-bridge.v1" ]; then
  [ "${#request}" -le 65536 ] || {
    fm_bridge_fail request_too_large "Bridge v1 requests are limited to 64 KiB"
    exit 2
  }
  case "$operation" in
    snapshot)
      fm_bridge_project_snapshot
      ;;
    command)
      command_json=$(printf '%s' "$request" | jq -c '.command // empty')
      command_id=$(printf '%s' "$command_json" | jq -r '.commandId // empty')
      action=$(printf '%s' "$command_json" | jq -r '.action // empty')
      task_id=$(printf '%s' "$command_json" | jq -r '.taskId // empty')
      expected=$(printf '%s' "$command_json" | jq -r '.expectedRevision // empty')
      [ -n "$command_id" ] && [ -n "$task_id" ] && [ -n "$expected" ] || {
        fm_bridge_fail malformed_command "commandId, taskId, and expectedRevision are required"
        exit 2
      }
      case "$command_id" in
        *[!A-Za-z0-9._-]*|'') fm_bridge_fail malformed_command "commandId contains unsafe characters"; exit 2 ;;
      esac
      [ "${#command_id}" -le 128 ] || {
        fm_bridge_fail malformed_command "commandId is too long"
        exit 2
      }
      case "$action" in sign-off|defer|feedback|merge) ;; *)
        fm_bridge_fail illegal_action "Unsupported Bridge action"
        exit 2
      esac
      journal="$STATE/bridge-command-journal"
      mkdir -p "$journal"
      lock="$journal/$command_id.lock"
      mkdir "$lock" 2>/dev/null || {
        fm_bridge_fail command_busy "This command is already being processed"
        exit 2
      }
      trap 'rmdir "$lock" 2>/dev/null || true' EXIT
      digest=$(printf '%s' "$command_json" | jq -cS . | fm_bridge_digest)
      record="$journal/$command_id.json"
      if [ -f "$record" ]; then
        prior_digest=$(jq -r '.requestDigest' "$record")
        [ "$prior_digest" = "$digest" ] || {
          fm_bridge_fail command_id_conflict "commandId was already used for a different request"
          exit 2
        }
        jq -c '.outcome + {replayed:true}' "$record"
        exit 0
      fi
      snapshot=$(fm_bridge_project_snapshot) || exit 1
      task=$(printf '%s' "$snapshot" | jq -c --arg id "$task_id" '.tasks[] | select(.id==$id)')
      [ -n "$task" ] || {
        fm_bridge_fail task_not_found "Task is not present in the current fleet"
        exit 2
      }
      current=$(printf '%s' "$task" | jq -r '.taskRevision')
      [ "$current" = "$expected" ] || {
        jq -n --arg current "$current" \
          '{accepted:false,error:{code:"stale_revision",message:"Task revision changed",currentRevision:$current}}'
        exit 2
      }
      capability=$(printf '%s' "$task" | jq -e --arg action "$action" '.capabilities | index($action) != null')
      [ "$capability" = true ] || {
        fm_bridge_fail capability_absent "Action is not legal for the current task state"
        exit 2
      }
      if [ "$action" = merge ]; then
        fm_bridge_fail merge_requires_guarded_mode "Merge is unavailable until a guarded project mode is configured"
        exit 2
      fi
      if [ "$action" = sign-off ]; then
        reviewed_evidence=$(printf '%s' "$command_json" | jq -r '.evidenceRevision // empty')
        current_evidence=$(printf '%s' "$task" | jq -r '.evidenceRevision')
        [ "$reviewed_evidence" = "$current_evidence" ] || {
          fm_bridge_fail stale_evidence "Evidence changed before sign-off"
          exit 2
        }
      fi
      case "$action" in
        feedback)
          feedback=$(printf '%s' "$command_json" | jq -r '.feedback // empty')
          [ -n "$feedback" ] || {
            fm_bridge_fail malformed_command "Feedback text is required"
            exit 2
          }
          FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-send.sh" "$task_id" "$feedback" >/dev/null || {
            fm_bridge_fail endpoint_unavailable "Feedback could not be delivered to the shipmate"
            exit 2
          }
          ;;
        sign-off|defer)
          review_dir="$FM_HOME/data/$task_id"
          mkdir -p "$review_dir"
          review_record="$review_dir/bridge-review.json"
          review_tmp="$review_record.$$"
          jq -n --arg action "$action" --arg revision "$current" \
            --arg evidenceRevision "$(printf '%s' "$task" | jq -r '.evidenceRevision')" \
            --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            '{action:$action,taskRevision:$revision,evidenceRevision:$evidenceRevision,recordedAt:$at}' \
            > "$review_tmp"
          mv "$review_tmp" "$review_record"
          ;;
      esac
      outcome=$(jq -n --arg action "$action" --arg task_id "$task_id" \
        '{accepted:true,message:("FirstMate accepted " + $action + " for " + $task_id)}')
      tmp="$record.$$"
      jq -n --arg requestDigest "$digest" --argjson outcome "$outcome" \
        '{requestDigest:$requestDigest,outcome:$outcome}' > "$tmp"
      mv "$tmp" "$record"
      printf '%s' "$outcome"
      ;;
    *)
      fm_bridge_fail unsupported_operation "Operation must be snapshot or command"
      exit 2
      ;;
  esac
  exit 0
fi

[ "$protocol" = "fm-bridge.v2" ] || {
  bridge_pre_dispatch_fail unsupported_version "unsupported protocol version"
  exit 2
}

case "$operation" in
  capabilities)
    version=$(git -C "$FM_ROOT" rev-parse HEAD 2>/dev/null || printf '%s' 'local-fork')
    # capabilityDigest is derived from the advertised capabilities object at
    # response time, so an edit to that object cannot advertise a stale digest.
    capabilities=$(jq -cn '{
      missionRevision:"mission-contract.v2",
      missionResultRevision:"mission-result.v2",
      missionResultOperations:[],
      evidenceContractRevisions:["evidence.v2"],
      harnesses:["local"],
      backends:["herdr"],
      validationProfiles:["no_mistakes"],
      evidenceKinds:["automated","visual"],
      deliveryModes:["local-only"],
      permissions:["repository-write"],
      externalReferences:{shapeUp:{revision:"shapeup-correlation.v1",matching:"opaque-reference-only",required:["cycleRef","buildRef"]}},
      learning:{supported:false,modes:[],skills:[],afterVerificationOnly:true,countsAsEvidence:false,allowedPath:"docs/solutions/"}
    }') || {
      fm_cycle_fail capabilities_unavailable "capabilities could not be composed"
      exit 2
    }
    capability_digest=$(printf '%s' "$capabilities" | fm_cycle_canonical_digest) || {
      fm_cycle_fail capabilities_unavailable "capability digest could not be derived"
      exit 2
    }
    jq -cn --arg home "$FM_HOME" --arg executable "$SCRIPT_DIR/fm-bridge.sh" --arg version "$version" \
      --arg capabilityDigest "$capability_digest" --argjson capabilities "$capabilities" '{
      accepted:true,
      protocolVersion:"fm-bridge.v2",
      operation:"capabilities",
      firstMate:{home:$home,executable:$executable,version:$version},
      effectiveProfile:{harness:"local",backend:"herdr",validationProfile:"no_mistakes",noMistakes:true,deliveryMode:"local-only"},
      capabilityDigest:$capabilityDigest,
      capabilityDigestSource:"sha256:canonical(capabilities)",
      dispatchable:true,
      capabilities:$capabilities
    }'
    ;;
  acceptExecutionGroup|createExecutionGroup)
    fm_cycle_accept_group "$request"
    ;;
  executionGroupStatus|getExecutionGroup)
    fm_cycle_status "$(printf '%s' "$request" | jq -r '.executionId // empty')"
    ;;
  delegateExecutionGroup|delegateChildren)
    fm_cycle_delegate "$(printf '%s' "$request" | jq -r '.executionId // empty')"
    ;;
  renewExecutionLease|renewLease)
    fm_cycle_renew "$request"
    ;;
  amendExecutionGroup|amendExecution)
    fm_cycle_amend "$request"
    ;;
  publishProgress|progressIntent)
    fm_cycle_emit_intent "$(printf '%s' "$request" | jq -c '.intent // .')"
    ;;
  acknowledgeProgress|ack)
    fm_cycle_ack "$(printf '%s' "$request" | jq -r '.intentId // empty')" \
      "$(printf '%s' "$request" | jq -r '.intentDigest // .digest // empty')"
    ;;
  projection|captainsLogProjection|captainsLogProjectionSnapshot)
    fm_cycle_projection
    ;;
  *)
    fm_cycle_fail unsupported_operation "unsupported protocol or operation"
    exit 2
    ;;
esac
