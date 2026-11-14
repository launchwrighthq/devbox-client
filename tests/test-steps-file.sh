#!/bin/bash
# .devbox/steps is parsed and checked on the laptop, by line number, before any
# target is asked (D2), and an each= line becomes one step per module (D12).
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
# shellcheck source=tests/lib.sh
source ./lib.sh
REPO="$(cd .. && pwd)"
# shellcheck source=client/libexec/devbox-steps-file
source "$REPO/client/libexec/devbox-steps-file"

TMP="$(mktemp -d)" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
contains() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }

# A checkout with three modules, a directory that holds no file, a hidden
# directory and a module whose name breaks the step-name rule.
ROOT="$TMP/root"
mkdir -p "$ROOT/.devbox" "$ROOT/apps/api/src" "$ROOT/apps/web/src" "$ROOT/apps/worker" \
  "$ROOT/apps/empty/nested" "$ROOT/apps/.cache" "$ROOT/packages/shared" "$ROOT/mods/Api"
: >"$ROOT/apps/api/src/index.ts"
: >"$ROOT/apps/web/src/main.ts"
: >"$ROOT/apps/worker/main.py"
: >"$ROOT/apps/.cache/blob"
: >"$ROOT/packages/shared/index.ts"
: >"$ROOT/mods/Api/index.ts"
STEPS="$ROOT/.devbox/steps"

# The parser never reaches a host: an ssh on PATH records any call.
mkdir -p "$TMP/bin"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >>"%s/ssh.log"\n' "$TMP" >"$TMP/bin/ssh"
chmod +x "$TMP/bin/ssh"
PATH="$TMP/bin:$PATH"

# ── each_dirs ────────────────────────────────────────────────────────────────

assert_eq $'apps/api/\napps/web/\napps/worker/' "$(devbox_steps_each_dirs "$ROOT" 'apps/*/')" \
  "each_dirs lists the modules that hold a file, sorted, with their /"
assert_eq "" "$(devbox_steps_each_dirs "$ROOT" 'apps/empty/')" \
  "each_dirs skips a directory with no file under it"
assert_eq "packages/" "$(devbox_steps_each_dirs "$ROOT" 'packages/')" \
  "each_dirs takes a pattern with no wildcard"

# ── refusals ─────────────────────────────────────────────────────────────────

# refused <desc> <file content> <line> <rule text>: exit 2, one stderr line,
# and that line names the line number and the rule.
refused() {
  local desc="$1" content="$2" line="$3" rule="$4" err rc=0 lines
  printf '%s\n' "$content" >"$STEPS"
  err="$( (devbox_steps_load "$STEPS" "$ROOT") 2>&1 >/dev/null)" || rc=$?
  assert_eq 2 "$rc" "$desc: exit 2"
  assert_ok "$desc: names line $line" contains "devbox verify: .devbox/steps line $line: " "$err"
  assert_ok "$desc: says the rule" contains "$rule" "$err"
  lines="$(printf '%s\n' "$err" | grep -c .)"
  assert_eq 1 "$lines" "$desc: one stderr line"
}

