# ShapeUp Engineering client

`bin/fm-shapeup-client.sh` is the supervisor-owned boundary for guarded Engineering intent submitted to ShapeUp.

Crewmates, mission records, report records, evidence, and session processes never receive the workspace credential.

## Configuration

The client reads `config/shapeup-client.json` from the active FirstMate home.

```json
{
  "schemaVersion": "fm-shapeup-client.v1",
  "workspaceId": "workspace-1",
  "transport": {
    "kind": "executable",
    "path": "/absolute/path/to/shapeup-transport"
  },
  "credentialFile": "shapeup-token"
}
```

The transport path must be absolute and executable.

The credential filename must be a simple filename under the active home's `config` directory.

The credential file must have mode `0400` or `0600` and should be provisioned by platform-protected secret storage.

The client reads the credential fresh for every operation, so replacing or removing the file rotates or revokes access without changing mission data.

## Transport contract

The transport receives one `shapeup-engineering.v1` JSON request on standard input and receives no command-line arguments.

The workspace credential is present only as `SHAPEUP_WORKSPACE_TOKEN` in the transport environment.

Capability negotiation sends `operation: capabilities` and requires an accepted response containing a capability array.

Submission sends `operation: submit`, a durable idempotency key, opaque Cycle and Build correlation, the expected Build revision guard, optional Scope correlation, and the validated observation.

The first release maps Scope discovery and Scope revision to `scope.write` and qualitative Hill judgment to `hill.write`.

When the configuration exists, accepted ordinary Scope and Hill reports invoke this boundary automatically after FirstMate durably stores the report.

A missing, revoked, incompatible, or partially capable ShapeUp endpoint leaves the FirstMate report accepted and returns only the affected submission as typed unavailable.

Consequential reports enter the durable Captain Call lifecycle and are not submitted as ordinary ShapeUp updates.

## Idempotency and failures

The durable request identity is `fm-report:<report-id>:<report-revision>`.

An exact retry returns the stored semantic outcome with `replayed: true`.

Successful authoritative outcomes are retained in `data/engineering/shapeup-outcomes` and published as `shapeUpOutcomes` by the Captain's Log snapshot.

Reusing a report identity after its accepted revision changes returns `identity_conflict`.

Capability absence returns `capability_unavailable`, a changed ShapeUp guard returns `shapeup_stale`, and an action requiring a proposal returns `proposal_required`.

Transport, credential, negotiation, and unknown remote failures return `shapeup_unavailable` without exposing the credential or deleting the source report.

The client suppresses transport standard error and never includes the credential in requests, arguments, stored reports, outcomes, or diagnostics.

Every transport response is scanned for credential material before it is trusted, and a response carrying any returns `credential_material` instead of being persisted or published.

The scan matches credential-named string values and known secret patterns, so benign non-string fields such as `credentialRotationRequired: false` do not fail a submission.

## Commands

Use `bin/fm-shapeup-client.sh capabilities` to negotiate the current workspace capability document.

Use `bin/fm-shapeup-client.sh submit <report-id>` to submit one already accepted report.

Run `bash tests/fm-shapeup-client.test.sh` for the fixture transport, replay, revocation, and secret-boundary checks.
