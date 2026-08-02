# Decision hold lifecycle mechanism

The normative policy is owned by `.agents/skills/decision-hold-lifecycle/SKILL.md` and is not restated here.
This document records the deterministic mechanism, structured surfaces, and privacy-safe regression evidence.

## Mechanism

`bin/fm-decision-hold.sh` is the only lifecycle command for an investigation or visual review's unresolved captain decisions and for the Captain Calls a consequential Engineering report raises.
The command runs tasks-axi in the active `FM_HOME`, so the existing backlog remains the only durable work database and a secondmate-owned decision stays in the secondmate home.
It never reads report bodies, review artifacts, terminal output, or chat.

The `hold` subcommand maps an originating work id and stable decision key to `<origin-id>-decision-<decision-key>`.
It creates a kind `captain` backlog item when absent and invokes `tasks-axi hold <id> --reason <reason> --kind captain` on every retry.
It rejects an identity collision, a changed title, and attempts to reopen an already resolved identity.
An accepted Engineering mission record is also a valid origin, so `bin/fm-report.sh` raises a consequential report's Captain Call through this same subcommand instead of a second attention store.

The `complete` subcommand unions the reviewed keys into `decision_keys=` and appends `decisions_reviewed=1` while originating task metadata is live.
A post-teardown visual review can complete against the surviving report and durable holds without recreating volatile task metadata.
It accepts `--none` as an explicit semantic inventory result, not as inferred absence.
It verifies every listed identity against tasks-axi before recording completion.
For an open keyed status decision, it appends a `captain-held [key=<key>]: ...` transfer event only after the matching backlog hold is durable.
`bin/fm-classify-lib.sh` recognizes that transfer as closing the live status copy without claiming that the captain has answered it.

Scout teardown calls the script's read-only `verify` subcommand after checking for the report and before removing any source state.
The `--force` path remains the explicit captain-approved discard escape hatch.

The `resolve` subcommand requires a decision file and at least one existing dependent task whose structured `blocked-by` edge points to the hold.
It records the decision digest and routed task identities as a retry identity in the hold body, clears each dependency edge through tasks-axi, and marks the hold Done only after those writes succeed.
An exact retry can finish a partial routing operation, while a changed decision or routed-task set is rejected.
A failed intermediate step leaves the hold open.

The `project` subcommand extends that same hold with a structured Captain Call packet revision and a raised, updated, or resolving lifecycle.
It requires an active hold and a packet file containing one condition, so projection cannot create a second attention store or completion owner.
It keeps the human decision context first in the hold body and appends only the durable record identity and packet revision, never the private packet path.

The `status --json` subcommand returns the condition identity, hold identity, packet revision, typed lifecycle, and durable held state without projecting its private packet path.
The Captain's Log projection uses the existing `resolve` subcommand for supported `resolveCondition` intent and records resolved lifecycle only after the durable completion owner succeeds.
Acknowledgement remains a separate semantic outcome and never calls `resolve`.

## Structured read surfaces

`bin/fm-fleet-snapshot.sh` parses canonical tasks-axi `(hold: ...)` and `(hold-kind: captain)` metadata alongside existing backlog fields.
It resolves every repeated `blocked-by:` edge against structured Done records, keeps missing blockers unresolved, and classifies only an unblocked captain hold as actionable.
Its secondmate-home summary classifies an actionable captain hold as `captain_decision` and preserves blocked captain holds as queued work in the owning home.

`bin/fm-bearings-snapshot.sh` projects actionable captain holds into `decisions_open` and leaves blocked captain holds in ordinary queued gates.
It excludes completed kind `captain` records from Recently Landed.
The projection remains read-only and does not inspect historical prose.

## Verification record

Verification date: 2026-08-02.
Earlier focused regression dates remain part of this record: 2026-07-14 for the end-to-end lifecycle, 2026-07-17 for quoted multi-entry `blocked_by` matching, and 2026-07-22 for plural blocker readiness and mixed-home projection.

The focused end-to-end regression uses only synthetic `sample` identities and decision text.
It begins with a completed investigation and visual review whose genuine unresolved choice exists only in the report.
The initial Bearings snapshot correctly has no open decision, and the teardown gate refuses to erase the source.
A later regression covers tasks-axi's quoted multi-entry `blocked_by` output so `resolve` matches the first, middle, and last ids and rejects a genuinely absent id.

