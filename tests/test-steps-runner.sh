#!/bin/bash
# client/share/steps/devbox-steps, the runner of a gate's step graph.
# docs/specs/2026-11-14-client-owns-the-gate-design.md section 6.3 holds the
# design and section 13 rows D3 and D4 the requirements of its graph and its
# plug-ins. docs/specs/2026-11-14-learned-selection-design.md section 5.6
# holds the plan format, section 7 the worker count, and section 15 rows D5,
# D6 and D7 the requirements this file checks of them. tests/test-steps-trace.sh
# checks the trace of a step (rows D4 and D4b).
#
# The risks: a step that starts before the step it runs after has ended, a
# failed step whose log never reaches the client, a ledger `pass` for a step
# that did not finish, a runner whose plug-in, worker option or files reach the
# test runner as the wrong words, a dir= step whose files keep the folder's
# prefix, a resume that passes --exclude, more runner steps at once than the
# grant has tokens, and a stopped gate that leaves its test processes running
# in the workspace.
#
# vitest and pytest are stubs on PATH that record their argv one word per line,
# so no test runner is installed. node is required to import the copied
# reporter, and a missing node FAILS this file, never skips it.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
# shellcheck source=tests/lib.sh
source ./lib.sh
REPO="$(cd .. && pwd)"
STEPS="$REPO/client/share/steps/devbox-steps"
TOOLS="$REPO/client/share/ledger"

TMP="$(mktemp -d)" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
unset DEVBOX_STEPS_PLAN DEVBOX_STEPS_LOGS DEVBOX_LEDGER DEVBOX_RESUME DEVBOX_LEDGER_TOOLS \
  DEVBOX_TOKENS DEVBOX_WORKER_MEMORY DEVBOX_CGROUP_ROOT DEVBOX_WORKERS DEVBOX_TRACE_DIR NODE_OPTIONS

PROJ="$TMP/project"
BIN="$TMP/bin"
mkdir -p "$PROJ/.devbox" "$BIN"
printf 'DEVBOX_PROJECT=app\n' >"$PROJ/.devbox/config.env"
KEY=0123456789abcdef  # a fixture machine id: gitleaks:allow

# The workspace's cgroup: 32 GiB, so the memory cap is (32 - 4) / 1.5 = 18
# workers and no case below meets it unless it sets its own figure.
CGROUP="$TMP/cgroup"
mkdir -p "$CGROUP"
printf '34359738368\n' >"$CGROUP/memory.max"

# The stubs: npx runs the stub vitest, and each runner appends its argv, one
# word per line, then `--end--`, so a word that holds a space stays one line,
# and its folder and DEVBOX_WORKERS to ENV_LOG. pytest answers -VV with the
# plug-ins it registers, pytest-xdist when STUB_XDIST=1, and logs no argv for it.
cat >"$BIN/npx" <<'STUB'
#!/bin/bash
exec "$@"
STUB
cat >"$BIN/vitest" <<'STUB'
#!/bin/bash
{ printf '%s\n' "$@"; echo --end--; } >>"$ARGV_LOG"
printf 'vitest pwd=%s workers=%s\n' "$PWD" "${DEVBOX_WORKERS-}" >>"$ENV_LOG"
exit "${STUB_RC:-0}"
STUB
cat >"$BIN/pytest" <<'STUB'
#!/bin/bash
if [ "$*" = -VV ]; then
  printf 'pytest 0.0.0\nregistered third-party plugins:\n'
  [ "${STUB_XDIST-}" != 1 ] || printf '  pytest-xdist-0.0.0 at /opt/site/xdist/plugin.py\n'
  exit 0
fi
{ printf '%s\n' "$@"; echo --end--; } >>"$ARGV_LOG"
printf '%s\n' "$PYTHONPATH" >>"$PYTHONPATH_LOG"
printf 'pytest pwd=%s workers=%s\n' "$PWD" "${DEVBOX_WORKERS-}" >>"$ENV_LOG"
STUB
chmod +x "$BIN/npx" "$BIN/vitest" "$BIN/pytest"
export ARGV_LOG="$TMP/argv.log" PYTHONPATH_LOG="$TMP/pythonpath.log" ENV_LOG="$TMP/env.log"

# plan_step <name> <mode> <runner> <after> <command> [<dir>] [<trace>]: one
# step line of the plan, dir - and trace 0 unless given.
plan_step() {
  printf 'step\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$KEY" "$3" "$4" \
    "$(printf '%s' "$5" | base64 | tr -d '\n')" "${6:--}" "${7:-0}"
}
plan_file() { printf 'file\t%s\t%s\n' "$1" "$2"; }
plan_test() { printf 'test\t%s\t%s\n' "$1" "$2"; }

# run_steps <case> <plan file> [VAR=value...]: runs the runner in the project
# directory with fresh logs in $TMP/logs-<case>, a 4-token grant and the
# cgroup above unless the case names its own. Sets OUT, ERR, RC and LOGS.
run_steps() {
  local case="$1" plan="$2"
  shift 2
  LOGS="$TMP/logs-$case"
  RC=0
  OUT="$(cd "$PROJ" && env PATH="$BIN:$PATH" DEVBOX_TOKENS=4 DEVBOX_CGROUP_ROOT="$CGROUP" \
    DEVBOX_STEPS_PLAN="$plan" DEVBOX_STEPS_LOGS="$LOGS" "$@" "$STEPS" 2>"$TMP/err")" || RC=$?
  ERR="$(cat "$TMP/err")"
}

# The outcomes of one step in ledger order, space-joined: "start pass".
step_outcomes() {
  LEDGER_NAME="$2" awk -F '\t' '$1 == "step" && $2 == ENVIRON["LEDGER_NAME"] { o = o (o == "" ? "" : " ") $3 } END { print o }' "$1"
}
# The line number of the first line equal to $2 in the file $1.
line_of() { grep -nxF -- "$2" "$1" | head -1 | cut -d: -f1; }
# The argv of the Nth runner call, one word per line.
argv_call() { awk -v n="$1" '$0 == "--end--" { c++; next } c == n - 1' "$ARGV_LOG"; }
new_ledger() { printf 'key\t%s\nresume\t0\n' "$KEY" >"$1"; }

# ── prerequisites ────────────────────────────────────────────────────────────

if command -v node >/dev/null 2>&1; then
  _pass "node is on PATH"
