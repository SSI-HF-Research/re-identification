#!/bin/bash
# lib.sh — timing instrumentation for benchmarks (Scenarios A/B/C).
#
# Output CSV format: label,duration_ms,success,timestamp
#   - duration_ms: command wall-clock time, in milliseconds
#   - success: 1 (rc=0) or 0 (rc!=0)
#   - timestamp: ISO-8601 UTC time at the end of the call
#
# CSV writes are protected by flock because scenarios run calls in parallel
# (multiple processes writing to the same file).

now_ns() { date +%s%N; }

ensure_csv_header() {
  local csv="$1"
  echo "label,duration_ms,success,timestamp" > "$csv"
}

# time_cmd <csv> <label> <out_file> <command...>
# <out_file> receives the command's stdout+stderr (use /dev/null if the output
# is not needed; pass a real file if the value must be read later, e.g.
# a query that returns PII/WP/SP).
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
    echo "  [ERROR in '$label'] rc=$rc: $(tail -c 500 "$out")" >&2
  fi

  return $rc
}
