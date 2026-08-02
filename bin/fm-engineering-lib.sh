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

# The ERE form spells every letter as an explicit two-case bracket instead of
# relying on a case-insensitivity flag, which awk has no portable form of and
# sed only carries as an extension.
fm_eng_credential_name_ere() {
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
  printf '[A-Za-z0-9_]*(%s)[A-Za-z0-9_]*' "$alt"
}

fm_eng_credential_name_regex() {
  printf '%s' "$FM_ENG_CREDENTIAL_NAMES" | LC_ALL=C tr 'A-Z ' 'a-z|'
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
