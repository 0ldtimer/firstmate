#!/usr/bin/env bash
# FirstMate-owned primary-liaison adapter for Cycle execution groups.
#
# The adapter is deliberately a thin consumer of the existing FirstMate spawn
# boundary.  It does not create worktrees, steer terminals, or invoke a Captain
# service itself: it validates the producer binding, persists dispatch intent,
# then calls fm-spawn.sh exactly as the ordinary primary would.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
FM_HOME=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || { echo 'liaison: invalid FM_HOME' >&2; exit 2; }
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
FM_CYCLE_ROOT="${FM_CYCLE_ROOT:-${FM_DATA_OVERRIDE:-$DATA}/engineering/execution}"
FM_CYCLE_GROUPS="$FM_CYCLE_ROOT/groups"
FM_CYCLE_CHILDREN="$FM_CYCLE_ROOT/children"
FM_CYCLE_LIAISON="$FM_CYCLE_ROOT/liaison"
FM_LIAISON_LOCK="$FM_CYCLE_LIAISON/dispatch.lock"
FM_SPAWN_BIN="${FM_SCOTTY_SPAWN_BIN:-$FM_ROOT/bin/fm-spawn.sh}"

# shellcheck source=bin/fm-cycle-execution-lib.sh
. "$SCRIPT_DIR/fm-cycle-execution-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

fail() { printf 'liaison: %s\n' "$*" >&2; }
json_error() { jq -cn --arg code "$1" --arg message "$2" '{accepted:false,protocolVersion:"fm-bridge.v2",operation:"scottyDelegation",error:{code:$code,message:$message}}'; }

take_execution_wakes() {
  local queue="$FM_WAKE_QUEUE" tmp rows
  mkdir -p "$STATE" "$FM_CYCLE_LIAISON" || return 1
  fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK" || return 1
  tmp="$STATE/.wake-queue.liaison.$(fm_current_pid)"
  rm -f "$tmp"
  [ -f "$queue" ] || : > "$queue"
  awk -F '\t' -v out="$tmp" '
    NF >= 5 && $3 == "signal" && $4 ~ /^execution:/ { print $0 >> out; next }
    { print $0 }
  ' "$queue" > "$queue.next.$(fm_current_pid)" || { fm_lock_release "$FM_WAKE_QUEUE_LOCK"; return 1; }
  mv "$queue.next.$(fm_current_pid)" "$queue" || { fm_lock_release "$FM_WAKE_QUEUE_LOCK"; return 1; }
  rows=$(cat "$tmp" 2>/dev/null || true)
  rm -f "$tmp"
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  printf '%s\n' "$rows"
}

# The dispatch mutex is the fleet's liveness-safe lock, not a bare exclusive
# file: a liaison killed mid-dispatch leaves an owner record whose dead pid the
# next run reclaims, so fan-out recovers instead of wedging on liaison_busy.
claim_liaison_lock() {
  mkdir -p "$FM_CYCLE_LIAISON" || return 1
  fm_lock_try_acquire "$FM_LIAISON_LOCK"
}
release_liaison_lock() { fm_lock_release "$FM_LIAISON_LOCK" 2>/dev/null || true; }

registry_has_project() {
  local project=$1 count
  [ -f "$DATA/projects.md" ] && [ ! -L "$DATA/projects.md" ] || return 1
  count=$(awk -v n="$project" '$1=="-" && $2==n { count++ } END { print count+0 }' "$DATA/projects.md")
  [ "$count" -eq 1 ]
}

validate_child_binding() {
  local child=$1 project path root base expected_root remote allowed
  project=$(printf '%s' "$child" | jq -r '.project // .repository.project // empty')
  case "$project" in ''|*[!A-Za-z0-9._-]*) fail "child has invalid project identity"; return 1;; esac
  registry_has_project "$project" || { fail "project is not in trusted registry: $project"; return 1; }
  path="$PROJECTS/$project"
  [ -d "$path" ] && [ ! -L "$path" ] || { fail "project root is missing or symlinked: $path"; return 1; }
  root=$(git -C "$path" rev-parse --show-toplevel 2>/dev/null) || { fail "project is not a git repository: $project"; return 1; }
  root=$(CDPATH='' cd -- "$root" && pwd -P) || return 1
  expected_root=$(CDPATH='' cd -- "$path" && pwd -P) || return 1
  [ "$root" = "$expected_root" ] || { fail "project root escapes trusted project path: $project"; return 1; }
  expected_root=$(printf '%s' "$child" | jq -r '.repository.root // empty')
  [ -z "$expected_root" ] || [ "$expected_root" = "$root" ] || { fail "repository root binding mismatch for $project"; return 1; }
  base=$(printf '%s' "$child" | jq -r '.baseRevision // .repository.baseRevision // empty')
  case "$base" in ''|*[!A-Fa-f0-9]*) fail "child has no valid base revision: $project"; return 1;; esac
  [ "${#base}" -eq 40 ] || { fail "child base revision must be a full commit id: $project"; return 1; }
  git -C "$root" cat-file -e "$base^{commit}" 2>/dev/null || { fail "bound base revision is unavailable: $project"; return 1; }
  [ "$(git -C "$root" rev-parse HEAD 2>/dev/null)" = "$(git -C "$root" rev-parse "$base^{commit}" 2>/dev/null)" ] || { fail "project is not at its bound base revision: $project"; return 1; }
  printf '%s' "$child" | jq -e '(.repository.allowedRemotes // []) | type == "array" and all(.[]; type == "string")' >/dev/null 2>&1 || { fail "child allowed remotes must be a string array: $project"; return 1; }
  allowed=$(printf '%s' "$child" | jq -r '.repository.allowedRemotes[]? // empty' 2>/dev/null || true)
  if [ -n "$allowed" ]; then
    remote=$(git -C "$root" remote get-url origin 2>/dev/null || true)
    printf '%s\n' "$allowed" | grep -F -x -- "$remote" >/dev/null || { fail "origin is outside child allowed remotes: $project"; return 1; }
  fi
  return 0
}

