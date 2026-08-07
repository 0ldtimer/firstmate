#!/usr/bin/env bash
# Shared validation and storage helpers for FirstMate Engineering records.

fm_eng_digest() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    sha256sum | awk '{print $1}'
  fi
}

fm_eng_fail() {  # <schema> <code> <message> [record-json]
  local schema=$1 code=$2 message=$3 record=${4:-null}
  jq -cn --arg schemaVersion "$schema" --arg code "$code" --arg message "$message" \
    --argjson record "$record" '
    {accepted:false,schemaVersion:$schemaVersion,error:{code:$code,message:$message}}
    + (if $record == null then {} else {report:$record} end)
  '
}

fm_eng_valid_identity() {  # <value>
  case "$1" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  [ "${#1}" -le 128 ]
}

fm_eng_read_json() {  # <path-or-dash> [max-bytes]
  local source=$1 max=${2:-262144} value
  if [ "$source" = - ]; then
    value=$(head -c $((max + 1)))
  else
    [ -f "$source" ] || return 1
    value=$(head -c $((max + 1)) "$source")
  fi
  [ "${#value}" -le "$max" ] || return 2
  printf '%s' "$value" | jq -ce 'select(type == "object")'
}

# The credential-name vocabulary is owned once here so record scanning and pane
# redaction recognize the same names. Each entry is an ERE fragment whose letters
# are matched without regard to case.
FM_ENG_CREDENTIAL_NAMES='TOKEN SECRET PASSWORD PASSWD CREDENTIAL API[-_]?KEY ACCESS[-_]?KEY PRIVATE[-_]?KEY'

# The alternation is built once here and wrapped by each consumer, so no form has
# to parse another form's output to recover it. Every letter is spelled as an
# explicit two-case bracket instead of relying on a case-insensitivity flag, which
# awk has no portable form of and sed only carries as an extension.
fm_eng_credential_alternation() {
  local word rest letter pair out alt=''
  for word in $FM_ENG_CREDENTIAL_NAMES; do
    out=''
    rest=$word
    while [ -n "$rest" ]; do
      letter=${rest%"${rest#?}"}
      rest=${rest#?}
      case "$letter" in
        [A-Za-z])
          for pair in Aa Bb Cc Dd Ee Ff Gg Hh Ii Jj Kk Ll Mm Nn Oo Pp Qq Rr Ss Tt Uu Vv Ww Xx Yy Zz; do
            case "$pair" in
              *"$letter"*) out="${out}[$pair]"; break ;;
            esac
          done
          ;;
        *) out="$out$letter" ;;
      esac
    done
    alt="${alt}${alt:+|}$out"
  done
  printf '%s' "$alt"
}

fm_eng_credential_name_ere() {
  printf '[A-Za-z0-9_]*(%s)[A-Za-z0-9_]*' "$(fm_eng_credential_alternation)"
}

fm_eng_credential_name_regex() {
  printf '%s' "$FM_ENG_CREDENTIAL_NAMES" | LC_ALL=C tr 'A-Z ' 'a-z|'
}

# A colon is both the credential-header separator and ordinary prose punctuation,
# so the colon form requires the credential word to end the label: anything may be
# glued in front of it and only separator-delimited components may follow it.
# `apitoken`, `dbpassword`, `SERVICE_TOKEN`, `X-Api-Key`, and `aws_access_key_id`
# all qualify, while the inert plural telemetry label `tokens` does not, because a
# trailing run is glued to its word rather than separated from it.
fm_eng_credential_label_ere() {
  printf '[A-Za-z0-9_-]*(%s)([-_][A-Za-z0-9]+)*' "$(fm_eng_credential_alternation)"
}

# A credential header may be quoted or bracketed by the surrounding config or JSON
# a pane echoes, so the label boundary admits those delimiters as well as
# whitespace and the start of the line.
fm_eng_credential_label_anchor() {
  printf '%s' "[]\"',{}()[[:space:]]"
}

