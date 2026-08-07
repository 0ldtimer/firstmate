#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

TMP=$(fm_test_tmproot fm-cycle-delegation)
HOME_DIR="$TMP/home"
PROJECTS="$HOME_DIR/projects"
STORE="$HOME_DIR/data/engineering/execution"
GROUP="$STORE/groups/execution:delegation-test.json"
mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$PROJECTS/demo"
fm_git_identity
git -C "$PROJECTS/demo" init -q
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
liaison() { FM_HOME="$HOME_DIR" FM_DATA_OVERRIDE="$HOME_DIR/data" FM_PROJECTS_OVERRIDE="$PROJECTS" FM_SCOTTY_SPAWN_BIN="$SPAWN" "$ROOT/bin/fm-scotty-liaison.sh" "$@"; }
spawn_count() { wc -l < "$HOME_DIR/state/spawn.log" | tr -d ' '; }

group=$(jq -cn --arg base "$BASE" '{protocolVersion:"fm-bridge.v2",operation:"acceptExecutionGroup",schemaVersion:"cycle-execution.v1",executionId:"execution:delegation-test",attemptId:"attempt:1",manifestDigest:"sha256:delegation-test",binding:{workspaceId:"workspace",cycleId:"cycle"},children:[{childId:"child-build",taskId:"task-build",kind:"build",project:"demo",repository:{project:"demo",baseRevision:$base},delivery:{mode:"local-only",yolo:"off"}}]}')
call "$group" >/dev/null || fail "execution group was not accepted"
call '{"protocolVersion":"fm-bridge.v2","operation":"delegateExecutionGroup","executionId":"execution:delegation-test"}' >/dev/null ||
  fail "delegation was refused"
liaison --once >/dev/null || fail "the liaison refused its first drain"

[ "$(spawn_count)" = 1 ] || fail "expected one FirstMate spawn, saw $(spawn_count)"
jq -e '.state == "delegated" and .taskId == "task-build"' "$STORE/children/child-build.json" >/dev/null ||
  fail "the child record is not durably delegated"
jq -e '.owner == "firstmate-primary-liaison" and .state == "delegated"' "$STORE/liaison/primary-backlog/child-build.json" >/dev/null ||
  fail "the primary-liaison backlog record is missing"
[ ! -s "$HOME_DIR/state/.wake-queue" ] || fail "Scotty wake was not consumed"
liaison --once >/dev/null || fail "the liaison refused its replay drain"
[ "$(spawn_count)" = 1 ] || fail "restart replay spawned a duplicate"

# A dispatch killed mid-fan-out leaves a reclaimable lock, not a permanent refusal.
bash -c 'exit 0' & dead=$!
wait "$dead" 2>/dev/null || true
stale_owner="$STORE/liaison/dispatch.lock.owner.stale"
mkdir -p "$stale_owner"
printf '%s\n' "$dead" > "$stale_owner/pid"
ln -s "$stale_owner" "$STORE/liaison/dispatch.lock"
reclaimed=$(liaison --once) || fail "a stale dispatch lock wedged the liaison"
printf '%s' "$reclaimed" | jq -e '.accepted == true' >/dev/null ||
  fail "a stale dispatch lock was reported as liaison_busy"$'\n'"$reclaimed"
[ ! -e "$STORE/liaison/dispatch.lock" ] && [ ! -L "$STORE/liaison/dispatch.lock" ] ||
  fail "the dispatch lock was not released"

# The acceptance lease never outlives the bound cycle, and a cycle that has
# already ended is not delegated at all.
clamped=$(call '{"protocolVersion":"fm-bridge.v2","operation":"acceptExecutionGroup","schemaVersion":"cycle-execution.v1","executionId":"execution:ended-cycle","attemptId":"attempt:1","manifestDigest":"sha256:ended-cycle","binding":{"workspaceId":"workspace","cycleId":"cycle","cycleEndsAt":"2000-01-01T00:00:00Z"},"children":[]}')
[ "$(printf '%s' "$clamped" | jq -r '.executionGroup.leaseExpiresAt')" = "2000-01-01T00:00:00Z" ] ||
  fail "acceptance did not clamp the lease to binding.cycleEndsAt"$'\n'"$clamped"
ended=$(call '{"protocolVersion":"fm-bridge.v2","operation":"delegateExecutionGroup","executionId":"execution:ended-cycle"}' || true)
printf '%s' "$ended" | jq -e '.accepted == false and .error.code == "lease_expired"' >/dev/null ||
  fail "a group whose cycle already ended still held a fan-out lease"$'\n'"$ended"
far=$(call '{"protocolVersion":"fm-bridge.v2","operation":"acceptExecutionGroup","schemaVersion":"cycle-execution.v1","executionId":"execution:long-cycle","attemptId":"attempt:1","manifestDigest":"sha256:long-cycle","binding":{"workspaceId":"workspace","cycleId":"cycle","cycleEndsAt":"2999-01-01T00:00:00Z"},"children":[]}')
printf '%s' "$far" | jq -e '.executionGroup.leaseExpiresAt < "2999-01-01T00:00:00Z"' >/dev/null ||
  fail "a distant cycle end extended the lease past its 24-hour bound"$'\n'"$far"

# A stale lease quiesces new children but leaves the durable child record intact.
jq -c '.leaseExpiresAt="2000-01-01T00:00:00Z" | .state="delegated"' "$GROUP" > "$TMP/group" && mv "$TMP/group" "$GROUP"
liaison --once >/dev/null || fail "the liaison failed on an expired lease"
jq -e '.state == "lease_expired"' "$GROUP" >/dev/null || fail "the expired lease was not recorded"
jq -e '.state == "delegated"' "$STORE/children/child-build.json" >/dev/null ||
  fail "an expired lease tore down an existing child"

