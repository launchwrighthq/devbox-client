#!/bin/bash
# The plan of a gate (docs/specs/2026-11-14-client-owns-the-gate-design.md,
# D5, D5a, D6, D12, D13, D14 and R1, plan half): client/libexec/devbox-plan
# keys each step, then carries, narrows, selects or runs it.
#
# Each consumer planned its gate from changed paths with its own global-input
# list, and reran every passed step after a one-file change. This file fills
# the STEP_* variables of section 6.7 directly, as devbox-steps-file would,
# hashes a temporary git repository into a manifest of `<sha256>  <path>`
# lines, as devbox_sync_manifest prints them, and writes the record each gate
# would leave with devbox_record_write. Each scenario runs in its own
# repository.
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
# shellcheck source=client/libexec/devbox-plan
source "$REPO/client/libexec/devbox-plan"

contains() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }

M="$TMP/manifest"
P="$TMP/plan"
E="$TMP/err"
AT=1000
SEQ=1000
LAST_RUN=""

# A fresh repository with three apps, a shared package and a lock file, as the
# current directory.
new_repo() {
  local dir="$TMP/$1" f
  mkdir -p "$dir" && cd "$dir" || exit 1
  git init -q -b main .
  for f in apps/api/src/a.ts apps/api/src/a.test.ts apps/web/src/w.ts apps/web/src/w.test.ts \
    apps/worker/src/x.py apps/worker/tests/test_a.py apps/worker/tests/test_b.py \
    apps/worker/tests/test_c.py packages/core/c.ts package-lock.json; do
    mkdir -p "$(dirname "$f")" && printf '%s v1\n' "$f" >"$f"
  done
  mkdir -p .devbox && printf 'DEVBOX_PROJECT=app\nDEVBOX_SETUP=true\nDEVBOX_VERIFY=true\n' >.devbox/config.env
  DEVBOX_CONFIG="$PWD/.devbox/config.env"
  DEVBOX_SHARED_INPUTS="package-lock.json"
  DEVBOX_FORWARD_ENV=""
}

# The manifest of the current repository, in devbox_sync_manifest's format.
manifest() {
  find . -path ./.git -prune -o -type f -print | sed 's|^\./||' | LC_ALL=C sort \
    | xargs -d '\n' sha256sum -- >"$M"
}

# Reset the parsed steps.
no_steps() {
  declare -ga STEP_NAMES=()
  declare -gA STEP_AFTER=() STEP_INPUTS=() STEP_RUNNER=() STEP_NARROW=() \
    STEP_SELECT=() STEP_RERUN=() STEP_CMD=() STEP_SOURCE=()
}

# Add one step: $1 name, $2 inputs (one per line), then key=value attributes.
add_step() {
  local name="$1" kv
  STEP_NAMES+=("$name")
  STEP_INPUTS[$name]="$2"
  STEP_CMD[$name]="run $name"
  shift 2
  for kv in "$@"; do
    case "$kv" in
      runner=*) STEP_RUNNER[$name]="${kv#*=}" ;;
      narrow=*) STEP_NARROW[$name]="${kv#*=}" ;;
      select=*) STEP_SELECT[$name]="${kv#*=}" ;;
      rerun=*) STEP_RERUN[$name]="${kv#*=}" ;;
      after=*) STEP_AFTER[$name]="${kv#*=}" ;;
      cmd=*) STEP_CMD[$name]="${kv#*=}" ;;
    esac
  done
  STEP_SOURCE[$name]="$name ${STEP_INPUTS[$name]//$'\n'/,} -- ${STEP_CMD[$name]}"
}

# Plan with the rerun value $1 and the step names after it. The stdout goes to
# $P and the stderr to $E, in this shell, so PLAN_* stay for devbox_plan_print.
plan() {
  local rerun="$1"
  shift
  manifest
  devbox_plan_build "$rerun" "$M" "$@" >"$P" 2>"$E"
}

# `<name>=<action>` of every step line of the plan, space separated.
actions() { awk -F'\t' '$1 == "step" { printf "%s%s=%s", sep, $2, $3; sep = " " }' "$P"; }

# The file lines of step $1, one path per line.
files_of() { PLAN_STEP="$1" awk -F'\t' '$1 == "file" && $2 == ENVIRON["PLAN_STEP"] { print $3 }' "$P"; }

# The reason devbox_plan_print gives step $1.
reason_of() { printf '%s' "${PLAN_REASON[$1]}"; }

