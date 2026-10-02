#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
source scripts/utils.sh

CC_SREID="${CC_SREID:-study-reidentification}"
CC_WREID="${CC_WREID:-warehouse-reidentification}"

# Register one committee member on a given channel using its public key and org.
# This step configures the K-of-N approval committee that will later validate
# re-identification requests on both the study and warehouse chains.
register_one() {
  local domain="$1"     # e.g. ec1.example.com
  local org="$2"        # e.g. OrgEC1
  local channel="$3"    # study-channel | warehouse-channel
  local cc="$4"         # chaincode name
  local endorsers="$5"  # space-separated list of organizations that endorse the transaction

  local pub
  pub=$(node scripts/test/ec-sign.js pubkey "$domain")

  local pub_json
  pub_json=$(printf '%s' "$pub" | jq -Rs .)

  infoln "Registering $org in $channel ($cc)"
  ./scripts/invokeCC.sh "$channel" "$cc" \
    "{\"function\":\"RegisterCommitteeMember\",\"Args\":[$pub_json]}" \
    NA "$org" $endorsers
}

# Register the SPI's public key so its attestation can be verified on both chains.
register_spi_key() {
  local domain="$1"     # e.g. spi.example.com
  local org="$2"        # e.g. OrgSPI
  local channel="$3"    # study-channel | warehouse-channel
  local cc="$4"         # chaincode name
  local endorsers="$5"  # space-separated list of organizations that endorse the transaction

  local pub
  pub=$(node scripts/test/ec-sign.js pubkey "$domain")

  local pub_json
  pub_json=$(printf '%s' "$pub" | jq -Rs .)

  infoln "Registering SPI public key in $channel ($cc)"
  ./scripts/invokeCC.sh "$channel" "$cc" \
    "{\"function\":\"RegisterSPIPublicKey\",\"Args\":[$pub_json]}" \
    NA "$org" $endorsers
}

STUDY_ENDORSERS_ALL="OrgEC1 OrgEC2 OrgRO"
WAREHOUSE_ENDORSERS_ALL="OrgRO OrgWPI OrgMO"

# Register the EC committee members on both channels.
for pair in "ec1.example.com OrgEC1" "ec2.example.com OrgEC2" "ec3.example.com OrgEC3"; do
  set -- $pair
  register_one "$1" "$2" study-channel     "$CC_SREID" "$STUDY_ENDORSERS_ALL"
  register_one "$1" "$2" warehouse-channel "$CC_WREID" "$WAREHOUSE_ENDORSERS_ALL"
done

# Register the SPI public key on both channels.
register_spi_key "spi.example.com" "OrgRO" study-channel     "$CC_SREID" "$STUDY_ENDORSERS_ALL"
register_spi_key "spi.example.com" "OrgRO" warehouse-channel "$CC_WREID" "$WAREHOUSE_ENDORSERS_ALL"

successln "Committee and SPI keys registered on both channels."