refused "missing --" 'lint npm run lint' 1 'no " -- " between the step and its command'
refused "empty command" $'# lint\nlint --' 2 'the command after " -- " is empty'
refused "no name" '-- npm test' 1 'the line names no step'
refused "attribute without =" 'lint fast -- npm run lint' 1 'attribute "fast" has no "="'
refused "unknown attribute" 'lint timeout=5 -- npm run lint' 1 'unknown attribute "timeout"'
refused "attribute twice" 'lint rerun=always rerun=always -- x' 1 'attribute "rerun" is given twice'
refused "attribute with no value" 'lint after= -- x' 1 'attribute "after" has no value'
refused "empty entry in a list" 'lint inputs=src/,,tests/ -- x' 1 'inputs=src/,,tests/ holds an empty entry'
refused "upper-case name" 'Lint -- x' 1 'step name "Lint" is not [a-z0-9][a-z0-9:_-]*'
refused "name with a dot" 'lint.js -- x' 1 'step name "lint.js" is not'
refused "name with an equals sign" 'a=b -- x' 1 'step name "a=b" is not'
refused "duplicate name" $'lint -- a\n# again\nlint -- b' 3 'step name "lint" is already used on line 1'
refused "each without /" 't:{name} each=apps/* -- x' 1 'each=apps/* must end in "/"'
refused "each matching no directory" 't:{name} each=libs/*/ -- x' 1 'each=libs/*/ matches no directory that holds a file'
refused "each matching only an empty directory" 't:{name} each=apps/empty/ -- x' 1 'matches no directory that holds a file'
refused "each without {name}" 't each=apps/*/ -- x' 1 'a step with each= must hold {name} in its name'
refused "bad name after expansion" 't:{name} each=mods/*/ -- x' 1 'step name "t:Api" is not'
refused "duplicate name after expansion" $'t:api -- a\nt:{name} each=apps/*/ -- b' 2 'step name "t:api" is already used on line 1'
refused "narrow without runner" 't narrow=failed -- npx vitest run' 1 'narrow=failed needs runner=vitest or runner=pytest'
refused "select without runner" 't select=related -- npx vitest run' 1 'select=related needs runner=vitest'
refused "select with pytest" 't runner=pytest select=related -- uv run pytest' 1 'select=related needs runner=vitest'
refused "select with no vitest run" 't runner=vitest select=related -- npm test' 1 'needs "vitest run" exactly once in the command, and it holds 0'
refused "select with two vitest runs" 't runner=vitest select=related -- npx vitest run a && npx vitest run b' 1 'and it holds 2'
refused "unknown runner" 't runner=jest -- npx jest' 1 'runner must be vitest or pytest, not "jest"'
refused "unknown narrow" 't runner=vitest narrow=all -- npx vitest run' 1 'narrow must be failed, not "all"'
refused "unknown select" 't runner=vitest select=all -- npx vitest run' 1 'select must be related, not "all"'
refused "unknown rerun" 't rerun=never -- x' 1 'rerun must be always, not "never"'
refused "after naming no step" $'lint -- a\n\ntest after=lint,ghost -- b' 3 'after names "ghost", which is no step'
refused "after with {name} and no each line" 'report after=test:{name} -- x' 1 'after names "test:{name}", which is no step'
refused "each after naming a missing module step" $'typecheck:api -- a\nt:{name} each=apps/*/ after=typecheck:{name} -- b' 2 'after names "typecheck:web", which is no step'
refused "after cycle" $'a after=b -- x\nb after=a -- y' 2 'after makes a cycle: a -> b -> a'
refused "after cycle of three" $'a after=c -- x\nb after=a -- y\nc after=b -- z' 2 'after makes a cycle: a -> c -> b -> a'
refused "after naming itself" 'a after=a -- x' 1 'after makes a cycle: a -> a'
refused "each line after its own step" 't:{name} each=apps/*/ after=t:{name} -- x' 1 'after makes a cycle: t:api -> t:api'

assert_eq "" "$(cat "$TMP/ssh.log" 2>/dev/null)" "no refusal calls ssh"

rc=0; err="$( (devbox_steps_load "$TMP/absent" "$ROOT") 2>&1)" || rc=$?
assert_eq 2 "$rc" "an unreadable file is refused"
assert_ok "and the refusal names the file" contains "cannot read $TMP/absent" "$err"

# ── a 3-module each= fixture (D12) ───────────────────────────────────────────

cat >"$STEPS" <<'EOF'
# .devbox/steps
   # an indented comment

typecheck:{name}  each=apps/*/  inputs={dir},packages/  -- npx tsc -p {dir}tsconfig.json --noEmit
test:{name}  each=apps/*/  after=typecheck:{name},lint  runner=vitest select=related narrow=failed inputs={dir}src/,packages/ -- npx vitest run --project {name}
report  after=test:{name},lint,test:api  -- echo {name} done
lint	inputs=apps/	--	npm run lint -- --max-warnings  0
EOF
rc=0
devbox_steps_load "$STEPS" "$ROOT" || rc=$?
assert_eq 0 "$rc" "the fixture loads"
assert_eq "typecheck:api typecheck:web typecheck:worker test:api test:web test:worker report lint" \
  "${STEP_NAMES[*]}" "an each= line becomes one step per module, in sorted order and file order"
assert_eq $'apps/web/\npackages/' "${STEP_INPUTS[typecheck:web]}" "{dir} is replaced in inputs, one path per line"
assert_eq $'apps/worker/src/\npackages/' "${STEP_INPUTS[test:worker]}" "{dir} is replaced inside a longer input path"
assert_eq "npx tsc -p apps/worker/tsconfig.json --noEmit" "${STEP_CMD[typecheck:worker]}" "{dir} is replaced in the command"
assert_eq "npx vitest run --project web" "${STEP_CMD[test:web]}" "{name} is replaced in the command"
assert_eq "typecheck:api lint" "${STEP_AFTER[test:api]}" "{name} in after on an each line names the same module's step"
assert_eq "typecheck:worker lint" "${STEP_AFTER[test:worker]}" "and each module waits on its own"
assert_eq "test:api test:web test:worker lint" "${STEP_AFTER[report]}" \
  "{name} in after on a line without each waits for every module, and a name given twice counts once"
assert_eq "echo {name} done" "${STEP_CMD[report]}" "a line without each keeps {name} in its command"
assert_eq "" "${STEP_AFTER[lint]}" "a step with no after waits on nothing"
assert_eq "" "${STEP_INPUTS[report]}" "a step with no inputs reads every synced file"
assert_eq "vitest|failed|related|" \
  "${STEP_RUNNER[test:web]}|${STEP_NARROW[test:web]}|${STEP_SELECT[test:web]}|${STEP_RERUN[test:web]}" \
  "the attributes of an each= line reach every module"
