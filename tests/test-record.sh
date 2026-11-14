#!/bin/bash
# The record of a gate (docs/specs/2026-11-14-client-owns-the-gate-design.md,
# D10 and section 7): client/libexec/devbox-record writes, reads and prunes the
# records under the git common dir, and client/libexec/devbox-result prints
# them.
#
# Each consumer kept its own record cache and printed it as one base64 line
# that every landing script decoded again, and the copies already disagreed.
# This file proves the one plain-text record: a passed, a failed, a cancelled
# and a partial gate, the prune at 200, that a `complete 0` record never
# carries (D10a, whose caller writes the 0), and every form of `devbox result`.
# Each case runs in its own temporary git repository.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
# shellcheck source=tests/lib.sh
source ./lib.sh

REPO="$(cd .. && pwd)"
TMP="$(mktemp -d)" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=t@fixture.invalid
export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=t@fixture.invalid

# shellcheck source=lib/devbox-lib.sh
source "$REPO/lib/devbox-lib.sh"
# shellcheck source=client/libexec/devbox-record
source "$REPO/client/libexec/devbox-record"
RESULT="$REPO/client/libexec/devbox-result"

contains() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }

# A fresh repository on branch main with one commit, as the current directory.
new_repo() {
  local dir="$TMP/$1"
  mkdir -p "$dir" && cd "$dir" || exit 1
  git init -q -b main . && printf 'x\n' >a.txt && git add a.txt && git commit -qm init
}

# Write the text of one record to stdout. $1 run id, $2 at, $3 branch, $4
# scope, $5 complete, then the step and file lines, each one argument with
# fields separated by spaces.
record_text() {
  local run="$1" at="$2" branch="$3" scope="$4" complete="$5" line
  shift 5
  printf 'run\t%s\nat\t%s\nclient\t3.3.0\nbranch\t%s\ncommit\t%s\ntarget\tlan1\nscope\t%s\ncomplete\t%s\n' \
    "$run" "$at" "$branch" 0123456789abcdef0123456789abcdef01234567 "$scope" "$complete"
  for line in "$@"; do printf '%s\n' "${line// /$'\t'}"; done
}

# Write one record through devbox_record_write, with a one-line manifest.
write_record() {
  local run="$1"
  record_text "$@" >"$TMP/rec.txt"
  printf '%064d  a.txt\n' 0 >"$TMP/files.txt"
  devbox_record_write "$run" "$TMP/rec.txt" "$TMP/files.txt"
}

R1=0123456789abcdef.1001
R2=0123456789abcdef.1002
R3=0123456789abcdef.1003
R4=0123456789abcdef.1004
R5=0123456789abcdef.1005

echo "-- the record directory is the git common dir's (D10)"
new_repo dir
dir="$(devbox_record_dir)"
assert_eq "$TMP/dir/.git/devbox/records" "$dir" "the main checkout's records lie under .git/devbox/records"
git worktree add -q "$TMP/dir-wt" -b side 2>/dev/null
wt_dir="$(cd "$TMP/dir-wt" && devbox_record_dir)"
assert_eq "$dir" "$wt_dir" "a linked worktree reads the same directory"
assert_eq "" "$(devbox_record_find_pass build k1)" "no record directory yet: find_pass prints nothing"
assert_ok "and exits 0" devbox_record_find_pass build k1

echo "-- a passed gate"
new_repo passed
write_record "$R1" 1000 main full 1 "step lint k-lint pass 4 0 full" "step test k-test pass 30 0 full" \
  "file test vitest src/a.test.ts pass"
