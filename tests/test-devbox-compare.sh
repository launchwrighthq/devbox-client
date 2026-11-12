#!/bin/bash
# Tests for counts(), the parser devbox-compare uses to decide whether the
# remote gate tested the same thing as the local one. Every input below is a
# REAL summary line, not a hand-written guess at the shape: each was captured
# from real pytest and vitest runs, including the exact wording pytest itself
# produces ("1 error" singular, "2 errors" plural). The one long pytest line
# keeps that real shape with neutral counts. If this
# parser misreads a real summary, devbox-compare either reports equivalence that does not exist or
# blocks on a difference that is not real, so it is pinned against the actual
# output shape rather than an assumption about it.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
# shellcheck source=tests/lib.sh
source ./lib.sh
# shellcheck source=client/libexec/devbox-compare
source ../client/libexec/devbox-compare

# ── pytest: a single summary line, counts in whatever order pytest prints ──

assert_eq "passed=20 failed=0 skipped=2 errors=0" \
  "$(printf '%s\n' '20 passed, 2 skipped in 0.71s' | counts)" \
  "pytest: passed+skipped, with failed and error absent entirely (both read as 0)"

assert_eq "passed=1 failed=1 skipped=1 errors=1" \
  "$(printf '%s\n' '1 failed, 1 passed, 1 skipped, 1 error in 2.93s' | counts)" \
  "pytest: all four counts present, singular 'error'"

assert_eq "passed=0 failed=0 skipped=0 errors=2" \
  "$(printf '%s\n' '2 errors in 1.24s' | counts)" \
  "pytest: only errors present, plural 'errors' still matches the ^error prefix"

assert_eq "passed=1200 failed=2 skipped=30 errors=0" \
  "$(printf '%s\n' '2 failed, 1200 passed, 30 skipped, 9 warnings in 95.40s' | counts)" \
  "pytest: a trailing 'N warnings' must not be misread as any of the four counts"

assert_eq "passed=3 failed=0 skipped=0 errors=0" \
  "$(printf '%s\n' '3 passed in 0.07s' | counts)" \
  "pytest: a fully clean run with nothing but passed"

# ── vitest: TWO summary lines, "Test Files" (per file) then "Tests" (per
# test), pipe-separated. The awk keeps the LAST match, so the more granular
# "Tests" line must win over the coarser "Test Files" line that precedes it. ──

vitest_clean='
 Test Files  3 passed (3)
      Tests  54 passed (54)
'
assert_eq "passed=54 failed=0 skipped=0 errors=0" "$(printf '%s\n' "$vitest_clean" | counts)" \
  "vitest: Test Files says 3, Tests says 54; the per-test line must win"

vitest_skipped='
 Test Files  1 passed (1)
      Tests  30 passed | 6 skipped (36)
'
assert_eq "passed=30 failed=0 skipped=6 errors=0" "$(printf '%s\n' "$vitest_skipped" | counts)" \
  "vitest: pipe-separated fields on the Tests line parse the same as pytest's comma-separated ones"

vitest_failed='
 Test Files  1 failed (1)
      Tests  1 failed | 1 passed | 1 skipped (3)
'
assert_eq "passed=1 failed=1 skipped=1 errors=0" "$(printf '%s\n' "$vitest_failed" | counts)" \
  "vitest: failed+passed+skipped together, Tests line overrides Test Files' coarser failed=1"

printf '%d %d\n' "$TESTS_RUN" "$TESTS_FAILED"
