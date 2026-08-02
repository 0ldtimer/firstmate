# Captain's Log machine projection

`bin/fm-captains-log-projection.sh` publishes FirstMate execution truth through one versioned JSON interface without exposing private logs, command text, terminal control, or backend processes.

The interface reads one JSON object of at most 256 KiB from standard input and writes one JSON result to standard output.

The request schema is `fm-captains-log-projection.v1`.

## Authority and correlation

FirstMate remains authoritative for missions, reports, evidence verification, durable Captain Calls, Captain outcomes, and exact session correlation.

ShapeUp remains authoritative for Cycle, Build, Scope, and Hill facts.

The shared `shapeup-correlation.v1` envelope carries opaque Cycle, Build, optional Scope, mission, task, crewmate, command or event, and optional session identities.

Those identities provide correlation only and do not transfer authority between systems.

The canonical envelope and compatibility cases live in `tests/fixtures/captains-log/correlation-envelope-v1.json` and `tests/fixtures/captains-log/compatibility-matrix-v1.json`.

## Operations

The `capabilities` operation advertises the core contract, accepted intents, and independently negotiated ShapeUp and session-inspection capabilities.

```json
{"schemaVersion":"fm-captains-log-projection.v1","operation":"capabilities"}
```

The `snapshot` operation returns deterministic missions, accepted and rejected reports, evidence, independently addressable conditions, Build Review packets, Captain outcomes, authoritative ShapeUp outcomes, and malformed-record diagnostics.

```json
{"schemaVersion":"fm-captains-log-projection.v1","operation":"snapshot"}
```

Every snapshot carries a source revision and capture time.

Malformed stored records remain visible in `invalidRecords` and never participate in conditions, Review readiness, or executable outcomes.

A record that parses but violates the shape this projection derives from it is isolated the same way, as `schema_invalid_record` naming the offending record, so one hand-edited record cannot blank unrelated projection operations or the fleet snapshot's embedded copy.

Isolation keeps the record visible and non-executable, and Build Review then fails closed rather than open: a packet lists the isolated mission and report records that bear on it as `isolatedRecords`, never reports ready while any remain, and refuses acceptance with the typed `review_records_isolated` error, because a shrunken mission set cannot prove it covers every active mission.
An isolated record whose own correlation is unreadable could belong to any Build, so it withholds readiness across the Review set until the operator repairs it; every other operation stays available throughout.
Isolation is reported ahead of a Build-revision conflict, because a conflict verdict derived from a mission set that is known to be incomplete is not yet trustworthy.

## Captain intents

The `intent` operation accepts `acknowledgeCondition`, `resolveCondition`, and `acceptBuildReview` only when the capability document advertises them.

Every intent requires a privacy-safe `intentId` that provides durable idempotency.

An exact replay returns the prior semantic outcome even when the live packet has since changed.

Reusing an `intentId` with different content returns `identity_conflict`.

Condition acknowledgement requires `missionId`, `conditionId`, and `packetRevision`, records an acknowledgement outcome, and never resolves the underlying hold.

Condition resolution additionally requires a bounded `decision` and one or more `routedTo` task identities.

Resolution marks the existing Captain Call as resolving, records and routes the decision through `fm-decision-hold.sh`, closes that same durable hold, and then projects the condition as resolved.

Build Review acceptance requires `cycleRef`, `buildRef`, and the current ready `packetRevision`.

Captain acceptance records `captainAccepted` and explicitly leaves delivery, ShapeUp Build closeout, and Cycle close false.

Unknown conditions, unavailable Review packets, changed packet revisions, unsupported actions, and identity conflicts return distinct typed errors.

An outcome the store could not accept returns the typed `outcome_not_durable` error, because an intent is only accepted once its durable outcome has landed.

## Reports, evidence, and Review

`bin/fm-mission.sh accept` binds an Engineering mission to one Build revision and adds instructions to establish initial Scopes when possible and continue reporting until the mission is terminal.

`bin/fm-report.sh append` accepts Scope discovery, Scope revision, qualitative Hill judgment, blocker, evidence, verification-instruction, and outcome records.

Report identity reuse is idempotent only for identical content.

Cross-Build, malformed, or identity-drifted reports are retained with `status: rejected` and are never submitted or used as execution truth.

A consequential report stays accepted when its durable hold cannot receive the packet; the record keeps a typed degraded projection state that an exact replay retries and heals.

A degraded packet whose Captain Call is no longer actively held becomes `abandoned` once, so replay stops retrying a projection that can never land.

A packet the durable owner withheld because its Captain Call carries an in-flight resolution record is recorded as the typed `retained` state, never as projected, and an exact replay retries it exactly like a degraded one.

Every projected condition carries its `projection` state, so a held condition that never received its packet is visible to the Captain.

