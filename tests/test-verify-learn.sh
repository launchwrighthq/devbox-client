#!/bin/bash
# devbox-verify learns from the traces a gate sends back
# (docs/specs/2026-11-14-learned-selection-design.md, section 5.6, the
# transport, and D2, D4 and D10 end to end on this laptop).
#
# The trace lines of the runner, `devbox-steps: trace <step> <seq> <chunk>`,
# stay off the terminal as the result lines do, and the client joins them into
# each step's map after a complete gate. The step runner is built by another
# part of the spec, so the end-to-end cases run a copy of this client whose
# client/share/steps/devbox-steps is a stub: it reads the plan of section 5.6,
# runs each step that does not carry, logs what the plan gave it, and prints
# the trace each step's fixture file holds, gzipped and in base64 chunks, then
# the result lines.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
# shellcheck source=tests/lib.sh
source ./lib.sh
unset CI DEVBOX_RERUN DEVBOX_STRICT

REPO="$(cd .. && pwd)"
TMP="$(mktemp -d)" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
contains() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }

# ── the transport, function by function ──────────────────────────────────────

eval "$(sed -n '/^steps_display() {/,/^}/p' "$REPO/client/libexec/devbox-verify")"
eval "$(sed -n '/^steps_results() {/,/^}/p' "$REPO/client/libexec/devbox-verify")"
eval "$(sed -n '/^steps_traces() {/,/^}/p' "$REPO/client/libexec/devbox-verify")"
is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }

# chunks <step> <first seq> <size> <file>: the trace lines of <file> as the
# runner prints them.
chunks() {
  local step="$1" seq="$2" size="$3" c
  { gzip -c <"$4" | base64 | tr -d '\n' | fold -w "$size"; echo; } | while IFS= read -r c; do
    [ -z "$c" ] || printf 'devbox-steps: trace %s %s %s\n' "$step" "$seq" "$c"; seq=$((seq + 1))
  done
}
printf 'read\ttests/test_a.py\tsrc/a.py\nread\t-\tpytest.ini\n' >"$TMP/t1"
printf 'read\t-\tsrc/b.py\n' >"$TMP/t2"
{
  printf '[0 s] lint started\n'
  printf 'step lint output\n'
  chunks test 1 16 "$TMP/t1"
  chunks lint 0 8 "$TMP/t2"
  printf 'devbox-steps: result lint pass 1 0\n'
  printf 'devbox-steps: result test pass 2 0\n'
  chunks late 1 1000 "$TMP/t2"
} >"$TMP/raw.in"
steps_display "$TMP/raw" <"$TMP/raw.in" >"$TMP/shown"
assert_fail "the display hides every trace line" grep -q 'devbox-steps: trace' "$TMP/shown"
assert_ok "and keeps the step's own output" grep -qx 'step lint output' "$TMP/shown"
assert_ok "which the raw copy keeps" grep -q 'devbox-steps: trace test 1 ' "$TMP/raw"
# shellcheck disable=SC2034 # read by steps_results, which the eval above defined
declare -A PLAN_ACTION=([lint]=run [test]=select) STEPS_RESULT=()
steps_results "$TMP/raw"
assert_eq "pass 1 0|pass 2 0" "${STEPS_RESULT[lint]-}|${STEPS_RESULT[test]-}" \
  "trace lines after the result block neither end nor break it"
steps_traces "$TMP/raw" "$TMP/tr" 2>"$TMP/err"
assert_eq "$(cat "$TMP/t1")" "$(cat "$TMP/tr/test.trace")" "chunks from seq 1 join into the step's trace"
assert_eq "$(cat "$TMP/t2")" "$(cat "$TMP/tr/lint.trace")" "and chunks from seq 0"
assert_eq "" "$(cat "$TMP/err")" "with no line on stderr"
grep -v 'devbox-steps: trace test 2 ' "$TMP/raw" >"$TMP/raw.gap"
rm -rf "$TMP/tr"
steps_traces "$TMP/raw.gap" "$TMP/tr" 2>"$TMP/err"
assert_eq "partial	-	the trace arrived incomplete" "$(cat "$TMP/tr/test.trace")" \
  "a missing chunk leaves the step a trace that says it arrived incomplete"