dir="$(devbox_record_dir)"
assert_ok "the record is written" test -f "$dir/$R1.record"
assert_ok "its manifest lies beside it" test -f "$dir/$R1.files"
assert_eq "" "$(find "$dir" -name '.*' -type f)" "no temporary file is left behind the rename"
assert_ok "the record holds the run line, tab separated" grep -qx $'run\t'"$R1" "$dir/$R1.record"
assert_eq "$R1" "$(devbox_record_find_pass test k-test)" "find_pass finds the step under its key"
assert_eq "" "$(devbox_record_find_pass test k-other)" "and nothing under another key"
assert_eq "" "$(devbox_record_find_pass build k-test)" "and nothing for another step"
assert_eq "$R1 pass 0" "$(devbox_record_last_of lint)" "last_of prints run, outcome and code"
assert_eq "$R1" "$(devbox_record_last_pass_of test)" "last_pass_of prints the run"
out="$(bash "$RESULT")"; rc=$?
assert_eq 0 "$rc" "devbox result exits 0"
assert_eq "lint pass 4s code 0 full
test pass 30s code 0 full
devbox: green (2 steps: 2 ran, 0 carried)" "$out" "devbox result prints one line per step and the green verdict"

echo "-- a failed gate"
new_repo failed
write_record "$R1" 1000 main full 1 "step lint k-lint pass 4 0 full" \
  "step test k-test fail 30 1 full" "step typecheck k-tc fail 9 2 full" \
  "file test vitest src/a.test.ts fail" "file test vitest src/b.test.ts pass" \
  "file test vitest src/c.test.ts fail"
assert_eq "$R1 fail 1" "$(devbox_record_last_of test)" "last_of reads the failure and its code"
assert_eq "" "$(devbox_record_last_pass_of test)" "a failed step has no pass"
assert_eq "src/a.test.ts
src/c.test.ts" "$(devbox_record_failed_files "$R1" test)" "failed_files prints the failed files only"
assert_eq "" "$(devbox_record_open_files "$R1" test)" "and no open file"
out="$(bash "$RESULT")"
assert_ok "devbox result names the red verdict with the failed file count" \
  contains "devbox: red (test failed: 2 files; typecheck failed)" "$out"
assert_ok "and the failed step's line" contains "test fail 30s code 1 full" "$out"
assert_eq "src/a.test.ts
src/c.test.ts" "$(bash "$RESULT" --failed-files)" "--failed-files prints every failed file"
assert_eq "src/a.test.ts
src/c.test.ts" "$(bash "$RESULT" --failed-files test)" "--failed-files test prints that step's"
assert_eq "" "$(bash "$RESULT" --failed-files lint)" "--failed-files of a passed step prints nothing"

echo "-- a gate that ended while a file ran"
new_repo open
write_record "$R1" 1000 main full 1 "step test k-test fail 30 1 full" \
  "file test pytest tests/test_a.py fail" "file test pytest tests/test_b.py open"
assert_eq "tests/test_b.py" "$(devbox_record_open_files "$R1" test)" "open_files prints the file that was still running"
assert_eq "tests/test_a.py" "$(devbox_record_failed_files "$R1" test)" "failed_files leaves it out"

echo "-- a cancelled gate: complete 0"
new_repo cancelled
write_record "$R1" 1000 main full 1 "step test k-test fail 30 1 full"
write_record "$R2" 1001 main full 0 "step lint k-lint pass 4 0 full" "step test k-test fail 12 143 full"
assert_eq "" "$(devbox_record_find_pass lint k-lint)" "a pass in a complete 0 record never carries"
assert_eq "" "$(devbox_record_last_pass_of lint)" "nor counts as a pass"
assert_eq "$R1 fail 1" "$(devbox_record_last_of test)" "last_of skips the complete 0 record"
out="$(bash "$RESULT")"
assert_ok "devbox result prints the newest record, incomplete" \
  contains "devbox: incomplete (run $R2 did not end every step, so it does not carry)" "$out"

echo "-- files changed while the gate ran (D10a, record half)"
new_repo changed
write_record "$R1" 1000 main full 0 "step test k-test pass 30 0 full"
assert_eq "" "$(devbox_record_find_pass test k-test)" "a passed step of a complete 0 record never carries"

