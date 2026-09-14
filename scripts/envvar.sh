#!/bin/bash
# envvar.sh — auxiliar function to change identity when calling the peer CLI.
# source scripts/envvar.sh ; setOrgIM ; peer channel list

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CRYPTO="$ROOT/network/crypto-config"

export CORE_PEER_TLS_ENABLED=true
export ORDERER_CA="$CRYPTO/ordererOrganizations/example.com/orderers/orderer.example.com/tls/ca.crt"
export ORDERER_ADMIN_TLS_SIGN_CERT="$CRYPTO/ordererOrganizations/example.com/orderers/orderer.example.com/tls/server.crt"
export ORDERER_ADMIN_TLS_PRIVATE_KEY="$CRYPTO/ordererOrganizations/example.com/orderers/orderer.example.com/tls/server.key"

setOrgIM() {
  export CORE_PEER_LOCALMSPID="OrgIMMSP"
  export CORE_PEER_TLS_ROOTCERT_FILE="$CRYPTO/peerOrganizations/im.example.com/peers/peer0.im.example.com/tls/ca.crt"
  export CORE_PEER_MSPCONFIGPATH="$CRYPTO/peerOrganizations/im.example.com/users/Admin@im.example.com/msp"
  export CORE_PEER_ADDRESS=localhost:7051
}

setOrgWPI() {
  export CORE_PEER_LOCALMSPID="OrgWPIMSP"
  export CORE_PEER_TLS_ROOTCERT_FILE="$CRYPTO/peerOrganizations/wpi.example.com/peers/peer0.wpi.example.com/tls/ca.crt"
  export CORE_PEER_MSPCONFIGPATH="$CRYPTO/peerOrganizations/wpi.example.com/users/Admin@wpi.example.com/msp"
  export CORE_PEER_ADDRESS=localhost:8051
}

setOrgHDW() {
  export CORE_PEER_LOCALMSPID="OrgHDWMSP"
  export CORE_PEER_TLS_ROOTCERT_FILE="$CRYPTO/peerOrganizations/hdw.example.com/peers/peer0.hdw.example.com/tls/ca.crt"
  export CORE_PEER_MSPCONFIGPATH="$CRYPTO/peerOrganizations/hdw.example.com/users/Admin@hdw.example.com/msp"
  export CORE_PEER_ADDRESS=localhost:9051
}

setOrgSC() {
  export CORE_PEER_LOCALMSPID="OrgSCMSP"
  export CORE_PEER_TLS_ROOTCERT_FILE="$CRYPTO/peerOrganizations/sc.example.com/peers/peer0.sc.example.com/tls/ca.crt"
  export CORE_PEER_MSPCONFIGPATH="$CRYPTO/peerOrganizations/sc.example.com/users/Admin@sc.example.com/msp"
  export CORE_PEER_ADDRESS=localhost:10051
}

setOrgSPI() {
  export CORE_PEER_LOCALMSPID="OrgSPIMSP"
  export CORE_PEER_TLS_ROOTCERT_FILE="$CRYPTO/peerOrganizations/spi.example.com/peers/peer0.spi.example.com/tls/ca.crt"
  export CORE_PEER_MSPCONFIGPATH="$CRYPTO/peerOrganizations/spi.example.com/users/Admin@spi.example.com/msp"
  export CORE_PEER_ADDRESS=localhost:11051
}

setOrgRO() {
  export CORE_PEER_LOCALMSPID="OrgROMSP"
  export CORE_PEER_TLS_ROOTCERT_FILE="$CRYPTO/peerOrganizations/ro.example.com/peers/peer0.ro.example.com/tls/ca.crt"
  export CORE_PEER_MSPCONFIGPATH="$CRYPTO/peerOrganizations/ro.example.com/users/Admin@ro.example.com/msp"
  export CORE_PEER_ADDRESS=localhost:12051
}

setOrgMO() {
  export CORE_PEER_LOCALMSPID="OrgMOMSP"
  export CORE_PEER_TLS_ROOTCERT_FILE="$CRYPTO/peerOrganizations/mo.example.com/peers/peer0.mo.example.com/tls/ca.crt"
  export CORE_PEER_MSPCONFIGPATH="$CRYPTO/peerOrganizations/mo.example.com/users/Admin@mo.example.com/msp"
  export CORE_PEER_ADDRESS=localhost:13051
}

setOrgEC1() {
  export CORE_PEER_LOCALMSPID="OrgEC1MSP"
  export CORE_PEER_TLS_ROOTCERT_FILE="$CRYPTO/peerOrganizations/ec1.example.com/peers/peer0.ec1.example.com/tls/ca.crt"
  export CORE_PEER_MSPCONFIGPATH="$CRYPTO/peerOrganizations/ec1.example.com/users/Admin@ec1.example.com/msp"
  export CORE_PEER_ADDRESS=localhost:14051
}
setOrgEC2() {
  export CORE_PEER_LOCALMSPID="OrgEC2MSP"
  export CORE_PEER_TLS_ROOTCERT_FILE="$CRYPTO/peerOrganizations/ec2.example.com/peers/peer0.ec2.example.com/tls/ca.crt"
  export CORE_PEER_MSPCONFIGPATH="$CRYPTO/peerOrganizations/ec2.example.com/users/Admin@ec2.example.com/msp"
  export CORE_PEER_ADDRESS=localhost:15051
}
setOrgEC3() {
  export CORE_PEER_LOCALMSPID="OrgEC3MSP"
  export CORE_PEER_TLS_ROOTCERT_FILE="$CRYPTO/peerOrganizations/ec3.example.com/peers/peer0.ec3.example.com/tls/ca.crt"
  export CORE_PEER_MSPCONFIGPATH="$CRYPTO/peerOrganizations/ec3.example.com/users/Admin@ec3.example.com/msp"
  export CORE_PEER_ADDRESS=localhost:16051
}


declare -A ORG_SETTER=(
  [OrgIM]=setOrgIM
  [OrgWPI]=setOrgWPI
  [OrgHDW]=setOrgHDW
  [OrgSC]=setOrgSC
  [OrgSPI]=setOrgSPI
  [OrgMO]=setOrgMO
  [OrgRO]=setOrgRO
  [OrgEC1]=setOrgEC1
  [OrgEC2]=setOrgEC2
  [OrgEC3]=setOrgEC3
)

setGlobalsForOrg() {
  local org="$1"
  local fn="${ORG_SETTER[$org]:-}"
  [ -z "$fn" ] && { echo "!! unknown org: $org (options: ${!ORG_SETTER[*]})" >&2; exit 1; }
  "$fn"
}

parsePeerConnectionParameters() {
  PEER_CONN_PARMS=()
  for org in "$@"; do
    setGlobalsForOrg "$org"
    PEER_CONN_PARMS+=(--peerAddresses "$CORE_PEER_ADDRESS" --tlsRootCertFiles "$CORE_PEER_TLS_ROOTCERT_FILE")
  done
}