#!/usr/bin/env bash
# tests/fm-codex-fleet-lock.test.sh - behavior tests for the maintained fork's
# Codex fleet-lock ownership in bin/fm-lock.sh and bin/fm-session-lock-lib.sh.
#
# A sandboxed Codex session proves ownership with FM_CODEX_SESSION_TOKEN plus
# the launcher PID in FM_HARNESS_OWNER_PID instead of process ancestry, so none
# of this is reachable from the upstream ancestry tests in
# tests/fm-session-lock-ancestry.test.sh.
#
# Coverage:
#   - acquire, contention, and release with no process visibility at all
#   - the shared ownership predicate honors the token, so every consumer
#     (startup network sweeps, session-start re-emit) sees the Codex session as
#     the lock owner rather than silently skipping its work
#   - malformed tokens and launcher PIDs fail closed and create no lock
#   - a recorded launcher PID reused by an unrelated process is stale, not a
#     permanent read-only wedge
#   - release is serialized by the same claim lock the acquire path takes
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LOCK="$ROOT/bin/fm-lock.sh"
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-codex-fleet-lock-tests)
TOKEN=0123456789abcdef0123456789abcdef
OTHER_TOKEN=fedcba9876543210fedcba9876543210

# new_home <name>: an empty FM_HOME with state/ plus its own fakebin.
# Echoes "<home>|<fakebin>".
new_home() {
  local name=$1 home fakebin
  home="$TMP_ROOT/$name/home"
  fakebin="$TMP_ROOT/$name/fakebin"
  mkdir -p "$home/state" "$fakebin"
  printf '%s|%s\n' "$home" "$fakebin"
}

# blind_ps <fakebin>: a `ps` that cannot report anything, standing in for the
# Codex sandbox whose process table is invisible. The token contract exists
# precisely for this case.
blind_ps() {
  cat > "$1/ps" <<'SH'
#!/usr/bin/env bash
exit 126
SH
  chmod +x "$1/ps"
}

# run_lock <home> <path> <token> <owner-pid> [args...]
run_lock() {
  local home=$1 path=$2 token=$3 owner=$4
  shift 4
  env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    CODEX_SHELL=1 FM_CODEX_SESSION_TOKEN="$token" FM_HARNESS_OWNER_PID="$owner" \
    FM_HOME="$home" PATH="$path" "$LOCK" "$@" 2>&1
}

# owns_lock <home> <token> <owner-pid>: the shared predicate every non-lock
# consumer routes through.
owns_lock() {
  local home=$1 token=$2 owner=$3
  # shellcheck disable=SC2016 # Positional parameters expand in the spawned shell, not here.
  env -u CLAUDECODE FM_CODEX_SESSION_TOKEN="$token" FM_HARNESS_OWNER_PID="$owner" \
    bash -c '. "$1/bin/fm-session-lock-lib.sh"; fm_session_lock_owned_by_self "$2"' \
    fm-codex-fleet-lock "$ROOT" "$home/state" >/dev/null 2>&1
}

# spawn_idle: a live process that is neither a harness nor a Codex launcher.
# Its output is detached so a `$(spawn_idle)` capture closes immediately
# rather than waiting out the sleep on the inherited command-substitution pipe.
spawn_idle() {
  sleep 300 >/dev/null 2>&1 &
  printf '%s\n' "$!"
}

