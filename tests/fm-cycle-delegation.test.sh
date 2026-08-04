#!/usr/bin/env bash
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
HOME_DIR="$TMP/home"
PROJECTS="$HOME_DIR/projects"
mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$PROJECTS/demo"
git -C "$PROJECTS/demo" init -q
git -C "$PROJECTS/demo" config user.email test@example.invalid
git -C "$PROJECTS/demo" config user.name test
printf 'base\n' > "$PROJECTS/demo/README"
git -C "$PROJECTS/demo" add README && git -C "$PROJECTS/demo" commit -qm base
BASE=$(git -C "$PROJECTS/demo" rev-parse HEAD)
printf '%s\n' '- demo - trusted test project (added 2026-08-04)' > "$HOME_DIR/data/projects.md"

SPAWN="$TMP/spawn.sh"
cat > "$SPAWN" <<'EOF'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_HOME/state/spawn.log"
printf 'endpoint\n' > "$FM_HOME/state/$1.meta"
EOF
chmod +x "$SPAWN"

call() { printf '%s' "$1" | FM_HOME="$HOME_DIR" FM_DATA_OVERRIDE="$HOME_DIR/data" FM_PROJECTS_OVERRIDE="$PROJECTS" "$ROOT/bin/fm-bridge.sh"; }
group=$(jq -cn --arg base "$BASE" '{protocolVersion:"fm-bridge.v2",operation:"acceptExecutionGroup",schemaVersion:"cycle-execution.v1",executionId:"execution:delegation-test",attemptId:"attempt:1",manifestDigest:"sha256:delegation-test",binding:{workspaceId:"workspace",cycleId:"cycle"},children:[{childId:"child-build",taskId:"task-build",kind:"build",project:"demo",repository:{project:"demo",baseRevision:$base},delivery:{mode:"local-only",yolo:"off"}}]}')
call "$group" >/dev/null
call '{"protocolVersion":"fm-bridge.v2","operation":"delegateExecutionGroup","executionId":"execution:delegation-test"}' >/dev/null
FM_HOME="$HOME_DIR" FM_DATA_OVERRIDE="$HOME_DIR/data" FM_PROJECTS_OVERRIDE="$PROJECTS" FM_SCOTTY_SPAWN_BIN="$SPAWN" "$ROOT/bin/fm-scotty-liaison.sh" --once >/dev/null

[ "$(wc -l < "$HOME_DIR/state/spawn.log" | tr -d ' ')" = 1 ] || { echo 'expected one FirstMate spawn' >&2; exit 1; }
jq -e '.state == "delegated" and .taskId == "task-build"' "$HOME_DIR/data/engineering/execution/children/child-build.json" >/dev/null
jq -e '.owner == "firstmate-primary-liaison" and .state == "delegated"' "$HOME_DIR/data/engineering/execution/liaison/primary-backlog/child-build.json" >/dev/null
[ ! -s "$HOME_DIR/state/.wake-queue" ] || { echo 'Scotty wake was not consumed' >&2; exit 1; }
FM_HOME="$HOME_DIR" FM_DATA_OVERRIDE="$HOME_DIR/data" FM_PROJECTS_OVERRIDE="$PROJECTS" FM_SCOTTY_SPAWN_BIN="$SPAWN" "$ROOT/bin/fm-scotty-liaison.sh" --once >/dev/null
[ "$(wc -l < "$HOME_DIR/state/spawn.log" | tr -d ' ')" = 1 ] || { echo 'restart replay spawned a duplicate' >&2; exit 1; }

# A stale lease quiesces new children but leaves the durable child record intact.
jq -c '.leaseExpiresAt="2000-01-01T00:00:00Z" | .state="delegated"' "$HOME_DIR/data/engineering/execution/groups/execution:delegation-test.json" > "$TMP/group" \
  && mv "$TMP/group" "$HOME_DIR/data/engineering/execution/groups/execution:delegation-test.json"
FM_HOME="$HOME_DIR" FM_DATA_OVERRIDE="$HOME_DIR/data" FM_PROJECTS_OVERRIDE="$PROJECTS" FM_SCOTTY_SPAWN_BIN="$SPAWN" "$ROOT/bin/fm-scotty-liaison.sh" --once >/dev/null
jq -e '.state == "lease_expired"' "$HOME_DIR/data/engineering/execution/groups/execution:delegation-test.json" >/dev/null

# Renewal is cursor-bound and restores only the lease, not a replacement group.
renew=$(call '{"protocolVersion":"fm-bridge.v2","operation":"renewExecutionLease","executionId":"execution:delegation-test","executionChangeCursor":"shapeup-cursor-2"}')
jq -e '.accepted == true and .executionChangeCursor == "shapeup-cursor-2"' <<<"$renew" >/dev/null

# A removal is paused for judgment and an addition remains under the same group.
parent=$(jq -r '.groupDigest' "$HOME_DIR/data/engineering/execution/groups/execution:delegation-test.json")
amend=$(jq -cn --arg parent "$parent" --arg base "$BASE" '{protocolVersion:"fm-bridge.v2",operation:"amendExecutionGroup",executionId:"execution:delegation-test",amendmentSequence:1,parentGroupDigest:$parent,addedChildren:[{childId:"child-issue",taskId:"task-issue",kind:"issue",project:"demo",repository:{project:"demo",baseRevision:$base},delivery:{mode:"local-only",yolo:"off"}}],removedChildren:[{childId:"child-build"}]}')
amended=$(call "$amend")
jq -e '.accepted == true and .replayed == false' <<<"$amended" >/dev/null
jq -e '.state == "paused" and .pauseReason == "removed_by_amendment"' "$HOME_DIR/data/engineering/execution/children/child-build.json" >/dev/null
jq -e '.state == "queued" and .amendmentSequence == 1' "$HOME_DIR/data/engineering/execution/children/child-issue.json" >/dev/null

printf 'ok - Scotty liaison consumes durable wakes, validates project/base bindings, delegates through fm-spawn, and recovers without duplicates\n'
