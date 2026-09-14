#!/bin/bash
# ============================================================================
# lib.sh — Shared helpers for the security test suite.
#
# PURPOSE
#   Provides positive/negative assertion helpers that produce a common
#   report format. Every test file uses the same pattern:
#     expect_allowed  "description" <cmd...>
#     expect_denied   "description" <cmd...>
#   and prints a summary at the end.
#
# METRICS SERVED
#   Not a metric — a test harness. Produces a pass/fail count per test file.
# ============================================================================

set -uo pipefail

PASS_COUNT=0
FAIL_COUNT=0
RESULTS_FILE="${RESULTS_FILE:-}"

# expect_allowed <description> <cmd...>
#   Runs the command; test PASSES if rc==0, FAILS otherwise.
expect_allowed() {
  local desc="$1"; shift
  local out; out="$(mktemp)"
  if "$@" > "$out" 2>&1; then
    PASS_COUNT=$(( PASS_COUNT + 1 ))
    printf "  \033[0;32mPASS\033[0m  %s\n" "$desc"
    [ -n "$RESULTS_FILE" ] && echo "PASS,$desc" >> "$RESULTS_FILE"
  else
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
    printf "  \033[0;31mFAIL\033[0m  %s (expected allow, got deny)\n" "$desc"
    tail -n 3 "$out" | sed 's/^/         /'
    [ -n "$RESULTS_FILE" ] && echo "FAIL,$desc" >> "$RESULTS_FILE"
  fi
  rm -f "$out"
}

# expect_denied <description> <cmd...>
#   Runs the command; test PASSES if rc!=0, FAILS otherwise.
#   Optional second description suffix documents the expected rejection reason.
expect_denied() {
  local desc="$1"; shift
  local out; out="$(mktemp)"
  if "$@" > "$out" 2>&1; then
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
    printf "  \033[0;31mFAIL\033[0m  %s (expected deny, got allow)\n" "$desc"
    [ -n "$RESULTS_FILE" ] && echo "FAIL,$desc" >> "$RESULTS_FILE"
  else
    PASS_COUNT=$(( PASS_COUNT + 1 ))
    printf "  \033[0;32mPASS\033[0m  %s\n" "$desc"
    [ -n "$RESULTS_FILE" ] && echo "PASS,$desc" >> "$RESULTS_FILE"
  fi
  rm -f "$out"
}

print_summary() {
  local title="$1"
  echo ""
  echo "=============================================================="
  echo " $title"
  echo " pass: $PASS_COUNT   fail: $FAIL_COUNT"
  echo "=============================================================="
  [ "$FAIL_COUNT" -eq 0 ] || return 1
}

# Convenience wrappers around the fabric scripts
q()  { "$ROOT/scripts/queryCC.sh" "$@"; }
inv(){ "$ROOT/scripts/invokeCC.sh" "$@"; }