# Stored records are scanned for credential-named keys, known secret value
# shapes, and assignment-shaped values. The assignment shape is deliberately
# narrower than pane redaction's: prose that merely names a credential after a
# colon is ordinary Captain and crewmate language and must stay storable.
fm_eng_contains_credentials() {  # <json>
  local names
  names=$(fm_eng_credential_name_regex)
  printf '%s' "$1" | jq -e --arg names "$names" '
    . as $root
    | any(paths(scalars);
        . as $path
        | ($root | getpath($path)) as $value
        | ($value | type == "string")
          and (
            (($path[-1] | tostring | ascii_downcase) | test($names))
            or ($value | test("gh[pousr]_[A-Za-z0-9]|Bearer[[:space:]]+|BEGIN[[:space:]]+(RSA[[:space:]]+)?PRIVATE[[:space:]]+KEY"; "i"))
            or ($value | test("[A-Za-z0-9_]*(" + $names + ")[A-Za-z0-9_]*=[^[:space:]]"; "i"))
          ))
  ' >/dev/null 2>&1
}

fm_eng_canonical() {  # <json>
  printf '%s' "$1" | jq -cS .
}

# A durable record either lands whole or reports failure; callers must never
# publish an outcome the store did not accept.
fm_eng_atomic_write() {  # <path> <json>
  local path=$1 value=$2 tmp="$1.$$"
  mkdir -p "$(dirname "$path")" 2>/dev/null || return 1
  if printf '%s\n' "$value" > "$tmp" 2>/dev/null && mv "$tmp" "$path" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null || true
  return 1
}

FM_ENG_LOCK_HOST=${HOSTNAME:-$(hostname 2>/dev/null || printf 'unknown-host')}
# Held locks are tracked as array elements rather than a joined string so a home
# whose path contains a space still releases the directory it actually holds.
FM_ENG_LOCK_HELD_DIRS=()
FM_ENG_PROCESS_START_METHOD=lstart

fm_eng_lock_stale_minutes() {  # <requested>
  case "$1" in
    ''|*[!0-9]*) printf '5'; return 0 ;;
  esac
  if [ "${#1}" -le 9 ] && [ "$1" -ge 1 ]; then
    printf '%s' "$1"
  else
    printf '5'
  fi
}

# The signature is rendered in a fixed locale and timezone so the same process
# always yields the same identity whatever environment observes it. It carries
# its method so a signature produced a different way is never mistaken for a
# different process.
fm_eng_process_start_signature() {  # <pid>
  local value
  value=$(LC_ALL=C TZ=UTC ps -o lstart= -p "$1" 2>/dev/null | tr -d '[:space:]')
  [ -n "$value" ] || return 1
  printf '%s:%s' "$FM_ENG_PROCESS_START_METHOD" "$value"
}

fm_eng_lock_remove() {  # <lock-dir>
  rm -f "$1/owner" 2>/dev/null || true
  rmdir "$1" 2>/dev/null || true
}

# A lock whose recorded owner is provably gone - exited, or its pid recycled by a
# process that started later - is reclaimed at once. An owner that cannot be
# compared, including one recorded by another identity method, falls back to the
# bounded age window, so no lock can wedge forever and none is reclaimed merely
# because its identity is presented differently. A confirmed live owner is never
# reclaimed, however long it runs and whoever owns it.
fm_eng_lock_owner_state() {  # <lock-dir>
  local dir=$1 owner_host owner_pid owner_started current_started
  if [ ! -f "$dir/owner" ]; then
    printf 'unknown'
    return 0
  fi
  owner_host=$(sed -n 's/^host=//p' "$dir/owner" 2>/dev/null | head -1)
  owner_pid=$(sed -n 's/^pid=//p' "$dir/owner" 2>/dev/null | head -1)
  owner_started=$(sed -n 's/^started=//p' "$dir/owner" 2>/dev/null | head -1)
  if [ "$owner_host" != "$FM_ENG_LOCK_HOST" ]; then
    printf 'unknown'
    return 0
  fi
  case "$owner_pid" in
    ''|*[!0-9]*) printf 'unknown'; return 0 ;;
  esac
  current_started=$(fm_eng_process_start_signature "$owner_pid") || current_started=''
  if [ -z "$current_started" ]; then
    if kill -0 "$owner_pid" 2>/dev/null; then
      printf 'unknown'
    else
      printf 'dead'
    fi
    return 0
  fi
  case "$owner_started" in
    "$FM_ENG_PROCESS_START_METHOD":?*) ;;
    *) printf 'unknown'; return 0 ;;
  esac
  if [ "$owner_started" = "$current_started" ]; then
    printf 'alive'
  else
    printf 'dead'
  fi
}

