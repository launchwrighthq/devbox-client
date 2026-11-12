#!/bin/bash
# Run every tests/test-*.sh and sum their results.
#
# Each test file is a normal script that sources lib.sh, runs assertions, and
# prints two space-separated integers as its last line -- TESTS_RUN and
# TESTS_FAILED (`printf '%d %d\n' "$TESTS_RUN" "$TESTS_FAILED"` in lib.sh).
# This runner reads that line with `read -r run failed` and sums the pair
# across every file, exiting non-zero if anything failed, so it works as a
# pre-commit gate.
#
# That last line is a contract, and this runner now enforces it. A file used to
# be able to print nothing at all: the empty run and failed then read as 0
# inside $(( )), so a file that crashed on its first line, stopped running, or
# was truncated added 0 assertions and 0 failures and left the gate green. That
# is the same silent skip this repository exists to prevent. A file that exits
# non-zero, times out, prints an unparseable last line, or reports 0 assertions
# is a failure of that file, named in the output, and the suite exits non-zero.
set -uo pipefail
# On a RunPod workspace the real client exports DEVBOX_TARGET=runpod (DEVBOX_BACKEND in an
# older client). Fixture clients must select their own target; inheriting DEVBOX_BACKEND routed SSH
# fixture assertions into real provisioning. The client reads its targets from .devbox.env
# alone and unsets every key of that file first, so these are unset for the suite's own
# scripts and stubs, which read the environment.
unset DEVBOX_BACKEND DEVBOX_TARGET DEVBOX_TARGETS DEVBOX_RENT DEVBOX_GATE_PASSWORD RUNPOD_KEY HCLOUD_TOKEN
cd "$(dirname "${BASH_SOURCE[0]}")" || exit

# A hung test file used to block the gate forever, because the runner waited on
# it with no limit. The budget is generous next to the slowest current file,
# which takes about 4 seconds.
: "${DEVBOX_TEST_TIMEOUT:=120}"
have_timeout=1
if ! command -v timeout >/dev/null 2>&1; then
  # Said once, then every file runs unbounded. A suite with no time limit is
  # still better than no suite at all.
  echo "timeout(1) not found: each test file runs without a time limit" >&2
  have_timeout=0
fi

total_run=0
total_failed=0
files=0
broken=0

for t in test-*.sh; do
  [ -e "$t" ] || continue
  files=$((files + 1))
  printf '\n== %s ==\n' "$t"

  status=0
  if [ "$have_timeout" -eq 1 ]; then
    out=$(timeout "$DEVBOX_TEST_TIMEOUT" bash "$t") || status=$?
  else
    out=$(bash "$t") || status=$?
  fi
  last=$(printf '%s\n' "$out" | tail -1)

  # Nothing below turns a missing or unreadable count into 0. A file that
  # cannot say what it ran is a broken file, not a file that ran nothing.
  reason=""
  run=0
  failed=0
  if [ "$have_timeout" -eq 1 ] && [ "$status" -eq 124 ]; then
    reason="timed out after ${DEVBOX_TEST_TIMEOUT}s"
  elif [ "$status" -ne 0 ]; then
    reason="exited $status"
  elif [[ ! "$last" =~ ^[0-9]+[[:space:]]+[0-9]+$ ]]; then
    reason="last line is not two integers: [$last]"
  else
    read -r run failed <<<"$last"
    # A file that asserts nothing is not a passing file. It is a file whose
    # assertions stopped running.
    [ "$run" -gt 0 ] || reason="reported 0 assertions"
  fi

  if [ -n "$reason" ]; then
    # Print the whole capture, last line included: after a crash that line is
    # evidence, not a summary to hide.
    printf '%s\n' "$out"
    printf '  FAIL %s: %s\n' "$t" "$reason"
    broken=$((broken + 1))
    total_failed=$((total_failed + 1))
    continue
  fi

  printf '%s\n' "$out" | sed '$d'
  # 10# keeps a count written with a leading zero decimal. As an octal literal
  # it would abort the substitution and leave the running total unchanged.
  total_run=$((total_run + 10#$run))
  total_failed=$((total_failed + 10#$failed))
done

printf '\n%s\n' "-----------------------------"
if [ "$files" -eq 0 ]; then
  echo "no test files found" >&2
  exit 1
fi
printf '%d assertions, %d failed, %d files\n' "$total_run" "$total_failed" "$files"
if [ "$broken" -gt 0 ]; then
  printf '%d test file(s) reported no usable result; see the FAIL lines above\n' "$broken" >&2
fi
[ "$total_failed" -eq 0 ]