# Write the record of the gate that ran the plan in $P over the manifest $M.
# A step whose plan is carry is `carried`, any other passes, unless an argument
# `<step>=<outcome>:<code>` says otherwise. An argument
# `file=<step>:<runner>:<path>:<outcome>` adds a file line. GATE_COMPLETE and
# GATE_SCOPE set the header. Sets LAST_RUN.
gate() {
  local run kind name action key outcome code mode o v s r p oc
  SEQ=$((SEQ + 1)) AT=$((AT + 1))
  run="0123456789abcdef.$SEQ"
  {
    printf 'run\t%s\nat\t%s\nclient\t3.3.0\nbranch\tmain\ncommit\t-\ntarget\tlan1\n' "$run" "$AT"
    printf 'scope\t%s\ncomplete\t%s\n' "${GATE_SCOPE:-full}" "${GATE_COMPLETE:-1}"
    while IFS=$'\t' read -r kind name action key _; do
      [ "$kind" = step ] || continue
      outcome=pass code=0 mode=full
      case "$action" in carry) outcome=carried ;; narrow) mode=narrowed ;; related) mode=related ;; esac
      for o in "$@"; do
        case "$o" in "$name="*) v="${o#*=}"; outcome="${v%%:*}"; code="${v#*:}" ;; esac
      done
      printf 'step\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$key" "$outcome" 1 "$code" "$mode"
    done <"$P"
    for o in "$@"; do
      case "$o" in
        file=*) IFS=: read -r s r p oc <<<"${o#file=}"; printf 'file\t%s\t%s\t%s\t%s\n' "$s" "$r" "$p" "$oc" ;;
      esac
    done
  } >"$TMP/record"
  devbox_record_write "$run" "$TMP/record" "$M" || echo "gate: devbox_record_write failed" >&2
  LAST_RUN="$run"
}

edit() { printf 'changed\n' >>"$1"; }

# The steps of D5 and D5a: disjoint inputs, a glob whose * crosses /, and one
# step with no inputs, which reads every synced file.
disjoint_steps() {
  no_steps
  add_step lint "apps/api/"
  add_step typecheck "apps/web/"
  add_step pytest "apps/*.py" runner=pytest
  add_step guards ""
}

echo "-- D5: a second run of an unchanged tree carries every step"
new_repo d5
disjoint_steps
plan changed
assert_eq "lint=run typecheck=run pytest=run guards=run" "$(actions)" "the first plan runs every step"
assert_eq "no earlier pass" "$(reason_of lint)" "because no step passed before"
first_keys="$(awk -F'\t' '$1 == "step" { print $4 }' "$P")"
gate
first="$LAST_RUN"
plan changed
assert_eq "lint=carry typecheck=carry pytest=carry guards=carry" "$(actions)" "the second plan carries every step"
assert_eq "$first_keys" "$(awk -F'\t' '$1 == "step" { print $4 }' "$P")" "under the same keys"
assert_eq "carried from run $first" "$(reason_of guards)" "each carried step names the run it carries from"
assert_eq 0 "$(grep -c '^file' "$P")" "a carried plan has no file line"
gate
plan changed
assert_eq "lint=carry typecheck=carry pytest=carry guards=carry" "$(actions)" "a record of carried steps carries again"

echo "-- D5a: a change to one input runs only the steps that read it"
edit apps/web/src/w.ts
plan changed
assert_eq "lint=carry typecheck=run pytest=carry guards=run" "$(actions)" "only typecheck and the step with every file run"
assert_eq "inputs changed: 1 files" "$(reason_of typecheck)" "the reason counts the changed inputs"
gate
edit apps/worker/src/x.py
plan changed
assert_eq "lint=carry typecheck=carry pytest=run guards=run" "$(actions)" "a pattern's * crosses /: apps/*.py holds apps/worker/src/x.py"
gate
printf 'note\n' >README.md
plan changed
assert_eq "lint=carry typecheck=carry pytest=carry guards=run" "$(actions)" "a new file outside every input runs the step with empty inputs alone"
gate

echo "-- D5a: a change to a shared input runs every step"
edit package-lock.json
plan changed
assert_eq "lint=run typecheck=run pytest=run guards=run" "$(actions)" "every step runs"
assert_eq "shared inputs changed: 1 files" "$(reason_of lint)" "and says the shared inputs changed"
gate
printf 'DEVBOX_LANES=2\n' >>.devbox/config.env
plan changed
assert_eq "lint=run typecheck=run pytest=run guards=run" "$(actions)" "a change to .devbox/config.env runs every step"
assert_ok "and says what else the key holds" contains "config, client version, step line or forwarded env changed" "$(reason_of lint)"

