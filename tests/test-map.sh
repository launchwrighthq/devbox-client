#!/bin/bash
# The map of each step (docs/specs/2026-11-14-learned-selection-design.md,
# sections 5.5 and 5.6): client/libexec/devbox-map merges a run's trace into
# <git common dir>/devbox/maps/<step>.<ctx>.map, one map per step and context
# (docs/specs/2026-11-16-gate-overload-design.md, section 6), and answers the
# plan with a step's learned inputs and the test files a change reaches.
#
# A step without inputs= hashed every synced file, so any change ran it in
# full. The traces here are written by hand in the format of section 5.6, as
# the runner plug-ins write them, and the records with devbox_record_write, as
# a gate leaves them.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
# shellcheck source=tests/lib.sh
source ./lib.sh

REPO="$(cd .. && pwd)"
TMP="$(mktemp -d)" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

# shellcheck source=lib/devbox-lib.sh
source "$REPO/lib/devbox-lib.sh"
# shellcheck source=client/libexec/devbox-record
source "$REPO/client/libexec/devbox-record"
# shellcheck source=client/libexec/devbox-map
source "$REPO/client/libexec/devbox-map"

contains() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }

mkdir -p "$TMP/repo" && cd "$TMP/repo" || exit 1
git init -q -b main .
for f in src/a.py src/b.py tests/test_a.py tests/test_b.py data/one.json docs/x.md; do
  mkdir -p "$(dirname "$f")" && printf '%s v1\n' "$f" >"$f"
done
M="$TMP/manifest"
# .pytest_cache stands for a tool's ignored cache, which the sync never sends.
manifest() {
  find . \( -path ./.git -o -path ./.pytest_cache \) -prune -o -type f -print | sed 's|^\./||' | LC_ALL=C sort \
    | xargs -d '\n' sha256sum -- >"$M"
}
SEQ=100
# Write a complete record for a run of step test with the outcomes after it,
# `<path>:<outcome>`, and the manifest of the tree. Sets RUN.
record() {
  local stepout="$1" o
  shift
  SEQ=$((SEQ + 1)); RUN="0123456789abcdef.$SEQ"
  manifest
  {
    printf 'run\t%s\nat\t%s\nclient\t3.4.0\nbranch\tmain\ncommit\t-\ntarget\tlan1\nscope\tfull\ncomplete\t1\n' "$RUN" "$SEQ"
    printf 'step\ttest\t%064d\t%s\t1\t0\tfull\n' 0 "$stepout"
    for o in "$@"; do printf 'file\ttest\tpytest\t%s\t%s\t1\n' "${o%%:*}" "${o#*:}"; done
  } >"$TMP/rec"
  devbox_record_write "$RUN" "$TMP/rec" "$M"
}
T="$TMP/trace"
MAPS="$(git rev-parse --path-format=absolute --git-common-dir)/devbox/maps"
C1="$(devbox_map_ctx base1 setup1)"
C2="$(devbox_map_ctx base2 setup1)"
MAP="$MAPS/test.$C1.map"

echo "-- no map"
assert_eq "$(printf 'base1\nsetup1\n' | sha256sum | cut -c1-16)" "$C1" \
  "gate overload D8: a context id is the first 16 hex digits of the sha256 of its values, each with a newline"
assert_eq none "$(devbox_map_state test "$C1")" "a step that never ran has no map"
assert_fail "and no learned inputs" devbox_map_step_inputs test "$C1"
rc=0; devbox_map_select test "$M" "$C1" >/dev/null || rc=$?
assert_eq 1 "$rc" "select says no map with 1"

echo "-- a full run's trace"
printf '%s\n' \
  $'read\ttests/test_a.py\ttests/test_a.py' $'read\ttests/test_a.py\t./src/a.py' \
  $'read\ttests/test_a.py\tdata/one.json' $'list\ttests/test_a.py\tdata' \
  $'setup\ttests/test_a.py' \
  $'read\ttests/test_b.py\tsrc/b.py' $'read\ttests/test_b.py\t/usr/lib/python3/os.py' \
  $'read\ttests/test_b.py\t.venv/lib/site.py' $'read\ttests/test_b.py\t../outside.txt' \
  $'read\t-\tpytest.ini' $'list\t-\ttests' >"$T"
