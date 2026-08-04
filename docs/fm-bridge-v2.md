# FirstMate execution bridge v2

The maintained fork exposes one JSON request/response boundary at
`bin/fm-bridge.sh`. `cycle-execution.v1` accepts one revision-bound Cycle group,
persists it before Scotty delegates children, and returns the original receipt
on exact replay. A changed manifest under an existing execution identity is a
typed conflict. `delegateExecutionGroup` writes child correlations through
FirstMate's durable execution store; Captain's Log never invokes `fm-spawn.sh`.

Crewmate progress is an append-only `fm-progress-intent.v1` record. It remains
in the outbox until Captain's Log acknowledges the exact intent digest. The
read-only `fm-captains-log-projection.sh --json` operation projects groups,
children, and pending intents without parsing terminal output or prose. Shape Up
remains the authority for lifecycle and Hill state; this fork is independently
releasable and does not require upstream maintainer acceptance.