echo "-- a step line is part of its key"
gate
STEP_SOURCE[lint]="lint apps/api/ -- run lint --strict"
plan changed
assert_eq "lint=run typecheck=carry pytest=carry guards=carry" "$(actions)" "an edited step line runs that step alone"

echo "-- D12: a change inside one module runs only that module's step"
new_repo d12
no_steps
add_step test:api $'apps/api/\npackages/' runner=vitest
add_step test:web $'apps/web/\npackages/' runner=vitest
add_step test:worker $'apps/worker/\npackages/' runner=pytest
plan changed
gate
edit apps/api/src/a.ts
plan changed
assert_eq "test:api=run test:web=carry test:worker=carry" "$(actions)" "a change in apps/api runs test:api alone"
gate
edit packages/core/c.ts
plan changed
assert_eq "test:api=run test:web=run test:worker=run" "$(actions)" "a change in packages/ runs every module's step"

echo "-- the step names of --step, the format of the plan"
new_repo format
no_steps
add_step build "" "cmd=npm run build"
add_step test "" runner=vitest after=build "cmd=npx vitest run --project api"
add_step e2e "" "after=build test" $'cmd=printf \'a\tb\'\necho two'
plan changed
assert_eq 3 "$(grep -c '^step' "$P")" "every step gets a line"
line="$(grep $'^step\te2e\t' "$P")"
IFS=$'\t' read -r f1 f2 f3 f4 f5 f6 f7 f8 <<<"$line"
assert_eq "step e2e run" "$f1 $f2 $f3" "a step line opens with step, the name and the action"
assert_ok "the key is a sha256" grep -qE '^[0-9a-f]{64}$' <<<"$f4"
assert_eq "-" "$f5" "a step with no runner says -"
assert_eq "build,test" "$f6" "after names are comma separated"
assert_eq $'printf \'a\tb\'\necho two' "$(printf '%s' "$f7" | base64 -d)" "the command is base64, with its tab and newline"
assert_eq "" "${f8-}" "and the line has seven fields"
assert_eq "vitest" "$(awk -F'\t' '$2 == "test" { print $5 }' "$P")" "a runner is named"
plan changed test e2e
assert_eq "test=run e2e=run" "$(actions)" "named steps alone are planned"
assert_eq "test" "$(awk -F'\t' '$2 == "e2e" { print $6 }' "$P")" "an after name that is not planned is dropped"
assert_eq "-" "$(awk -F'\t' '$2 == "test" { print $6 }' "$P")" "down to -"
plan changed nosuch; rc=$?
assert_eq 2 "$rc" "an unknown step name returns 2"
assert_ok "with a line that names it" grep -q "no step named 'nosuch'" "$E"
plan sometimes; rc=$?
assert_eq 2 "$rc" "a rerun value other than changed or full returns 2"
DEVBOX_CONFIG="$TMP/none.env" plan changed; rc=$?
assert_eq 1 "$rc" "an unreadable config returns 1, and no plan"
assert_ok "with a line that names it" grep -q "could not read $TMP/none.env" "$E"

echo "-- D13: DEVBOX_RERUN, by precedence"
unset RERUN_FLAG DEVBOX_RERUN_ENV DEVBOX_RERUN_CONFIG
assert_eq changed "$(devbox_rerun_setting)" "nothing set is changed"
assert_eq full "$(DEVBOX_RERUN_CONFIG=full devbox_rerun_setting)" "the config sets full"
assert_eq changed "$(DEVBOX_RERUN_CONFIG=full DEVBOX_RERUN_ENV=changed devbox_rerun_setting)" "the environment beats the config"
assert_eq full "$(DEVBOX_RERUN_CONFIG=changed DEVBOX_RERUN_ENV=full devbox_rerun_setting)" "either way"
assert_eq full "$(DEVBOX_RERUN_ENV=changed RERUN_FLAG=full devbox_rerun_setting)" "the flag beats the environment"
assert_eq changed "$(DEVBOX_RERUN_ENV=full DEVBOX_RERUN_CONFIG=full RERUN_FLAG=changed devbox_rerun_setting)" "--changed beats both"
out="$(DEVBOX_RERUN_ENV=sometimes devbox_rerun_setting 2>&1)"; rc=$?
assert_eq 2 "$rc" "a value other than changed or full returns 2"
assert_ok "with a line that names where it came from" contains "refusing DEVBOX_RERUN 'sometimes' from the environment" "$out"
out="$(DEVBOX_CONFIG=.devbox/config.env DEVBOX_RERUN_CONFIG=all devbox_rerun_setting 2>&1)"; rc=$?
assert_eq 2 "$rc" "a bad config value returns 2"
assert_ok "and names the config" contains "from .devbox/config.env" "$out"

