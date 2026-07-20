#!/usr/bin/env bash
# Shared helpers for the fm-bridge.v1 machine contract.

fm_bridge_fail() { # <code> <message>
  jq -n --arg code "$1" --arg message "$2" \
    '{accepted:false,error:{code:$code,message:$message}}'
}

fm_bridge_digest() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    sha256sum | awk '{print $1}'
  fi
}

fm_bridge_task_revision() { # <task-json>
  printf '%s' "$1" | jq -cS . | fm_bridge_digest
}

fm_bridge_state() { # <snapshot state>
  case "$1" in
    parked|needs-decision|awaiting-captain) printf 'awaitingCaptain' ;;
    blocked|failed) printf 'blocked' ;;
    validating|reviewing|ci|checks-running) printf 'verifying' ;;
    pr-ready|ready) printf 'prReady' ;;
    working|running|fixing) printf 'working' ;;
    paused|idle) printf 'paused' ;;
    approved|signed-off) printf 'approved' ;;
    done|merged|completed) printf 'completed' ;;
    *) printf 'unknown' ;;
  esac
}

fm_bridge_capabilities() { # <state> <pr-url>
  local state=$1
  jq -n --arg state "$state" '
    ["feedback","defer"]
    + (if ($state == "awaitingCaptain" or $state == "prReady") then ["sign-off"] else [] end)
  '
}

fm_bridge_evidence() { # <task-json> <revision>
  local task=$1 revision=$2 id report pr manifest manifest_items='[]'
  id=$(printf '%s' "$task" | jq -r '.id // empty')
  report=$(printf '%s' "$task" | jq -r '.paths.report.path // empty')
  pr=$(printf '%s' "$task" | jq -r '.pr.url // empty')
  manifest="$DATA/$id/evidence.json"
  if [ -f "$manifest" ]; then
    manifest_items=$(jq -c '
      if type != "array" then [] else [
        .[] | select(type == "object") |
        select((.id | type) == "string" and (.kind | type) == "string") |
        {
          id, kind,
          status:(.status // "unknown"),
          summary:(.summary // .kind),
          detail:(.detail // null),
          source:(.source // "FirstMate"),
          capturedAt:(.capturedAt // null),
          commit:(.commit // null),
          reference:(.reference // null)
        }
      ] end
    ' "$manifest" 2>/dev/null || printf '[]')
  fi
  jq -n --arg report "$report" --arg pr "$pr" --arg revision "$revision" \
    --argjson manifest "$manifest_items" '
    [
      if $report != "" then {
        id:"report",kind:"Report",status:"present",summary:"Shipmate report is available",
        source:"FirstMate",taskRevision:$revision,reference:$report
      } else empty end,
      if $pr != "" then {
        id:"pull-request",kind:"Pull request",status:"present",summary:"Pull request is available",
        source:"GitHub",taskRevision:$revision,reference:$pr
      } else empty end
    ] as $defaults |
    reduce ($manifest[] | . + {taskRevision:$revision}) as $item
      ($defaults; map(select(.id != $item.id)) + [$item])
  '
}

fm_bridge_snapshot() {
  local raw captured snapshot_revision
  raw=$("$SCRIPT_DIR/fm-fleet-snapshot.sh" --json) || return
  captured=$(printf '%s' "$raw" | jq -r '.generated')
  snapshot_revision=$(printf '%s' "$raw" | jq -cS '{tasks,backlog,scout_reports,secondmate_current}' | fm_bridge_digest)
  printf '%s' "$raw" | jq -c \
    --arg protocol "fm-bridge.v1" \
    --arg snapshot_revision "$snapshot_revision" --arg captured "$captured" '
    {
      protocolVersion:$protocol,
      snapshotRevision:$snapshot_revision,
      capturedAt:.generated,
      freshness:"fresh",
      tasks:[.tasks[] | {
        id:.id,
        title:(.backlog.title // .id),
        project:(.project // "unknown"),
        shipmate:(.harness // "shipmate"),
        rawState:(.current_state.state // "unknown"),
        updatedAt:$captured,
        attentionReason:(.current_state.detail // null),
        summary:(.backlog.body_excerpt // null),
        pr:(.pr.url // ""),
        source:.
      }]
    }'
}

fm_bridge_project_snapshot() {
  local base tasks='[]' task source revision state evidence evidence_revision capabilities projected
  base=$(fm_bridge_snapshot) || return
  while IFS= read -r task; do
    source=$(printf '%s' "$task" | jq -c '.source | {
      id,
      current_state:{
        state:.current_state.state,
        source:.current_state.source,
        detail:.current_state.detail
      },
      pr,
      backlog,
      hints,
      report:.paths.report
    }')
    revision=$(fm_bridge_task_revision "$source")
    state=$(fm_bridge_state "$(printf '%s' "$task" | jq -r '.rawState')")
    evidence=$(fm_bridge_evidence "$(printf '%s' "$task" | jq -c '.source')" "$revision" | jq -c .)
    evidence_revision=$(printf '%s' "$evidence" | jq -cS . | fm_bridge_digest)
    capabilities=$(fm_bridge_capabilities "$state" "$(printf '%s' "$task" | jq -r '.pr')" | jq -c .)
    projected=$(printf '%s' "$task" | jq -c \
      --arg revision "$revision" --arg state "$state" \
      --arg evidence_revision "$evidence_revision" \
      --argjson evidence "$evidence" --argjson capabilities "$capabilities" '
      del(.rawState,.pr,.source) + {
        state:$state,
        taskRevision:$revision,
        capabilities:$capabilities,
        evidenceRevision:$evidence_revision,
        evidence:$evidence
      }')
    tasks=$(jq -c --argjson tasks "$tasks" --argjson task "$projected" '$tasks + [$task]' <<< '{}')
  done < <(printf '%s' "$base" | jq -c '.tasks[]')
  printf '%s' "$base" | jq -c --argjson tasks "$tasks" '.tasks=$tasks'
}
