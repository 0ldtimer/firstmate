#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "$TMP/bin" "$TMP/home"
cat > "$TMP/bin/codex" <<'SH'
#!/usr/bin/env bash
set -u
case "$FM_CODEX_SESSION_TOKEN" in
  *[!0-9a-f]*|'') exit 10 ;;
esac
[ "${#FM_CODEX_SESSION_TOKEN}" -eq 32 ] || exit 11
printf '%s\n' "$FM_CODEX_SESSION_TOKEN" > "$FM_HOME/token-seen"
printf '%s\n' "$FM_HARNESS_OWNER_PID" > "$FM_HOME/pid-seen"
printf '%s\n' "$*" > "$FM_HOME/args-seen"
"$FM_TEST_ROOT/bin/fm-lock.sh"
SH
chmod +x "$TMP/bin/codex"

FM_TEST_ROOT="$ROOT" FM_HOME="$TMP/home" FM_CODEX_BIN="$TMP/bin/codex" PATH="/usr/bin:/bin" \
  "$ROOT/bin/fm-primary-codex.sh" >/dev/null

[ -s "$TMP/home/token-seen" ] || fail "launcher did not pass a session token"
[ -s "$TMP/home/pid-seen" ] || fail "launcher did not pass its owner PID"
grep -Fq -- "--add-dir $TMP/home" "$TMP/home/args-seen" || fail "launcher did not grant access to FM_HOME"
[ ! -e "$TMP/home/state/.lock" ] || fail "launcher did not release the PID lock on exit"
[ ! -e "$TMP/home/state/.lock-token" ] || fail "launcher did not release the token lock on exit"
[ ! -e "$TMP/home/state/.lock-claim" ] || fail "launcher did not release the atomic claim on exit"

echo "PASS: Codex launcher propagates ownership and cleans up on exit"
