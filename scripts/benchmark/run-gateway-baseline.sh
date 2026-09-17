#!/bin/bash
# run-gateway-baseline.sh — measure CLI vs gateway overhead
# Sets up test data, runs the same operations via both transports, writes CSV.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
source scripts/utils.sh
source scripts/envvar.sh
source scripts/benchmark/config.sh

RESULTS="$ROOT/bench-results"
mkdir -p "$RESULTS"
CSV="$RESULTS/gateway-baseline.csv"
echo "operation,type,transport,iter,p50_ms,p95_ms,mean_ms,notes" > "$CSV"

GATEWAY_ITER="${GATEWAY_ITER:-100}"
CLI_ITER="${CLI_ITER:-10}"
WRITE_RUN_ID="$(openssl rand -hex 6)"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
banner() {
  printf '\n== %s ==\n' "$1"
}

kv() {
  printf '  %-10s %s\n' "$1" "$2"
}

now_ms() { echo $(( $(date +%s%N) / 1000000 )); }

cli_read() {
  local org="$1" channel="$2" cc="$3" ctor="$4"
  ./scripts/queryCC.sh "$org" "$channel" "$cc" "$ctor" 2>/dev/null
}

time_cli() {
  # time_cli <n> <cmd...> -> prints p50 p95 mean
  local n="$1"; shift
  local times=()
  local failures=0
  for ((i=0; i<n; i++)); do
    local t0=$(now_ms)
    if ! "$@" >/dev/null 2>&1; then
      failures=$((failures + 1))
    fi
    local t1=$(now_ms)
    times+=($((t1 - t0)))
  done
  if (( failures > 0 )); then
    echo "CLI read failed: $failures/$n invocations" >&2
    return 1
  fi
  printf '%s\n' "${times[@]}" | sort -n > /tmp/cli-times.$$
  local p50 p95 mean
  p50=$(sed -n "$(( n / 2 + 1 ))p" /tmp/cli-times.$$)
  p95=$(sed -n "$(( n * 95 / 100 + 1 ))p" /tmp/cli-times.$$)
  mean=$(awk '{s+=$1} END {printf "%.2f", s/NR}' /tmp/cli-times.$$)
  rm -f /tmp/cli-times.$$
  echo "$p50 $p95 $mean"
}

record() {
  local op="$1" type="$2" transport="$3" iter="$4" p50="$5" p95="$6" mean="$7" notes="${8:-}"
  echo "$op,$type,$transport,$iter,$p50,$p95,$mean,$notes" >> "$CSV"
}

gateway() {
  node "$ROOT/scripts/benchmark/gateway-baseline.js" "$@"
}

# ---------------------------------------------------------------------------
# Setup: 1 patient + 1 datamart + 1 approved re-id request
# ---------------------------------------------------------------------------
banner "Setup"
PII="gw-pii-$(openssl rand -hex 4)"
REF="gw-ref-$(openssl rand -hex 8)"
WP=$(node scripts/test/crypto-helper.js wp "$WP_MASTER_KEY" "$PII")
DM="gw-dm-$(openssl rand -hex 4)"

./scripts/invokeCC.sh warehouse-channel identity-mapping \
  '{"function":"RegisterIdentityReference","Args":[]}' \
  "{\"pii\":\"$PII\",\"identityReference\":\"$REF\"}" \
  OrgIM OrgIM OrgWPI >/dev/null

./scripts/invokeCC.sh warehouse-channel warehouse-mapping \
  "{\"function\":\"RegisterWP\",\"Args\":[\"$REF\"]}" \
  "{\"wp\":\"$WP\"}" OrgWPI OrgWPI OrgHDW >/dev/null

STUDY_KEY=$(node scripts/test/crypto-helper.js hkdf "$SP_MASTER_KEY" study-poc "$DM")
./scripts/invokeCC.sh study-channel study-mapping \
  "{\"function\":\"RegisterSPBatch\",\"Args\":[\"$DM\"]}" \
  "{\"studyKey\":\"$STUDY_KEY\",\"wpList\":[\"$WP\"]}" \
  OrgSPI OrgSPI OrgSC >/dev/null

