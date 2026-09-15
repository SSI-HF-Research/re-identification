#!/bin/bash
# Cenario C: teste de carga. Sobe o nivel de concorrencia e mede
# throughput (tx/s) e latencia por nivel, ate a saturacao.
#
# Metricas cobertas: M2 (throughput maximo), M6 (escalabilidade por
# concorrencia).
#
# Operacao usada como carga: RegisterIdentityReference (invoke simples,
# 2 endossantes, escreve em chave unica por chamada — minimiza risco de
# conflito MVCC para isolar o efeito de concorrencia pura).
#
# Uso:
#   LEVELS="1 2 4 8 16 32" OPS_PER_LEVEL=50 ./scenario-c-load.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/scripts/benchmark/config.sh"
source "$ROOT/scripts/benchmark/lib.sh"

SUMMARY_CSV="$BENCH_DIR/scenario-c-throughput-summary.csv"
echo "concurrency,ops_attempted,ops_ok,ops_failed,elapsed_s,throughput_tps_ok" > "$SUMMARY_CSV"

one_op() {
  local idx="$1" csv="$2" out
  out="$(mktemp)"
  local pii="load-pii-${idx}-$(date +%s%N)"
  local ref="load-ref-${idx}-$(openssl rand -hex 8)"
  time_cmd "$csv" "C_register_identity" "$out" \
    "$ROOT/scripts/invokeCC.sh" "$CHANNEL_WAREHOUSE" "$CC_IDENTITY" \
    '{"function":"RegisterIdentityReference","Args":[]}' \
    "{\"pii\":\"$pii\",\"identityReference\":\"$ref\"}" \
    OrgIM OrgIM OrgWPI
  rm -f "$out"
}

for level in $LEVELS; do
  CSV="$BENCH_DIR/scenario-c_level${level}.csv"
  ensure_csv_header "$CSV"
  echo ">> Nivel de concorrencia: $level ($OPS_PER_LEVEL operacoes)"

  t0=$(now_ns)
  i=1
  while [ "$i" -le "$OPS_PER_LEVEL" ]; do
    batch_end=$(( i + level - 1 ))
    [ "$batch_end" -gt "$OPS_PER_LEVEL" ] && batch_end=$OPS_PER_LEVEL
    for ((j=i; j<=batch_end; j++)); do
      one_op "$j" "$CSV" &
    done
    wait
    i=$(( batch_end + 1 ))
  done
  t1=$(now_ns)

  elapsed_s=$(awk "BEGIN{printf \"%.3f\", ($t1-$t0)/1000000000}")
  ok_count=$(awk -F',' '$3==1{c++} END{print c+0}' "$CSV")
  fail_count=$(awk -F',' '$3==0{c++} END{print c+0}' "$CSV")
  tps=$(awk "BEGIN{printf \"%.2f\", $ok_count/$elapsed_s}")

  echo "$level,$OPS_PER_LEVEL,$ok_count,$fail_count,$elapsed_s,$tps" >> "$SUMMARY_CSV"
  echo "   -> ${elapsed_s}s | ok=$ok_count fail=$fail_count | ${tps} tx/s (sucesso)"

  if [ "$fail_count" -gt 0 ]; then
    echo "   ATENCAO: $fail_count falhas neste nivel — checar MVCC_READ_CONFLICT / timeout de endorsement"
  fi
done

echo ""
echo ">> Resumo de throughput por nivel de concorrencia:"
column -t -s',' "$SUMMARY_CSV" 2>/dev/null || cat "$SUMMARY_CSV"
echo ">> Arquivo: $SUMMARY_CSV"