record pass tests/test_a.py:pass tests/test_b.py:pass
run1="$RUN"
devbox_map_update test "$RUN" "$T" run "$C1" base1 setup1
assert_eq ok "$(devbox_map_state test "$C1")" "the update writes a map that reads"
assert_eq "data/
data/one.json
pytest.ini
src/a.py
src/b.py
tests/
tests/test_a.py
tests/test_b.py" "$(devbox_map_step_inputs test "$C1")" \
  "the inputs: the step's own reads, every test file's reads and the test files, ./ and paths outside dropped"
assert_ok "a read under .venv marks the setup key" devbox_map_reads_setup test "$C1"
assert_eq "base1 setup1" "$(devbox_map_context test "$C1")" "the map keeps the context it was traced under"
assert_eq "$run1" "$(devbox_map_step_run test "$C1")" "a run updates the step's last full trace"
assert_fail "no map path leaves the checkout" grep -q 'outside\|/usr/lib\|\.venv' "$MAP"

echo "-- select: what a change reaches"
manifest
assert_eq "" "$(devbox_map_select test "$M" "$C1" base1 setup1)" "an unchanged tree selects nothing"
printf 'more\n' >>docs/x.md
manifest
assert_eq "" "$(devbox_map_select test "$M" "$C1" base1 setup1)" "an unread file selects nothing"
printf 'more\n' >>data/one.json
manifest
assert_eq "tests/test_a.py	read data/one.json" "$(devbox_map_select test "$M" "$C1" base1 setup1)" \
  "a changed data file selects the test that read it alone"
printf 'data/one.json v1\n' >data/one.json
printf '{}\n' >data/two.json
manifest
assert_eq "tests/test_a.py	read data/" "$(devbox_map_select test "$M" "$C1" base1 setup1)" \
  "a file added to a listed directory selects the test that listed it"
rm data/two.json
printf 'more\n' >>pytest.ini
manifest
assert_eq "tests/test_a.py	read pytest.ini
tests/test_b.py	read pytest.ini" "$(devbox_map_select test "$M" "$C1" base1 setup1)" \
  "a file the step's own process read selects every test file"
rm pytest.ini
printf 'more\n' >>tests/test_b.py
manifest
assert_eq "tests/test_b.py	changed" "$(devbox_map_select test "$M" "$C1" base1 setup1)" "a changed test file is changed"
printf 'tests/test_b.py v1\n' >tests/test_b.py
manifest
rc=0; devbox_map_select test "$M" "$C2" base2 setup1 >/dev/null || rc=$?
assert_eq 1 "$rc" "gate overload D8: another context reads its own map, and it has none"
# The context line stays as a check: a map whose line names another context
# than the one its name says proves nothing for this run.
rc=0; devbox_map_select test "$M" "$C1" base2 setup1 >/dev/null || rc=$?
assert_eq 3 "$rc" "a context line with another base returns 3"
rc=0; devbox_map_select test "$M" "$C1" base1 setup2 >/dev/null || rc=$?
assert_eq 3 "$rc" "another setup key returns 3, when a file read under a setup output"

echo "-- a part run merges, a failure clears the pass"
printf '%s\n' $'read\ttests/test_a.py\tsrc/a.py' $'read\ttests/test_a.py\tsrc/b.py' >"$T"
record fail tests/test_a.py:fail
devbox_map_update test "$RUN" "$T" select "$C1" base1 setup1
assert_eq "$run1" "$(devbox_map_step_run test "$C1")" "a part run keeps the last full trace"
assert_ok "test_b keeps its line" grep -q $'^file\ttests/test_b.py\t'"$run1" "$MAP"
assert_ok "test_a failed, so it has no pass" grep -q $'^file\ttests/test_a.py\t-\tcomplete' "$MAP"
manifest
assert_eq "tests/test_a.py	no trace" "$(devbox_map_select test "$M" "$C1" base1 setup1)" "a file with no pass reads as no trace"

echo "-- a partial file, a gone file, a pruned record"
printf '%s\n' $'read\ttests/test_a.py\tsrc/a.py' $'partial\ttests/test_a.py\tsubprocess python' >"$T"
record pass tests/test_a.py:pass
devbox_map_update test "$RUN" "$T" select "$C1" base1 setup1
# 4.0.1 D2: one partial file once gave its step every synced file as its key,
# so a docs-only edit selected every partial file of the step.
assert_eq "pytest.ini
src/a.py
src/b.py
tests/
tests/test_a.py
tests/test_b.py" "$(devbox_map_step_inputs test "$C1")" \
  "4.0.1 D2: a partial file keeps the step's learned inputs, its own reads among them"