SP=$(./scripts/queryCC.sh OrgSC study-channel study-mapping \
  "{\"function\":\"GetSPForWP\",\"Args\":[\"$DM\",\"$WP\"]}")

TX=$(mktemp)
CAPTURE_TXID_FILE="$TX" ./scripts/invokeCC.sh study-channel study-reidentification \
  "{\"function\":\"CreateReIDRequest\",\"Args\":[\"study-poc\",\"$DM\",\"$SP\"]}" \
  NA OrgRO OrgRO OrgSPI OrgSC OrgEC1 OrgEC2 >/dev/null
REQ_ID=$(cat "$TX"); rm -f "$TX"

for ec in ec1 ec2; do
  MSG="reid_approval:${REQ_ID}:approve"
  SIG=$(node scripts/test/ec-sign.js sign "${ec}.example.com" "$MSG")
  ./scripts/invokeCC.sh study-channel study-reidentification \
    "{\"function\":\"SignReIDRequest\",\"Args\":[\"$REQ_ID\",\"approve\",\"$SIG\"]}" \
    NA "Org${ec^^}" "OrgEC1" "OrgEC2" "OrgEC3" "OrgSPI" "OrgRO" >/dev/null
done

./scripts/invokeCC.sh study-channel study-reidentification \
  "{\"function\":\"RegisterReIDResult\",\"Args\":[\"$REQ_ID\"]}" \
  "{\"wp\":\"$WP\"}" OrgSPI OrgSPI OrgRO >/dev/null

APPROVALS=$(./scripts/queryCC.sh OrgRO study-channel study-reidentification \
  "{\"function\":\"GetReIDApprovals\",\"Args\":[\"$REQ_ID\"]}")
./scripts/invokeCC.sh warehouse-channel warehouse-reidentification \
  "{\"function\":\"RegisterReIdentifiedPII\",\"Args\":[\"$REQ_ID\"]}" \
  "{\"pii\":\"$PII\",\"approvals\":$APPROVALS}" \
  OrgWPI OrgWPI OrgMO OrgEC1 OrgEC2 >/dev/null

PUBKEY=$(node scripts/test/ec-sign.js pubkey ec1.example.com)

successln "Setup done: REF=$REF WP=$WP SP=$SP REQ_ID=$REQ_ID"

# ---------------------------------------------------------------------------
# READ baseline — no-op
# ---------------------------------------------------------------------------
banner "Read: testChaincode (no-op baseline)"

cli_stats=$(time_cli "$CLI_ITER" cli_read OrgWPI warehouse-channel identity-mapping '{"function":"testChaincode","Args":[]}')
read op50 op95 omean <<< "$cli_stats"
record "testChaincode" "read" "cli" "$CLI_ITER" "$op50" "$op95" "$omean" ""
kv "CLI:" "$omean ms"

GW=$(gateway OrgWPI warehouse-channel identity-mapping testChaincode)
record "testChaincode" "read" "gateway" "$GATEWAY_ITER" "$(echo "$GW" | jq -r .p50_ms)" "$(echo "$GW" | jq -r .p95_ms)" "$(echo "$GW" | jq -r .mean_ms)" ""
kv "Gateway:" "$(echo "$GW" | jq -r .mean_ms) ms"

# ---------------------------------------------------------------------------
# READ — GetPii (PDC read, 2-org collection)
# ---------------------------------------------------------------------------
banner "Read: GetPii"

cli_stats=$(time_cli "$CLI_ITER" cli_read OrgWPI warehouse-channel identity-mapping "{\"function\":\"GetPii\",\"Args\":[\"$REF\"]}")
read op50 op95 omean <<< "$cli_stats"
record "GetPii" "read" "cli" "$CLI_ITER" "$op50" "$op95" "$omean" "ref=$REF"
kv "CLI:" "$omean ms"

GW=$(gateway OrgWPI warehouse-channel identity-mapping GetPii "$REF")
record "GetPii" "read" "gateway" "$GATEWAY_ITER" "$(echo "$GW" | jq -r .p50_ms)" "$(echo "$GW" | jq -r .p95_ms)" "$(echo "$GW" | jq -r .mean_ms)" ""
kv "Gateway:" "$(echo "$GW" | jq -r .mean_ms) ms"

