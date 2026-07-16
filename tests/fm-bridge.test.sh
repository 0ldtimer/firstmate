#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BRIDGE="$ROOT/bin/fm-bridge.sh"
TMP_ROOT=$(fm_test_tmproot fm-bridge)
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/projects" "$HOME_DIR/config"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

snapshot=$(printf '{"protocolVersion":"fm-bridge.v1","operation":"snapshot"}' | FM_HOME="$HOME_DIR" "$BRIDGE")
printf '%s' "$snapshot" | jq -e '
  .protocolVersion == "fm-bridge.v1"
  and (.snapshotRevision | length > 10)
  and .freshness == "fresh"
  and (.tasks | length == 0)
' >/dev/null || fail "empty Bridge snapshot contract is invalid"
pass "Bridge snapshot is versioned and read-only"

set +e
bad=$(printf '{"protocolVersion":"future","operation":"snapshot"}' | FM_HOME="$HOME_DIR" "$BRIDGE")
status=$?
set -e
[ "$status" -ne 0 ] || fail "unsupported versions must fail"
printf '%s' "$bad" | jq -e '.error.code == "unsupported_version"' >/dev/null ||
  fail "unsupported version must return a typed error"
pass "Bridge rejects unsupported versions"

set +e
malformed=$(printf 'not-json' | FM_HOME="$HOME_DIR" "$BRIDGE")
status=$?
set -e
[ "$status" -ne 0 ] || fail "malformed JSON must fail"
printf '%s' "$malformed" | jq -e '.error.code == "malformed_request"' >/dev/null ||
  fail "malformed JSON must return a typed error"
pass "Bridge rejects malformed requests"

mkdir -p "$HOME_DIR/projects/task-one"
fm_write_meta "$HOME_DIR/state/task-one.meta" \
  "window=firstmate:fm-task-one" \
  "worktree=$HOME_DIR/projects/task-one" \
  "project=alpha" \
  "harness=codex" \
  "kind=ship" \
  "mode=ship"
snapshot=$(printf '{"protocolVersion":"fm-bridge.v1","operation":"snapshot"}' | FM_HOME="$HOME_DIR" "$BRIDGE")
revision=$(printf '%s' "$snapshot" | jq -r '.tasks[] | select(.id=="task-one") | .taskRevision')
request=$(jq -n --arg revision "$revision" '{
  protocolVersion:"fm-bridge.v1",operation:"command",
  command:{
    protocolVersion:"fm-bridge.v1",commandId:"command-1",action:"defer",
    taskId:"task-one",expectedRevision:$revision
  }
}')
first=$(printf '%s' "$request" | FM_HOME="$HOME_DIR" "$BRIDGE")
second=$(printf '%s' "$request" | FM_HOME="$HOME_DIR" "$BRIDGE")
printf '%s' "$first" | jq -e '.accepted == true' >/dev/null ||
  fail "current revision feedback must be accepted"
printf '%s' "$second" | jq -e '.accepted == true and .replayed == true' >/dev/null ||
  fail "identical command ID must replay the original outcome"
pass "Bridge commands are revisioned and idempotent"

set +e
stale=$(printf '%s' "$request" | jq '.command.commandId="command-2" | .command.expectedRevision="stale"' |
  FM_HOME="$HOME_DIR" "$BRIDGE")
status=$?
set -e
[ "$status" -ne 0 ] || fail "stale revisions must fail"
printf '%s' "$stale" | jq -e '.error.code == "stale_revision"' >/dev/null ||
  fail "stale revision must return a typed error"
pass "Bridge rejects stale commands without mutation"

set +e
conflict=$(printf '%s' "$request" | jq '.command.extra="Different request"' |
  FM_HOME="$HOME_DIR" "$BRIDGE")
status=$?
set -e
[ "$status" -ne 0 ] || fail "command ID reuse with a different digest must fail"
printf '%s' "$conflict" | jq -e '.error.code == "command_id_conflict"' >/dev/null ||
  fail "command ID conflict must return a typed error"
pass "Bridge binds command IDs to request digests"

set +e
unsafe=$(printf '%s' "$request" | jq '.command.commandId="../../config/escape"' |
  FM_HOME="$HOME_DIR" "$BRIDGE")
status=$?
set -e
[ "$status" -ne 0 ] || fail "unsafe command IDs must fail"
printf '%s' "$unsafe" | jq -e '.error.code == "malformed_command"' >/dev/null ||
  fail "unsafe command ID must return a typed error"
pass "Bridge rejects command ID path traversal"
