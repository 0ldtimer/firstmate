#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

TMP=$(fm_test_tmproot fm-bridge-capabilities)
out=$(printf '%s' '{"protocolVersion":"fm-bridge.v2","operation":"capabilities"}' | FM_HOME="$TMP" "$ROOT/bin/fm-bridge.sh") ||
  fail "capabilities request failed"

printf '%s' "$out" | jq -e '
  .accepted == true
  and .protocolVersion == "fm-bridge.v2"
  and .operation == "capabilities"
  and .dispatchable == true
  and (.capabilities | type == "object")
  and .capabilities.missionRevision == "mission-contract.v2"
  and (.capabilities.harnesses | index("local") != null)
  and (.capabilities.deliveryModes | index("local-only") != null)
  and (.capabilities.externalReferences.shapeUp.revision == "shapeup-correlation.v1")
' >/dev/null || fail "fm-bridge.v2 did not advertise the execution capabilities object"$'\n'"$out"

# The advertised digest is derived from the payload, so a consumer can recompute
# it. A hand-written literal would drift the moment the block above changes.
digest=$(printf '%s' "$out" | jq -c '.capabilities' | jq -cS . | { if command -v shasum >/dev/null 2>&1; then shasum -a 256; else sha256sum; fi; } | awk '{print $1}')
[ "$(printf '%s' "$out" | jq -r '.capabilityDigest')" = "$digest" ] ||
  fail "capabilityDigest is not the canonical digest of the advertised capabilities"
[ "$(printf '%s' "$out" | jq -r '.capabilityDigestSource')" = "sha256:canonical(capabilities)" ] ||
  fail "capabilityDigestSource does not name the digest derivation"

matrix="$ROOT/contracts/fm-bridge/compatibility-matrix.v2.json"
for operation in capabilities acceptExecutionGroup executionGroupStatus delegateExecutionGroup \
  renewExecutionLease amendExecutionGroup publishProgress acknowledgeProgress captainsLogProjection; do
  jq -e --arg operation "$operation" '.operations | has($operation)' "$matrix" >/dev/null ||
    fail "compatibility matrix omits the dispatched operation $operation"
done

pass "fm-bridge.v2 advertises a derived capability digest and every dispatched operation is in the matrix"