assert_ok "and one line names the step" grep -qx "devbox verify: the trace of step test arrived incomplete, so its map keeps its earlier reads" "$TMP/err"
sed 's/^\(devbox-steps: trace test 1 \)..../\1AAAA/' "$TMP/raw" >"$TMP/raw.bad"
rm -rf "$TMP/tr"
steps_traces "$TMP/raw.bad" "$TMP/tr" 2>"$TMP/err"
assert_ok "a chunk that does not decode is incomplete too" grep -q 'arrived incomplete' "$TMP/tr/test.trace"
printf 'devbox-steps: untraced lint strace: not found\n' >"$TMP/raw.untraced"
chunks test 1 1000 "$TMP/t1" >>"$TMP/raw.untraced"
printf 'devbox-steps: untraced test a line the trace wins over\n' >>"$TMP/raw.untraced"
rm -rf "$TMP/tr"
steps_traces "$TMP/raw.untraced" "$TMP/tr" 2>"$TMP/err"
assert_eq "partial	-	strace: not found" "$(cat "$TMP/tr/lint.trace")" \
  "a step the runner could not trace gets one partial line with the runner's reason"
assert_eq "$(cat "$TMP/t1")" "$(cat "$TMP/tr/test.trace")" "and a step that sent a trace keeps it"
steps_display "$TMP/raw.u2" <"$TMP/raw.untraced" >"$TMP/shown"
assert_ok "the untraced line stays on the terminal" grep -qx 'devbox-steps: untraced lint strace: not found' "$TMP/shown"

# ── the record's file lines: each ledger file goes to its own step ───────────
#
# The ledger names a file's runner and not its step. The last fallback once
# gave a file to every step of its runner whose inputs= was empty: in a
# monorepo of one vitest step per module, with dir= and no inputs=, one test
# file was recorded under every step, and `devbox result --failed-files
# <step>` listed the failed files of every module.

# steps_file_lines matches inputs= with _devbox_plan_match.
# shellcheck source=client/libexec/devbox-plan
source "$REPO/client/libexec/devbox-plan"
eval "$(sed -n '/^steps_file_lines() {/,/^}/p' "$REPO/client/libexec/devbox-verify")"
STEPS_DIR="$TMP/attr"
mkdir -p "$STEPS_DIR"
STEPS_LEDGER="$STEPS_DIR/ledger"
# attr_steps <name>:<runner>:<dir>:<inputs>:<action>...: the steps of a plan.
attr_steps() {
  local spec name runner dir inputs action
  declare -ga PLAN_STEPS=()
  declare -gA PLAN_ACTION=() STEP_RUNNER=() STEP_DIR=() STEP_INPUTS=()
  for spec in "$@"; do
    IFS=: read -r name runner dir inputs action <<<"$spec"
    PLAN_STEPS+=("$name")
    PLAN_ACTION[$name]="${action:-run}" STEP_RUNNER[$name]="$runner" STEP_DIR[$name]="$dir" STEP_INPUTS[$name]="$inputs"
  done
}
printf '%s\n' $'test\tmod-a\tmods/a/ts/x.test.ts' $'test\tmod-a\tmods/a/ts/deep/p.test.ts' >"$STEPS_DIR/plan"
printf '%s\n' $'file\tvitest\tmods/a/ts/x.test.ts\tstart' $'file\tvitest\tmods/a/ts/x.test.ts\tpass\t3' \
  $'file\tvitest\tmods/a/ts/deep/p.test.ts\tpass\t1' $'file\tvitest\tmods/a/ts/deep/z.test.ts\tfail\t2' \
  $'file\tvitest\tmods/b/ts/y.test.ts\tfail\t4' $'file\tvitest\tother/w.test.ts\tpass\t1' \
  $'file\tpytest\tmods/a/py/test_q.py\tpass\t5' $'file\tvitest\tmods/c/ts/c.test.ts\tpass\t1' >"$STEPS_LEDGER"