else
  _fail "node is on PATH" "the import of the copied reporter needs node; a missing one fails this file, never skips it"
fi
assert_ok "devbox-steps is executable" test -x "$STEPS"

# ── row D3: a 4-step graph runs by its after edges ───────────────────────────
#
# a, then b and c side by side, then d after both. Each command appends its
# start and its end to one events file, so the order of the lines is the order
# of the events.

EV="$TMP/events"
q_ev="$(printf '%q' "$EV")"
ev_cmd() { printf 'echo %s:start >>%s; echo output of %s; sleep %s; echo %s:end >>%s' "$1" "$q_ev" "$1" "$2" "$1" "$q_ev"; }
{
  plan_step a run - - "$(ev_cmd a 0.3)"
  plan_step b run - a "$(ev_cmd b 0.3)"
  plan_step c run - a "$(ev_cmd c 1.2)"
  plan_step d run - b,c "$(ev_cmd d 0.1)"
} >"$TMP/graph.plan"
L="$TMP/graph.ledger"
new_ledger "$L"
run_steps graph "$TMP/graph.plan" DEVBOX_LEDGER="$L"

assert_eq "0" "$RC" "a graph whose steps all pass exits 0: $ERR"
assert_eq "8" "$(wc -l <"$EV" | tr -d ' ')" "each of the 4 steps started and ended once"
assert_ok "b starts after a ended" test "$(line_of "$EV" a:end)" -lt "$(line_of "$EV" b:start)"
assert_ok "c starts after a ended" test "$(line_of "$EV" a:end)" -lt "$(line_of "$EV" c:start)"
assert_ok "b and c run side by side: c starts before b ends" test "$(line_of "$EV" c:start)" -lt "$(line_of "$EV" b:end)"
assert_ok "d starts after b ended" test "$(line_of "$EV" b:end)" -lt "$(line_of "$EV" d:start)"
assert_ok "d starts after c ended" test "$(line_of "$EV" c:end)" -lt "$(line_of "$EV" d:start)"
for s in a b c d; do
  assert_ok "step $s has its own log with its output" grep -qx "output of $s" "$LOGS/$s.log"
  assert_eq "start pass" "$(step_outcomes "$L" "$s")" "the ledger records step $s as start, then pass"
done
assert_eq "0" "$(grep -c 'output of b' "$LOGS/a.log")" "a step's log holds no other step's output"
assert_eq "4" "$(awk -F '\t' '$1 == "step" && $3 == "pass" && NF == 4 && $4 ~ /^[0-9]+$/' "$L" | wc -l | tr -d ' ')" \
  "each pass line is step, name, pass and whole seconds, the existing ledger format"
assert_ok "a progress line names the step that ended and the steps still running" \
  grep -Eq '^\[[0-9]+ s\] b passed \([0-9]+ s\); running: c$' <<<"$OUT"
assert_ok "a line says when a step starts" grep -Eq '^\[[0-9]+ s\] d started$' <<<"$OUT"
assert_ok "the summary table has one line per step with outcome, seconds and code" \
  grep -Eq '^  c +pass +[0-9]+ s  code 0$' <<<"$OUT"
assert_eq "devbox-steps: result a pass
devbox-steps: result b pass
devbox-steps: result c pass
devbox-steps: result d pass" "$(grep '^devbox-steps: result ' <<<"$OUT" | sed -E 's/ [0-9]+ [0-9]+$//')" \
  "one result line per step, in plan order"
assert_eq "devbox-steps: result c pass" "$(tail -2 <<<"$OUT" | head -1 | sed -E 's/ [0-9]+ 0$//')" \
  "the result lines come last, each with seconds and code"
assert_eq "" "$ERR" "a clean run prints nothing on stderr, no job notice either"

# ── row D3: a failed step ────────────────────────────────────────────────────

{
  plan_step good run - - 'echo fine'
  plan_step bad run - - 'echo "expected 2 got 3"; echo "trace line" >&2; exit 1'
  plan_step later run - bad 'echo ran after the failure'
} >"$TMP/fail.plan"
L="$TMP/fail.ledger"
new_ledger "$L"
run_steps fail "$TMP/fail.plan" DEVBOX_LEDGER="$L"

assert_eq "1" "$RC" "a failed step makes the runner exit 1"
assert_ok "a failed step's result line carries its code" grep -Eq '^devbox-steps: result bad fail [0-9]+ 1$' <<<"$OUT"
assert_ok "a step after a failed step still runs" grep -Eq '^devbox-steps: result later pass [0-9]+ 0$' <<<"$OUT"
assert_ok "the progress line of a failed step names its code" grep -Eq '^\[[0-9]+ s\] bad failed \([0-9]+ s, code 1\)' <<<"$OUT"
assert_ok "the failed step's log is announced by a header with its path" grep -qxF "== bad: $LOGS/bad.log" <<<"$OUT"
hdr="$(grep -nxF "== bad: $LOGS/bad.log" <<<"$OUT" | cut -d: -f1)"
assert_eq "expected 2 got 3" "$(sed -n "$((hdr + 2))p" <<<"$OUT")" "the full log follows its header, stdout"
assert_eq "trace line" "$(sed -n "$((hdr + 3))p" <<<"$OUT")" "the full log follows its header, stderr too"
assert_eq "0" "$(grep -c '^== good:' <<<"$OUT")" "a passed step's log is not printed"
assert_eq "start fail" "$(step_outcomes "$L" bad)" "the ledger records the failed step as start, then fail"
assert_ok "the summary names the failed step with its code" grep -Eq '^  bad +fail +[0-9]+ s  code 1$' <<<"$OUT"

# ── carried steps ────────────────────────────────────────────────────────────

{
  plan_step kept carry - - "touch $(printf '%q' "$TMP/carry-ran")"
  plan_step next run - kept 'echo next ran'
} >"$TMP/carry.plan"
L="$TMP/carry.ledger"
new_ledger "$L"
run_steps carry "$TMP/carry.plan" DEVBOX_LEDGER="$L"

assert_eq "0" "$RC" "a carried step and a passed step exit 0: $ERR"
assert_ok "a carried step prints its result as carried 0 0" grep -qx 'devbox-steps: result kept carried 0 0' <<<"$OUT"
assert_fail "a carried step starts nothing" test -e "$TMP/carry-ran"
assert_ok "a step after a carried step runs" grep -Eq '^devbox-steps: result next pass [0-9]+ 0$' <<<"$OUT"
assert_eq "" "$(step_outcomes "$L" kept)" "a carried step writes no ledger line"

