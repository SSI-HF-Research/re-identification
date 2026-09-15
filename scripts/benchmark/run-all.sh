#!/bin/bash
# run-all.sh — roda os 3 cenarios em sequencia com parametros default
# (ajuste as env vars antes de chamar, ou edite config.sh).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

echo "=================================================="
echo " BENCHMARK — Cenarios A, B, C"
echo "=================================================="

echo ""
echo ">>> Cenario A (ingestao em lote)"
"$ROOT/scripts/benchmark/scenario-a-ingest.sh"

echo ""
echo ">>> Cenario B (re-identificacao completa)"
"$ROOT/scripts/benchmark/scenario-b-reid.sh"

echo ""
echo ">>> Cenario C (teste de carga / throughput)"
"$ROOT/scripts/benchmark/scenario-c-load.sh"

echo ""
echo "=================================================="
echo " Analise agregada"
echo "=================================================="
for csv in "$ROOT"/bench-results/*.csv; do
  [ -f "$csv" ] || continue
  echo ""
  python3 "$ROOT/scripts/benchmark/analyze.py" "$csv"
done