# ---------------------------------------------------------------------------
# READ — GetSPListByDatamart (larger payload)
# ---------------------------------------------------------------------------
banner "Read: GetSPListByDatamart"

cli_stats=$(time_cli "$CLI_ITER" cli_read OrgSC study-channel study-mapping "{\"function\":\"GetSPListByDatamart\",\"Args\":[\"$DM\"]}")
read op50 op95 omean <<< "$cli_stats"
record "GetSPListByDatamart" "read" "cli" "$CLI_ITER" "$op50" "$op95" "$omean" "dm=$DM"
kv "CLI:" "$omean ms"

GW=$(gateway OrgSPI study-channel study-mapping GetSPListByDatamart "$DM")
record "GetSPListByDatamart" "read" "gateway" "$GATEWAY_ITER" "$(echo "$GW" | jq -r .p50_ms)" "$(echo "$GW" | jq -r .p95_ms)" "$(echo "$GW" | jq -r .mean_ms)" ""
kv "Gateway:" "$(echo "$GW" | jq -r .mean_ms) ms"

# ---------------------------------------------------------------------------
# READ — GetReIDRequest (world-state read)
# ---------------------------------------------------------------------------
banner "Read: GetReIDRequest"

cli_stats=$(time_cli "$CLI_ITER" cli_read OrgRO study-channel study-reidentification "{\"function\":\"GetReIDRequest\",\"Args\":[\"$REQ_ID\"]}")
read op50 op95 omean <<< "$cli_stats"
record "GetReIDRequest" "read" "cli" "$CLI_ITER" "$op50" "$op95" "$omean" "req=$REQ_ID"
kv "CLI:" "$omean ms"

GW=$(gateway OrgRO study-channel study-reidentification GetReIDRequest "$REQ_ID")
record "GetReIDRequest" "read" "gateway" "$GATEWAY_ITER" "$(echo "$GW" | jq -r .p50_ms)" "$(echo "$GW" | jq -r .p95_ms)" "$(echo "$GW" | jq -r .mean_ms)" ""
kv "Gateway:" "$(echo "$GW" | jq -r .mean_ms) ms"

# ---------------------------------------------------------------------------
# WRITE — RegisterCommitteeMember (world-state write, no transient)
# ---------------------------------------------------------------------------
banner "Write: RegisterCommitteeMember"

# CLI: caller=OrgEC1, endorsers=OrgEC1 OrgEC2 (5 to satisfy MAJORITY on study channel)
time_cli_write() {
  local n="$1"; shift
  local times=()
  local failures=0
  for ((i=0; i<n; i++)); do
    local t0=$(now_ms)
    if ! "$@" >/dev/null 2>&1; then
      failures=$((failures + 1))
    fi
    local t1=$(now_ms)
    times+=($((t1 - t0)))
  done
  if (( failures > 0 )); then
    echo "CLI write failed: $failures/$n invocations" >&2
    return 1
  fi
  printf '%s\n' "${times[@]}" | sort -n > /tmp/cli-w.$$
  local p50 p95 mean
  p50=$(sed -n "$(( n / 2 + 1 ))p" /tmp/cli-w.$$)
  p95=$(sed -n "$(( n * 95 / 100 + 1 ))p" /tmp/cli-w.$$)
  mean=$(awk '{s+=$1} END {printf "%.2f", s/NR}' /tmp/cli-w.$$)
  rm -f /tmp/cli-w.$$
  echo "$p50 $p95 $mean"
}

cli_stats=$(time_cli_write "$CLI_ITER" \
  ./scripts/invokeCC.sh study-channel study-reidentification \
  "{\"function\":\"RegisterCommitteeMember\",\"Args\":[$(printf '%s' "$PUBKEY" | jq -Rs .)]}" \
  NA OrgEC1 OrgEC1 OrgEC2 OrgEC3 OrgSPI OrgRO)
read op50 op95 omean <<< "$cli_stats"
record "RegisterCommitteeMember" "write" "cli" "$CLI_ITER" "$op50" "$op95" "$omean" ""
kv "CLI:" "$omean ms"