# ── a resume skips a step whose last ledger record is pass ───────────────────

{
  plan_step built run - - "touch $(printf '%q' "$TMP/built-ran")"
  plan_step checked run - - "touch $(printf '%q' "$TMP/checked-ran")"
  plan_step tail run - built 'echo tail ran'
} >"$TMP/resume.plan"
L="$TMP/resume.ledger"
new_ledger "$L"
printf 'step\tbuilt\tstart\nstep\tbuilt\tpass\t3\nstep\tchecked\tstart\nstep\tchecked\tpass\t2\nstep\tchecked\tstart\n' >>"$L"
run_steps resume "$TMP/resume.plan" DEVBOX_LEDGER="$L" DEVBOX_RESUME=1

assert_eq "0" "$RC" "a resumed gate exits 0: $ERR"
assert_fail "a step whose last record is pass is not started on a resume" test -e "$TMP/built-ran"
assert_ok "a resumed step prints its result as resumed" grep -qx 'devbox-steps: result built resumed 0 0' <<<"$OUT"
assert_ok "a step whose last record is start runs again on a resume" test -e "$TMP/checked-ran"
assert_ok "a step after a resumed step runs" grep -Eq '^devbox-steps: result tail pass [0-9]+ 0$' <<<"$OUT"
assert_eq "start pass" "$(step_outcomes "$L" built)" "a resumed step writes no new ledger line"
rm -f "$TMP/built-ran"
L="$TMP/resume0.ledger"
new_ledger "$L"
printf 'step\tbuilt\tstart\nstep\tbuilt\tpass\t3\n' >>"$L"
run_steps resume0 "$TMP/resume.plan" DEVBOX_LEDGER="$L" DEVBOX_RESUME=0
assert_ok "with DEVBOX_RESUME=0 a passed step runs, because only a resume skips" test -e "$TMP/built-ran"

# ── row D4: the vitest wiring ────────────────────────────────────────────────

REP=(--reporter=default --reporter=./node_modules/.devbox-ledger/vitest-ledger.mjs)
plan_step unit run vitest - 'npx vitest run --project api' >"$TMP/vitest.plan"
L="$TMP/vitest.ledger"
new_ledger "$L"
: >"$ARGV_LOG"
run_steps vitest "$TMP/vitest.plan" DEVBOX_LEDGER="$L" DEVBOX_LEDGER_TOOLS="$TOOLS"
assert_eq "0" "$RC" "a vitest step runs: $ERR"
assert_eq "$(printf '%s\n' run --project api "${REP[@]}" --maxWorkers=4)" "$(argv_call 1)" \
  "a vitest step gets the default reporter, the ledger reporter and its workers appended"
assert_ok "the reporter is copied into the project's node_modules" cmp -s "$TOOLS/vitest-ledger.mjs" "$PROJ/node_modules/.devbox-ledger/vitest-ledger.mjs"
assert_ok "ledger-core.mjs is copied beside it" cmp -s "$TOOLS/ledger-core.mjs" "$PROJ/node_modules/.devbox-ledger/ledger-core.mjs"
imported="$(cd "$PROJ" && node --input-type=module -e "import('./node_modules/.devbox-ledger/vitest-ledger.mjs').then((m) => console.log(typeof m.default, typeof m.passedFiles))" 2>&1)"
assert_eq "function function" "$imported" "the copied reporter imports its ledger-core.mjs from its own directory"

# A narrowed step appends its failed files as file arguments.
{
  plan_step unit narrow vitest - 'npx vitest run'
  plan_file unit src/x.test.ts
  plan_file unit 'src/with space.test.ts'
} >"$TMP/narrow.plan"
L="$TMP/narrow.ledger"
new_ledger "$L"
: >"$ARGV_LOG"
run_steps narrow "$TMP/narrow.plan" DEVBOX_LEDGER="$L" DEVBOX_LEDGER_TOOLS="$TOOLS"
assert_eq "$(printf '%s\n' run "${REP[@]}" --maxWorkers=2 src/x.test.ts 'src/with space.test.ts')" "$(argv_call 1)" \
  "a narrowed vitest step appends its files after the options, one word each, and no more workers than files"

# ── row D7: a resume and a selection pass the files to run ───────────────────
#
# A vitest 2 release ignored an --exclude from the command line in a project that set
# its own `exclude`, so a resume passes the files still to run instead.

{
  plan_step unit run vitest - 'npx vitest run --project api'
  plan_test unit 'app/[id]/page.test.ts'
  plan_test unit src/a.test.ts
  plan_test unit 'src/b c.test.ts'
  plan_test unit src/d.test.ts
  plan_test unit src/e.test.ts
} >"$TMP/vitest-tests.plan"
L="$TMP/vitest-resume.ledger"
new_ledger "$L"
printf '%s\n' \
  $'file\tvitest\tsrc/a.test.ts\tstart' \
  $'file\tvitest\tsrc/a.test.ts\tpass\t1' \
  $'file\tvitest\tsrc/b c.test.ts\tpass\t1' \
  $'file\tvitest\tapp/[id]/page.test.ts\tpass\t1' \
  $'file\tvitest\tsrc/d.test.ts\tpass\t1' \
  $'file\tvitest\tsrc/d.test.ts\tstart' \
  $'file\tpytest\tsrc/e.test.ts\tpass\t1' >>"$L"
: >"$ARGV_LOG"
run_steps vitest-resume "$TMP/vitest-tests.plan" DEVBOX_LEDGER="$L" DEVBOX_LEDGER_TOOLS="$TOOLS" DEVBOX_RESUME=1
assert_eq "0" "$RC" "a resumed vitest step runs: $ERR"
assert_eq "$(printf '%s\n' run --project api "${REP[@]}" --maxWorkers=2 src/d.test.ts src/e.test.ts)" "$(argv_call 1)" \
  "a resumed run step gets its test files less those whose last vitest record is pass, as file arguments"
assert_eq "0" "$(grep -c -- '--exclude' "$ARGV_LOG")" "a resumed vitest step gets no --exclude"

