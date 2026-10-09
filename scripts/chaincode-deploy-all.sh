#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

MAX_PARALLEL="${MAX_PARALLEL:-3}"
LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/fabric-deploy-all.XXXXXX")"
cleanup() {
  local status=$?
  if ((status == 0)); then
    rm -rf "$LOG_DIR"
  else
    echo "!! deployment logs retained in $LOG_DIR" >&2
  fi
  exit "$status"
}
trap cleanup EXIT

if ! [[ "$MAX_PARALLEL" =~ ^[1-9][0-9]*$ ]]; then
  echo "MAX_PARALLEL must be a positive integer" >&2
  exit 2
fi

WAREHOUSE_COLLECTIONS="./chaincode/warehouse/collections_config.json"
STUDY_COLLECTIONS="./chaincode/study/collections_config.json"

WAREHOUSE_ORGS=(OrgIM OrgWPI OrgHDW)

STUDY_ORGS=(OrgSC OrgSPI OrgRO)

W_REID_ORGS=(OrgRO OrgWPI OrgMO)

S_REID_ORGS=(OrgRO OrgSPI OrgEC1 OrgEC2 OrgEC3)

deploy_chaincode() {
  local channel="$1"
  local name="$2"
  local source="$3"
  local collections="$4"
  local version="$5"
  local sequence="$6"
  shift 6
  local orgs=("$@")

  printf '%s\n' "$channel" "$name" "$source" "$collections" "$version" "$sequence" "${orgs[*]}"
}

deployments=()
add_deployment() {
  deployments+=("$(deploy_chaincode "$@" | paste -sd '|' -)")
}

add_deployment warehouse-channel identity-mapping \
  ./chaincode/warehouse/identity-mapping "$WAREHOUSE_COLLECTIONS" 1.0 1 \
  "${WAREHOUSE_ORGS[@]}"
add_deployment warehouse-channel warehouse-mapping \
  ./chaincode/warehouse/warehouse-mapping "$WAREHOUSE_COLLECTIONS" 1.0 1 \
  "${WAREHOUSE_ORGS[@]}"
add_deployment warehouse-channel warehouse-reidentification \
  ./chaincode/warehouse/warehouse-reidentification "$WAREHOUSE_COLLECTIONS" 1.0 1 \
  "${W_REID_ORGS[@]}"
add_deployment study-channel study-mapping \
  ./chaincode/study/study-mapping "$STUDY_COLLECTIONS" 1.0 1 \
  "${STUDY_ORGS[@]}"
add_deployment study-channel study-reidentification \
  ./chaincode/study/study-reidentification "$STUDY_COLLECTIONS" 1.0 1 \
  "${S_REID_ORGS[@]}"

run_deployment() {
  local definition="$1"
  local channel name source collections version sequence orgs
  IFS='|' read -r channel name source collections version sequence orgs <<< "$definition"

  echo ">> starting $name on $channel"
  FABRIC_LOG_FILE="$LOG_DIR/${name}.log" \
    ./scripts/network.sh deployCC "$channel" "$name" "$source" "$version" "$sequence" "$collections" $orgs
}

run_deployment_with_output() {
  local definition="$1"
  local name="$2"
  run_deployment "$definition" 2>&1 | tee "$LOG_DIR/$name.log"
}

for ((index = 0; index < ${#deployments[@]}; index += MAX_PARALLEL)); do
  pids=()
  names=()

  for ((offset = 0; offset < MAX_PARALLEL && index + offset < ${#deployments[@]}; offset++)); do
    name="${deployments[index + offset]#*|}"
    name="${name%%|*}"
    run_deployment_with_output "${deployments[index + offset]}" "$name" &
    pids+=("$!")
    names+=("$name")
  done

  batch_failed=0
  for ((offset = 0; offset < ${#pids[@]}; offset++)); do
    if wait "${pids[offset]}"; then
      echo ">> completed ${names[offset]}"
    else
      echo "!! failed ${names[offset]}; output: $LOG_DIR/${names[offset]}.log" >&2
      batch_failed=1
    fi
  done

  if ((batch_failed)); then
    echo "!! deployment batch failed; remaining chaincodes were not started" >&2
    exit 1
  fi
done

echo ">> all chaincodes deployed successfully"