attr_steps mod-a:vitest:mods/a/ts/ mod-a-deep:vitest:mods/a/ts/deep/ mod-b:vitest:mods/b/ts/ \
  mod-b2:vitest:mods/b/ts/ mod-c:vitest:mods/c/ts/::carry root:vitest py:pytest:mods/a/py/ lint::
assert_eq "file	mod-a	vitest	mods/a/ts/x.test.ts	pass	3
file	mod-a	vitest	mods/a/ts/deep/p.test.ts	pass	1
file	mod-a-deep	vitest	mods/a/ts/deep/z.test.ts	fail	2
file	mod-b	vitest	mods/b/ts/y.test.ts	fail	4
file	mod-b2	vitest	mods/b/ts/y.test.ts	fail	4
file	root	vitest	other/w.test.ts	pass	1
file	py	pytest	mods/a/py/test_q.py	pass	5
file	root	vitest	mods/c/ts/c.test.ts	pass	1" "$(steps_file_lines)" \
  "a file goes to the step whose plan names it, else to the longest dir= over its path, both of a tie, else to a step with no dir="
attr_steps mod-a:vitest:mods/a/ts/ mod-b:vitest:mods/b/ts/
assert_eq "file	mod-a	vitest	mods/a/ts/x.test.ts	pass	3
file	mod-a	vitest	mods/a/ts/deep/p.test.ts	pass	1
file	mod-a	vitest	mods/a/ts/deep/z.test.ts	fail	2
file	mod-b	vitest	mods/b/ts/y.test.ts	fail	4" "$(steps_file_lines)" \
  "a file under no step's folder goes to none, never to every step of its runner"
: >"$STEPS_DIR/plan"
printf '%s\n' $'file\tvitest\tapps/api/t.test.ts\tfail\t2' $'file\tvitest\ttools/u.test.ts\tpass\t1' >"$STEPS_LEDGER"
attr_steps api:vitest::apps/api/ web:vitest::apps/web/
assert_eq "file	api	vitest	apps/api/t.test.ts	fail	2
file	api	vitest	tools/u.test.ts	pass	1
file	web	vitest	tools/u.test.ts	pass	1" "$(steps_file_lines)" \
  "of steps with no dir=, the one whose inputs= holds the file wins, and with none, each keeps it"
attr_steps verify::
assert_eq "file	verify	vitest	apps/api/t.test.ts	fail	2
file	verify	vitest	tools/u.test.ts	pass	1" "$(steps_file_lines)" \
  "the one step of a DEVBOX_VERIFY gate keeps every file of its own ledger"

# ── end to end on this laptop, with the stub runner ──────────────────────────

DBX="$TMP/dbx"
mkdir -p "$DBX"
cp -r "$REPO/client" "$REPO/lib" "$REPO/VERSION" "$DBX/"
cat >"$DBX/client/share/steps/devbox-steps" <<'RUNNER'
#!/bin/bash
# A stub of the step runner, for tests/test-verify-learn.sh.
set -u
log="$FAKE_RUNNER_LOG"
names=()
declare -A act=() cmd=() tr=()
while IFS=$'\t' read -r kind name a key runner after b64 dir trace; do
  case "$kind" in
    step)
      names+=("$name"); act[$name]="$a"; tr[$name]="$trace"
      cmd[$name]="$(printf '%s' "$b64" | base64 -d)"
      printf 'plan %s %s %s %s %s\n' "$name" "$a" "$runner" "$dir" "$trace" >>"$log" ;;
    file|test) printf '%s %s %s\n' "$kind" "$name" "$a" >>"$log" ;;
  esac
done <"$DEVBOX_STEPS_PLAN"
res=() all=0
for n in "${names[@]}"; do
  if [ "${act[$n]}" = carry ]; then res+=("$n carried 0 0"); continue; fi
  bash -c "${cmd[$n]}"; rc=$?
  if [ "$rc" = 0 ]; then res+=("$n pass 1 0"); else res+=("$n fail 1 $rc"); all=1; fi