: >"$ARGV_LOG"
run_steps vitest-noresume "$TMP/vitest-tests.plan" DEVBOX_LEDGER="$L" DEVBOX_LEDGER_TOOLS="$TOOLS" DEVBOX_RESUME=0
assert_eq "$(printf '%s\n' run --project api "${REP[@]}" --maxWorkers=4)" "$(argv_call 1)" \
  "a run step that is not resumed runs its whole suite, with no file argument"

L="$TMP/vitest-allpassed.ledger"
new_ledger "$L"
for f in 'app/[id]/page.test.ts' src/a.test.ts 'src/b c.test.ts' src/d.test.ts src/e.test.ts; do
  printf 'file\tvitest\t%s\tpass\t1\n' "$f" >>"$L"
done
: >"$ARGV_LOG"
run_steps vitest-allpassed "$TMP/vitest-tests.plan" DEVBOX_LEDGER="$L" DEVBOX_LEDGER_TOOLS="$TOOLS" DEVBOX_RESUME=1
assert_eq "0" "$RC" "a resumed step whose every file passed exits 0: $ERR"
assert_ok "a resumed step whose every file passed prints its result as resumed" grep -qx 'devbox-steps: result unit resumed 0 0' <<<"$OUT"
assert_eq "" "$(cat "$ARGV_LOG")" "a resumed step whose every file passed never starts its runner, which would run the whole suite"

# ── gate fixes 4.0.1, row D1: a resume owes what its own ledger left ─────────
#
# MEASURED: a stopped gate's vitest step failed two files. Its resume was
# planned again, and the plan narrowed the step to the failed files of
# another branch's newer record. Every file on that list had passed in this
# gate, so the step resumed as passed, and the gate read green while its own
# two failed files never ran again.
{
  plan_step unit narrow vitest - 'npx vitest run'
  plan_file unit src/c.test.ts
  plan_file unit src/d.test.ts
  for f in src/a.test.ts src/b.test.ts src/c.test.ts src/d.test.ts src/e.test.ts; do plan_test unit "$f"; done
} >"$TMP/owed-narrow.plan"
L="$TMP/owed-narrow.ledger"
new_ledger "$L"
printf '%s\n' $'step\tunit\tstart' \
  $'file\tvitest\tsrc/a.test.ts\tstart' $'file\tvitest\tsrc/a.test.ts\tfail\t1' \
  $'file\tvitest\tsrc/b.test.ts\tstart' $'file\tvitest\tsrc/b.test.ts\tfail\t1' \
  $'file\tvitest\tsrc/c.test.ts\tpass\t1' $'file\tvitest\tsrc/d.test.ts\tpass\t1' \
  $'file\tvitest\tsrc/e.test.ts\tstart' $'step\tunit\tfail\t9' >>"$L"
: >"$ARGV_LOG"
run_steps owed-narrow "$TMP/owed-narrow.plan" DEVBOX_LEDGER="$L" DEVBOX_LEDGER_TOOLS="$TOOLS" DEVBOX_RESUME=1 STUB_RC=1
assert_eq "$(printf '%s\n' run "${REP[@]}" --maxWorkers=3 src/a.test.ts src/b.test.ts src/e.test.ts)" "$(argv_call 1)" \
  "D1: a resumed narrow step runs its test lines less its passed files, never the narrow list a record gave"
assert_ok "D1: and its result is the run's, never resumed" grep -qE '^devbox-steps: result unit fail [0-9]+ 1$' <<<"$OUT"
assert_eq "1" "$RC" "D1: the resumed gate fails"

{
  plan_step unit select vitest - 'npx vitest run'
  plan_file unit src/c.test.ts
  for f in src/a.test.ts src/b.test.ts src/c.test.ts src/d.test.ts; do plan_test unit "$f"; done
  plan_step other select pytest unit 'pytest -q'
  plan_file other tests/test_x.py
  plan_test other tests/test_x.py
  plan_test other tests/test_y.py
} >"$TMP/owed-select.plan"
L="$TMP/owed-select.ledger"
new_ledger "$L"
printf '%s\n' $'step\tunit\tstart' \
  $'file\tvitest\tsrc/a.test.ts\tstart' $'file\tvitest\tsrc/a.test.ts\tfail\t1' \
  $'file\tvitest\tsrc/b.test.ts\tstart' $'file\tvitest\tsrc/c.test.ts\tpass\t1' \
  $'file\tvitest\tsrc/z.test.ts\tfail\t1' $'file\tpytest\ttests/test_y.py\tfail\t1' >>"$L"
: >"$ARGV_LOG"
run_steps owed-select "$TMP/owed-select.plan" DEVBOX_LEDGER="$L" DEVBOX_LEDGER_TOOLS="$TOOLS" DEVBOX_RESUME=1
assert_eq "$(printf '%s\n' run "${REP[@]}" --maxWorkers=2 src/a.test.ts src/b.test.ts)" "$(argv_call 1)" \
  "D1: a resumed select step adds its own failed and open files to its selection, and no file of another step"
assert_eq "$(printf '%s\n' -q -p devbox_ledger tests/test_x.py tests/test_y.py)" "$(argv_call 2)" \
  "D1: a pytest select step adds its own failed file the same way"

L="$TMP/owed-stepfail.ledger"
new_ledger "$L"
printf '%s\n' $'step\tunit\tstart' >>"$L"
for f in 'app/[id]/page.test.ts' src/a.test.ts 'src/b c.test.ts' src/d.test.ts src/e.test.ts; do
  printf 'file\tvitest\t%s\tpass\t1\n' "$f" >>"$L"
done
printf 'step\tunit\tfail\t9\n' >>"$L"
: >"$ARGV_LOG"
run_steps owed-stepfail "$TMP/vitest-tests.plan" DEVBOX_LEDGER="$L" DEVBOX_LEDGER_TOOLS="$TOOLS" DEVBOX_RESUME=1
assert_fail "D1: a step that failed while every file passed is not resumed as passed" grep -q 'devbox-steps: result unit resumed' <<<"$OUT"
assert_eq "$(printf '%s\n' run --project api "${REP[@]}" --maxWorkers=4 'app/[id]/page.test.ts' src/a.test.ts 'src/b c.test.ts' src/d.test.ts src/e.test.ts)" \
  "$(argv_call 1)" "D1: it runs every file of its list again"