manifest
assert_eq "tests/test_a.py	partial" "$(devbox_map_select test "$M" "$C1" base1 setup1)" "and is selected"
rm tests/test_b.py
record pass
devbox_map_update test "$RUN" "$T" select "$C1" base1 setup1
assert_fail "a test file that is gone loses its line" grep -q $'^file\ttests/test_b.py' "$MAP"
printf 'tests/test_b.py v1\n' >tests/test_b.py
printf '%s\n' $'read\ttests/test_b.py\tsrc/b.py' >"$T"
record pass tests/test_b.py:pass
devbox_map_update test "$RUN" "$T" select "$C1" base1 setup1
rm "$(devbox_record_dir)/$RUN.files"
manifest
assert_ok "a pruned manifest makes its files no trace" contains "tests/test_b.py	no trace" "$(devbox_map_select test "$M" "$C1" base1 setup1)"

echo "-- a context line that changed clears the passes of files that did not run"
# A step with no runner keys its map by its trace base alone (gate overload
# D8), so a forwarded value or a lock file edit writes the same map under
# another map base.
printf '%s\n' $'read\ttests/test_b.py\tsrc/b.py' >"$T"
record pass tests/test_b.py:pass
devbox_map_update test "$RUN" "$T" narrow "$C1" base9 setup1
assert_ok "test_a, which did not run, has no pass" grep -q $'^file\ttests/test_a.py\t-\t' "$MAP"
assert_ok "test_b, which ran, has this run" grep -q $'^file\ttests/test_b.py\t'"$RUN" "$MAP"

echo "-- an untraced step keeps its inputs"
rm -f "$MAP"
printf '%s\n' $'read\t-\tsrc/a.py' $'list\t-\t.' >"$T"
record pass
devbox_map_update test "$RUN" "$T" run "$C1" base1 setup1
assert_eq "./
src/a.py" "$(devbox_map_step_inputs test "$C1")" "a step's own trace is its inputs, the root listed as ./"
printf '%s\n' $'partial\t-\tstrace: not found' >"$T"
record pass
devbox_map_update test "$RUN" "$T" run "$C1" base1 setup1
assert_eq "strace: not found" "$(devbox_map_untraced test "$C1")" "a trace with no read marks the map untraced, with its reason"
assert_eq "./
src/a.py" "$(devbox_map_step_inputs test "$C1")" "and keeps the earlier inputs"
: >"$T"
devbox_map_update test "$RUN" "$T" run "$C1" base1 setup1
assert_eq "the runner sent no trace" "$(devbox_map_untraced test "$C1")" "an empty trace says the runner sent none"
printf '%s\n' $'read\t-\tsrc/b.py' >"$T"
devbox_map_update test "$RUN" "$T" run "$C1" base1 setup1
assert_eq "" "$(devbox_map_untraced test "$C1")" "a trace with reads clears the mark"
assert_fail "a step trace with no traced-under hash is no valid trace" devbox_map_step_traced test "$C1"
devbox_map_update test "$RUN" "$T" run "$C1" base1 setup1 traced1
assert_eq traced1 "$(devbox_map_step_traced test "$C1")" "a run records what the step's trace was taken under"
printf '%s\n' $'partial\t-\tstrace: not found' >"$T"
devbox_map_update test "$RUN" "$T" run "$C1" base1 setup1 traced2
assert_eq traced1 "$(devbox_map_step_traced test "$C1")" "an untraced run keeps it"
printf '%s\n' $'read\t-\tsrc/b.py' $'partial\t-\ttrace cut short' >"$T"
devbox_map_update test "$RUN" "$T" run "$C1" base1 setup1 traced3
assert_fail "a partial step trace is no valid trace, so it is taken again" devbox_map_step_traced test "$C1"
assert_fail "4.0.1 D2a: a step trace cut short gives no learned inputs, so the key covers every synced file" \
  devbox_map_step_inputs test "$C1"