new_repo d13
disjoint_steps
STEP_RERUN[guards]=always
plan changed
gate
plan changed
assert_eq "lint=carry typecheck=carry pytest=carry guards=run" "$(actions)" "rerun=always runs under changed"
assert_eq "rerun=always" "$(reason_of guards)" "and says so"
plan full
assert_eq "lint=run typecheck=run pytest=run guards=run" "$(actions)" "full runs every step, carried or not"
assert_eq "DEVBOX_RERUN=full" "$(reason_of lint)" "and says so"
assert_eq 0 "$(grep -c '^file' "$P")" "full narrows and selects nothing"

echo "-- D6: a narrow=failed step after an attributable failure"
new_repo d6
no_steps
add_step test "apps/worker/" runner=pytest narrow=failed
add_step plain "apps/worker/" runner=pytest
plan changed
gate test=fail:1 plain=fail:1 \
  file=test:pytest:apps/worker/tests/test_a.py:fail file=test:pytest:apps/worker/tests/test_b.py:fail \
  file=test:pytest:apps/worker/tests/test_c.py:pass file=plain:pytest:apps/worker/tests/test_a.py:fail
failed_run="$LAST_RUN"
plan changed
assert_eq "test=narrow plain=run" "$(actions)" "an unchanged tree narrows the failed step; one without narrow=failed runs"
assert_eq "apps/worker/tests/test_a.py
apps/worker/tests/test_b.py" "$(files_of test)" "to exactly its failed files"
assert_eq "narrowed to 2 failed files" "$(reason_of test)" "and says so"
assert_eq "failed in run $failed_run with code 1" "$(reason_of plain)" "the plain step names its failure"
edit apps/worker/tests/test_c.py
edit apps/worker/src/x.py
plan changed
assert_eq "apps/worker/tests/test_a.py
apps/worker/tests/test_b.py
apps/worker/tests/test_c.py" "$(files_of test)" "a changed test file joins the failed files, a changed source file does not"
assert_eq "narrowed to 2 failed files and 1 changed test files" "$(reason_of test)" "and the reason counts both"
rm apps/worker/tests/test_b.py
plan changed
assert_eq "apps/worker/tests/test_a.py
apps/worker/tests/test_c.py" "$(files_of test)" "a failed file that is gone is left out"
gate test=pass:0 plain=fail:1
plan changed
assert_eq "test=carry plain=run" "$(actions)" "a narrowed pass carries"

new_repo d6-crash
no_steps
add_step test "apps/worker/" runner=pytest narrow=failed
plan changed
gate test=fail:2 file=test:pytest:apps/worker/tests/test_a.py:fail
plan changed
assert_eq "test=run" "$(actions)" "a failure with code 2 runs the step in full"
assert_ok "and says which code" contains "with code 2" "$(reason_of test)"
assert_eq "" "$(files_of test)" "with no file line"
gate test=fail:1 file=test:pytest:apps/worker/tests/test_a.py:fail file=test:pytest:apps/worker/tests/test_b.py:open
plan changed
assert_eq "test=run" "$(actions)" "a failure with a file still open runs in full"
gate test=fail:1
plan changed
assert_eq "test=run" "$(actions)" "a failure with no failed file runs in full"
GATE_COMPLETE=0 gate test=fail:1 file=test:pytest:apps/worker/tests/test_a.py:fail
plan changed
assert_eq "test=run" "$(actions)" "a complete 0 failure is never the last result"