{
  plan_step unit select vitest - 'npx vitest run'
  plan_file unit src/reads-data.test.ts
  plan_test unit src/a.test.ts
  plan_test unit src/reads-data.test.ts
} >"$TMP/select.plan"
L="$TMP/select.ledger"
new_ledger "$L"
: >"$ARGV_LOG"
run_steps select "$TMP/select.plan" DEVBOX_LEDGER="$L" DEVBOX_LEDGER_TOOLS="$TOOLS"
assert_eq "0" "$RC" "a select step runs: $ERR"
assert_eq "$(printf '%s\n' run "${REP[@]}" --maxWorkers=1 src/reads-data.test.ts)" "$(argv_call 1)" \
  "a select step runs exactly its file lines"
assert_eq "0" "$(grep -c 'related' "$ARGV_LOG")" "a select step never runs vitest related"

: >"$ARGV_LOG"
run_steps select-noledger "$TMP/select.plan"
assert_eq "$(printf '%s\n' run --maxWorkers=1 src/reads-data.test.ts)" "$(argv_call 1)" \
  "with no DEVBOX_LEDGER and no trace no reporter is wired, and the files still are"

# ── row D4: the pytest wiring ────────────────────────────────────────────────

plan_step py run pytest - 'pytest -q -n 2' >"$TMP/pytest.plan"
L="$TMP/pytest.ledger"
new_ledger "$L"
: >"$ARGV_LOG"
: >"$PYTHONPATH_LOG"
run_steps pytest "$TMP/pytest.plan" DEVBOX_LEDGER="$L" DEVBOX_LEDGER_TOOLS="$TOOLS" PYTHONPATH=/opt/site STUB_XDIST=1
assert_eq "0" "$RC" "a pytest step runs: $ERR"
assert_eq "$(printf '%s\n' -q -n 2 -p devbox_ledger)" "$(argv_call 1)" \
  "a pytest step gets -p devbox_ledger appended, and a command that sets -n keeps its own"
assert_eq "$TOOLS:/opt/site" "$(cat "$PYTHONPATH_LOG")" "a pytest step finds the plugin first on PYTHONPATH and keeps the PYTHONPATH it had"
assert_eq "start pass" "$(step_outcomes "$L" py)" "the runner writes the pytest step's own ledger lines"
assert_ok "the step log says the command keeps its own workers" grep -q 'sets its own pytest workers' "$LOGS/py.log"

{
  plan_step py narrow pytest - 'pytest -q'
  plan_file py tests/test_a.py
  plan_file py 'tests/test b.py'
} >"$TMP/pytest-narrow.plan"
: >"$ARGV_LOG"
run_steps pytest-narrow "$TMP/pytest-narrow.plan" DEVBOX_LEDGER="$L" DEVBOX_LEDGER_TOOLS="$TOOLS"
assert_eq "$(printf '%s\n' -q -p devbox_ledger tests/test_a.py 'tests/test b.py')" "$(argv_call 1)" \
  "a narrowed pytest step whose pytest has no xdist appends its files after the plugin, and no -n"
assert_ok "the step log says xdist does not load, and names the words it ran" grep -qF "pytest-xdist does not load in \`pytest -VV\`" "$LOGS/py.log"

: >"$ARGV_LOG"
run_steps pytest-narrow-xdist "$TMP/pytest-narrow.plan" DEVBOX_LEDGER="$L" DEVBOX_LEDGER_TOOLS="$TOOLS" STUB_XDIST=1
assert_eq "$(printf '%s\n' -q -p devbox_ledger -n 2 tests/test_a.py 'tests/test b.py')" "$(argv_call 1)" \
  "a pytest step whose pytest loads xdist gets -n before its files"

# ── row D5: workers come from the grant ──────────────────────────────────────
#
# A 12-token grant and two runner steps that start together: each gets half,
# capped by its file count. A step that starts later, with one runner step
# still running, shares the grant with that one.

{
  plan_step suite run vitest - 'npx vitest run'
  for i in 01 02 03 04 05 06 07 08 09 10; do plan_test suite "src/t$i.test.ts"; done
  plan_step service run pytest - 'uv run pytest -q'
  plan_test service tests/test_a.py
  plan_test service tests/test_b.py
  plan_test service tests/test_c.py
  plan_step build run - - "printf '%s\n' \"\$DEVBOX_WORKERS\" >$(printf '%q' "$TMP/build-workers")"
} >"$TMP/workers.plan"
cat >"$BIN/uv" <<'STUB'
#!/bin/bash
[ "$1" = run ] && shift
exec "$@"
STUB
chmod +x "$BIN/uv"
: >"$ARGV_LOG"
: >"$ENV_LOG"
run_steps workers "$TMP/workers.plan" DEVBOX_TOKENS=12 STUB_XDIST=1
assert_eq "0" "$RC" "a 12-token gate with two runner steps runs: $ERR"
vitest_argv="$(awk '$0 == "--end--" { print c; c = ""; next } { c = c " " $0 }' "$ARGV_LOG" | grep ' run' | head -1)"
pytest_argv="$(awk '$0 == "--end--" { print c; c = ""; next } { c = c " " $0 }' "$ARGV_LOG" | grep ' -q' | head -1)"
assert_eq " run --maxWorkers=6" "$vitest_argv" "a vitest step of 10 files gets 12 / 2 = 6 workers when two runner steps start together"
assert_eq " -q -n 3" "$pytest_argv" "a pytest step of 3 files gets min(6, 3) = 3 workers"
assert_ok "the vitest step's DEVBOX_WORKERS is its worker count" grep -qx "vitest pwd=$PROJ workers=6" "$ENV_LOG"
assert_ok "the pytest step's DEVBOX_WORKERS is its worker count" grep -qx "pytest pwd=$PROJ workers=3" "$ENV_LOG"
assert_eq "6" "$(cat "$TMP/build-workers")" "a step with no runner gets DEVBOX_WORKERS too: the grant shared by the two runner steps that start with it"