# A lease this boundary cannot read is spent rather than unbounded.
jq -c '.leaseExpiresAt="whenever" | .state="delegated"' "$GROUP" > "$TMP/group" && mv "$TMP/group" "$GROUP"
liaison --once >/dev/null || fail "the liaison failed on an unreadable lease"
jq -e '.state == "lease_expired"' "$GROUP" >/dev/null || fail "an unreadable lease was treated as unbounded"

# Renewal is cursor-bound and restores only the lease, not a replacement group.
renew=$(call '{"protocolVersion":"fm-bridge.v2","operation":"renewExecutionLease","executionId":"execution:delegation-test","executionChangeCursor":"shapeup-cursor-2"}')
printf '%s' "$renew" | jq -e '.accepted == true and .executionChangeCursor == "shapeup-cursor-2"' >/dev/null ||
  fail "lease renewal was refused"$'\n'"$renew"
jq -e '.executionChangeCursor == "shapeup-cursor-2" and .leaseState == "active"' "$GROUP" >/dev/null ||
  fail "the renewed lease is not durable"

# A removal is paused for judgment and an addition remains under the same group.
parent=$(jq -r '.groupDigest' "$GROUP")
amend=$(jq -cn --arg parent "$parent" --arg base "$BASE" '{protocolVersion:"fm-bridge.v2",operation:"amendExecutionGroup",executionId:"execution:delegation-test",amendmentSequence:1,parentGroupDigest:$parent,addedChildren:[{childId:"child-issue",taskId:"task-issue",kind:"issue",project:"demo",repository:{project:"demo",baseRevision:$base},delivery:{mode:"local-only",yolo:"off"}}],removedChildren:[{childId:"child-build"}]}')
amended=$(call "$amend")
printf '%s' "$amended" | jq -e '.accepted == true and .replayed == false and (.groupDigest|length) == 64' >/dev/null ||
  fail "the amendment was refused"$'\n'"$amended"
jq -e '.state == "paused" and .pauseReason == "removed_by_amendment"' "$STORE/children/child-build.json" >/dev/null ||
  fail "a removed child was not paused for judgment"
jq -e '.state == "queued" and .amendmentSequence == 1' "$STORE/children/child-issue.json" >/dev/null ||
  fail "an added child was not queued under the same group"

# The amendment chains the group digest, so the same parent cannot be reused.
chained=$(printf '%s' "$amended" | jq -r '.groupDigest')
[ "$(jq -r '.groupDigest' "$GROUP")" = "$chained" ] || fail "the chained group digest is not durable"
[ "$(jq -r '.previousGroupDigest' "$GROUP")" = "$parent" ] || fail "the prior group digest was not retained"
replayed=$(call "$amend")
printf '%s' "$replayed" | jq -e '.accepted == true and .replayed == true' >/dev/null ||
  fail "a redelivered amendment was not replayed idempotently"$'\n'"$replayed"
stale=$(call "$(jq -cn --arg parent "$parent" '{protocolVersion:"fm-bridge.v2",operation:"amendExecutionGroup",executionId:"execution:delegation-test",amendmentSequence:2,parentGroupDigest:$parent,addedChildren:[]}')" || true)
printf '%s' "$stale" | jq -e '.accepted == false and .error.code == "parent_digest_mismatch"' >/dev/null ||
  fail "an amendment validating against a superseded digest was accepted"$'\n'"$stale"

# Order is enforced: a sequence that does not advance is refused.
ordered=$(call "$(jq -cn --arg parent "$chained" '{protocolVersion:"fm-bridge.v2",operation:"amendExecutionGroup",executionId:"execution:delegation-test",amendmentSequence:5,parentGroupDigest:$parent,addedChildren:[]}')")
printf '%s' "$ordered" | jq -e '.accepted == true' >/dev/null || fail "amendment 5 was refused"$'\n'"$ordered"
rewind=$(call "$(jq -cn --arg parent "$(printf '%s' "$ordered" | jq -r '.groupDigest')" '{protocolVersion:"fm-bridge.v2",operation:"amendExecutionGroup",executionId:"execution:delegation-test",amendmentSequence:2,parentGroupDigest:$parent,addedChildren:[]}')" || true)
printf '%s' "$rewind" | jq -e '.accepted == false and .error.code == "amendment_out_of_order"' >/dev/null ||
  fail "an out-of-order amendment silently rewound the recorded sequence"$'\n'"$rewind"
jq -e '.amendmentSequence == 5 and (.amendments|length) == 2' "$GROUP" >/dev/null ||
  fail "the amendment index does not reflect the accepted amendments in order"

# A child element that is not an object is refused at acceptance rather than
# taking the liaison down mid-fan-out.
malformed=$(call '{"protocolVersion":"fm-bridge.v2","operation":"acceptExecutionGroup","schemaVersion":"cycle-execution.v1","executionId":"execution:bad-children","attemptId":"attempt:1","manifestDigest":"sha256:bad","binding":{"workspaceId":"workspace","cycleId":"cycle"},"children":[{"childId":"child-a"},"child-b"]}' || true)
printf '%s' "$malformed" | jq -e '.accepted == false and .error.code == "malformed_group"' >/dev/null ||
  fail "a non-object child descriptor was accepted"$'\n'"$malformed"

pass "Scotty liaison consumes durable wakes, reclaims a stale dispatch lock, honours UTC leases, and records ordered digest-chained amendments"