A record store that cannot be read in full, or a Build Review set that cannot be computed, is a typed `projection_unavailable` result, and a condition history that cannot be read in full is a typed `condition_history_unavailable` result; neither is ever reported as a fresh but empty projection.

Every scan proves it read each expected record, so a partially readable store is a typed failure rather than a silently truncated history.

Every durable write is checked, so a mission, report, or outcome the store could not accept returns the typed `record_not_durable` or `outcome_not_durable` error instead of an accepted result the store does not hold.

Hill judgments are qualitative and may move backward as learning changes the execution picture.

Numeric progress fields are rejected because task count, elapsed time, evidence count, terminal output, and process activity cannot determine Hill position.

Projected evidence retains its report revision, producer, verifier, mission, task, Build, optional Scope, contract, execution revision, proof reference, verification status, and human verification instructions.

Evidence references are limited to canonical files under mission-approved roots or HTTPS URLs that require explicit navigation confirmation.

Evidence media types and sizes are bounded, active content is rejected, credential material is rejected, and verification distinguishes missing, present, failed, stale, unavailable, not-applicable, and verified.

One Build Review packet covers every active accepted mission of a Cycle and Build, and it records the distinct Build revisions those missions are bound to.

The packet becomes ready only when each mission is terminal, every required evidence contract is verified, and every active mission is bound to the same Build revision.

Conflicting bound Build revisions keep the packet not ready and return the typed `review_revision_conflict` error on acceptance.

The authoritative latest report for terminal state and evidence verification is the one FirstMate accepted last, so a crewmate-supplied capture time cannot pin readiness to a stale record.

Acceptance order is a monotonic `acceptanceSequence` FirstMate assigns as it accepts each report, so two reports accepted inside the same wall-clock second are still ordered by FirstMate rather than by anything the crewmate supplied.
The sequence is allocated under the same liveness-safe mutex the Captain intent path uses, so concurrent appends into one home cannot be handed the same number, and a store that cannot be read in full is a typed `record_not_durable` refusal rather than an order that repeats.

Superseded missions retain history outside the active set, and deferred missions require a revision-bound Captain decision.

Any mission-set, report, evidence, execution, or Build-revision change produces a new packet revision and invalidates pending acceptance.

## Optional session inspection

The `inspectSession` operation is optional and cannot block the core projection.

It requires the exact mission, task, and expected mission revision and refuses missing, stale, ambiguous, or identity-drifted correlation.

The result contains a closed descriptor and bounded redacted output from `fm-peek.sh --json`.

Redaction runs on the capture's reconstructed logical lines, so a credential the pane wrapped across capture lines is redacted whole instead of releasing the fragment on either side of the wrap.
Reconstruction fails closed rather than trusting a measured display width, covers a wrap that lands on the space between an introducer and its value, and reads a bounded number of rows above the requested window so a value wrapped across the window edge is redacted too.
A separator is restored only for an introducer that is genuinely space-separated from its value; an assignment introducer such as `SERVICE_TOKEN=`, `X-Api-Key:`, or `ghp_` rejoins its wrapped value with nothing between the rows, so the value rules still consume the rejoined token whole.
Redaction recognizes the credential-name vocabulary `bin/fm-engineering-lib.sh` owns for the whole subsystem - token, secret, password, passwd, credential, API key, access key, and private key, in any case - plus bearer headers, GitHub token prefixes, and PEM private-key headers.
The two separators carry different evidence, so they are matched differently: `=` is an assignment and accepts any credential-named operand, while `:` is also ordinary prose punctuation and additionally requires a whole separator-delimited credential label and an operand long enough to be a secret.
That keeps inert telemetry such as `Total tokens: 4821` rendered as the pane printed it, and keeps a pane-wide inert label from being read as a dangling introducer that would stitch away the next row's event.
A row that merely fills the pane without wrapping keeps its own line, so unrelated events are never merged into one.

The operation never attaches an input-capable terminal client and never returns command text, arbitrary arguments, or unrestricted environment values.

Session content and process state are explicitly non-authoritative for Hill movement, evidence verification, condition resolution, and progress.

Inspection reads the task's own recorded backend, so every supported backend reports its actual descriptor and failure state without guessing a target; [configuration.md](configuration.md#runtime-backend-configbackend--fm_backend) owns which backend a task is launched on.

## Verification

Run the focused portable suites with the following commands.

```text
bash tests/fm-captains-log-projection.test.sh
bash tests/fm-mission-shapeup.test.sh
bash tests/fm-report.test.sh
bash tests/fm-shapeup-client.test.sh
bash tests/fm-decision-hold.test.sh
bash tests/fm-build-review.test.sh
bash tests/fm-peek.test.sh
```