# The memory cap: (8 GiB - 4 GiB) / 1536 MiB is 2 workers, and with a worker
# that needs 1 GiB it is 4. memory.max `max` means no limit, so memory.high is
# read.
plan_step suite run vitest - 'npx vitest run' >"$TMP/one-vitest.plan"
CG8="$TMP/cgroup-8g"
mkdir -p "$CG8"
printf 'max\n' >"$CG8/memory.max"
printf '8589934592\n' >"$CG8/memory.high"
: >"$ARGV_LOG"
run_steps mem8 "$TMP/one-vitest.plan" DEVBOX_TOKENS=12 DEVBOX_CGROUP_ROOT="$CG8"
assert_eq "$(printf '%s\n' run --maxWorkers=2)" "$(argv_call 1)" "an 8 GiB workspace caps a 12-token step at 2 workers of 1536M"
: >"$ARGV_LOG"
run_steps mem8-1g "$TMP/one-vitest.plan" DEVBOX_TOKENS=12 DEVBOX_CGROUP_ROOT="$CG8" DEVBOX_WORKER_MEMORY=1G
assert_eq "$(printf '%s\n' run --maxWorkers=4)" "$(argv_call 1)" "DEVBOX_WORKER_MEMORY=1G raises that cap to 4"
printf '3221225472\n' >"$CG8/memory.high"
: >"$ARGV_LOG"
run_steps mem3 "$TMP/one-vitest.plan" DEVBOX_TOKENS=12 DEVBOX_CGROUP_ROOT="$CG8"
assert_eq "$(printf '%s\n' run --maxWorkers=1)" "$(argv_call 1)" "a workspace under 4 GiB still gets 1 worker"

# vitest 2 takes its minimum worker count from the cores, and a lower
# --maxWorkers alone stopped it with a RangeError, so 2 and 3 also get
# --minWorkers=1. vitest 4 has no such option.
mkdir -p "$PROJ/node_modules/vitest"
for v in 2.0.0 3.0.0 4.0.0; do
  printf '{\n  "name": "vitest",\n  "version": "%s"\n}\n' "$v" >"$PROJ/node_modules/vitest/package.json"
  : >"$ARGV_LOG"
  run_steps "vitest-${v%%.*}" "$TMP/one-vitest.plan" DEVBOX_TOKENS=12 DEVBOX_CGROUP_ROOT="$CG8"
  if [ "$v" = 4.0.0 ]; then
    assert_eq "$(printf '%s\n' run --maxWorkers=1)" "$(argv_call 1)" "vitest $v gets --maxWorkers alone"
  else
    assert_eq "$(printf '%s\n' run --maxWorkers=1 --minWorkers=1)" "$(argv_call 1)" "vitest $v also gets --minWorkers=1"
  fi
done
rm -r "$PROJ/node_modules/vitest"
run_steps bad-memory "$TMP/one-vitest.plan" DEVBOX_WORKER_MEMORY=lots
assert_eq "2" "$RC" "a DEVBOX_WORKER_MEMORY that is not a size is refused with exit 2"
assert_ok "the refusal names DEVBOX_WORKER_MEMORY" grep -q 'DEVBOX_WORKER_MEMORY is lots' <<<"$ERR"
run_steps bad-tokens "$TMP/one-vitest.plan" DEVBOX_TOKENS=many
assert_eq "2" "$RC" "a DEVBOX_TOKENS that is not a count is refused with exit 2"

# A command that sets its own worker count keeps it.
for own in '--maxWorkers=3' '--maxWorkers 3' '--pool-options.forks.maxForks=3'; do
  plan_step suite run vitest - "npx vitest run $own" >"$TMP/own.plan"
  : >"$ARGV_LOG"
  run_steps own "$TMP/own.plan" DEVBOX_TOKENS=12
  assert_eq "0" "$(grep -c -- '--maxWorkers=6\|--maxWorkers=12' "$ARGV_LOG")" "a vitest command with $own keeps its own workers"
done
for own in '-n 3' '-n3' '-nauto' '--numprocesses=3' '--numprocesses 3'; do
  plan_step py run pytest - "pytest $own" >"$TMP/own.plan"
  : >"$ARGV_LOG"
  run_steps own "$TMP/own.plan" DEVBOX_TOKENS=12 STUB_XDIST=1
  read -r -a own_words <<<"$own"
  assert_eq "$(printf '%s\n' "${own_words[@]}")" "$(argv_call 1)" "a pytest command with $own keeps its own workers and gets no second -n"
done

# ── row D5: no more runner steps at once than the grant has tokens ───────────
#
# Each runner step gets at least one worker, so every runner step of a
# monorepo started at once ran several times as many test processes as the
# grant had tokens, and the host's load failed most of them on timeouts. Four
# runner steps on a 2-token grant run two at a time; a step without a runner
# that is ready with them starts at once.

CAP_EV="$TMP/cap-events"
q_cap="$(printf '%q' "$CAP_EV")"
: >"$CAP_EV"
{
  for s in r1 r2 r3 r4; do
    plan_step "$s" run vitest - "echo $s:start >>$q_cap; sleep 0.4; echo $s:end >>$q_cap; npx vitest run"
  done
  plan_step build run - - "echo build:start >>$q_cap; echo build:end >>$q_cap"
} >"$TMP/cap.plan"
: >"$ARGV_LOG"
run_steps cap "$TMP/cap.plan" DEVBOX_TOKENS=2
assert_eq "0" "$RC" "four runner steps on a 2-token grant all run and pass: $ERR"
assert_eq "10" "$(wc -l <"$CAP_EV" | tr -d ' ')" "each of the 5 steps started and ended once"
peak="$(awk -F: '$1 != "build" { n += ($2 == "start") ? 1 : -1; if (n > m) m = n } END { print m + 0 }' "$CAP_EV")"
assert_eq "2" "$peak" "at most 2 runner steps ran at once, one per token"
first_end="$(grep -n ':end$' "$CAP_EV" | grep -v build | head -1 | cut -d: -f1)"
assert_ok "the step without a runner started before any runner step ended: the cap does not hold it" \
  test "$(line_of "$CAP_EV" build:start)" -lt "$first_end"
assert_eq "4" "$(grep -c -- '^--maxWorkers=1$' "$ARGV_LOG")" "each runner step got 2 tokens / 2 running = 1 worker"
assert_eq "1" "$(grep -c 'runner steps wait: at most 2 run at once' <<<"$OUT")" "one line says that runner steps wait for the grant"
assert_eq "5" "$(grep -c '^devbox-steps: result .* pass ' <<<"$OUT")" "and every step has its result line"