done
for n in "${names[@]}"; do
  [ "${tr[$n]}" = 1 ] && [ -r "$FAKE_TRACES/$n.trace" ] || continue
  seq=1
  while IFS= read -r c; do
    [ "$n:$seq" = "${FAKE_TRACE_GAP-}" ] || printf 'devbox-steps: trace %s %s %s\n' "$n" "$seq" "$c"
    seq=$((seq + 1))
  done < <(gzip -c <"$FAKE_TRACES/$n.trace" | base64 | tr -d '\n' | fold -w 24; echo)
done
for r in "${res[@]}"; do printf 'devbox-steps: result %s\n' "$r"; done
exit "$all"
RUNNER

CO="$TMP/co"
mkdir -p "$CO/.devbox" "$CO/src" "$CO/tests" "$CO/data" "$CO/docs"
git -C "$CO" init -q
: >"$CO/.devbox/exclude"
for f in src/a.py src/b.py tests/test_a.py tests/test_b.py data/one.json docs/x.md; do printf '%s v1\n' "$f" >"$CO/$f"; done
printf 'DEVBOX_PROJECT=app\nDEVBOX_WANT_TOKENS=4\nDEVBOX_MIN_TOKENS=2\nDEVBOX_SETUP=:\n' >"$CO/.devbox/config.env"
cat >"$CO/.devbox/steps" <<EOF
lint -- echo lint >>"$TMP/ran"
test runner=pytest requires=cmd:fixture-tool -- echo test >>"$TMP/ran"
EOF
TRACES="$TMP/traces"
mkdir -p "$TRACES" "$TMP/home" "$TMP/run" "$TMP/tmp"
printf 'read\t-\tsrc/a.py\nread\t-\tsrc/b.py\n' >"$TRACES/lint.trace"
printf '%s\n' $'read\ttests/test_a.py\tdata/one.json' $'read\ttests/test_a.py\tsrc/a.py' \
  $'read\ttests/test_b.py\tsrc/b.py' >"$TRACES/test.trace"

out="" rc=0
verify() {
  rc=0
  : >"$TMP/ran"; : >"$TMP/runner.log"
  out="$(cd "$CO" && env PATH="$PATH" HOME="$TMP/home" XDG_RUNTIME_DIR="$TMP/run" TMPDIR="$TMP/tmp" \
    FAKE_RUNNER_LOG="$TMP/runner.log" FAKE_TRACES="$TRACES" bash "$DBX/client/libexec/devbox-verify" "$@" 2>&1)" || rc=$?
}
ran() { tr '\n' ' ' <"$TMP/ran" | sed 's/ $//'; }
MAPS="$CO/.git/devbox/maps"

verify --local
assert_eq 0 "$rc" "the first gate passes"
assert_eq "lint test" "$(ran)" "and runs both steps"
assert_ok "the plan asked both for a trace" grep -qx 'plan lint run - - 1' "$TMP/runner.log"
assert_fail "no trace line reaches the terminal" contains "devbox-steps: trace" "$out"
assert_ok "lint's map holds what it read" grep -q $'^path\t[0-9]*\tsrc/b.py$' "$MAPS/lint.map"
assert_ok "test's map holds each test file" grep -q $'^file\ttests/test_a.py\t' "$MAPS/test.map"

verify --local
assert_eq "" "$(ran)" "a second gate on an unchanged tree runs nothing"
assert_eq "devbox: green (2 steps: 0 ran, 2 carried)" "$(printf '%s\n' "$out" | tail -n 1)" "it carries both, by their learned keys"

printf 'more\n' >>"$CO/docs/x.md"
verify --local
assert_eq "" "$(ran)" "an edit to a file no step read carries both"

printf 'more\n' >>"$CO/data/one.json"
verify --local --plan
assert_ok "--plan selects the test that read the data file" grep -qx 'test  select 1 files  selected 1 of 2 test files' <<<"$out"
assert_ok "and names the file and its reason" grep -qx '  tests/test_a.py  read data/one.json' <<<"$out"
assert_ok "lint carries" grep -qE '^lint  carry  ' <<<"$out"
verify --local
assert_eq "test" "$(ran)" "the gate runs the test step alone"
assert_ok "the runner got the selected file" grep -qx 'file test tests/test_a.py' "$TMP/runner.log"
assert_ok "and every test file of the step" grep -qx 'test test tests/test_b.py' "$TMP/runner.log"