echo "-- a partial gate"
new_repo partial
write_record "$R1" 1000 main partial 1 "step lint k-lint pass 4 0 full"
assert_eq "$R1" "$(devbox_record_find_pass lint k-lint)" "a partial record's pass carries, because a key is a key"
out="$(bash "$RESULT")"
assert_ok "devbox result calls it a partial pass" contains "devbox: partial pass (1 steps: 1 ran, 0 carried" "$out"
assert_fail "and never green" contains "devbox: green" "$out"

echo "-- carried steps"
new_repo carried
write_record "$R1" 1000 main full 1 "step lint k-lint carried 0 0 full" "step test k-test pass 30 0 narrowed"
assert_eq "$R1" "$(devbox_record_find_pass lint k-lint)" "a carried step answers find_pass under its key"
out="$(bash "$RESULT")"
assert_ok "devbox result counts it as carried" contains "devbox: green (2 steps: 1 ran, 1 carried)" "$out"
assert_ok "and prints a narrowed pass's mode" contains "test pass 30s code 0 narrowed" "$out"

echo "-- the newest record wins, by at"
new_repo newest
write_record "$R2" 2000 main full 1 "step lint k-new pass 4 0 full"
write_record "$R1" 1000 main full 1 "step lint k-old pass 4 0 full"
assert_eq "$R2" "$(devbox_record_last_pass_of lint)" "last_pass_of reads at, never the write order"
write_record "$R3" 3000 main full 1 "step lint k-old pass 4 0 full"
assert_eq "$R3" "$(devbox_record_find_pass lint k-old)" "find_pass prints the newest run under that key"

echo "-- devbox result reads this branch first"
new_repo branches
write_record "$R1" 1000 main full 1 "step lint k1 pass 1 0 full"
write_record "$R2" 2000 side full 1 "step lint k2 fail 2 1 full"
out="$(bash "$RESULT")"
assert_ok "on main, main's record answers though another branch's is newer" contains "lint pass 1s" "$out"
git checkout -q -b fresh
out="$(bash "$RESULT")"
assert_ok "a branch with no record gets the newest of any branch" contains "lint fail 2s" "$out"

echo "-- devbox result --log"
new_repo log
write_record "$R1" 1000 main full 1 "step lint k1 fail 1 1 full" "step test k2 fail 2 1 full"
dir="$(devbox_record_dir)"
cat >"$dir/$R1.log" <<'LOG'
==> sync
[12 s] lint failed (1 s); running: test
== lint: /home/dev/.devbox/logs/run/lint.log
lint line one
lint line two
== test: /home/dev/.devbox/logs/run/test.log
test line one
devbox-steps: result lint fail 1 1
devbox-steps: result test fail 2 1
LOG
assert_eq "== lint: /home/dev/.devbox/logs/run/lint.log
lint line one
lint line two" "$(bash "$RESULT" --log lint)" "--log lint prints its section up to the next header"
assert_eq "== test: /home/dev/.devbox/logs/run/test.log
test line one" "$(bash "$RESULT" --log test)" "--log test stops at the runner's result lines"
bash "$RESULT" --log build >/dev/null 2>"$TMP/err"; rc=$?
assert_eq 1 "$rc" "--log of a step with no section exits 1"
assert_ok "with a line that names the step" grep -q "no section for step build" "$TMP/err"

echo "-- devbox result with no record, and its usage"
new_repo empty
bash "$RESULT" >/dev/null 2>"$TMP/err"; rc=$?
assert_eq 1 "$rc" "no record exits 1"
assert_ok "with a line that says devbox verify writes one" grep -q "no record in .*devbox verify writes one" "$TMP/err"
bash "$RESULT" --bogus >/dev/null 2>&1; rc=$?
assert_eq 2 "$rc" "an unknown option exits 2"
bash "$RESULT" --log >/dev/null 2>&1; rc=$?
assert_eq 2 "$rc" "--log with no step exits 2"
bash "$RESULT" --log 'a b' >/dev/null 2>&1; rc=$?
assert_eq 2 "$rc" "a word that is not a step name exits 2"
mkdir -p "$TMP/nogit" && cd "$TMP/nogit" || exit 1
GIT_CEILING_DIRECTORIES="$TMP" bash "$RESULT" >/dev/null 2>"$TMP/err"; rc=$?
assert_eq 2 "$rc" "outside a git checkout exits 2"

