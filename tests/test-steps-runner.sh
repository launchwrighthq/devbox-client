#!/bin/bash
# client/share/steps/devbox-steps, the runner of a gate's step graph.
# docs/specs/2026-11-14-client-owns-the-gate-design.md section 6.3 holds the
# design, section 6.7 the plan format and the output, and section 13 rows D3,
# D4 and D14 the requirements this file checks.
#
# The risks: a step that starts before the step it runs after has ended, a
# failed step whose log never reaches the client, a ledger `pass` for a step
# that did not finish, a runner whose plug-in or file filters reach the test
# runner as the wrong words, and a stopped gate that leaves its test processes
# running in the workspace.
#
# vitest and pytest are stubs on PATH that record their argv one word per line,
# so no test runner is installed. node is required for the --exclude of a
# resumed vitest step, and a missing node FAILS this file, never skips it.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
# shellcheck source=tests/lib.sh
source ./lib.sh
REPO="$(cd .. && pwd)"
STEPS="$REPO/client/share/steps/devbox-steps"
TOOLS="$REPO/client/share/ledger"

TMP="$(mktemp -d)" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
unset DEVBOX_STEPS_PLAN DEVBOX_STEPS_LOGS DEVBOX_LEDGER DEVBOX_RESUME DEVBOX_LEDGER_TOOLS

PROJ="$TMP/project"
BIN="$TMP/bin"
mkdir -p "$PROJ/.devbox" "$BIN"
printf 'DEVBOX_PROJECT=app\n' >"$PROJ/.devbox/config.env"
KEY=0123456789abcdef

# The stubs: npx runs the stub vitest, and each runner appends its argv, one
# word per line, then `--end--`, so a word that holds a space stays one line.
cat >"$BIN/npx" <<'STUB'
#!/bin/bash
exec "$@"
STUB
cat >"$BIN/vitest" <<'STUB'
#!/bin/bash
{ printf '%s\n' "$@"; echo --end--; } >>"$ARGV_LOG"
STUB
cat >"$BIN/pytest" <<'STUB'
#!/bin/bash
{ printf '%s\n' "$@"; echo --end--; } >>"$ARGV_LOG"
printf '%s\n' "$PYTHONPATH" >>"$PYTHONPATH_LOG"
STUB
chmod +x "$BIN/npx" "$BIN/vitest" "$BIN/pytest"
export ARGV_LOG="$TMP/argv.log" PYTHONPATH_LOG="$TMP/pythonpath.log"

# plan_step <name> <mode> <runner> <after> <command>: one step line of the plan.
plan_step() {
  printf 'step\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$KEY" "$3" "$4" "$(printf '%s' "$5" | base64 | tr -d '\n')"
}
plan_file() { printf 'file\t%s\t%s\n' "$1" "$2"; }

