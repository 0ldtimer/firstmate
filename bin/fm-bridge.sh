#!/usr/bin/env bash
# fm-bridge.sh - versioned machine boundary for Captain's Log and local clients.
#
# Reads one JSON request from stdin.
# Supported operations:
#   {"protocolVersion":"fm-bridge.v1","operation":"snapshot"}
#   {"protocolVersion":"fm-bridge.v1","operation":"command","command":{...}}
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
SEND_BIN="${FM_BRIDGE_SEND_BIN:-$SCRIPT_DIR/fm-send.sh}"

# shellcheck source=bin/fm-bridge-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-bridge-lib.sh"

command -v jq >/dev/null 2>&1 || {
  echo "fm-bridge: jq not found" >&2
  exit 1
}

request=$(head -c 65537)
[ "${#request}" -le 65536 ] || {
  fm_bridge_fail request_too_large "Bridge requests are limited to 64 KiB"
  exit 2
}
printf '%s' "$request" | jq -e . >/dev/null 2>&1 || {
  fm_bridge_fail malformed_request "Request must be valid JSON"
  exit 2
}
version=$(printf '%s' "$request" | jq -r '.protocolVersion // empty')
[ "$version" = "fm-bridge.v1" ] || {
  fm_bridge_fail unsupported_version "Only fm-bridge.v1 is supported"
  exit 2
}
operation=$(printf '%s' "$request" | jq -r '.operation // empty')
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
        feedback_dir="$DATA/$task_id/feedback"
        feedback_record="$feedback_dir/$command_id.json"
        mkdir -p "$feedback_dir"
        jq -n --arg commandId "$command_id" --arg feedback "$feedback" \
          --arg scope "original" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
          '{commandId:$commandId,feedback:$feedback,scope:$scope,status:"recorded",recordedAt:$at}' \
          > "$feedback_record"
        feedback_summary=$(printf '%s' "$feedback" | tr '\n' ' ' | cut -c1-160)
        printf 'feedback-provided: %s\n' "$feedback_summary" >> "$STATE/$task_id.status"
        redispatch="Captain feedback for the existing mission: $feedback

Resume this same task within its original scope and agreed evidence contract. Append working: when you resume. If this direction expands scope, authority, or evidence expectations, append needs-decision: feedback changes the mission contract and stop instead of implementing it."
        FM_HOME="$FM_HOME" "$SEND_BIN" "$task_id" "$redispatch" >/dev/null || {
          jq '.status="delivery-failed"' "$feedback_record" > "$feedback_record.tmp" && mv "$feedback_record.tmp" "$feedback_record"
          fm_bridge_fail endpoint_unavailable "Feedback could not be delivered to the shipmate"
          exit 2
        }
        jq --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.status="redispatched" | .redispatchedAt=$at' "$feedback_record" > "$feedback_record.tmp"
        mv "$feedback_record.tmp" "$feedback_record"
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
    next_snapshot=$(fm_bridge_project_snapshot) || exit 1
    if [ "$action" = feedback ]; then
      message="Feedback recorded and automatically redispatched to $task_id"
    else
      message="FirstMate accepted $action for $task_id"
    fi
    outcome=$(jq -n --arg message "$message" --argjson snapshot "$next_snapshot" \
      '{accepted:true,message:$message,snapshot:$snapshot}')
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
