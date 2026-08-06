#!/usr/bin/env bash
# FirstMate maintained machine boundary. One JSON request on stdin, one bounded
# JSON response on stdout. Provider state is durable under FM_HOME/data.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
# shellcheck source=bin/fm-cycle-execution-lib.sh
. "$SCRIPT_DIR/fm-cycle-execution-lib.sh"
command -v jq >/dev/null 2>&1 || { printf '%s\n' '{"accepted":false,"error":{"code":"dependency_missing","message":"jq is required"}}'; exit 2; }

request=$(head -c 1048577)
[ "${#request}" -le 1048576 ] || { fm_cycle_fail request_too_large "request exceeds 1 MiB"; exit 2; }
printf '%s' "$request" | jq -e 'type == "object"' >/dev/null 2>&1 || { fm_cycle_fail malformed_request "request must be a JSON object"; exit 2; }
protocol=$(printf '%s' "$request" | jq -r '.protocolVersion // empty')
operation=$(printf '%s' "$request" | jq -r '.operation // empty')
case "$protocol:$operation" in
  fm-bridge.v2:capabilities)
    version=$(git -C "$FM_ROOT" rev-parse HEAD 2>/dev/null || printf '%s' 'local-fork')
    jq -cn --arg home "$FM_HOME" --arg executable "$SCRIPT_DIR/fm-bridge.sh" --arg version "$version" '{
      accepted:true,
      protocolVersion:"fm-bridge.v2",
      operation:"capabilities",
      firstMate:{home:$home,executable:$executable,version:$version},
      effectiveProfile:{harness:"local",backend:"herdr",validationProfile:"no_mistakes",noMistakes:true,deliveryMode:"local-only"},
      capabilityDigest:"545b6719953de01b2274c62bd990888299acf00440b78997158f08e2656bfa54",
      dispatchable:true,
      capabilities:{
        missionRevision:"mission-contract.v2",
        missionResultRevision:"mission-result.v2",
        missionResultOperations:[],
        evidenceContractRevisions:["evidence.v2"],
        harnesses:["local"],
        backends:["herdr"],
        validationProfiles:["no_mistakes"],
        evidenceKinds:["automated","visual"],
        deliveryModes:["local-only"],
        permissions:["repository-write"],
        externalReferences:{shapeUp:{revision:"shapeup-correlation.v1",matching:"opaque-reference-only",required:["cycleRef","buildRef"]}},
        learning:{supported:false,modes:[],skills:[],afterVerificationOnly:true,countsAsEvidence:false,allowedPath:"docs/solutions/"}
      }
    }' ;;
  fm-bridge.v2:acceptExecutionGroup|fm-bridge.v2:createExecutionGroup)
    fm_cycle_accept_group "$request" ;;
  fm-bridge.v2:executionGroupStatus|fm-bridge.v2:getExecutionGroup)
    fm_cycle_status "$(printf '%s' "$request" | jq -r '.executionId // empty')" ;;
  fm-bridge.v2:delegateExecutionGroup|fm-bridge.v2:delegateChildren)
    fm_cycle_delegate "$(printf '%s' "$request" | jq -r '.executionId // empty')" ;;
  fm-bridge.v2:renewExecutionLease|fm-bridge.v2:renewLease)
    fm_cycle_renew "$request" ;;
  fm-bridge.v2:amendExecutionGroup|fm-bridge.v2:amendExecution)
    fm_cycle_amend "$request" ;;
  fm-bridge.v2:publishProgress|fm-bridge.v2:progressIntent)
    fm_cycle_emit_intent "$(printf '%s' "$request" | jq -c '.intent // .')" ;;
  fm-bridge.v2:acknowledgeProgress|fm-bridge.v2:ack)
    fm_cycle_ack "$(printf '%s' "$request" | jq -r '.intentId // empty')" "$(printf '%s' "$request" | jq -r '.intentDigest // .digest // empty')" ;;
  fm-bridge.v2:projection|fm-bridge.v2:captainsLogProjection|fm-bridge.v2:captainsLogProjectionSnapshot)
    fm_cycle_projection ;;
  fm-bridge.v1:snapshot)
    if [ -x "$SCRIPT_DIR/fm-fleet-snapshot.sh" ]; then exec "$SCRIPT_DIR/fm-fleet-snapshot.sh" --json; else jq -cn '{protocolVersion:"fm-bridge.v1",freshness:"unavailable",tasks:[]}' ; fi ;;
  *) fm_cycle_fail unsupported_operation "unsupported protocol or operation"; exit 2 ;;
esac