`tests/fm-decision-hold.test.sh` covers the Captain Call packet subcommands end to end: `project` raises and then independently updates one condition over the same durable hold, `status --json` reports that lifecycle and held state without exposing the private packet path, acknowledgement leaves the hold open, and resolution closes it through the existing `resolve` owner.
That suite skips itself when `jq` or tasks-axi is absent, so a recorded `ok` line is the only proof it actually ran.
The projection and Build Review suites are recorded alongside it because the projection is the only caller that closes one of these holds, and because Captain acceptance of a Build Review must not create a second attention store.

The commands below were re-run on this tree on 2026-08-02, and their real outcomes follow.
Long suites are quoted only for their decision-relevant cases; every elision states the suite's true case count.
This evidence is scoped to exactly these commands.
Repository-wide shell lint is owned by `bin/fm-lint.sh` and is recorded below as an exact command.
The complete local suite is environment-sensitive on a developer machine, so it is not claimed green by this record.

```text
$ bash tests/fm-decision-hold-lifecycle.test.sh
ok - report-only unresolved decision is reproduced and completion refuses before loss
ok - non-forced scout teardown always requires durable inventory verification
ok - captain holds are idempotent, distinct, teardown-safe, Bearings-visible, and durably routed before close
ok - completion and verification validate origins before constructing paths
ok - ended visual review follows the same decision-hold completion owner
ok - resolved findings and decision-like prose do not create false holds
ok - terminal single-owner stale status decisions do not block empty inventory
ok - main-home and secondmate-home captain holds remain correctly routed
ok - resolve matches first/middle/last in quoted blocked_by and rejects a genuinely absent id

$ bash tests/fm-decision-hold.test.sh
ok - Captain Call packets update independently and resolve through one durable completion owner

$ bash tests/fm-report.test.sh
ok - a Captain Call packet that cannot be projected stays accepted, typed, and heals on exact replay
ok - packet healing terminates once its durable Captain Call is closed
(7 ok cases total; the two packet-projection lines are quoted, the rest elided)

$ bash tests/fm-captains-log-projection.test.sh
ok - projection journals exact replay and rejects changed identity reuse
ok - the intent mutex recovers from crashes without ever reclaiming a live owner
(6 ok cases total; the two intent-durability lines are quoted, the rest elided)

$ bash tests/fm-build-review.test.sh
ok - Build Review binds the active mission/evidence revision and acceptance is not closeout
ok - one Build Review packet spans every active mission and refuses conflicting revisions
ok - a Build Review set that cannot be computed degrades to a typed unavailable projection

$ bash tests/fm-fleet-snapshot-view.test.sh
ok - backlog normalization preserves strict roles and resolves every blocker compatibly
ok - durable captain-held transfer closes the duplicate live status decision
ok - snapshot parses tasks-axi rows and respects operational overrides
(15 ok cases total; the three decision-relevant lines are quoted, the rest elided)

$ bash tests/fm-bearings-snapshot.test.sh
ok - a completed scout with decision-like report prose is a pointer, not pending
ok - action-free items (working/done/queued/landed) do not leak into Captain's Call
ok - mixed secondmate roles, partial state, and captain readiness project independently
ok - main and secondmate captain actionability use the same blocker readiness
(41 ok cases total; the four decision-relevant lines are quoted, the rest elided)

$ bash tests/fm-brief.test.sh
ok - fm-brief.sh: investigation and visual-review completions load the shared decision policy
(17 ok cases total; the decision-policy line is quoted, the rest elided)

$ bash tests/fm-teardown.test.sh
ok - herdr flat teardown never erases records when pane presence is unparseable
not ok - herdr-preflight-missing-adapter: the retryable pre-return refusal was not explained visibly
(12 ok cases precede the failure, which aborts the suite)

$ bash bin/fm-lint.sh
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)
(exit 0; no diagnostics)
```

The teardown suite is the one command above that does not pass on this tree.
Its failing case removes the Herdr adapter from a copied `bin/` tree and expects a retryable refusal, but under the recording machine's bash 3.2 the failed `.` of that deleted adapter in `bin/fm-backend.sh` ends the `set -e` shell before the refusal is printed.
Neither that case nor any file it exercises belongs to this mechanism, and the decision-hold teardown gate itself is proven above by `tests/fm-decision-hold-lifecycle.test.sh`.
