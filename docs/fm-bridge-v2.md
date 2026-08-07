# FirstMate execution bridge v2

The maintained fork exposes one JSON request/response boundary at
`bin/fm-bridge.sh`. `cycle-execution.v1` accepts one revision-bound Cycle group,
persists it before Scotty delegates children, and returns the original receipt
on exact replay. A changed manifest under an existing execution identity is a
typed conflict. `delegateExecutionGroup` writes child correlations through
FirstMate's durable execution store; Captain's Log never invokes `fm-spawn.sh`.

Scotty fan-out is owned by the FirstMate primary liaison at
`bin/fm-scotty-liaison.sh`. The liaison consumes the durable execution
notification, records a `fm-scotty-delegation-transition.v1` transition before
the first provider call, places each descriptor in the durable
`liaison/primary-backlog/` ingress, validates each child against the trusted
`data/projects.md` registry, canonical non-symlink project root, repository
remote policy, and exact bound base commit, then invokes the existing
`bin/fm-spawn.sh` boundary. Captain's Log never invokes `fm-spawn.sh` and a
descriptor cannot supply an arbitrary path. Dispatching child records and the
transition journal are durable; an interrupted spawn is retried after restart,
while a child with an existing FirstMate task metadata record is not spawned a
second time. A stale lease marks only new work as quiesced and leaves existing
children and progress inspectable. `renewExecutionLease` requires a current
Shape Up execution-change cursor; `amendExecutionGroup` preserves the parent
group identity, queues additions, and pauses removals for judgment.

Crewmate progress is an append-only `fm-progress-intent.v1` record. It remains
in the outbox until Captain's Log acknowledges the exact intent digest. The
read-only `fm-captains-log-projection.sh --json` operation projects groups,
children, and pending intents without parsing terminal output or prose. One
record the store cannot read is isolated in `snapshot.invalidRecords` and never
blanks the rest of the projection. Shape Up remains the authority for lifecycle
and Hill state; this fork is independently releasable and does not require
upstream maintainer acceptance.

## Identity, paths, and leases

Every durable path is derived from a validated identity. An `executionId`,
`childId`, or `intentId` is limited to `A-Za-z0-9._:-`, may not begin with `.`,
and is at most 160 characters, so a producer-supplied identifier can never name
a record outside its own store.

`leaseExpiresAt` is a UTC instant and is compared as one on every host. A lease
is bounded to 24 hours and clamped at acceptance and at renewal to
`binding.cycleEndsAt` when the bound cycle ends sooner, so fan-out never outlives
its cycle. A lease this boundary cannot parse is treated as spent.

## Ordered amendment

`amendExecutionGroup` enforces order rather than assuming it. `amendmentSequence`
must advance beyond the sequence already recorded on the group, and
`parentGroupDigest` must equal the group's current `groupDigest`. Each accepted
amendment chains that digest:

```
groupDigest = sha256(canonical({parentGroupDigest, amendmentDigest, amendmentSequence}))
```

`amendmentDigest` is the SHA-256 of the canonicalised amendment request, and
`canonical` is `jq -cS`. The response returns the new `groupDigest`, which the
next amendment must present as its `parentGroupDigest`. A redelivered amendment
is answered from the stored record before either check, so replay stays
idempotent, and the group's prior digest is retained as `previousGroupDigest`.

## Hill position on the wire

A `kind: "hill"` intent carries `target.position`, an integer from 0 through 5 on
the Shape Up hill: 0 and 1 are uphill (figuring it out), 2 and 3 are the crest,
and 4 and 5 are downhill (execution). The producer supplies it. FirstMate never
derives a Hill position from task counts, elapsed time, evidence counts, terminal
output, or process activity, which is why `bin/fm-report.sh` still refuses a
numeric `hill.value` or `hill.progress` on its own qualitative reports.

## Capability digest

`capabilityDigest` is the SHA-256 of the canonicalised (`jq -cS`) `capabilities`
object in the same response, and `capabilityDigestSource` names that derivation.
It is computed at response time rather than stored, so it cannot advertise a
stale digest, and a consumer can recompute it from the payload it received.

## Engineering Scotty fixture correspondence

`contracts/fm-bridge/fixtures/engineering-scotty/` is the frozen
`engineering-scotty.v1` cross-repo fixture set, not the `fm-bridge.v2` request
wire: each fixture carries `protocolRevision` and `kind`, and the acceptance and
acknowledgement fixtures describe outcomes rather than requests. A peer repo maps
them onto this bridge as follows.

| Fixture field | fm-bridge.v2 field |
| --- | --- |
| `kind: "execution-group-acceptance"` | `operation: "acceptExecutionGroup"`, `schemaVersion: "cycle-execution.v1"` |
| `kind: "progress-intent"` | `operation: "publishProgress"`, `schemaVersion: "fm-progress-intent.v1"` |
| `taskId` | `childId` and `target.taskId` |
| `shapeUp.hillPosition` | `target.position` |
| `evidence[0].reference` | `evidence.reference` |
| `disposition` | response `state` |

`tests/fm-bridge-cycle-execution-v1.test.sh` drives the frozen fixtures through
the real bridge under that mapping and re-derives the frozen fixture-set digest,
so fixture drift and validator drift both fail loudly. Semantic changes to the
fixtures still require a protocol revision and a coordinated three-repository
re-freeze.