printf 'more\n' >>"$CO/src/b.py"
verify --local
assert_eq "lint test" "$(ran)" "a file both steps read runs both"
assert_ok "lint, whose trace is valid, runs untraced" grep -qx 'plan lint run - - 0' "$TMP/runner.log"
assert_ok "test, a runner step, is traced" grep -qx 'plan test select pytest - 1' "$TMP/runner.log"

printf 'more\n' >>"$CO/src/b.py"
rc=0
(cd "$CO" && env HOME="$TMP/home" XDG_RUNTIME_DIR="$TMP/run" TMPDIR="$TMP/tmp" FAKE_RUNNER_LOG="$TMP/runner.log" \
  FAKE_TRACES="$TRACES" FAKE_TRACE_GAP="test:1" bash "$DBX/client/libexec/devbox-verify" --local >"$TMP/gap.out" 2>&1) || rc=$?
assert_eq 0 "$rc" "a gate whose trace arrived incomplete still passes"
assert_ok "with one line that names the step" grep -q 'trace of step test arrived incomplete' "$TMP/gap.out"
assert_ok "and test's map says so" grep -q $'^untraced\tthe trace arrived incomplete' "$MAPS/test.map"

echo "-- --shard and its refusals"
verify --local --shard 1/2
assert_eq 2 "$rc" "--shard without --step is refused"
verify --local --step test --shard 3/2
assert_eq 2 "$rc" "--shard 3/2 is refused"
assert_ok "with the form it takes" contains "--shard takes <i>/<n> with 1 <= i <= n" "$out"
verify --local --step lint --shard 1/2
assert_eq 2 "$rc" "--shard of a step with no runner is refused"
assert_ok "and says so" contains "step lint has no runner=" "$out"
verify --local --full --step test --shard 2/2
assert_eq 0 "$rc" "shard 2 of 2 runs"
assert_ok "with the second half of the test files" grep -qx 'file test tests/test_b.py' "$TMP/runner.log"
assert_fail "and not the first" grep -qx 'file test tests/test_a.py' "$TMP/runner.log"
assert_ok "its verdict is a partial pass" contains "devbox: partial pass" "$(printf '%s\n' "$out" | tail -n 1)"
verify --run --shard 1/2 -- true
assert_eq 2 "$rc" "a run takes no --shard"

echo "-- DEVBOX_SERVICES on this laptop"
# A stub of devbox-services, which devbox_services_load sources.
cat >"$DBX/client/libexec/devbox-services" <<EOF
devbox_services_hook() { :; }
devbox_services_local_up() { echo "up \$DEVBOX_SERVICES \${1%%.*}" >>"$TMP/services.log"; export REDIS_URL=redis://fixture DEVBOX_SERVICES_LOCAL=1; }
devbox_services_local_down() { echo "down \${1%%.*}" >>"$TMP/services.log"; }
EOF
printf 'DEVBOX_SERVICES=redis\n' >>"$CO/.devbox/config.env"
sed -i "s|^lint -- .*|lint -- echo \"lint \$REDIS_URL\" >>\"$TMP/ran\"|" "$CO/.devbox/steps"
verify --local --full
assert_eq 0 "$rc" "with a service declared, the gate passes"
prefix="$(sed -n 's/^up redis //p' "$TMP/services.log")"
assert_eq "up redis $prefix
down $prefix" "$(cat "$TMP/services.log")" "the services start before the gate with its run id, and stop after it"
assert_ok "the run id is the gate's" test -n "$prefix"
assert_ok "and a step sees the URL the services exported" grep -qx 'lint redis://fixture' "$TMP/ran"
printf 'devbox_services_hook() { :; }\ndevbox_services_local_up() { echo "devbox verify: docker is absent" >&2; return 2; }\ndevbox_services_local_down() { :; }\n' \
  >"$DBX/client/libexec/devbox-services"
verify --local --full
assert_eq 2 "$rc" "a refusal of the services is this run's code"
assert_eq "" "$(ran)" "and no step ran"

printf '%d %d\n' "$TESTS_RUN" "$TESTS_FAILED"