reap() {
  local pid=$1
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

test_codex_token_owns_and_releases_without_process_visibility() {
  local rec home fakebin path out status other_pid
  rec=$(new_home token-owner)
  IFS='|' read -r home fakebin <<EOF
$rec
EOF
  blind_ps "$fakebin"
  path="$fakebin:$BASE_PATH"

  out=$(run_lock "$home" "$path" "$TOKEN" "$$") \
    || fail "Codex token did not acquire the lock without process visibility"
  assert_contains "$out" "lock acquired: Codex launcher pid $$" \
    "Codex acquisition did not name the launcher pid"
  [ "$(cat "$home/state/.lock")" = "$$" ] || fail "fleet lock did not record the launcher pid"
  [ "$(cat "$home/state/.lock-token")" = "$TOKEN" ] || fail "fleet lock did not record the Codex token"
  assert_absent "$home/state/.lock.acquire" "acquisition left the claim lock behind"

  owns_lock "$home" "$TOKEN" "$$" \
    || fail "the shared ownership predicate did not honor the owning Codex token"
  owns_lock "$home" "$OTHER_TOKEN" "$$" \
    && fail "the shared ownership predicate honored a token that does not own the lock"

  # A second Codex session, with its own live launcher, must be refused.
  other_pid=$(spawn_idle)
  status=0
  out=$(run_lock "$home" "$path" "$OTHER_TOKEN" "$other_pid") || status=$?
  reap "$other_pid"
  expect_code 1 "$status" "a second Codex session must be refused while the holder is live"
  assert_contains "$out" "another live firstmate session holds the lock" \
    "second Codex session did not report contention"
  [ "$(cat "$home/state/.lock-token")" = "$TOKEN" ] || fail "a refused session rewrote the token lock"

  status=0
  out=$(run_lock "$home" "$path" "$OTHER_TOKEN" "$$" release) || status=$?
  expect_code 1 "$status" "a different Codex token must not release the lock"
  assert_contains "$out" "Codex session token does not own the fleet lock" \
    "a foreign token release was not diagnosed"
  assert_present "$home/state/.lock" "a foreign token removed the PID lock"

  out=$(run_lock "$home" "$path" "$TOKEN" "$$" release) \
    || fail "the owning Codex token did not release the lock"
  assert_contains "$out" "lock released: Codex launcher pid $$" "release did not name the launcher pid"
  assert_absent "$home/state/.lock" "release left the PID lock behind"
  assert_absent "$home/state/.lock-token" "release left the token behind"
  assert_absent "$home/state/.lock.acquire" "release left the acquisition claim lock behind"

  pass "Codex token ownership acquires, refuses, and releases without process visibility"
}

test_malformed_codex_ownership_fails_closed() {
  local rec home fakebin path out status owner token
  rec=$(new_home malformed-ownership)
  IFS='|' read -r home fakebin <<EOF
$rec
EOF
  blind_ps "$fakebin"
  path="$fakebin:$BASE_PATH"

  for owner in '' not-a-pid 12x 0 1; do
    status=0
    out=$(run_lock "$home" "$path" "$TOKEN" "$owner") || status=$?
    expect_code 1 "$status" "launcher PID '$owner' must fail acquisition"
    assert_contains "$out" "Codex launcher PID" "launcher PID '$owner' was not diagnosed"
    assert_absent "$home/state/.lock" "launcher PID '$owner' created a fleet lock"
  done

  for token in 0123456789abcdef0123456789abcde 0123456789abcdef0123456789abcdeff \
    0123456789abcdef0123456789abcdeZ; do
    status=0
    out=$(run_lock "$home" "$path" "$token" "$$") || status=$?
    expect_code 1 "$status" "token '$token' must fail acquisition"
    assert_contains "$out" "invalid Codex session token" "token '$token' was not diagnosed"
    assert_absent "$home/state/.lock" "token '$token' created a fleet lock"
  done

  pass "malformed Codex tokens and launcher PIDs fail closed"
}

test_reused_launcher_pid_is_stale_not_a_permanent_wedge() {
  local rec home fakebin out idle_pid
  rec=$(new_home reused-launcher-pid)
  IFS='|' read -r home fakebin <<EOF
$rec
EOF
  # A Codex session that died without releasing, whose recorded launcher pid has
  # since been inherited by an unrelated long-lived process. Only the original
  # token may release, so treating any live pid as proof of a live launcher
  # would force every later session read-only with no automated recovery.
  idle_pid=$(spawn_idle)
  printf '%s\n' "$idle_pid" > "$home/state/.lock"
  printf '%s\n' "$OTHER_TOKEN" > "$home/state/.lock-token"

  out=$(env -u CLAUDECODE -u FM_CODEX_SESSION_TOKEN -u FM_HARNESS_OWNER_PID \
    FM_HOME="$home" PATH="$BASE_PATH" "$LOCK" status 2>&1)
  assert_contains "$out" "lock: stale" "a reused launcher pid was reported as a live Codex holder"

  out=$(run_lock "$home" "$BASE_PATH" "$TOKEN" "$$") \
    || fail "a new Codex session could not take over a stale token lock"
  assert_contains "$out" "lock acquired: Codex launcher pid $$" \
    "takeover of a stale token lock did not record the new launcher"
  [ "$(cat "$home/state/.lock-token")" = "$TOKEN" ] || fail "takeover did not replace the stale token"
  reap "$idle_pid"

  pass "a reused launcher pid leaves the lock stale rather than permanently wedged"
}

test_release_is_serialized_by_the_acquisition_claim_lock() {
  local rec home fakebin path out status holder_pid ownerdir
  rec=$(new_home release-claim-lock)
  IFS='|' read -r home fakebin <<EOF
$rec
EOF
  blind_ps "$fakebin"
  path="$fakebin:$BASE_PATH"

  run_lock "$home" "$path" "$TOKEN" "$$" >/dev/null \
    || fail "Codex token did not acquire the lock"

  # Stand in for a concurrent acquirer inside the claim-lock critical section:
  # release must not read, verify, and delete the lock files beside it.
  holder_pid=$(spawn_idle)
  ownerdir="$home/state/.lock.acquire.owner.fixture"
  mkdir -p "$ownerdir"
  printf '%s\n' "$holder_pid" > "$ownerdir/pid"
  ln -s "$ownerdir" "$home/state/.lock.acquire"

  status=0
  out=$(run_lock "$home" "$path" "$TOKEN" "$$" release) || status=$?
  expect_code 1 "$status" "release must fail rather than race a held acquisition claim"
  assert_contains "$out" "fleet-lock claim" "a contended release was not diagnosed"
  assert_present "$home/state/.lock" "a contended release removed the PID lock"
  assert_present "$home/state/.lock-token" "a contended release removed the token lock"

  rm -f "$home/state/.lock.acquire"
  rm -rf "$ownerdir"
  reap "$holder_pid"

  out=$(run_lock "$home" "$path" "$TOKEN" "$$" release) \
    || fail "release did not succeed once the claim lock was free"
  assert_absent "$home/state/.lock" "release left the PID lock behind"
  assert_absent "$home/state/.lock.acquire" "release left the acquisition claim lock behind"

  pass "Codex release takes the same claim lock the acquire path serializes on"
}

test_codex_token_owns_and_releases_without_process_visibility
test_malformed_codex_ownership_fails_closed
test_reused_launcher_pid_is_stale_not_a_permanent_wedge
test_release_is_serialized_by_the_acquisition_claim_lock