mark_child() {
  local state=$2 reason=${3:-} path
  path=$(fm_cycle_child_path "$1") || return 1
  [ -f "$path" ] || return 1
  # shellcheck disable=SC2016 # jq owns every $ in this filter; the shell must not expand it.
  fm_cycle_update "$path" --arg state "$state" --arg reason "$reason" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '.state=$state | .updatedAt=$at | (if $reason == "" then del(.dispatchError) else .dispatchError=$reason end)'
}

dispatch_child() {
  local execution=$1 child_file=$2 child project task child_key mode yolo harness model effort backend out err rc backlog errexit=0
  child=$(cat "$child_file") || return 1
  project=$(printf '%s' "$child" | jq -r '.project // .repository.project // empty')
  child_key=$(printf '%s' "$child" | jq -r '.childId // .workItemId // .taskId // empty')
  task=$(printf '%s' "$child" | jq -r '.taskId // .childId // .workItemId // empty')
  mode=$(printf '%s' "$child" | jq -r '.delivery.mode // .mode // empty')
  yolo=$(printf '%s' "$child" | jq -r '.delivery.yolo // .yolo // "off"')
  harness=$(printf '%s' "$child" | jq -r '.dispatch.harness // empty')
  model=$(printf '%s' "$child" | jq -r '.dispatch.model // empty')
  effort=$(printf '%s' "$child" | jq -r '.dispatch.effort // empty')
  backend=$(printf '%s' "$child" | jq -r '.dispatch.backend // empty')
  fm_cycle_identity "$task" || { fail "child has invalid task identity"; return 1; }
  fm_cycle_identity "$child_key" || { fail "child $task has invalid child identity"; return 1; }
  case "$mode" in no-mistakes|direct-PR|local-only) ;; *) fail "child $task has no explicit delivery mode"; return 1;; esac
  case "$yolo" in on|off) ;; *) fail "child $task has invalid yolo posture"; return 1;; esac
  validate_child_binding "$child" || return 1
  # The primary-liaison ingress is itself durable.  This record is the
  # FirstMate backlog handoff consumed by the supervision cycle; it separates
  # wake consumption from provider resolution and survives a primary restart.
  backlog="$FM_CYCLE_LIAISON/primary-backlog/$child_key.json"
  if [ ! -f "$backlog" ]; then
    fm_cycle_write "$backlog" "$(printf '%s' "$child" | jq -c --arg executionId "$execution" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '. + {executionId:$executionId,state:"queued",queuedAt:$at,owner:"firstmate-primary-liaison"}')" || return 1
  fi
  mark_child "$child_key" dispatching || return 1
  out="$FM_CYCLE_LIAISON/$task.stdout"; err="$FM_CYCLE_LIAISON/$task.stderr"
  local -a args=("$task" "$PROJECTS/$project" --mode "$mode" --yolo "$yolo")
  [ -n "$harness" ] && args+=(--harness "$harness")
  [ -n "$model" ] && args+=(--model "$model")
  [ -n "$effort" ] && args+=(--effort "$effort")
  [ -n "$backend" ] && args+=(--backend "$backend")
  case $- in *e*) errexit=1 ;; esac
  set +e
  FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" FM_DATA_OVERRIDE="$DATA" FM_PROJECTS_OVERRIDE="$PROJECTS" \
    "$FM_SPAWN_BIN" "${args[@]}" >"$out" 2>"$err"
  rc=$?
  if [ "$errexit" -eq 1 ]; then set -e; fi
  if [ "$rc" -eq 0 ]; then
    mark_child "$child_key" delegated || return 1
    # shellcheck disable=SC2016 # jq owns every $ in these filters; the shell must not expand them.
    fm_cycle_update "$backlog" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.state="delegated" | .delegatedAt=$at' || return 1
    # shellcheck disable=SC2016 # jq owns every $ in these filters; the shell must not expand them.
    fm_cycle_update "$child_file" --arg task "$task" --arg execution "$execution" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg output "$(cat "$out" 2>/dev/null || true)" \
      '. + {executionId:$execution,taskId:$task,state:"delegated",delegatedAt:$at,spawnOutput:$output}' || return 1
    return 0
  fi
  mark_child "$child_key" queued "spawn failed (exit $rc): $(tr '\n' ' ' < "$err" | cut -c1-500)" || true
  return 1
}

