#!/usr/bin/env bash
# Print the tail of a crewmate endpoint (bounded, for cheap diagnosis).
# Usage: fm-peek.sh <target> [lines=40]
#        fm-peek.sh --json <exact-task-id> [lines=40]
#   <target> may be an exact task id, a legacy fm-<id> task label resolved
#   through this home's state/<id>.meta, or an explicit backend target.
#   --json accepts only an exact task id with one metadata record and returns a
#   closed descriptor plus bounded redacted capture. It never resolves a bare
#   or ambiguous live target and never exposes commands or environment values.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-engineering-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-engineering-lib.sh"

machine_error() {  # <code> <message>
  jq -n --arg code "$1" --arg message "$2" \
    '{available:false,schemaVersion:"fm-session-inspection.v1",error:{code:$code,message:$message}}'
}

valid_task_id() {
  case "$1" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  [ "${#1}" -le 128 ]
}

valid_target_id() {
  [ -n "$1" ] && [ "${#1}" -le 512 ] || return 1
  ! printf '%s' "$1" | LC_ALL=C grep -q '[[:cntrl:]]'
}

# redact_capture: credential redaction over one bounded pane capture on stdin.
# A pane inserts a real newline at its width, so a credential wider than the
# pane arrives split across capture lines and per-line rules would only match
# the fragment on one of them. Rows the pane may have wrapped are therefore
# stitched into one logical line before the single-line rules run, so a value -
# or the introducer itself - split across the wrap is matched whole, and a
# multi-row value stays a single token the value rules consume entirely.
# An introducer left bare at a row end is one of two shapes, and only one of them
# lost a separator to the wrap. A space-separated introducer such as `Bearer` did
# lose the space, so a stitched row gets it back. An assignment introducer such as
# `SERVICE_TOKEN=` or `X-Api-Key:` is contiguous with its value, so the wrap landed
# mid-token and the rows rejoin with nothing between them; inserting a space there
# would break the very value rule that has to consume the rejoined token. An
# unstitched row of either shape fails closed onto the next row's first token
# regardless of the whitespace in front of it.
# The two separators carry different amounts of evidence, so they are recognized
# differently. `=` is an assignment and is unambiguous, so any credential-named
# operand qualifies. `:` is also ordinary prose punctuation, so it asks for a label
# whose credential word ends it and for one of two independent signals from the
# operand: it either closes the line, the way a credential header's value does, or
# it is long enough to be a secret wherever it sits. Inert telemetry such as
# `Total tokens: 4821 in this run` gives neither signal - its label is a glued
# plural and its operand is short and mid-sentence - so it renders as the pane
# printed it, and a pane-wide inert label never stitches away the next row's event.
# Stitching never trusts a measured display width. A mid-token wrap leaves the
# row exactly as wide as the pane, so a row counts as possibly pane-wide when
# its codepoints plus its non-ASCII codepoints - each of which may occupy two
# columns - reach the widest row's guaranteed width, itself a lower bound on the
# pane width because each non-ASCII codepoint may instead occupy none. Both
# bounds err toward stitching, so a wide glyph cannot hide the wrap.
# Stitching is speculative, so every logical line is offered to the rules twice:
# once joined and once as the rows the pane actually printed. When redacting the
# rows one at a time produces exactly what redacting the joined line produced, no
# redaction depended on the stitch and the rows are handed back with their own
# boundaries; only a redaction that straddles a wrap keeps the joined line. That
# way a row which merely fills the pane keeps its own line and its own event even
# when the row beside it carries a credential of its own.
redact_capture() {
  local names labels anchor quotes
  names=$(fm_eng_credential_name_ere)
  labels=$(fm_eng_credential_label_ere)
  anchor=$(fm_eng_credential_label_anchor)
  quotes="[\"']*"
  LC_ALL=C awk -v names="$names" -v labels="$labels" -v anchor="$anchor" -v quotes="$quotes" '
    function codepoints(text,   rest) { rest = text; return length(text) - gsub(/[\200-\277]/, "", rest) }
    function multibyte(text,    rest) { rest = text; return gsub(/[\300-\377]/, "", rest) }
    # A dangling introducer from the previous logical line claims the first token
    # of this one, which is the wrapped value in full.
    function claim(text,   indent) {
      indent = ""
      if (match(text, /^[ \t]+/)) { indent = substr(text, 1, RLENGTH); text = substr(text, RLENGTH + 1) }
      sub(/^[^ \t]+/, "[REDACTED]", text)
      return indent text
    }
    {
      line[NR] = $0
      cells = codepoints($0)
      wide = multibyte($0)
      reach[NR] = cells + wide
      if (cells - wide > floor) floor = cells - wide
    }
    END {
      logical = ""; rows = 0; open = 0
      for (i = 1; i <= NR; i++) {
        row = line[i]
        if (!open) { carried = pending; pending = 0; open = 1 }
        separated = (row ~ /Bearer$/)
        contiguous = (row ~ /gh[pousr]_$/ || row ~ ("(" names ")=$") || row ~ ("(^|" anchor ")(" labels ")" quotes "[[:space:]]*:$"))
        dangling = (separated || contiguous)
        stitch = (i < NR && floor > 0 && reach[i] >= floor)
        if (stitch && separated) row = row " "
        logical = logical row
        row_text[++rows] = row
        if (stitch) continue
        if (carried) {
          logical = claim(logical)
          row_text[1] = claim(row_text[1])
        }
        print "J\t" logical
        for (r = 1; r <= rows; r++) print "R\t" row_text[r]
        logical = ""; rows = 0; open = 0
        pending = dangling
      }
    }
  ' | LC_ALL=C sed -E \
    -e 's/(Bearer)[[:space:]]+[^[:space:]]+/\1 [REDACTED]/g' \
    -e 's/(gh[pousr]_)[A-Za-z0-9_]+/\1[REDACTED]/g' \
    -e "s/($names)=[^[:space:]]+/\\1=[REDACTED]/g" \
    -e "s/(^|$anchor)($labels$quotes)[[:space:]]*:[[:space:]]*${quotes}[^[:space:]]{6,}/\\1\\2: [REDACTED]/g" \
    -e "s/(^|$anchor)($labels$quotes)[[:space:]]*:[[:space:]]*${quotes}[^[:space:]]+\$/\\1\\2: [REDACTED]/" \
    -e 's/(-----BEGIN ([A-Z ]+)?PRIVATE KEY-----)/[REDACTED PRIVATE KEY]/g' \
  | LC_ALL=C awk '
    # Each logical line arrives as its joined form followed by the rows the pane
    # printed, both already redacted. The rules cannot match across the one-letter
    # tag, so the two forms agreeing means no redaction needed the stitch.
    function settle(   r, joined_rows) {
      if (!open) return
      joined_rows = ""
      for (r = 1; r <= rows; r++) joined_rows = joined_rows row_text[r]
      if (joined_rows == logical) {
        for (r = 1; r <= rows; r++) print row_text[r]
      } else {
        print logical
      }
      open = 0; rows = 0
    }
    {
      cut = index($0, "\t")
      text = substr($0, cut + 1)
      if (substr($0, 1, cut - 1) == "J") {
        settle()
        logical = text
        open = 1
      } else {
        row_text[++rows] = text
      }
    }
    END { settle() }
  '
}