# On a 1-token grant a held step starts only after the running one ended, the
# ready steps in plan order, and r3 still waits for r1 by its after= edge.
: >"$CAP_EV"
{
  plan_step r1 run vitest - "echo r1:start >>$q_cap; echo r1:end >>$q_cap; npx vitest run"
  plan_step r2 run vitest - "echo r2:start >>$q_cap; echo r2:end >>$q_cap; npx vitest run"
  plan_step r3 run vitest r1 "echo r3:start >>$q_cap; echo r3:end >>$q_cap; npx vitest run"
  plan_step r4 run vitest - "echo r4:start >>$q_cap; echo r4:end >>$q_cap; npx vitest run"
} >"$TMP/cap-after.plan"
run_steps cap-after "$TMP/cap-after.plan" DEVBOX_TOKENS=1
assert_eq "0" "$RC" "a 1-token grant runs four runner steps one at a time: $ERR"
assert_eq "r1:start r1:end r2:start r2:end r3:start r3:end r4:start r4:end" "$(tr '\n' ' ' <"$CAP_EV" | sed 's/ $//')" \
  "in plan order, each after the one before ended, r3 after r1"

# ── row D6: a step may run in a subfolder ────────────────────────────────────

mkdir -p "$PROJ/service/tests" "$PROJ/web"
{
  plan_step service narrow pytest - 'pytest -q' service/
  plan_file service service/tests/test_a.py
  plan_file service 'service/tests/test b.py'
} >"$TMP/dir-pytest.plan"
L="$TMP/dir.ledger"
new_ledger "$L"
: >"$ARGV_LOG"
: >"$ENV_LOG"
run_steps dir-pytest "$TMP/dir-pytest.plan" DEVBOX_LEDGER="$L" DEVBOX_LEDGER_TOOLS="$TOOLS"
assert_eq "0" "$RC" "a dir= pytest step runs: $ERR"
assert_eq "$(printf '%s\n' -q -p devbox_ledger tests/test_a.py 'tests/test b.py')" "$(argv_call 1)" \
  "a dir= step's files reach its runner relative to its folder"
assert_ok "a dir= step runs in its folder" grep -qx "pytest pwd=$PROJ/service workers=2" "$ENV_LOG"

{
  plan_step web run vitest - 'npx vitest run' web/
  plan_test web web/src/a.test.ts
} >"$TMP/dir-vitest.plan"
rm -rf "$PROJ/web/node_modules"
: >"$ARGV_LOG"
run_steps dir-vitest "$TMP/dir-vitest.plan" DEVBOX_LEDGER="$L" DEVBOX_LEDGER_TOOLS="$TOOLS"
assert_eq "$(printf '%s\n' run "${REP[@]}" --maxWorkers=1)" "$(argv_call 1)" \
  "a dir= vitest step names its reporter relative to its folder"
assert_ok "a dir= vitest step's reporter is copied under its folder, which vitest 3 requires" \
  cmp -s "$TOOLS/vitest-ledger.mjs" "$PROJ/web/node_modules/.devbox-ledger/vitest-ledger.mjs"

run_steps no-tools "$TMP/pytest.plan" DEVBOX_LEDGER="$L"
assert_eq "2" "$RC" "a ledger and a runner step with no DEVBOX_LEDGER_TOOLS is refused with exit 2"
assert_ok "the refusal names DEVBOX_LEDGER_TOOLS" grep -q 'DEVBOX_LEDGER_TOOLS' <<<"$ERR"

# ── a TERM or an INT stops every step's process group ────────────────────────
#
# Each step leaves a sleep in the background and waits on it, so a signal that
# reached the step's shell alone would leave the sleep running.

term_case() {
  local sig="$1" want="$2" dir="$TMP/sig-$1" pid child shell_pgid steps_pgid rc
  mkdir -p "$dir"
  {
    plan_step slow1 run - - "sleep 60 & echo \$! >$(printf '%q' "$dir/slow1.child"); echo \$\$ >$(printf '%q' "$dir/slow1.shell"); wait"
    plan_step slow2 run - - "sleep 60 & echo \$! >$(printf '%q' "$dir/slow2.child"); wait"
  } >"$dir/plan"
  L="$dir/ledger"
  new_ledger "$L"
  # A background job of a non-interactive shell ignores SIGINT, and a signal
  # ignored at entry cannot be trapped, so the runner starts in its own group.
  set -m
  (cd "$PROJ" && exec env PATH="$BIN:$PATH" DEVBOX_STEPS_PLAN="$dir/plan" DEVBOX_STEPS_LOGS="$dir/logs" DEVBOX_LEDGER="$L" \
    "$STEPS" >"$dir/out" 2>"$dir/err") &
  pid=$!
  set +m
  for _ in $(seq 1 50); do
    [ -s "$dir/slow1.child" ] && [ -s "$dir/slow2.child" ] && [ -s "$dir/slow1.shell" ] && break
    sleep 0.1
  done
  child="$(cat "$dir/slow1.child")"
  shell_pgid="$(ps -o pgid= -p "$(cat "$dir/slow1.shell")" | tr -d ' ')"
  steps_pgid="$(ps -o pgid= -p "$pid" | tr -d ' ')"
  assert_ok "SIG$sig: the step's shell and the runner each report a process group" test -n "$shell_pgid" -a -n "$steps_pgid"
  assert_eq "$shell_pgid" "$(ps -o pgid= -p "$child" | tr -d ' ')" "SIG$sig: a step's background child is in the step's process group"
  assert_ok "SIG$sig: a step's process group is not the runner's" test "$shell_pgid" != "$steps_pgid"
  kill "-$sig" "$pid"
  rc=0
  wait "$pid" || rc=$?
  assert_eq "$want" "$rc" "SIG$sig: the runner exits $want"
  for c in "$child" "$(cat "$dir/slow2.child")"; do
    for _ in $(seq 1 20); do kill -0 "$c" 2>/dev/null || break; sleep 0.1; done
    assert_fail "SIG$sig: the background child $c of a step is gone" kill -0 "$c"
  done
  assert_ok "SIG$sig: the runner says it stopped the running steps" grep -q "stopped by SIG$sig; stopped the process groups of: slow1 slow2" "$dir/err"
  assert_eq "start" "$(step_outcomes "$L" slow1)" "SIG$sig: a stopped step stays start in the ledger, so a resume runs it again"
  assert_eq "0" "$(grep -c '^devbox-steps: result' "$dir/out")" "SIG$sig: a stopped run prints no result line"
}
term_case TERM 143
term_case INT 130

# ── a malformed plan is refused before any step starts ───────────────────────