process_group() {
  local group_file=$1 group id lease state child_file child task child_id result=0
  group=$(cat "$group_file") || return 1
  id=$(printf '%s' "$group" | jq -r '.executionId // empty')
  state=$(printf '%s' "$group" | jq -r '.state // empty')
  case "$state" in delegated|accepted) ;; *) return 0;; esac
  # This is the durable primary-liaison transition.  It is written before the
  # first child invocation so a restart can prove Scotty, rather than Captain's
  # Log, owned the fan-out even when the provider call is interrupted.
  if [ ! -f "$FM_CYCLE_LIAISON/transitions/$id.delegating.json" ]; then
    fm_cycle_write "$FM_CYCLE_LIAISON/transitions/$id.delegating.json" \
      "$(jq -cn --arg executionId "$id" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{schemaVersion:"fm-scotty-delegation-transition.v1",executionId:$executionId,owner:"firstmate-primary-liaison",state:"delegating",at:$at}')" || return 1
  fi
  lease=$(printf '%s' "$group" | jq -r '.leaseExpiresAt // empty')
  if fm_cycle_lease_expired "$lease"; then
    fm_cycle_update "$group_file" '.leaseState="expired" | .state="lease_expired"' || return 1
    return 0
  fi
  while IFS= read -r child; do
    child_id=$(printf '%s' "$child" | jq -r '.childId // .workItemId // .taskId // empty')
    task=$(printf '%s' "$child" | jq -r '.taskId // .childId // .workItemId // empty')
    child_file=$(fm_cycle_child_path "$child_id") || { fail "child has invalid identity in execution group $id"; result=1; continue; }
    [ -f "$child_file" ] || fm_cycle_write "$child_file" "$(printf '%s' "$child" | jq -c --arg executionId "$id" '. + {executionId:$executionId,state:"queued"}')" || { result=1; continue; }
    child=$(cat "$child_file") || { result=1; continue; }
    case "$(printf '%s' "$child" | jq -r '.state // "queued"')" in
      delegated|paused) continue ;;
      dispatching)
        [ -f "$STATE/$task.meta" ] && { mark_child "$child_id" delegated; continue; }
        mark_child "$child_id" queued "recovered after interrupted spawn" || { result=1; continue; } ;;
    esac
    dispatch_child "$id" "$child_file" || result=1
  done < <(printf '%s' "$group" | jq -c '.children[]? | select(type == "object")')
  if [ "$result" -eq 0 ]; then
    fm_cycle_write "$FM_CYCLE_LIAISON/transitions/$id.delegated.json" \
      "$(jq -cn --arg executionId "$id" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{schemaVersion:"fm-scotty-delegation-transition.v1",executionId:$executionId,owner:"firstmate-primary-liaison",state:"delegated",at:$at}')" || result=1
  fi
  return "$result"
}

run_once() {
  local wakes groups rc=0
  fm_cycle_init || { json_error durable_store "execution store unavailable"; return 2; }
  wakes=$(take_execution_wakes) || { json_error queue_unavailable "cannot consume Scotty notification queue"; return 2; }
  if [ -n "$wakes" ]; then printf '%s\n' "$wakes" > "$FM_CYCLE_LIAISON/last-wakes"; fi
  for groups in "$FM_CYCLE_GROUPS"/*.json; do
    [ -f "$groups" ] || continue
    process_group "$groups" || rc=1
  done
  jq -cn --arg state "$( [ "$rc" -eq 0 ] && echo delegated || echo partial )" --arg wakes "$(printf '%s\n' "$wakes" | awk 'NF{n++} END{print n+0}')" \
    '{accepted:true,protocolVersion:"fm-bridge.v2",operation:"scottyDelegation",state:$state,consumedWakeCount:($wakes|tonumber)}'
  return "$rc"
}

case "${1:---once}" in
  --once|--drain) claim_liaison_lock || { json_error liaison_busy "another Scotty liaison is dispatching"; exit 2; }; trap release_liaison_lock EXIT; run_once ;;
  *) printf '%s\n' 'usage: fm-scotty-liaison.sh [--once|--drain]' >&2; exit 2 ;;
esac