machine_peek() {  # <task-id> <lines>
  # A wrapped credential's introducer can sit just above the requested window,
  # so the capture reads a bounded number of extra rows for redaction context
  # and the answer is trimmed back to the requested bound afterwards.
  local task_id=$1 lines=$2 lookback=8 meta backend target expected capture bytes truncated=false lifecycle=running
  command -v jq >/dev/null 2>&1 || { echo "fm-peek: jq not found" >&2; return 1; }
  valid_task_id "$task_id" || { machine_error malformed_task "Task identity is invalid"; return 2; }
  case "$lines" in ''|*[!0-9]*|0) machine_error invalid_bound "Capture lines must be a positive integer"; return 2 ;; esac
  [ "$lines" -le 200 ] || { machine_error invalid_bound "Capture lines are limited to 200"; return 2; }
  meta="$STATE/$task_id.meta"
  [ -f "$meta" ] || { machine_error session_not_found "No exact session descriptor exists for the task"; return 2; }
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  valid_target_id "$target" || { machine_error session_unavailable "The task has no valid backend target"; return 2; }
  expected="fm-$task_id"
  if ! fm_backend_target_exists "$backend" "$target" "$expected"; then
    lifecycle=ended
    machine_error session_ended "The recorded session endpoint is no longer available"
    return 2
  fi
  capture=$(fm_backend_capture "$backend" "$target" "$((lines + lookback))" "$expected" 2>/dev/null) || {
    machine_error session_unavailable "The recorded session could not be captured"
    return 2
  }
  capture=$(printf '%s\n' "$capture" | redact_capture | tail -n "$lines")
  bytes=$(printf '%s' "$capture" | LC_ALL=C wc -c | tr -d '[:space:]')
  if [ "$bytes" -gt 32768 ]; then
    capture=$(printf '%s' "$capture" | head -c 32768)
    bytes=32768
    truncated=true
  fi
  jq -n --arg taskId "$task_id" --arg backend "$backend" --arg targetId "$target" \
    --arg lifecycle "$lifecycle" --arg text "$capture" --argjson lines "$lines" \
    --argjson bytes "$bytes" --argjson truncated "$truncated" '
    {
      available:true,
      schemaVersion:"fm-session-inspection.v1",
      descriptor:{taskId:$taskId,backend:$backend,targetId:$targetId,lifecycle:$lifecycle},
      capture:{text:$text,lines:$lines,bytes:$bytes,truncated:$truncated},
      mode:"bounded-read-only",
      authoritative:false
    }
  '
}

if [ "${1:-}" = --json ]; then
  [ "$#" -ge 2 ] && [ "$#" -le 3 ] || { machine_error malformed_request "Usage: fm-peek.sh --json <task-id> [lines]"; exit 2; }
  machine_peek "$2" "${3:-40}"
  exit $?
fi

"$SCRIPT_DIR/fm-guard.sh" || true

RAW_TARGET=$1
T=$(fm_backend_resolve_selector "$RAW_TARGET" "$STATE")
N=${2:-40}

BACKEND=$(fm_backend_of_selector "$RAW_TARGET" "$T" "$STATE")
EXPECTED_LABEL=$(fm_backend_expected_label_of_selector "$RAW_TARGET" "$STATE")

fm_backend_capture "$BACKEND" "$T" "$N" "$EXPECTED_LABEL"