echo "-- a runner step's own reads, owner -"
# pytest reads its config, a root conftest and its cache at session start,
# before any test file runs, so the plug-in writes those reads as `-`. Section
# 5.4: such a read counts for every test file of the step.
rm -f "$MAP"
printf 'conftest v1\n' >conftest.py
mkdir -p .pytest_cache/v/cache
printf '[]\n' >.pytest_cache/v/cache/nodeids
printf '%s\n' \
  $'read\ttests/test_a.py\tsrc/a.py' $'read\ttests/test_b.py\tsrc/b.py' \
  $'read\t-\tconftest.py' $'read\t-\t.pytest_cache/v/cache/nodeids' $'read\t-\tsetup.cfg' \
  $'list\t-\t.' $'list\t-\ttests' >"$T"
record pass tests/test_a.py:pass tests/test_b.py:pass
devbox_map_update test "$RUN" "$T" run "$C1" base1 setup1
manifest
assert_eq "" "$(devbox_map_select test "$M" "$C1" base1 setup1)" "an unchanged tree selects nothing"
printf 'more\n' >>conftest.py
manifest
assert_eq "tests/test_a.py	read conftest.py
tests/test_b.py	read conftest.py" "$(devbox_map_select test "$M" "$C1" base1 setup1)" \
  "a file read outside any test file, owner -, selects every test file of the step"
printf 'conftest v1\n' >conftest.py
printf '["tests/test_a.py::test_a"]\n' >.pytest_cache/v/cache/nodeids
manifest
assert_eq "" "$(devbox_map_select test "$M" "$C1" base1 setup1)" \
  "a read of a path outside the sync manifest is ignored, though the file changed"
printf 'helper\n' >tests/helper.py
manifest
assert_eq "" "$(devbox_map_select test "$M" "$C1" base1 setup1)" \
  "a folder the step's own process listed selects nothing: pytest's collection lists every folder"
rm tests/helper.py
printf '[tool]\n' >setup.cfg
manifest
assert_eq "tests/test_a.py	read setup.cfg
tests/test_b.py	read setup.cfg" "$(devbox_map_select test "$M" "$C1" base1 setup1)" \
  "a file the step's own process looked for and missed selects every test file when it appears"
rm setup.cfg conftest.py
rm -r .pytest_cache

echo "-- a Worker's token, as the runner packs it (section 5.7)"
# The trace below is the packed result tests/test-steps-trace.sh checks the
# runner prints: a.test.ts started a Worker whose hook confirmed its token, so
# its partial line is gone and the Worker's read of src/worker.ts is its own;
# b.test.ts started a node child that never confirmed, so it keeps the plain
# partial line, with no token.
rm -f "$MAP"
for f in src/a.test.ts src/b.test.ts src/a.ts src/b.ts src/worker.ts; do printf '%s v1\n' "$f" >"$f"; done
printf '%s\n' \
  $'partial\tsrc/b.test.ts\tchild_process' \
  $'read\tsrc/a.test.ts\tsrc/a.ts' $'read\tsrc/a.test.ts\tsrc/worker.ts' \
  $'read\tsrc/b.test.ts\tsrc/b.ts' >"$T"
record pass src/a.test.ts:pass src/b.test.ts:pass
devbox_map_update test "$RUN" "$T" run "$C1" base1 setup1
assert_eq ok "$(devbox_map_state test "$C1")" "the packed trace of a Worker's token makes a map that reads"
assert_ok "the file whose Worker confirmed is complete" grep -q $'^file\tsrc/a.test.ts\t'"$RUN"$'\tcomplete\t' "$MAP"
assert_ok "the file whose child did not confirm is partial" grep -q $'^file\tsrc/b.test.ts\t'"$RUN"$'\tpartial\t' "$MAP"
assert_eq "" "$(awk -F '\t' '!(($1 == "map" && NF == 2) || ($1 == "context" && NF == 3) || ($1 == "untraced" && NF == 2) \
  || (($1 == "path" || $1 == "dir") && NF == 3) || ($1 == "file" && NF == 5) || ($1 == "step" && (NF == 5 || NF == 6)))' "$MAP")" \
  "every map line is a kind of section 5.5 with its field count: the format does not change"
printf 'more\n' >>src/worker.ts
manifest
assert_eq "src/b.test.ts	partial
src/a.test.ts	read src/worker.ts" "$(devbox_map_select test "$M" "$C1" base1 setup1)" \
  "a change to the file the Worker read selects the test file that started it, and the partial file runs on any change of its step"
