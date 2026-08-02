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

fm_eng_contains_credentials() {  # <json>
  printf '%s' "$1" | jq -e '
    . as $root
    | any(paths(scalars);
        . as $path
        | ($root | getpath($path)) as $value
        | ($value | type == "string")
          and (
            (($path[-1] | tostring | ascii_downcase) | test("token|secret|credential|password"))
            or ($value | test("gh[pousr]_[A-Za-z0-9]|Bearer[[:space:]]+|BEGIN[[:space:]]+(RSA[[:space:]]+)?PRIVATE[[:space:]]+KEY"; "i"))
          ))
  ' >/dev/null 2>&1
}

fm_eng_canonical() {  # <json>
  printf '%s' "$1" | jq -cS .
}

fm_eng_atomic_write() {  # <path> <json>
  local path=$1 value=$2 tmp="$1.$$"
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$value" > "$tmp" && mv "$tmp" "$path"
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
