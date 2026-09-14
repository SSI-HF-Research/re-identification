#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
source scripts/utils.sh

CC_SREID="${CC_SREID:-study-reidentification}"
CC_WREID="${CC_WREID:-warehouse-reidentification}"

register_one() {
  local domain="$1"     # e.g. ec1.example.com
  local org="$2"        # e.g. OrgEC1
  local channel="$3"    # study-channel | warehouse-channel
  local cc="$4"         # chaincode name
  local endorsers="$5"  # space-separated

  local pub
  pub=$(node scripts/test/ec-sign.js pubkey "$domain")
  local pub_json
  pub_json=$(printf '%s' "$pub" | jq -Rs .)

  infoln "Registrando $org em $channel ($cc)"
  ./scripts/invokeCC.sh "$channel" "$cc" \
    "{\"function\":\"RegisterCommitteeMember\",\"Args\":[$pub_json]}" \
    NA "$org" $endorsers
}

STUDY_ENDORSERS_ALL="OrgEC1 OrgEC2 OrgEC3 OrgSPI OrgRO"
WAREHOUSE_ENDORSERS_ALL="OrgEC1 OrgEC2 OrgEC3 OrgWPI OrgMO"

for pair in "ec1.example.com OrgEC1" "ec2.example.com OrgEC2" "ec3.example.com OrgEC3"; do
  set -- $pair
  register_one "$1" "$2" study-channel     "$CC_SREID" "$STUDY_ENDORSERS_ALL"
  register_one "$1" "$2" warehouse-channel "$CC_WREID" "$WAREHOUSE_ENDORSERS_ALL"
done

successln "Committee registered on both channels."