rm src/a.test.ts src/b.test.ts src/a.ts src/b.ts src/worker.ts

echo "-- 4.0.1 D3b: the git database is no input"
# A map an earlier client wrote can hold reads of .git-common/, the git
# database of a workspace, which a test that ran git recorded. A commit then
# changed a read of that test.
rm -f "$MAP"
mkdir -p .git-common/refs/heads
printf 'ref: refs/heads/main\n' >.git-common/HEAD
printf '0123\n' >.git-common/refs/heads/main
printf 'tests/test_a.py v1\n' >tests/test_a.py
printf '%s\n' 'map	1' 'context	base1	setup1' \
  'path	1	src/a.py' 'path	2	.git-common/HEAD' 'dir	3	.git-common/refs/heads/' 'path	4	.git' \
  'dir	5	.github/' >"$MAP"
record pass tests/test_a.py:pass
printf 'file\ttests/test_a.py\t%s\tcomplete\t1,2,3,4,5\nstep\t%s\tcomplete\t-\t-\n' "$RUN" "$RUN" >>"$MAP"
assert_eq ok "$(devbox_map_state test "$C1")" "a map with reads under .git-common reads"
assert_eq ".github/
src/a.py
tests/test_a.py" "$(devbox_map_step_inputs test "$C1")" "4.0.1 D3b: the learned inputs leave out .git and .git-common, and keep .github"
printf '4567\n' >.git-common/refs/heads/main
printf 'ref: refs/heads/other\n' >.git-common/HEAD
printf 'x\n' >.git-common/refs/heads/new
manifest
assert_eq "" "$(devbox_map_select test "$M" "$C1" base1 setup1)" "4.0.1 D3b: a commit, a change under .git-common, selects no test"
printf 'more\n' >>src/a.py
manifest
assert_eq "tests/test_a.py	read src/a.py" "$(devbox_map_select test "$M" "$C1" base1 setup1)" "while a read outside it still selects"
printf 'src/a.py v1\n' >src/a.py
rm -r .git-common

echo "-- gate fixes 4.0.1, row D4: a resumed gate stamps every file it passed"
# MEASURED: after a resume, the map wrote the files that passed before the
# stop with the pass run `-`, because their trace went with the stopped part
# and the map's context had changed since, so the next plan named each of
# them `no trace` and ran it again.
rm -f "$MAP"
printf 'tests/test_c.py v1\n' >tests/test_c.py
printf '%s\n' $'read\ttests/test_a.py\tsrc/a.py' $'read\ttests/test_b.py\tsrc/b.py' \
  $'read\ttests/test_c.py\tdata/one.json' >"$T"
record pass tests/test_a.py:pass tests/test_b.py:pass tests/test_c.py:pass
devbox_map_update test "$RUN" "$T" run "$C1" base1 setup1
printf '%s\n' $'read\ttests/test_b.py\tsrc/b.py' >"$T"
record fail tests/test_a.py:pass tests/test_b.py:pass tests/test_c.py:fail
rc=0; devbox_map_update test "$RUN" "$T" resume "$C1" base2 setup1 || rc=$?
assert_eq 0 "$rc" "D4: the map takes the merge of a resumed gate"
assert_ok "D4: a file that passed before the stop, with no trace this run, has this gate's run" \
  grep -q $'^file\ttests/test_a.py\t'"$RUN"$'\tcomplete\t' "$MAP"
assert_ok "D4: a file that passed after the resume has it too" grep -q $'^file\ttests/test_b.py\t'"$RUN"$'\tcomplete\t' "$MAP"
assert_ok "D4: a file that failed in the gate has no pass" grep -q $'^file\ttests/test_c.py\t-\t' "$MAP"
manifest
assert_eq "tests/test_c.py	no trace" "$(devbox_map_select test "$M" "$C1" base2 setup1)" \
  "D4: on the gate's own tree only the failed file runs"
printf 'more\n' >>src/a.py
manifest
assert_eq "tests/test_a.py	read src/a.py
tests/test_c.py	no trace" "$(devbox_map_select test "$M" "$C1" base2 setup1)" \
  "D4: the stamped file keeps its learned reads, so a change to what it read selects it"
printf 'src/a.py v1\n' >src/a.py
rm tests/test_c.py