echo "-- D14: a select=related step after a pass"
new_repo d14
no_steps
add_step test:web "apps/web/" runner=vitest select=related
add_step test:api "apps/api/" runner=vitest
plan changed
gate
edit apps/web/src/w.ts
printf 'new\n' >apps/web/src/new.ts
plan changed
assert_eq "test:web=related test:api=carry" "$(actions)" "a changed input selects the related tests"
assert_eq "apps/web/src/new.ts
apps/web/src/w.ts" "$(files_of test:web)" "of exactly the changed and new input files"
assert_eq "related to 2 changed files" "$(reason_of test:web)" "and says so"
rm apps/web/src/w.test.ts
plan changed
assert_eq "test:web=run test:api=carry" "$(actions)" "a deleted input runs the step in full"
assert_eq "" "$(files_of test:web)" "with no file line"
printf 'w\n' >apps/web/src/w.test.ts
edit package-lock.json
plan changed
assert_eq "test:web=run test:api=run" "$(actions)" "a changed shared input runs it in full"
printf 'package-lock.json v1\n' >package-lock.json
printf 'apps/web/src/w.test.ts v1\n' >apps/web/src/w.test.ts
plan changed
assert_eq "test:web=related test:api=carry" "$(actions)" "back to the passed lock file and test file, it selects again"
printf 'DEVBOX_LANES=1\n' >>.devbox/config.env
plan changed
assert_eq "test:web=run test:api=run" "$(actions)" "a changed config runs it in full, though only inputs differ from its pass otherwise"

new_repo d14-nomanifest
no_steps
add_step test:web "apps/web/" runner=vitest select=related
plan changed
gate
rm "$(devbox_record_dir)/$LAST_RUN.files"
edit apps/web/src/w.ts
plan changed
assert_eq "test:web=run" "$(actions)" "a pass without its manifest never selects"

echo "-- R1: --plan prints each step's plan and reason"
new_repo r1
no_steps
add_step lint "apps/api/"
add_step test "apps/worker/" runner=pytest narrow=failed
add_step web "apps/web/" runner=vitest select=related
add_step guards "" rerun=always
plan changed
gate test=fail:1 file=test:pytest:apps/worker/tests/test_a.py:fail file=test:pytest:apps/worker/tests/test_b.py:fail
r1_run="$LAST_RUN"
edit apps/web/src/w.ts
plan changed
assert_eq "lint  carry  carried from run $r1_run
test  narrow 2 files  narrowed to 2 failed files
web  related 1 files  related to 1 changed files
guards  run  rerun=always" "$(devbox_plan_print)" "one line per step: name, action and reason"

echo "-- a forwarded value enters the key as a hash, and never an output"
new_repo forward
disjoint_steps
export FIXTURE_FORWARD_TOKEN=fixture-secret-value-7c1
FIXTURE_NOT_EXPORTED=fixture-shell-value-3d2
DEVBOX_FORWARD_ENV="FIXTURE_FORWARD_TOKEN FIXTURE_NOT_EXPORTED"
plan changed
gate
plan changed
assert_eq "lint=carry typecheck=carry pytest=carry guards=carry" "$(actions)" "the same values carry"
# shellcheck disable=SC2034  # read by name through DEVBOX_FORWARD_ENV, in _devbox_plan_forward
FIXTURE_NOT_EXPORTED=another-shell-value
plan changed
assert_eq "lint=carry typecheck=carry pytest=carry guards=carry" "$(actions)" "a value that is not exported never reaches the gate, nor the key"
FIXTURE_FORWARD_TOKEN=fixture-secret-value-8e4
plan changed
assert_eq "lint=run typecheck=run pytest=run guards=run" "$(actions)" "a new exported value runs every step"
printed="$(cat "$P" "$E"; devbox_plan_print; for s in "${STEP_NAMES[@]}"; do printf '%s\n' "${STEP_SOURCE[$s]}"; done)"
assert_fail "the old value appears in no output" contains "fixture-secret-value-7c1" "$printed"
assert_fail "nor the new one" contains "fixture-secret-value-8e4" "$printed"
assert_fail "nor the shell value" contains "another-shell-value" "$printed"
DEVBOX_FORWARD_ENV="BAD-NAME"
plan changed; rc=$?
assert_eq 1 "$rc" "a forwarded word that is not a variable name returns 1"
assert_ok "with a line that names it" grep -q "refusing 'BAD-NAME' in DEVBOX_FORWARD_ENV" "$E"

echo "-- the test-file rule of a narrowed step"
assert_ok "test_x.py is a pytest test file" devbox_plan_is_test_file apps/worker/tests/test_x.py pytest
assert_ok "x.spec.ts is a vitest test file" devbox_plan_is_test_file src/x.spec.ts vitest
assert_fail "x.test.ts is not a pytest test file" devbox_plan_is_test_file src/x.test.ts pytest
assert_fail "a test fixture's JSON is no test file" devbox_plan_is_test_file tests/data.json vitest
assert_fail "a source file is no test file" devbox_plan_is_test_file src/x.ts vitest

printf '%d %d\n' "$TESTS_RUN" "$TESTS_FAILED"