assert_eq "|||" \
  "${STEP_RUNNER[lint]}|${STEP_NARROW[lint]}|${STEP_SELECT[lint]}|${STEP_RERUN[lint]}" \
  "an attribute that is not given is empty"
assert_eq "npm run lint -- --max-warnings  0" "${STEP_CMD[lint]}" \
  "tabs around -- split, and the command keeps a later -- and its blanks"
assert_eq "test:api after=lint,typecheck:api inputs=apps/api/src/,packages/ narrow=failed runner=vitest select=related -- npx vitest run --project api" \
  "${STEP_SOURCE[test:api]}" "the source is the expanded step with its attributes in a fixed order"
assert_eq "lint inputs=apps/ -- npm run lint -- --max-warnings  0" "${STEP_SOURCE[lint]}" \
  "the source leaves out an attribute that is not given"

# ── the canonical source ─────────────────────────────────────────────────────

source_of() {  # $1 the file content, $2 the step; prints its STEP_SOURCE
  printf '%s\n' "$1" >"$STEPS"
  ( devbox_steps_load "$STEPS" "$ROOT" || exit; printf '%s' "${STEP_SOURCE[$2]}" )
}
a="$(source_of $'lint -- x\ntest runner=vitest narrow=failed inputs=src/,tests/ after=lint -- npx vitest run' test)"
b="$(source_of $'lint -- x\ntest   after=lint  inputs=tests/,src/   narrow=failed runner=vitest -- npx vitest run' test)"
c="$(source_of $'lint -- x\ntest runner=vitest narrow=failed inputs=src/,tests/ after=lint -- npx vitest run --bail' test)"
assert_eq "$a" "$b" "attribute order, list order and blanks do not change the source"
assert_ok "a changed command changes the source" test "$a" != "$c"
d="$(source_of $'t:{name} each=apps/*/ -- x\nr after=t:{name} -- y' r)"
e="$(source_of $'t:{name} each=apps/*/ -- x\nr after=t:worker,t:api,t:web -- y' r)"
assert_eq "$d" "$e" "after=t:{name} and the module names it covers give one source"

# ── the caller's scope ───────────────────────────────────────────────────────

printf '%s\n' 'only -- true' >"$STEPS"
load_in_function() { devbox_steps_load "$STEPS" "$ROOT"; }
load_in_function
assert_eq "only" "${STEP_NAMES[*]}" "a load from inside a function fills global variables"
assert_eq "true" "${STEP_CMD[only]}" "and the commands with them"
assert_eq "" "${STEP_CMD[lint]+set}" "a second load clears the steps of the first"

printf '%s\n' 'ok -- true' >"$STEPS"
assert_eq "ok" "$( set -eu; devbox_steps_load "$STEPS"; printf '%s' "${STEP_NAMES[*]}" )" \
  "with no root, the parent of .devbox/ is the root, and set -eu does not stop the load"
printf '%s\n' 'm:{name} each=apps/*/ -- true' >"$STEPS"
assert_eq "m:api m:web m:worker" "$( devbox_steps_load "$STEPS" || exit; printf '%s' "${STEP_NAMES[*]}" )" \
  "with no root, each= matches under the parent of .devbox/"
printf '%s\n' 'bad' >"$STEPS"
rc=0; ( set -e; devbox_steps_load "$STEPS" "$ROOT" ) 2>/dev/null || rc=$?
assert_eq 2 "$rc" "under set -e a refusal still returns 2"

# ── DEVBOX_VERIFY as one step ────────────────────────────────────────────────

devbox_steps_from_verify "npm run verify -- --ci"
assert_eq "verify" "${STEP_NAMES[*]}" "DEVBOX_VERIFY becomes one step named verify"
assert_eq "npm run verify -- --ci" "${STEP_CMD[verify]}" "with the command as written"
assert_eq "||||||" \
  "${STEP_AFTER[verify]}|${STEP_INPUTS[verify]}|${STEP_RUNNER[verify]}|${STEP_NARROW[verify]}|${STEP_SELECT[verify]}|${STEP_RERUN[verify]}|" \
  "and no attribute"
assert_eq "verify -- npm run verify -- --ci" "${STEP_SOURCE[verify]}" "its source matches a steps line of the same step"
assert_eq "verify -- npm run verify -- --ci" \
  "$(source_of 'verify -- npm run verify -- --ci' verify)" "the same step written in .devbox/steps"
rc=0; err="$( (devbox_steps_from_verify "") 2>&1)" || rc=$?
assert_eq 2 "$rc" "an empty DEVBOX_VERIFY is refused"
assert_ok "and the refusal says so" contains "DEVBOX_VERIFY is empty" "$err"

printf '%d %d\n' "$TESTS_RUN" "$TESTS_FAILED"