fm_eng_lock_reclaim() {  # <lock-dir> <stale-minutes>
  local dir=$1 stale=$2
  [ -d "$dir" ] || return 0
  case "$(fm_eng_lock_owner_state "$dir")" in
    alive) return 0 ;;
    dead) ;;
    *)
      [ -n "$(find "$dir" -maxdepth 0 -mmin "+$stale" -print 2>/dev/null)" ] || return 0
      ;;
  esac
  fm_eng_lock_remove "$dir"
}

fm_eng_lock_release_all() {
  local dir
  [ "${#FM_ENG_LOCK_HELD_DIRS[@]}" -gt 0 ] || return 0
  for dir in "${FM_ENG_LOCK_HELD_DIRS[@]}"; do
    fm_eng_lock_remove "$dir"
  done
  FM_ENG_LOCK_HELD_DIRS=()
}

fm_eng_lock_release() {  # <lock-dir>
  local dir
  local -a kept=()
  if [ "${#FM_ENG_LOCK_HELD_DIRS[@]}" -gt 0 ]; then
    for dir in "${FM_ENG_LOCK_HELD_DIRS[@]}"; do
      [ "$dir" = "$1" ] || kept[${#kept[@]}]=$dir
    done
  fi
  if [ "${#kept[@]}" -gt 0 ]; then
    FM_ENG_LOCK_HELD_DIRS=("${kept[@]}")
  else
    FM_ENG_LOCK_HELD_DIRS=()
  fi
  fm_eng_lock_remove "$1"
}

# Taking the lock and recording who holds it are one step, so the cheap retry path
# registers ownership exactly the way the first attempt does.
fm_eng_lock_record() {  # <lock-dir> <recorded-at>
  local started
  FM_ENG_LOCK_HELD_DIRS[${#FM_ENG_LOCK_HELD_DIRS[@]}]=$1
  started=$(fm_eng_process_start_signature "$$") || started=unknown
  printf 'host=%s\npid=%s\nstarted=%s\nacquiredAt=%s\n' \
    "$FM_ENG_LOCK_HOST" "$$" "$started" "${2:-}" > "$1/owner" 2>/dev/null || true
}

# The mutex is a mkdir the filesystem serializes, and the owner record is what
# makes reclaiming it safe rather than a blind timeout. Contention and a store that
# cannot hold a lock at all are separate answers: status 1 means another owner has
# it and waiting can help, status 2 means it can never be taken here.
fm_eng_lock_acquire() {  # <lock-dir> <stale-minutes> <recorded-at>
  local dir=$1 stale
  stale=$(fm_eng_lock_stale_minutes "${2:-}")
  mkdir -p "$(dirname "$dir")" 2>/dev/null || return 2
  if ! mkdir "$dir" 2>/dev/null; then
    fm_eng_lock_reclaim "$dir" "$stale"
    if ! mkdir "$dir" 2>/dev/null; then
      [ -d "$dir" ] || return 2
      return 1
    fi
  fi
  fm_eng_lock_record "$dir" "${3:-}"
}

FM_ENG_LOCK_PAUSE_UNIT=''

# The probe costs a real sleep, so it assigns the shared answer directly rather
# than being read back through a command substitution that would discard it, and
# it is only ever reached once a wait is already going to pause.
fm_eng_lock_pause_unit() {
  [ -z "$FM_ENG_LOCK_PAUSE_UNIT" ] || return 0
  if sleep 0.05 2>/dev/null; then
    FM_ENG_LOCK_PAUSE_UNIT=0.05
  else
    FM_ENG_LOCK_PAUSE_UNIT=1
  fi
}

# Contending for a shared counter is normal rather than an error, so this waits a
# bounded time instead of refusing. The bound is a wall-clock deadline, so probe,
# reclaim, and process-spawn cost all come out of the caller's budget rather than
# extending it. An uncontended acquisition never pauses, never probes, and never
# reads the clock. Once contended, retries are the bare mkdir the filesystem
# serializes, and the owner probe that reclaims a crashed holder runs about once a
# second instead of on every retry. A store that can never hold the lock is not
# contention and is refused at once rather than after the whole wait.
# The clock this reads counts whole seconds, so the deadline carries one extra
# second: the requested interval is a grace period the caller is owed in full
# rather than a ceiling a partly elapsed second can cut short, and the overshoot
# that buys stays under one second.
fm_eng_lock_acquire_wait() {  # <lock-dir> <stale-minutes> <recorded-at> [seconds]
  local dir=$1 stale=${2:-} at=${3:-} seconds=${4:-5} deadline probes=0 reclaim_every status
  case "$seconds" in
    ''|*[!0-9]*|0) seconds=5 ;;
  esac
  [ "${#seconds}" -le 4 ] || seconds=5
  fm_eng_lock_acquire "$dir" "$stale" "$at"
  status=$?
  [ "$status" -eq 1 ] || return "$status"
  stale=$(fm_eng_lock_stale_minutes "$stale")
  fm_eng_lock_pause_unit
  if [ "$FM_ENG_LOCK_PAUSE_UNIT" = 1 ]; then
    reclaim_every=1
  else
    reclaim_every=20
  fi
  deadline=$(( $(date +%s) + seconds + 1 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    sleep "$FM_ENG_LOCK_PAUSE_UNIT"
    if mkdir "$dir" 2>/dev/null; then
      fm_eng_lock_record "$dir" "$at"
      return 0
    fi
    probes=$((probes + 1))
    if [ "$probes" -ge "$reclaim_every" ]; then
      probes=0
      fm_eng_lock_reclaim "$dir" "$stale"
    fi
  done
  return 1
}

fm_eng_validate_correlation() {  # <json> <mission> <task> <crewmate>
  local value=$1 mission=$2 task=$3 crewmate=$4
  printf '%s' "$value" | jq -e \
    --arg mission "$mission" --arg task "$task" --arg crewmate "$crewmate" '
    .schemaVersion == "shapeup-correlation.v1"
    and (.sourceRevision | type == "string" and length > 0)
    and (.capturedAt | type == "string" and length > 0)
    and (.identity.kind == "command" or .identity.kind == "event")
    and (.identity.id | type == "string" and length > 0)
    and (.shapeUp.cycleRef | type == "string" and length > 0)
    and (.shapeUp.buildRef | type == "string" and length > 0)
    and (.shapeUp.scopeRef == null or (.shapeUp.scopeRef | type == "string" and length > 0))
    and (.firstMate.missionId == $mission)
    and (.firstMate.taskId == $task)
    and (.firstMate.crewmateId == $crewmate)
    and (
      .firstMate.session == null
      or (
        (.firstMate.session | keys - ["backend","targetId","lifecycle"] | length) == 0
        and (.firstMate.session.backend | IN("tmux","herdr","zellij","orca","cmux"))
        and (.firstMate.session.targetId | type == "string" and length > 0 and length <= 512)
        and ((.firstMate.session.targetId | test("[[:cntrl:]]")) | not)
        and (.firstMate.session.lifecycle | IN("starting","running","detached","reconnecting","ended","crashed"))
      )
    )
  ' >/dev/null 2>&1
}

fm_eng_relative_to() {  # <path> <root>
  case "$1/" in
    "$2/"*) return 0 ;;
  esac
  return 1
}