echo "-- gate fixes 4.0.1, row D3b: no git path in a map"
# MEASURED: a test that runs git recorded reads of .git-common/refs/ and
# .git-common/worktrees/, the workspace copy of the git common dir, so a
# commit would have selected it.
rm -f "$MAP"
printf '%s\n' $'read\ttests/test_a.py\tsrc/a.py' $'read\ttests/test_a.py\t.git-common/refs/heads/x' \
  $'list\ttests/test_a.py\t.git-common/worktrees' $'read\ttests/test_a.py\t.git/HEAD' >"$T"
record pass tests/test_a.py:pass
devbox_map_update test "$RUN" "$T" run "$C1" base1 setup1
assert_ok "D3b: the merge keeps the real read" grep -q $'^path\t[0-9]*\tsrc/a.py$' "$MAP"
assert_fail "D3b: and no .git-common or .git path" grep -qE $'^(path|dir)\t[0-9]+\t\\.git(-common)?/' "$MAP"

echo "-- a map that breaks the format"
printf 'map\t1\nfile\tx\n' >"$MAP"
assert_eq bad "$(devbox_map_state test "$C1")" "a broken line makes the map bad"
assert_fail "with no learned inputs" devbox_map_step_inputs test "$C1"
printf 'map\t1\nstep\t-\tcomplete\t7\t-\n' >"$MAP"
assert_eq bad "$(devbox_map_state test "$C1")" "an id with no path makes it bad"
err="$(devbox_map_update test "$RUN" "$T" run "$C1" base1 setup1 2>&1)"
assert_ok "an update over a bad map says so" contains "could not be read" "$err"
assert_eq ok "$(devbox_map_state test "$C1")" "and starts the map again"
rc=0; devbox_map_update test "$RUN" "$T" related 2>/dev/null || rc=$?
assert_eq 2 "$rc" "an unknown mode is refused"
rc=0; devbox_map_update test "not-a-run" "$T" run 2>/dev/null || rc=$?
assert_eq 2 "$rc" "a run id that breaks the rule is refused"

echo "-- gate overload D8 and D8a: one map per step and context"
# MEASURED: one map per step held one context, and worktrees of one checkout
# on three client versions reset each other's run ids on every gate, so about
# 4 in 10 runs of a project's test steps ran in full.
rm -f "$MAPS"/test.*.map
printf '%s\n' $'read\ttests/test_a.py\tsrc/a.py' $'read\ttests/test_b.py\tsrc/b.py' $'read\t-\tpytest.ini' >"$T"
record pass tests/test_a.py:pass tests/test_b.py:pass
runa="$RUN"
devbox_map_update test "$RUN" "$T" run "$C1" base1 setup1 tracedA
printf '%s\n' $'read\ttests/test_a.py\tdata/one.json' $'setup\ttests/test_a.py' $'read\t-\tsetup.cfg' >"$T"
record pass tests/test_a.py:pass
runb="$RUN"
devbox_map_update test "$RUN" "$T" run "$C2" base2 setup1 tracedB
printf '%s\n' $'partial\t-\tstrace: not found' >"$T"
devbox_map_update test "$RUN" "$T" run "$C2" base2 setup1 tracedB
assert_ok "D8: each context has its own file" test -f "$MAPS/test.$C1.map" -a -f "$MAPS/test.$C2.map"
assert_ok "D8: a write under the second context keeps the first context's passes" \
  grep -q $'^file\ttests/test_b.py\t'"$runa"$'\tcomplete\t' "$MAPS/test.$C1.map"
assert_eq "ok|ok|none" "$(devbox_map_state test "$C1")|$(devbox_map_state test "$C2")|$(devbox_map_state test "$(devbox_map_ctx base3 setup1)")" \
  "D8a: state reads each context's map, and a third context has none"
assert_eq "pytest.ini
src/a.py
src/b.py
tests/test_a.py
tests/test_b.py|data/one.json
setup.cfg
tests/test_a.py" "$(devbox_map_step_inputs test "$C1")|$(devbox_map_step_inputs test "$C2")" "D8a: step_inputs"
assert_eq "no|yes" "$(devbox_map_reads_setup test "$C1" && echo yes || echo no)|$(devbox_map_reads_setup test "$C2" && echo yes || echo no)" \
  "D8a: reads_setup"