FIRST="$(plan_step first run - - "touch $(printf '%q' "$TMP/malformed-ran")")"
# refused <description> <line number> <reason pattern> <plan lines after the first>
refused() {
  local desc="$1" want_line="$2" pattern="$3"
  printf '%s\n%s' "$FIRST" "$4" >"$TMP/bad.plan"
  rm -f "$TMP/malformed-ran"
  run_steps malformed "$TMP/bad.plan"
  assert_eq "2" "$RC" "refused with exit 2: $desc"
  assert_ok "the refusal names plan line $want_line and why: $desc ($ERR)" grep -Eq "^devbox-steps: plan line $want_line: .*$pattern" <<<"$ERR"
  assert_fail "no step started: $desc" test -e "$TMP/malformed-ran"
}
refused "a step line with 8 fields" 2 '9 non-empty fields' "$(printf 'step\tx\trun\t%s\t-\t-\t%s\t-\n' "$KEY" "$(printf 'true' | base64)")"
refused "a 3.3 step line of 7 fields" 2 '9 non-empty fields' "$(printf 'step\tx\trun\t%s\t-\t-\t%s\n' "$KEY" "$(printf 'true' | base64)")"
refused "an empty field" 2 '9 non-empty fields' "$(printf 'step\tx\trun\t%s\t\t-\t%s\t-\t0\n' "$KEY" "$(printf 'true' | base64)")"
refused "an unknown plan word" 2 'not run, carry, narrow or select' "$(plan_step x skip - - true)"
refused "the plan word related, which select replaced" 2 'not run, carry, narrow or select' "$(plan_step x related vitest - 'npx vitest run'; plan_file x a.ts)"
refused "a name with a capital" 2 'is not \[a-z0-9\]' "$(plan_step Xy run - - true)"
refused "a name planned twice" 2 'planned twice' "$(plan_step first run - - true)"
refused "an unknown runner" 2 'not vitest, pytest or -' "$(plan_step x run jest - true)"
refused "a command that is not base64" 2 'not base64' "$(printf 'step\tx\trun\t%s\t-\t-\t!!!\t-\t0\n' "$KEY")"
refused "a trace that is not 0 or 1" 2 'not 0 or 1' "$(plan_step x run - - true - yes)"
refused "a dir that does not end in /" 2 'does not end in /' "$(plan_step x run - - true service)"
refused "an absolute dir" 2 'not a relative folder' "$(plan_step x run - - true /srv/)"
refused "a dir with .." 2 'not a relative folder' "$(plan_step x run - - true service/../../)"
refused "a dir that is not a folder" 2 'is not a folder' "$(plan_step x run - - true nothere/)"
refused "an after name the plan does not hold" 2 'does not hold' "$(plan_step x run - nothere true)"
refused "a cycle of after edges" 2 'cycle' "$(plan_step x run - y true; plan_step y run - x true)"
refused "a file line for a run step" 3 'not narrow or select' "$(plan_step x run vitest - 'npx vitest run'; plan_file x a.test.ts)"
refused "a file line before its step" 2 'no step line above it' "$(plan_file x a.test.ts; plan_step x narrow vitest - 'npx vitest run')"
refused "a test line for a step with no runner" 3 'names no runner' "$(plan_step x run - - 'make test'; plan_test x a.test.ts)"
refused "a narrow step with no file line" 2 'has no file line' "$(plan_step x narrow vitest - 'npx vitest run')"
refused "a select step with no file line" 2 'has no file line' "$(plan_step x select vitest - 'npx vitest run'; plan_test x a.test.ts)"
refused "a narrow step with no runner" 2 'names no runner' "$(plan_step x narrow - - 'make test'; plan_file x a.test.ts)"
refused "a select step with no runner" 2 'names no runner' "$(plan_step x select - - 'make test'; plan_file x a.test.ts)"
refused "a file that starts with -" 3 'starts with -' "$(plan_step x narrow vitest - 'npx vitest run'; plan_file x --reporter=json)"
refused "a test file that starts with -" 3 'starts with -' "$(plan_step x run vitest - 'npx vitest run'; plan_test x -x)"
refused "a file outside the dir of its step" 3 'is outside service/' "$(plan_step x narrow pytest - pytest service/; plan_file x tests/test_a.py)"
refused "a line of another kind" 2 'starts with step, file or test' 'hello'

# ── a streamed step whose log fills up ───────────────────────────────────────
#
# A strace log filled a CI runner's tmpfs, and with pipefail tee's ENOSPC
# failed a streamed step whose command passed. Here a 1 KiB file size limit
# fills the log: the runner's first lines fit, and tee's write of the 4 KiB of
# output fails with EFBIG. SIGXFSZ is ignored, so tee gets the error as it got
# ENOSPC on that runner, and is not killed.

# full_log_run <case> <exit code>: one streamed step that prints 4 KiB, then
# "solo output", then exits with that code, under the limit.
full_log_run() {
  plan_step solo run - - "head -c 4096 /dev/zero | tr -c x x; echo; echo solo output; exit $2" >"$TMP/$1.plan"
  LOGS="$TMP/logs-$1"
  RC=0
  OUT="$(cd "$PROJ" && trap '' XFSZ && ulimit -f 1 && env PATH="$BIN:$PATH" DEVBOX_TOKENS=4 \
    DEVBOX_CGROUP_ROOT="$CGROUP" DEVBOX_STEPS_PLAN="$TMP/$1.plan" DEVBOX_STEPS_LOGS="$LOGS" "$STEPS" 2>"$TMP/err")" || RC=$?
  ERR="$(cat "$TMP/err")"
}

full_log_run full-pass 0
assert_eq "0" "$RC" "a streamed step that passes passes when its log fills up"
assert_ok "and its result line is pass" grep -Eq '^devbox-steps: result solo pass [0-9]+ 0$' <<<"$OUT"
assert_ok "and its output streams past the full log" grep -qxF "solo output" <<<"$OUT"
assert_ok "and the runner names the log it could not write" \
  grep -qxF "devbox-steps: could not write all of the log $LOGS/solo.log" <<<"$ERR"

full_log_run full-fail 3
assert_eq "1" "$RC" "a streamed step that fails still fails when its log fills up"
assert_ok "and its result line keeps the command's code" grep -Eq '^devbox-steps: result solo fail [0-9]+ 3$' <<<"$OUT"

run_steps no-plan "$TMP/does-not-exist.plan"
assert_eq "2" "$RC" "a plan file that does not exist is refused with exit 2"

printf '%d %d\n' "$TESTS_RUN" "$TESTS_FAILED"
