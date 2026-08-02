#!/usr/bin/env bash
# Behavior tests for bounded read-only machine session inspection.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PEEK="$ROOT/bin/fm-peek.sh"
PROJECTION="$ROOT/bin/fm-captains-log-projection.sh"
MISSION="$ROOT/bin/fm-mission.sh"
TMP_ROOT=$(fm_test_tmproot fm-peek-machine)
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/projects/task-42"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

fakebin=$(fm_fakebin "$HOME_DIR")
DEFAULT_CAPTURE="$TMP_ROOT/default-capture.txt"
printf 'tests passed\nBearer should-redact\nno lifecycle authority here\n' > "$DEFAULT_CAPTURE"
# The fake honours the requested row count so a bounded window really is a
# window: a capture that asks for fewer rows than the pane holds must not see
# the rows above it unless fm-peek.sh deliberately reads further back.
cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  list-windows) printf 'fm-task-42\n' ;;
  display-message) printf '%%1\n' ;;
  capture-pane)
    rows=40
    for arg in "\$@"; do
      case "\$arg" in -[0-9]*) rows=\${arg#-} ;; esac
    done
    tail -n "\$rows" "\${FM_PEEK_TEST_CAPTURE:-$DEFAULT_CAPTURE}"
    ;;
esac
SH
chmod +x "$fakebin/tmux"

fm_write_meta "$HOME_DIR/state/task-42.meta" \
  "window=firstmate:fm-task-42" \
  "worktree=$HOME_DIR/projects/task-42" \
  "project=sample" \
  "harness=codex" \
  "kind=ship" \
  "mode=ship"

machine=$(PATH="$fakebin:$PATH" FM_HOME="$HOME_DIR" "$PEEK" --json task-42 20)
printf '%s' "$machine" | jq -e '
  .available == true
  and .descriptor.backend == "tmux"
  and .descriptor.taskId == "task-42"
  and .descriptor.targetId == "firstmate:fm-task-42"
  and .descriptor.lifecycle == "running"
  and (.capture.text | contains("tests passed"))
  and (.capture.text | contains("[REDACTED]"))
  and (.descriptor | has("command") | not)
' >/dev/null || fail "machine peek descriptor is invalid: $machine"
pass "machine peek returns bounded redacted output with a closed descriptor"

mission=$(jq -n --arg root "$HOME_DIR/projects/task-42" '{
  schemaVersion:"fm-engineering-mission.v1",missionId:"mission-42",taskId:"task-42",crewmateId:"keiko",
  acceptedBuildRevision:"build-8:r7",evidenceRequirements:[],allowedEvidenceRoots:[$root],
  correlation:{schemaVersion:"shapeup-correlation.v1",sourceRevision:"dispatch:r1",capturedAt:"2026-08-01T12:00:00Z",
    identity:{kind:"command",id:"dispatch-42"},shapeUp:{cycleRef:"cycle-13",buildRef:"build-8",buildRevision:"build-8:r7",scopeRef:null},
    firstMate:{missionId:"mission-42",taskId:"task-42",crewmateId:"keiko",
      session:{backend:"tmux",targetId:"firstmate:fm-task-42",lifecycle:"running"}}}
}')
accepted=$(printf '%s' "$mission" | FM_HOME="$HOME_DIR" "$MISSION" accept -)
revision=$(printf '%s' "$accepted" | jq -r '.mission.sourceRevision')
inspection=$(jq -n --arg revision "$revision" '{
  schemaVersion:"fm-captains-log-projection.v1",operation:"inspectSession",
  missionId:"mission-42",taskId:"task-42",expectedMissionRevision:$revision,lines:20
}' | PATH="$fakebin:$PATH" FM_HOME="$HOME_DIR" "$PROJECTION")
printf '%s' "$inspection" | jq -e '
  .accepted == true
  and .inspection.available == true
  and .inspection.authoritative == false
  and .inspection.mode == "bounded-read-only"
' >/dev/null || fail "projection inspection is invalid: $inspection"
pass "session inspection is optional, exact, and explicitly non-authoritative"

# A pane inserts a real newline at its width, so a credential wider than the
# pane arrives split across capture lines. The fixtures below are exact pane
# geometry rather than folded text, because the shape of the wrap is what
# decides the boundary: pane_row refuses a row that does not occupy the columns
# it claims, so every wrap here stays the one a live endpoint produces.
PANE_COLUMNS=40

pane_row() {  # <file> <columns> <text>
  # Display columns, not bytes: the fixtures pair each non-ASCII codepoint with
  # a second column, which is what a pane gives a CJK or emoji glyph.
  local file=$1 want=$2 text=$3 got
  got=$(printf '%s' "$text" | LC_ALL=C awk '{
    bytes = length($0); rest = $0
    lead = gsub(/[\300-\377]/, "", rest); rest = $0
    cont = gsub(/[\200-\277]/, "", rest)
    print bytes - cont + lead
  }')
  [ "$got" = "$want" ] || fail "pane fixture row occupies $got columns, not $want: $text"
  [ "$want" -le "$PANE_COLUMNS" ] || fail "pane fixture row is wider than the pane: $text"
  printf '%s\n' "$text" >> "$file"
}

refute_fragments() {  # <label> <text> <secret>
  local label=$1 text=$2 secret=$3 i window=8
  for ((i = 0; i + window <= ${#secret}; i++)); do
    case "$text" in
      *"${secret:i:window}"*) fail "$label released a credential fragment across the wrap: ${secret:i:window}" ;;
    esac
  done
}

WRAP_CAPTURE="$TMP_ROOT/wrapped-capture.txt"
: > "$WRAP_CAPTURE"
SPLIT_VALUE='fm_fake_51QsecretPAYLOADabcdefghijklmnop'
BOUNDARY_VALUE='fm_fake_92RwrappedAtIntroducerSpace'
STRIPPED_VALUE='fm_fake_66StrippedSpaceValueZZZZZZZZZZZZYYYY'
ONELINE_VALUE='fm_fake_unwrappedONELINE'
pane_row "$WRAP_CAPTURE" 12 'tests passed'
# The pane wrapped inside the value itself.
pane_row "$WRAP_CAPTURE" 40 'Authorization: Bearer fm_fake_51QsecretP'
pane_row "$WRAP_CAPTURE" 22 'AYLOADabcdefghijklmnop'
# The pane wrapped on the space separating introducer from value, leaving that
# space at the start of the next row.
pane_row "$WRAP_CAPTURE" 40 'request auth note                 Bearer'
pane_row "$WRAP_CAPTURE" 36 ' fm_fake_92RwrappedAtIntroducerSpace'
# The same wrap, with the pane stripping the separating space off this row and
# the value then running on across a second wrap.
pane_row "$WRAP_CAPTURE" 39 'upload step 3 of 9 auth header   Bearer'
pane_row "$WRAP_CAPTURE" 40 'fm_fake_66StrippedSpaceValueZZZZZZZZZZZZ'
pane_row "$WRAP_CAPTURE" 4 'YYYY'
# A credential that fits on one row, and inert output that must survive.
pane_row "$WRAP_CAPTURE" 31 'Bearer fm_fake_unwrappedONELINE'
pane_row "$WRAP_CAPTURE" 27 'no lifecycle authority here'

peek_capture() {  # <capture-file> <lines>
  FM_PEEK_TEST_CAPTURE="$1" PATH="$fakebin:$PATH" FM_HOME="$HOME_DIR" "$PEEK" --json task-42 "$2"
}

inspect_capture() {  # <capture-file> <lines>
  jq -n --arg revision "$revision" --argjson lines "$2" '{
    schemaVersion:"fm-captains-log-projection.v1",operation:"inspectSession",
    missionId:"mission-42",taskId:"task-42",expectedMissionRevision:$revision,lines:$lines
  }' | FM_PEEK_TEST_CAPTURE="$1" PATH="$fakebin:$PATH" FM_HOME="$HOME_DIR" "$PROJECTION"
}

wrapped=$(peek_capture "$WRAP_CAPTURE" 20)
printf '%s' "$wrapped" | jq -e '
  .available == true
  and (.capture.text | contains("Bearer [REDACTED]"))
  and (.capture.text | contains("tests passed"))
  and (.capture.text | contains("no lifecycle authority here"))
' >/dev/null || fail "a wrapped credential must still return redacted inert output: $wrapped"
wrapped_inspection=$(inspect_capture "$WRAP_CAPTURE" 20)
printf '%s' "$wrapped_inspection" | jq -e '.accepted == true and .inspection.available == true' >/dev/null \
  || fail "session inspection must stay available for a wrapped capture: $wrapped_inspection"
for secret in "$SPLIT_VALUE" "$BOUNDARY_VALUE" "$STRIPPED_VALUE" "$ONELINE_VALUE"; do
  refute_fragments "machine peek" "$wrapped" "$secret"
  refute_fragments "session inspection" "$wrapped_inspection" "$secret"
done
pass "a credential wrapped at the pane width is redacted across the capture line boundary"

# A two-column glyph makes a row occupy the whole pane while counting fewer
# codepoints than a plain row beside it, so the wrap must not be recognized by
# a measured width that a wide glyph can hide.
GLYPH_CAPTURE="$TMP_ROOT/glyph-capture.txt"
: > "$GLYPH_CAPTURE"
GLYPH_VALUE='fm_fake_77QwideGlyphAheadOfSecretXYZ012'
pane_row "$GLYPH_CAPTURE" 40 '✅ Authorization: Bearer fm_fake_77Qwide'
pane_row "$GLYPH_CAPTURE" 24 'GlyphAheadOfSecretXYZ012'
pane_row "$GLYPH_CAPTURE" 22 '世界 progress 12 of 30'
pane_row "$GLYPH_CAPTURE" 40 'plain ascii progress line that is long o'
glyph=$(peek_capture "$GLYPH_CAPTURE" 20)
glyph_inspection=$(inspect_capture "$GLYPH_CAPTURE" 20)
printf '%s' "$glyph" | jq -e '
  (.capture.text | contains("Bearer [REDACTED]"))
  and (.capture.text | contains("世界 progress 12 of 30"))
  and (.capture.text | contains("plain ascii progress line that is long o"))
' >/dev/null || fail "a wide glyph must not hide the wrap or redact unrelated output: $glyph"
refute_fragments "machine peek" "$glyph" "$GLYPH_VALUE"
refute_fragments "session inspection" "$glyph_inspection" "$GLYPH_VALUE"
pass "a credential wrapped behind a two-column glyph is redacted with the wrap"

# Filling the pane is not the same as wrapping: two unrelated events must not
# be handed to the machine consumer as one line.
FIDELITY_CAPTURE="$TMP_ROOT/fidelity-capture.txt"
: > "$FIDELITY_CAPTURE"
pane_row "$FIDELITY_CAPTURE" 39 'ok 12 fixture rows rebuilt and verified'
pane_row "$FIDELITY_CAPTURE" 38 'ok 13 unrelated assertion on next line'
fidelity=$(peek_capture "$FIDELITY_CAPTURE" 20)
printf '%s' "$fidelity" | jq -e '
  .capture.text == "ok 12 fixture rows rebuilt and verified\nok 13 unrelated assertion on next line"
' >/dev/null || fail "an exactly full-width unrelated row must keep its own line: $fidelity"
pass "capture rows that merely fill the pane keep their own event boundary"

# The bound is a window over the pane, so it can open on a continuation row
# whose introducer scrolled above it.
window=$(peek_capture "$WRAP_CAPTURE" 8)
window_inspection=$(inspect_capture "$WRAP_CAPTURE" 8)
printf '%s' "$window" | jq -e '
  .capture.lines == 8
  and (.capture.text | contains("no lifecycle authority here"))
' >/dev/null || fail "a bounded window must stay bounded and inert: $window"
refute_fragments "machine peek" "$window" "$SPLIT_VALUE"
refute_fragments "session inspection" "$window_inspection" "$SPLIT_VALUE"
pass "a bounded capture opening on a continuation row still redacts the value above it"

set +e
unknown=$(PATH="$fakebin:$PATH" FM_HOME="$HOME_DIR" "$PEEK" --json unknown-task 20)
status=$?
set -e
[ "$status" -ne 0 ] || fail "unknown task must not select a guessed endpoint"
printf '%s' "$unknown" | jq -e '.error.code == "session_not_found"' >/dev/null \
  || fail "unknown task must return a typed unavailable result: $unknown"
pass "machine peek never guesses an ambiguous or missing target"

inspect_with_lines() {  # <lines-json>
  jq -n --arg revision "$revision" --argjson lines "$1" '{
    schemaVersion:"fm-captains-log-projection.v1",operation:"inspectSession",
    missionId:"mission-42",taskId:"task-42",expectedMissionRevision:$revision,lines:$lines
  }' | PATH="$fakebin:$PATH" FM_HOME="$HOME_DIR" "$PROJECTION"
}

for bad_lines in '0' '201' '"abc"' 'true' '99999999999999999999999'; do
  set +e
  bounded=$(inspect_with_lines "$bad_lines")
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "lines=$bad_lines must be refused"
  printf '%s' "$bounded" | jq -e '.accepted == false and .error.code == "malformed_request"' >/dev/null \
    || fail "lines=$bad_lines must return one typed JSON result: $bounded"
done
padded=$(inspect_with_lines '"007"')
printf '%s' "$padded" | jq -e '.accepted == true and .inspection.capture.lines == 7' >/dev/null \
  || fail "a zero-padded bound must normalize instead of breaking the contract: $padded"
pass "session inspection bounds its capture size and always answers with one typed result"

INSPECT_BIN="$TMP_ROOT/inspect-bin"
mkdir -p "$INSPECT_BIN"
for script in "$ROOT"/bin/*; do
  ln -s "$script" "$INSPECT_BIN/$(basename "$script")"
done
rm -f "$INSPECT_BIN/fm-peek.sh"
printf '#!/usr/bin/env bash\nexit 127\n' > "$INSPECT_BIN/fm-peek.sh"
chmod +x "$INSPECT_BIN/fm-peek.sh"
set +e
silent=$(jq -n --arg revision "$revision" '{
  schemaVersion:"fm-captains-log-projection.v1",operation:"inspectSession",
  missionId:"mission-42",taskId:"task-42",expectedMissionRevision:$revision,lines:20
}' | PATH="$fakebin:$PATH" FM_HOME="$HOME_DIR" "$INSPECT_BIN/fm-captains-log-projection.sh")
status=$?
set -e
[ "$status" -ne 0 ] || fail "a silent inspection subprocess must not look successful"
printf '%s' "$silent" | jq -e '.accepted == false and .error.code == "inspection_unavailable"' >/dev/null \
  || fail "an inspection producing no JSON must return a typed result, not empty output: $silent"
pass "session inspection failure is typed rather than an empty response"
