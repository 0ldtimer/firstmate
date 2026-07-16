# Residual Review Findings

Source: LFG review of the `fm-bridge.v1` walking skeleton on 2026-07-16.

- P2 - `bin/fm-bridge.sh` - A process crash can leave a per-command directory lock behind.
  Replace the narrow atomic directory lock with FirstMate's owner-aware lock primitive and stale-owner recovery.
- P2 - `bin/fm-bridge.sh` - Guarded merge is intentionally unsupported in the first protocol slice.
  Add it only for a project mode that can return an authoritative structured outcome.