echo "-- a run id that is not one is refused"
new_repo badid
record_text "bad;id" 1000 main full 1 >"$TMP/rec.txt"
devbox_record_write "bad;id" "$TMP/rec.txt" "" 2>/dev/null; rc=$?
assert_eq 2 "$rc" "devbox_record_write refuses it with 2"
assert_ok "and writes nothing" test ! -e "$(devbox_record_dir)"
write_record "$R4" 1000 main full 1 "step lint k1 pass 1 0 full"
record_text "$R5" 1001 main full 1 "step lint k1 pass 1 0 full" >"$TMP/rec.txt"
devbox_record_write "$R5" "$TMP/rec.txt" ""
assert_ok "an empty manifest writes the record alone" test ! -e "$(devbox_record_dir)/$R5.files"
assert_eq "$R5" "$(devbox_record_find_pass lint k1)" "and that record still carries"

echo "-- the prune keeps the 200 newest"
new_repo prune
dir="$(devbox_record_dir)"
mkdir -p "$dir"
for i in $(seq 1 200); do
  run="0123456789abcdef.$((5000 + i))"
  record_text "$run" "$((1000 + i))" main full 1 "step lint k$i pass 1 0 full" >"$dir/$run.record"
  printf '%064d  a.txt\n' 0 >"$dir/$run.files"
  printf 'log\n' >"$dir/$run.log"
done
printf 'running\n' >"$dir/0123456789abcdef.9999.log"
write_record "$R1" 9000 main full 1 "step lint knew pass 1 0 full"
assert_eq 200 "$(find "$dir" -name '*.record' | wc -l | tr -d ' ')" "201 records become 200"
assert_ok "the oldest record is gone" test ! -e "$dir/0123456789abcdef.5001.record"
assert_ok "with its manifest" test ! -e "$dir/0123456789abcdef.5001.files"
assert_ok "and its log" test ! -e "$dir/0123456789abcdef.5001.log"
assert_ok "the second oldest stays" test -e "$dir/0123456789abcdef.5002.record"
assert_ok "the new record stays" test -e "$dir/$R1.record"
assert_ok "a log with no record, a gate that still runs, stays" test -e "$dir/0123456789abcdef.9999.log"
write_record "$R2" 9001 main full 1 "step lint knew pass 1 0 full"
assert_eq 200 "$(find "$dir" -name '*.record' | wc -l | tr -d ' ')" "the next write keeps 200"
assert_ok "and removes the next oldest" test ! -e "$dir/0123456789abcdef.5002.record"

# A gate cancelled before any step ended writes no step line. Its summary once
# read "planned no step" for a gate that was running its test step.
printf 'run\t0123456789abcdef.7001\nat\t1\nclient\t3.3.0\nbranch\tmain\ncommit\t-\ntarget\tlan1\nscope\tpartial\ncomplete\t0\n' >"$TMP/cut.record"
assert_eq "devbox: incomplete (run 0123456789abcdef.7001 ended before any step did, so it does not carry)" \
  "$(devbox_record_summary "$TMP/cut.record")" "a record with no step line and complete 0 reads as incomplete, not empty"
printf 'run\t0123456789abcdef.7002\nat\t1\nclient\t3.3.0\nbranch\tmain\ncommit\t-\ntarget\t-\nscope\tfull\ncomplete\t1\n' >"$TMP/none.record"
assert_eq "devbox: empty (run 0123456789abcdef.7002 planned no step)" \
  "$(devbox_record_summary "$TMP/none.record")" "a complete record with no step line still reads as empty"

printf '%d %d\n' "$TESTS_RUN" "$TESTS_FAILED"