assert_eq "tests/test_a.py
tests/test_b.py|tests/test_a.py" "$(devbox_map_test_files test "$C1")|$(devbox_map_test_files test "$C2")" "D8a: test_files"
assert_eq "base1 setup1|base2 setup1" "$(devbox_map_context test "$C1")|$(devbox_map_context test "$C2")" "D8a: context"
assert_eq "|strace: not found" "$(devbox_map_untraced test "$C1")|$(devbox_map_untraced test "$C2")" "D8a: untraced"
assert_eq "tracedA|tracedB" "$(devbox_map_step_traced test "$C1")|$(devbox_map_step_traced test "$C2")" "D8a: step_traced"
assert_eq "$runa|$runb" "$(devbox_map_step_run test "$C1")|$(devbox_map_step_run test "$C2")" "D8a: step_run"
printf 'more\n' >>data/one.json
manifest
assert_eq "|tests/test_a.py	read data/one.json" \
  "$(devbox_map_select test "$M" "$C1" base1 setup1)|$(devbox_map_select test "$M" "$C2" base2 setup1)" \
  "D8a: select reads each context's map: only the second one's test read the changed file"
printf 'data/one.json v1\n' >data/one.json
assert_eq bad "$(devbox_map_state test "not-a-context" 2>/dev/null)" "a context id that breaks its rule names no file"
rc=0; devbox_map_update test "$RUN" "$T" run "../x" base1 setup1 2>/dev/null || rc=$?
assert_eq 2 "$rc" "and an update under it is refused"

echo "-- gate overload D9 and D10: at most 8 maps of a step, and the legacy map untouched"
rm -f "$MAPS"/*.map
# The legacy map holds this run's own context, so a client that read it would
# find a pass in it.
printf 'map\t1\ncontext\tbase1\tsetup1\npath\t1\tsrc/a.py\nfile\ttests/test_a.py\t%s\tcomplete\t1\nstep\t%s\tcomplete\t-\t-\n' \
  "$runa" "$runa" >"$MAPS/test.map"
printf 'another step whose name starts with test\n' >"$MAPS/test-unit.$C1.map"
printf 'no context id\n' >"$MAPS/test.0123456789ABCDEF.map"
cp "$MAPS/test.map" "$TMP/legacy" && cp "$MAPS/test-unit.$C1.map" "$TMP/prefix" && cp "$MAPS/test.0123456789ABCDEF.map" "$TMP/upper"
assert_eq none "$(devbox_map_state test "$C1")" "D10: a legacy map of the run's own context is never read"
printf '%s\n' $'read\ttests/test_a.py\tsrc/a.py' >"$T"
record pass tests/test_a.py:pass
declare -a ctx=()
for i in 1 2 3 4 5 6 7 8 9 10; do
  ctx[i]="$(devbox_map_ctx "base$i" setup1)"
  devbox_map_update test "$RUN" "$T" run "${ctx[i]}" "base$i" setup1
  # One second apart, oldest first: a write lands within one tick of the last.
  touch -d "@$((1700000000 + i))" "$MAPS/test.${ctx[i]}.map"
done
assert_eq 8 "$(find "$MAPS" -name 'test.*.map' | grep -cE '/test\.[0-9a-f]{16}\.map$')" "D9: 8 context maps of the step remain"
assert_ok "D9: the two oldest are gone" test ! -e "$MAPS/test.${ctx[1]}.map" -a ! -e "$MAPS/test.${ctx[2]}.map"
assert_ok "D9: the third and the newest stay" test -f "$MAPS/test.${ctx[3]}.map" -a -f "$MAPS/test.${ctx[10]}.map"
assert_ok "D9: a step whose name starts with this one keeps its map, byte for byte" cmp -s "$TMP/prefix" "$MAPS/test-unit.$C1.map"
assert_ok "D9: a name that is no context id stays" cmp -s "$TMP/upper" "$MAPS/test.0123456789ABCDEF.map"
assert_ok "D10: the legacy map is byte-identical after 10 writes" cmp -s "$TMP/legacy" "$MAPS/test.map"
assert_eq "$RUN" "$(devbox_map_step_run test "${ctx[10]}")" "D10: the run's map holds this run, not the legacy map's pass"

printf '%d %d\n' "$TESTS_RUN" "$TESTS_FAILED"
