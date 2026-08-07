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
children, and pending intents without parsing terminal output or prose. Shape Up
remains the authority for lifecycle and Hill state; this fork is independently
releasable and does not require upstream maintainer acceptance.