# run_steps <case> <plan file> [VAR=value...]: runs the runner in the project
# directory with fresh logs in $TMP/logs-<case>. Sets OUT, ERR, RC and LOGS.
run_steps() {
  local case="$1" plan="$2"
  shift 2
  LOGS="$TMP/logs-$case"
  RC=0
  OUT="$(cd "$PROJ" && env PATH="$BIN:$PATH" DEVBOX_STEPS_PLAN="$plan" DEVBOX_STEPS_LOGS="$LOGS" "$@" "$STEPS" 2>"$TMP/err")" || RC=$?
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
  _fail "node is on PATH" "the --exclude of a resumed vitest step needs node; a missing one fails this file, never skips it"
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
assert_eq "$(printf '%s\n' run --project api "${REP[@]}")" "$(argv_call 1)" \
  "a vitest step gets the default reporter and the ledger reporter appended"
assert_ok "the reporter is copied into the project's node_modules" cmp -s "$TOOLS/vitest-ledger.mjs" "$PROJ/node_modules/.devbox-ledger/vitest-ledger.mjs"
assert_ok "ledger-core.mjs is copied beside it" cmp -s "$TOOLS/ledger-core.mjs" "$PROJ/node_modules/.devbox-ledger/ledger-core.mjs"
imported="$(cd "$PROJ" && node --input-type=module -e "import('./node_modules/.devbox-ledger/vitest-ledger.mjs').then((m) => console.log(typeof m.default, typeof m.passedFiles))" 2>&1)"
assert_eq "function function" "$imported" "the copied reporter imports its ledger-core.mjs from its own directory"

# A resume leaves out each file whose last vitest record is pass, through the
# reporter's own passedFiles(): a file opened again after its pass runs, a
# pytest file is not vitest's, and a glob character is escaped.
L="$TMP/vitest-resume.ledger"
new_ledger "$L"
printf '%s\n' \
  $'file\tvitest\tsrc/a.test.ts\tstart' \
  $'file\tvitest\tsrc/a.test.ts\tpass\t1' \
  $'file\tvitest\tsrc/b c.test.ts\tpass\t1' \
  $'file\tvitest\tapp/[id]/page.test.ts\tpass\t1' \
  $'file\tvitest\tsrc/d.test.ts\tpass\t1' \
  $'file\tvitest\tsrc/d.test.ts\tstart' \
  $'file\tpytest\ttests/test_p.py\tpass\t1' >>"$L"
: >"$ARGV_LOG"
run_steps vitest-resume "$TMP/vitest.plan" DEVBOX_LEDGER="$L" DEVBOX_LEDGER_TOOLS="$TOOLS" DEVBOX_RESUME=1
assert_eq "0" "$RC" "a resumed vitest step runs: $ERR"
assert_eq "$(printf '%s\n' run --project api "${REP[@]}" --exclude src/a.test.ts --exclude 'src/b c.test.ts' --exclude 'app/\[id\]/page.test.ts')" \
  "$(argv_call 1)" "a resumed vitest step gets one --exclude per passed vitest file, a space kept inside one word"

# A narrowed step appends its failed files as filters.
{
  plan_step unit narrow vitest - 'npx vitest run'
  plan_file unit src/x.test.ts
  plan_file unit 'src/with space.test.ts'
} >"$TMP/narrow.plan"
L="$TMP/narrow.ledger"
new_ledger "$L"
: >"$ARGV_LOG"
run_steps narrow "$TMP/narrow.plan" DEVBOX_LEDGER="$L" DEVBOX_LEDGER_TOOLS="$TOOLS"
assert_eq "$(printf '%s\n' run "${REP[@]}" src/x.test.ts 'src/with space.test.ts')" "$(argv_call 1)" \
  "a narrowed vitest step appends its files after the options, one word each"

# ── row D14: a related step runs vitest related on its changed files ─────────

{
  plan_step web related vitest - 'npx vitest run --project web'
  plan_file web src/util.ts
  plan_file web "src/it's here.ts"
} >"$TMP/related.plan"
L="$TMP/related.ledger"
new_ledger "$L"
: >"$ARGV_LOG"
run_steps related "$TMP/related.plan" DEVBOX_LEDGER="$L" DEVBOX_LEDGER_TOOLS="$TOOLS"
assert_eq "0" "$RC" "a related step runs: $ERR"
assert_eq "$(printf '%s\n' related --run --project web "${REP[@]}" src/util.ts "src/it's here.ts")" "$(argv_call 1)" \
  "a related step runs vitest related --run with the changed files after its options"
assert_ok "the step log names the command that ran" grep -qF 'npx vitest related --run --project web' "$LOGS/web.log"

: >"$ARGV_LOG"
run_steps related-noledger "$TMP/related.plan"
assert_eq "$(printf '%s\n' related --run --project web src/util.ts "src/it's here.ts")" "$(argv_call 1)" \
  "with no DEVBOX_LEDGER no reporter is wired, and the files still are"

# ── row D4: the pytest wiring ────────────────────────────────────────────────

plan_step py run pytest - 'pytest -q -n 2' >"$TMP/pytest.plan"
L="$TMP/pytest.ledger"
new_ledger "$L"
: >"$ARGV_LOG"
: >"$PYTHONPATH_LOG"
run_steps pytest "$TMP/pytest.plan" DEVBOX_LEDGER="$L" DEVBOX_LEDGER_TOOLS="$TOOLS" PYTHONPATH=/opt/site
assert_eq "0" "$RC" "a pytest step runs: $ERR"
assert_eq "$(printf '%s\n' -q -n 2 -p devbox_ledger)" "$(argv_call 1)" "a pytest step gets -p devbox_ledger appended"
assert_eq "$TOOLS:/opt/site" "$(cat "$PYTHONPATH_LOG")" "a pytest step finds the plugin first on PYTHONPATH and keeps the PYTHONPATH it had"
assert_eq "start pass" "$(step_outcomes "$L" py)" "the runner writes the pytest step's own ledger lines"

{
  plan_step py narrow pytest - 'pytest -q'
  plan_file py tests/test_a.py
  plan_file py 'tests/test b.py'
} >"$TMP/pytest-narrow.plan"
: >"$ARGV_LOG"
run_steps pytest-narrow "$TMP/pytest-narrow.plan" DEVBOX_LEDGER="$L" DEVBOX_LEDGER_TOOLS="$TOOLS"
assert_eq "$(printf '%s\n' -q -p devbox_ledger tests/test_a.py 'tests/test b.py')" "$(argv_call 1)" \
  "a narrowed pytest step appends its files after the plugin, one word each"

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
refused "a step line with 6 fields" 2 '7 non-empty fields' "$(printf 'step\tx\trun\t%s\t-\t-\n' "$KEY")"
refused "an empty field" 2 '7 non-empty fields' "$(printf 'step\tx\trun\t%s\t\t-\t%s\n' "$KEY" "$(printf 'true' | base64)")"
refused "an unknown plan word" 2 'not run, carry, narrow or related' "$(plan_step x skip - - true)"
refused "a name with a capital" 2 'is not \[a-z0-9\]' "$(plan_step Xy run - - true)"
refused "a name planned twice" 2 'planned twice' "$(plan_step first run - - true)"
refused "an unknown runner" 2 'not vitest, pytest or -' "$(plan_step x run jest - true)"
refused "a command that is not base64" 2 'not base64' "$(printf 'step\tx\trun\t%s\t-\t-\t!!!\n' "$KEY")"
refused "an after name the plan does not hold" 2 'does not hold' "$(plan_step x run - nothere true)"
refused "a cycle of after edges" 2 'cycle' "$(plan_step x run - y true; plan_step y run - x true)"
refused "a file line for a run step" 3 'not narrow or related' "$(plan_step x run vitest - 'npx vitest run'; plan_file x a.test.ts)"
refused "a file line before its step" 2 'no step line above it' "$(plan_file x a.test.ts; plan_step x narrow vitest - 'npx vitest run')"
refused "a narrow step with no file line" 2 'has no file line' "$(plan_step x narrow vitest - 'npx vitest run')"
refused "a narrow step with no runner" 2 'names no runner' "$(plan_step x narrow - - 'make test'; plan_file x a.test.ts)"
refused "a related pytest step" 2 'not a vitest step' "$(plan_step x related pytest - pytest; plan_file x a.py)"
refused "a related step with vitest run twice" 2 'exactly once' "$(plan_step x related vitest - 'npx vitest run && npx vitest run'; plan_file x a.ts)"
refused "a file that starts with -" 3 'starts with -' "$(plan_step x narrow vitest - 'npx vitest run'; plan_file x --reporter=json)"
refused "a line of another kind" 2 'starts with step or file' 'hello'

run_steps no-plan "$TMP/does-not-exist.plan"
assert_eq "2" "$RC" "a plan file that does not exist is refused with exit 2"

printf '%d %d\n' "$TESTS_RUN" "$TESTS_FAILED"
