#!/bin/bash
# lib.sh — instrumentacao de tempo para os benchmarks (Cenarios A/B/C).
#
# Formato do CSV de saida: label,duration_ms,success,timestamp
#   - duration_ms: tempo de parede (wall-clock) do comando, em milissegundos
#   - success: 1 (rc=0) ou 0 (rc!=0)
#   - timestamp: ISO-8601 UTC do fim da chamada
#
# Escrita no CSV e protegida por flock, pois os cenarios rodam chamadas
# em paralelo (varios processos escrevendo no mesmo arquivo).

now_ns() { date +%s%N; }

ensure_csv_header() {
  local csv="$1"
  if [ ! -f "$csv" ]; then
    echo "label,duration_ms,success,timestamp" > "$csv"
  fi
}

# time_cmd <csv> <label> <out_file> <comando...>
# <out_file> recebe stdout+stderr do comando (use /dev/null se nao precisar
# do retorno; passe um arquivo real se precisar ler o valor depois, ex.
# uma query que retorna PII/WP/SP).
time_cmd() {
  local csv="$1" label="$2" out="$3"; shift 3

  local t0 t1 rc=0
  t0=$(now_ns)
  "$@" >"$out" 2>&1 || rc=$?
  t1=$(now_ns)

  local duration_ms=$(( (t1 - t0) / 1000000 ))
  local ts; ts=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)
  local success=1
  [ "$rc" -ne 0 ] && success=0

  {
    flock -x 200
    echo "$label,$duration_ms,$success,$ts" >> "$csv"
  } 200>>"${csv}.lock"

  if [ "$success" -eq 0 ]; then
    echo "  [ERRO em '$label'] rc=$rc: $(tail -c 500 "$out")" >&2
  fi

  return $rc
}