GW=$(gateway --submit --endorsing-orgs OrgEC1MSP,OrgEC2MSP,OrgEC3MSP,OrgSPIMSP,OrgROMSP \
  OrgEC1 study-channel study-reidentification RegisterCommitteeMember "$PUBKEY")
record "RegisterCommitteeMember" "write" "gateway" "$GATEWAY_ITER" "$(echo "$GW" | jq -r .p50_ms)" "$(echo "$GW" | jq -r .p95_ms)" "$(echo "$GW" | jq -r .mean_ms)" ""
kv "Gateway:" "$(echo "$GW" | jq -r .mean_ms) ms"

# ---------------------------------------------------------------------------
# WRITE — RegisterWP (PDC write with transient)
# ---------------------------------------------------------------------------
banner "Write: RegisterWP (PDC + transient)"

# Each iteration needs a fresh ref+wp to avoid idempotent short-circuit.
# We measure setup (fresh ref+wp) outside the timer.
time_cli_write_transient() {
  local n="$1"; shift
  local times=()
  local failures=0
  for ((i=0; i<n; i++)); do
    local fresh_pii="gw-write-pii-$WRITE_RUN_ID-$i"
    local fresh_ref="gw-write-ref-$i-$(openssl rand -hex 4)"
    local fresh_wp=$(node scripts/test/crypto-helper.js wp "$WP_MASTER_KEY" "$fresh_pii")
    # register identity first (not timed)
    if ! ./scripts/invokeCC.sh warehouse-channel identity-mapping \
      '{"function":"RegisterIdentityReference","Args":[]}' \
      "{\"pii\":\"$fresh_pii\",\"identityReference\":\"$fresh_ref\"}" \
      OrgIM OrgIM OrgWPI >/dev/null 2>&1; then
      echo "CLI identity setup failed at iteration $i" >&2
      return 1
    fi
    local t0=$(now_ms)
    if ! ./scripts/invokeCC.sh warehouse-channel warehouse-mapping \
      "{\"function\":\"RegisterWP\",\"Args\":[\"$fresh_ref\"]}" \
      "{\"wp\":\"$fresh_wp\"}" OrgWPI OrgWPI OrgHDW >/dev/null 2>&1; then
      failures=$((failures + 1))
    fi
    local t1=$(now_ms)
    times+=($((t1 - t0)))
  done
  if (( failures > 0 )); then
    echo "CLI transient write failed: $failures/$n invocations" >&2
    return 1
  fi
  printf '%s\n' "${times[@]}" | sort -n > /tmp/cli-wt.$$
  local p50 p95 mean
  p50=$(sed -n "$(( n / 2 + 1 ))p" /tmp/cli-wt.$$)
  p95=$(sed -n "$(( n * 95 / 100 + 1 ))p" /tmp/cli-wt.$$)
  mean=$(awk '{s+=$1} END {printf "%.2f", s/NR}' /tmp/cli-wt.$$)
  rm -f /tmp/cli-wt.$$
  echo "$p50 $p95 $mean"
}

cli_stats=$(time_cli_write_transient "$CLI_ITER")
read op50 op95 omean <<< "$cli_stats"
record "RegisterWP" "write" "cli" "$CLI_ITER" "$op50" "$op95" "$omean" "fresh ref per iter"
kv "CLI:" "$omean ms"

GW=$(gateway --submit --fresh-register-wp \
  --endorsing-orgs OrgWPIMSP,OrgHDWMSP \
  OrgWPI warehouse-channel warehouse-mapping RegisterWP)
record "RegisterWP" "write" "gateway" "$GATEWAY_ITER" \
  "$(echo "$GW" | jq -r .p50_ms)" "$(echo "$GW" | jq -r .p95_ms)" \
  "$(echo "$GW" | jq -r .mean_ms)" "fresh ref per iter"
kv "Gateway:" "$(echo "$GW" | jq -r .mean_ms) ms"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
banner "Summary"
column -t -s',' "$CSV" 2>/dev/null || cat "$CSV"
successln "CSV: $CSV"