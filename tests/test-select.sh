#!/bin/bash
# The plan selects and carries by what each step and test file read
# (docs/specs/2026-11-14-learned-selection-design.md, D2, D2a, D2b, D3, D3a,
# D3b, D4, D4a, D4b, and the shards of D10, plan half).
#
# A step without inputs= hashed every synced file, so a Markdown edit ran the
# whole suite: a docs-only change that a project wrapper answered in seconds
# ran the whole suite, many minutes. Here
# each gate is played by hand: the plan of client/libexec/devbox-plan, a record
# written with devbox_record_write, and a trace per step in the format of
# section 5.6, which devbox_plan_learn merges into the maps as devbox-verify
# does after a complete gate.
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
SEQ=1000
LAST_RUN=""
# D3b, counted by every gate: a select step that reaches the runner with no
# file, and a runner step recorded carried by a selection whose plan did not
# say `no test read a changed file`.
EMPTY_SELECT=0
SILENT_CARRY=0
TRACES="$TMP/traces"

# A fresh repository as the current directory: a pytest suite with a conftest
# and fixture data, a web app with vitest tests, a lock file and docs.
new_repo() {
  local dir="$TMP/$1" f
  mkdir -p "$dir" && cd "$dir" || exit 1
  git init -q -b main .
  for f in src/a.py src/b.py tests/conftest.py tests/test_a.py tests/test_b.py tests/test_c.py \
    data/one.json docs/x.md README.md package-lock.json \
    web/src/w.ts web/src/w.test.ts web/src/v.test.ts api/src/a.ts api/src/a.test.ts; do
    mkdir -p "$(dirname "$f")" && printf '%s v1\n' "$f" >"$f"
  done
  mkdir -p .devbox && printf 'DEVBOX_PROJECT=app\nDEVBOX_SETUP=true\n' >.devbox/config.env
  DEVBOX_CONFIG="$PWD/.devbox/config.env"
  DEVBOX_SHARED_INPUTS="" DEVBOX_FORWARD_ENV="" DEVBOX_SETUP_INPUTS=""
  rm -rf "$TRACES" && mkdir -p "$TRACES"
  declare -ga STEP_NAMES=()
  declare -gA STEP_AFTER=() STEP_INPUTS=() STEP_RUNNER=() STEP_NARROW=() \
    STEP_RERUN=() STEP_CMD=() STEP_SOURCE=() STEP_DIR=()
  PLAN_SHARD=""
}

manifest() {
  find . -path ./.git -prune -o -type f -print | sed 's|^\./||' | LC_ALL=C sort \
    | xargs -d '\n' sha256sum -- >"$M"
}

# Add one step: $1 name, then key=value attributes.
add_step() {
  local name="$1" kv
  shift
  STEP_NAMES+=("$name")
  STEP_INPUTS[$name]="" STEP_CMD[$name]="run $name" STEP_DIR[$name]=""
  for kv in "$@"; do
    case "$kv" in
      runner=*) STEP_RUNNER[$name]="${kv#*=}" ;;
      narrow=*) STEP_NARROW[$name]="${kv#*=}" ;;
      inputs=*) STEP_INPUTS[$name]="${kv#*=}" ;;
      dir=*) STEP_DIR[$name]="${kv#*=}" ;;
    esac
  done
  STEP_SOURCE[$name]="$name $* -- ${STEP_CMD[$name]}"
}

plan() {
  local rerun="$1"
  shift
  manifest
  devbox_plan_build "$rerun" "$M" "$@" >"$P" 2>"$E"
}

actions() { awk -F'\t' '$1 == "step" { printf "%s%s=%s", sep, $2, $3; sep = " " }' "$P"; }
files_of() { PLAN_STEP="$1" awk -F'\t' '$1 == "file" && $2 == ENVIRON["PLAN_STEP"] { print $3 }' "$P"; }
reason_of() { printf '%s' "${PLAN_REASON[$1]}"; }
freason_of() { printf '%s' "${PLAN_FREASON[$1$'\t'$2]-}"; }

# trace <step> <line>...: the trace of the step's next run, one line per
# argument, `<kind> <owner> <path or reason>`, the first two blanks for tabs.
trace() {
  local step="$1" l rest
  shift
  : >"$TRACES/$step.trace"
  for l in "$@"; do
    rest="${l#* }"
    printf '%s\t%s\t%s\n' "${l%% *}" "${rest%% *}" "${rest#* }" >>"$TRACES/$step.trace"
  done
}

# Play the gate of the plan in $P over the manifest $M, as devbox-verify does:
# write the record, merge the traces of the steps that ran into their maps,
# write the record again with each passed step's learned key. Each argument
# `<step>=<outcome>:<code>` sets a step's result, and
# `file=<step>:<runner>:<path>:<outcome>` adds a file line. Sets LAST_RUN.
gate() {
  local run kind name action key outcome code mode o v s r p oc
  local -a ran=()
  SEQ=$((SEQ + 1))
  run="0123456789abcdef.$SEQ"
  {
    printf 'run\t%s\nat\t%s\nclient\t3.4.0\nbranch\tmain\ncommit\t-\ntarget\tlan1\n' "$run" "$SEQ"
    printf 'scope\t%s\ncomplete\t1\n' "$([ -n "$PLAN_SHARD" ] && echo partial || echo full)"
    while IFS=$'\t' read -r kind name action key _; do
      [ "$kind" = step ] || continue
      outcome=pass code=0 mode="${PLAN_MODE[$name]}"
      [ "$action" != carry ] || outcome=carried
      [ "$action" = carry ] || ran+=("$name")
      if [ "$action" = select ] && [ "${PLAN_NFILES[$name]}" = 0 ]; then EMPTY_SELECT=$((EMPTY_SELECT + 1)); fi
      if [ "$action" = carry ] && [ "$mode" = selected ] && [ "${PLAN_REASON[$name]}" != "no test read a changed file" ]; then
        SILENT_CARRY=$((SILENT_CARRY + 1))
      fi
      for o in "$@"; do
        case "$o" in "$name="*) v="${o#*=}"; outcome="${v%%:*}"; code="${v#*:}" ;; esac
      done
      printf 'step\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$key" "$outcome" 1 "$code" "$mode"
    done <"$P"
    for o in "$@"; do
      case "$o" in
        file=*) IFS=: read -r s r p oc <<<"${o#file=}"; printf 'file\t%s\t%s\t%s\t%s\t%s\n' "$s" "$r" "$p" "$oc" 3 ;;
      esac
    done
  } >"$TMP/record"
  devbox_record_write "$run" "$TMP/record" "$M" || echo "gate: devbox_record_write failed" >&2
  devbox_plan_learn "$run" "$M" "$TRACES" "$TMP/record" ${ran[@]+"${ran[@]}"} 2>"$TMP/learn.err"
  devbox_record_write "$run" "$TMP/record" "$M" || echo "gate: devbox_record_write failed" >&2
  rm -f "$TRACES"/*.trace
  LAST_RUN="$run"
}

edit() { printf 'changed\n' >>"$1"; }

# The traces of a full run of the pytest step: test_a reads src/a.py and the
# data file and lists data/, test_b reads src/b.py, every test file reads the
# conftest and a file under .venv/, and pytest's own process reads pytest.ini.
pytest_trace() {
  trace test \
    "read tests/test_a.py tests/test_a.py" "read tests/test_a.py src/a.py" "read tests/test_a.py data/one.json" \
    "list tests/test_a.py data" "read tests/test_a.py tests/conftest.py" "read tests/test_a.py .venv/lib/x.py" \
    "read tests/test_b.py tests/test_b.py" "read tests/test_b.py src/b.py" "read tests/test_b.py tests/conftest.py" \
    "read tests/test_c.py tests/test_c.py" "read tests/test_c.py tests/conftest.py" \
    "read - pytest.ini" "list - tests"
}

echo "-- D2: a change selects exactly the test files that read it"
new_repo d2
add_step test runner=pytest narrow=failed
plan changed
assert_eq "test=run" "$(actions)" "the first plan runs the step in full"
assert_eq "no earlier pass; no record of branch main to narrow by" "$(reason_of test)" \
  "because it never passed, and its narrow=failed has no result of this branch"
assert_eq 1 "$(awk -F'\t' '$1 == "step" { print $9 }' "$P")" "and asks for a trace"
assert_eq "tests/test_a.py
tests/test_b.py
tests/test_c.py" "$(awk -F'\t' '$1 == "test" { print $3 }' "$P")" "its test lines are the test files by the name rule, conftest left out"
pytest_trace
gate
first="$LAST_RUN"
plan changed
assert_eq "test=carry" "$(actions)" "an unchanged tree carries, under the key learned in the first run"
assert_eq "carried from run $first" "$(reason_of test)" "from that run"
edit docs/x.md
plan changed
assert_eq "test=carry" "$(actions)" "an edit to a file no test read carries"
edit data/one.json
plan changed
assert_eq "test=select" "$(actions)" "a changed data file selects"
assert_eq "tests/test_a.py" "$(files_of test)" "exactly the test file that read it"
assert_eq "read data/one.json" "$(freason_of test tests/test_a.py)" "with the reason"
assert_eq "test  select 1 files  selected 1 of 3 test files
  tests/test_a.py  read data/one.json" "$(devbox_plan_print)" "--plan prints the selected file and its reason"
assert_eq "tests/test_a.py
tests/test_b.py
tests/test_c.py" "$(awk -F'\t' '$1 == "test" { print $3 }' "$P")" "a selected step still lists every test file"
trace test "read tests/test_a.py tests/test_a.py" "read tests/test_a.py src/a.py" "read tests/test_a.py data/one.json" \
  "list tests/test_a.py data" "read tests/test_a.py tests/conftest.py" "read tests/test_a.py .venv/lib/x.py"
gate
assert_eq "selected" "$(awk -F'\t' '$1 == "step" { print $7 }' "$(devbox_record_dir)/$LAST_RUN.record")" "the record says selected"
plan changed
assert_eq "test=carry" "$(actions)" "a passed selection carries the step"

echo "-- D2a: a config every test reads selects every test file"
edit tests/conftest.py
plan changed
assert_eq "tests/test_a.py
tests/test_b.py
tests/test_c.py" "$(files_of test)" "the conftest selects every file, with no list"
pytest_trace
gate
edit pytest.ini 2>/dev/null || printf 'x\n' >pytest.ini
plan changed
assert_eq "tests/test_a.py
tests/test_b.py
tests/test_c.py" "$(files_of test)" "a file pytest's own process read selects every file"
assert_eq "read pytest.ini" "$(freason_of test tests/test_b.py)" "and names it"
pytest_trace
gate

echo "-- D2b: a file added to a listed directory selects the test that listed it"
printf '{}\n' >data/two.json
plan changed
assert_eq "tests/test_a.py" "$(files_of test)" "data/two.json selects test_a alone"
assert_eq "read data/" "$(freason_of test tests/test_a.py)" "by its listing"
pytest_trace
gate

echo "-- new, changed and failed test files"
printf 'def test_new(): pass\n' >tests/test_new.py
edit tests/test_b.py
plan changed
assert_eq "tests/test_b.py
tests/test_new.py" "$(files_of test)" "a new and a changed test file are selected"
assert_eq "new|changed" "$(freason_of test tests/test_new.py)|$(freason_of test tests/test_b.py)" "each with its reason"
trace test "read tests/test_b.py src/b.py" "read tests/test_new.py tests/test_new.py"
gate test=fail:1 file=test:pytest:tests/test_b.py:fail file=test:pytest:tests/test_new.py:pass
plan changed
assert_eq "tests/test_b.py" "$(files_of test)" "a failed file is selected on an unchanged tree"
assert_eq "failed" "$(freason_of test tests/test_b.py)" "as failed"
trace test "read tests/test_b.py src/b.py"
gate test=fail:2
plan changed
assert_eq "test=run" "$(actions)" "after a crash, code 2, the step runs in full"
assert_ok "and says why" contains "with code 2" "$(reason_of test)"
pytest_trace
gate

echo "-- D3: no read reached means carried, and no map means a full run"
add_step web runner=vitest
add_step api runner=vitest
STEP_CMD[web]="npx vitest run --project web" STEP_CMD[api]="npx vitest run --project api"
plan changed web api
trace web "read web/src/w.test.ts web/src/w.test.ts" "read web/src/w.test.ts web/src/w.ts" \
  "read web/src/v.test.ts web/src/v.test.ts"
trace api "read api/src/a.test.ts api/src/a.test.ts" "read api/src/a.test.ts api/src/a.ts"
gate
edit web/src/v.test.ts
plan changed web api
assert_eq "web=select api=carry" "$(actions)" "a web test file's edit changes api's key, and selects none of its files"
assert_eq "no test read a changed file" "$(reason_of api)" "so api carries with the reason of D3"
assert_eq "" "$(files_of api)" "and has no file line"
trace web "read web/src/v.test.ts web/src/v.test.ts"
gate
assert_eq "carried selected" "$(awk -F'\t' '$1 == "step" && $2 == "api" { print $4, $7 }' "$(devbox_record_dir)/$LAST_RUN.record")" \
  "the record says carried and selected"
printf 'test("n", () => {})\n' >web/src/n.test.ts
plan changed web api
assert_eq "web=select api=carry" "$(actions)" "a new web test file goes to web, whose files share its folder"
assert_eq "web/src/n.test.ts" "$(files_of web)" "alone"
trace web "read web/src/n.test.ts web/src/n.test.ts"
gate
rm "$(devbox_map_dir)/test.map"
edit src/a.py
plan changed test
assert_eq "test=run" "$(actions)" "a step whose map is gone runs in full"
assert_ok "and says no map" contains "no map" "$(reason_of test)"
pytest_trace
gate
printf 'map\t1\nfile\tbroken\n' >"$(devbox_map_dir)/test.map"
edit src/a.py
plan changed test
assert_eq "test=run" "$(actions)" "a map that cannot be read runs the step in full"
assert_eq 1 "$(grep -c 'map of step test could not be read' "$E")" "with one warning line"
pytest_trace
gate

echo "-- D3a: a test file that started a child process is partial"
edit src/b.py
plan changed test
trace test "read tests/test_a.py src/a.py" "read tests/test_b.py src/b.py" \
  "read tests/test_c.py tests/test_c.py" "partial tests/test_c.py subprocess git"
gate
# 4.0.1 D2: one partial file once gave its step every synced file as its key,
# so a docs-only edit selected every partial file of the step.
edit README.md
plan changed test
assert_eq "test=carry" "$(actions)" "4.0.1 D2: an edit no test of the step read carries, partial file and all"
edit src/a.py
plan changed test
assert_eq "test=select" "$(actions)" "4.0.1 D2: an edit a test of the step read reaches the step"
assert_eq "tests/test_a.py
tests/test_c.py" "$(files_of test)" "and selects the file that read it and the partial file"
assert_eq "read src/a.py|partial" "$(freason_of test tests/test_a.py)|$(freason_of test tests/test_c.py)" "each with its reason"
pytest_trace
gate

echo "-- D3b: no pass of a runner step that ran no test"
assert_eq 0 "$EMPTY_SELECT" "no select step of any gate above reached the runner with no file"
assert_eq 0 "$SILENT_CARRY" "every selection carry above had the plan's reason"
bad=0
for r in "$(devbox_record_dir)"/*.record; do
  awk -F'\t' '$1 == "step" && $7 == "related" { exit 1 }' "$r" || bad=1
done
assert_eq 0 "$bad" "no record holds a related step"
assert_fail "no plan line ever says related" grep -q $'\trelated\t' "$P"

echo "-- D4: a step without inputs= learns them, and is traced only when it must be"
new_repo d4
add_step lint
traced() { awk -F'\t' -v s="$1" '$1 == "step" && $2 == s { print $9 }' "$P"; }
plan changed
assert_eq "lint=run" "$(actions)" "the first plan runs it"
assert_eq 1 "$(traced lint)" "and traces it, since its map holds no trace"
trace lint "read - src/a.py" "read - src/b.py" "list - data" "read - .cache/none"
gate
plan changed
assert_eq "lint=carry" "$(actions)" "an unchanged tree carries"
edit docs/x.md
plan changed
assert_eq "lint=carry" "$(actions)" "an edit to a third file carries it"
edit data/one.json
plan changed
assert_eq "lint=carry" "$(actions)" "an edit to a file it only listed carries it: a listing reads names, not content"
edit src/b.py
plan changed
assert_eq "lint=run" "$(actions)" "an edit to a file it read runs it"
assert_ok "and the reason counts the changed inputs" contains "inputs changed: 1 files" "$(reason_of lint)"
assert_eq 0 "$(traced lint)" "untraced, because its trace is still valid"
gate
plan changed
assert_eq "lint=carry" "$(actions)" "its untraced pass carries"
mkdir -p data/sub && printf '{}\n' >data/sub/deep.json
plan changed
assert_eq "lint=run" "$(actions)" "a new folder in a listed directory runs it"
assert_eq 0 "$(traced lint)" "still untraced"
gate
printf '{}\n' >data/sub/more.json
plan changed
assert_eq "lint=carry" "$(actions)" "a new file in a folder it never listed carries: a listing names its own entries alone"
rm data/sub/more.json data/one.json
plan changed
assert_eq "lint=run" "$(actions)" "a file removed from a listed directory runs it"
assert_ok "and the reason counts the listing as one changed input" contains "inputs changed: 1 files" "$(reason_of lint)"
gate
printf 'data/one.json v1\n' >data/one.json
plan changed
gate
STEP_SOURCE[lint]="lint -- run lint --fix"
plan changed
assert_eq 1 "$(traced lint)" "a changed step line traces it again"
STEP_SOURCE[lint]="lint  -- run lint"
plan full
assert_eq 1 "$(traced lint)" "and a full run traces it"

echo "-- D4a: a read under node_modules/ puts the setup key in the key"
trace lint "read - src/a.py"
gate
edit package-lock.json
plan changed
assert_eq "lint=carry" "$(actions)" "without a setup read, a lock file edit carries"
plan full
trace lint "read - src/a.py" "read - node_modules/x/index.js"
gate
plan changed
assert_eq "lint=carry" "$(actions)" "a step that read node_modules/ carries an unchanged tree"
edit package-lock.json
plan changed
assert_eq "lint=run" "$(actions)" "and runs when the lock file changes"
DEVBOX_SETUP_INPUTS="docs/x.md"
plan changed
assert_eq "lint=run" "$(actions)" "DEVBOX_SETUP_INPUTS names the setup's own files instead"
DEVBOX_SETUP_INPUTS=""

echo "-- D4b: a step that cannot be traced keeps its inputs and says why"
plan full
trace lint "partial - strace: not found"
gate
assert_eq "strace: not found" "$(devbox_map_untraced lint)" "its map is marked untraced"
edit src/a.py
plan changed
assert_eq "lint=run" "$(actions)" "an edit to an input it read before runs it"
assert_ok "and --plan names the reason" contains "no trace: strace: not found" "$(devbox_plan_print)"
assert_eq 0 "$(traced lint)" "its earlier trace stays valid, so it is not traced on every run"
rm "$(devbox_map_dir)/lint.map"
plan full
trace lint "partial - strace: not found"
gate
edit docs/x.md
plan changed
assert_eq "lint=run" "$(actions)" "with no earlier inputs, every synced file is its input, as in 3.3"
assert_eq 1 "$(traced lint)" "and it asks for a trace again"

echo "-- inputs= turns the trace off"
new_repo inputs
add_step lint "inputs=src/"
plan changed
assert_eq 0 "$(awk -F'\t' '$1 == "step" { print $9 }' "$P")" "a step with inputs= asks for no trace"
gate
edit README.md
plan changed
assert_eq "lint=carry" "$(actions)" "its own list decides"
assert_eq none "$(devbox_map_state lint)" "and it has no map"

echo "-- dir=: a step's test files are those of its folder"
new_repo dir
add_step test runner=pytest dir=tests/
plan changed
assert_eq "tests/" "$(awk -F'\t' '$1 == "step" { print $8 }' "$P")" "the folder reaches the plan"
assert_eq 3 "$(grep -c $'^test\t' "$P")" "and the test lines are the files under it"

echo "-- D4: a step that listed the checkout root still carries"
# A type check that listed ./ keyed every synced file by content, so it never
# carried.
new_repo root
add_step typecheck
plan changed
trace typecheck "read - src/a.py" "list - ." "list - src"
gate
edit README.md
plan changed
assert_eq "typecheck=carry" "$(actions)" "an edit to a root file it only listed carries it"
edit src/b.py
plan changed
assert_eq "typecheck=carry" "$(actions)" "and so does an edit to a file of a listed folder it never read"
printf 'x\n' >NOTES.md
plan changed
assert_eq "typecheck=run" "$(actions)" "a new file in the root runs it"
gate
printf 'x\n' >src/c.py
plan changed
assert_eq "typecheck=run" "$(actions)" "and so does a new file in a listed folder"
gate

echo "-- a runner step plans only the test files of its own folder and runner"
# A record once gave one failed test file to every step of its runner, so a
# step narrowed or selected the failed files of other folders, and the runner
# refused the plan of a dir= step.
new_repo own
add_step web runner=vitest narrow=failed dir=web/
add_step api runner=vitest narrow=failed dir=api/
plan changed
trace web "read web/src/w.test.ts web/src/w.ts" "read web/src/v.test.ts web/src/v.test.ts"
trace api "read api/src/a.test.ts api/src/a.ts"
gate
edit web/src/w.ts
plan changed
assert_eq "web=select api=carry" "$(actions)" "a web edit selects in web"
trace web "read web/src/w.test.ts web/src/w.ts"
gate web=fail:1 file=web:vitest:web/src/w.test.ts:fail file=web:vitest:api/src/a.test.ts:fail \
  file=web:vitest:web/src/w.ts:fail
plan changed
assert_eq "web=select api=carry" "$(actions)" "a step with failed files of other folders in its record selects"
assert_eq "web/src/w.test.ts" "$(files_of web)" "its own failed file alone: neither another folder's test file nor a file the name rule rejects"
assert_eq "failed" "$(freason_of web web/src/w.test.ts)" "as failed"
assert_fail "and no test line of web leaves its folder" grep -q $'^test\tweb\tapi/' "$P"
rm "$(devbox_map_dir)/web.map"
plan changed
assert_eq "web=narrow api=carry" "$(actions)" "with no map, the step narrows"
assert_eq "web/src/w.test.ts" "$(files_of web)" "to its own failed file alone"
trace web "read web/src/w.test.ts web/src/w.ts" "read web/src/v.test.ts web/src/v.test.ts"
gate web=fail:1 file=web:vitest:api/src/a.test.ts:fail
plan changed
assert_eq "web=run api=carry" "$(actions)" "a step whose failed files all lie outside its folder runs in full"
trace web "read web/src/w.test.ts web/src/w.ts" "read web/src/v.test.ts web/src/v.test.ts" \
  "read api/src/a.test.ts api/src/a.ts"
gate
edit api/src/a.ts
plan changed
assert_eq "web=carry api=select" "$(actions)" "a test file of web's map outside web/ is never selected in web"
assert_eq "no test read a changed file" "$(reason_of web)" "so web carries with the reason of D3"
assert_eq "api/src/a.test.ts" "$(files_of api)" "and api runs it"

echo "-- D10: the shards of a runner step"
new_repo shard
for f in tests/test_d.py tests/test_e.py tests/test_f.py tests/test_g.py; do printf '%s v1\n' "$f" >"$f"; done
add_step test runner=pytest
union=""
for i in 1 2 3; do
  PLAN_SHARD="test $i 3"
  plan changed test
  assert_eq "test=select" "$(actions)" "shard $i of 3 with no map runs its part"
  union+="$(files_of test)"$'\n'
done
assert_eq "tests/test_a.py
tests/test_b.py
tests/test_c.py
tests/test_d.py
tests/test_e.py
tests/test_f.py
tests/test_g.py" "$(printf '%s' "$union" | LC_ALL=C sort)" "the shards are disjoint and their union is every test file"
PLAN_SHARD="test 1 3"
plan changed test
assert_eq "tests/test_a.py
tests/test_b.py
tests/test_c.py" "$(files_of test)" "with no duration known, shard 1 is the first run of the sorted list"
gate file=test:pytest:tests/test_g.py:pass file=test:pytest:tests/test_a.py:pass
assert_eq "shard" "$(awk -F'\t' '$1 == "step" { print $7 }' "$(devbox_record_dir)/$LAST_RUN.record")" "a shard's record says shard"
SEQ=$((SEQ + 1))
printf 'run\t0123456789abcdef.%s\nat\t%s\ncomplete\t1\nscope\tfull\n' "$SEQ" "$SEQ" >"$TMP/timed"
for f in a:50 b:10 c:10 d:10 e:10 f:10 g:10; do
  printf 'file\ttest\tpytest\ttests/test_%s.py\tpass\t%s\n' "${f%%:*}" "${f#*:}" >>"$TMP/timed"
done
devbox_record_write "0123456789abcdef.$SEQ" "$TMP/timed" ""
union=""
for i in 1 2 3; do
  PLAN_SHARD="test $i 3"
  plan changed test
  union+="$(files_of test)"$'\n'
  [ "$i" != 1 ] || assert_eq "tests/test_a.py" "$(files_of test)" "by duration, the 50 s file fills shard 1 alone"
done
assert_eq 7 "$(printf '%s' "$union" | LC_ALL=C sort -u | grep -c .)" "and the timed shards still cover every file once"
PLAN_SHARD=""
plan changed
assert_fail "a full gate never carries from a shard's pass" test "$(actions)" = "test=carry"
PLAN_SHARD="test 1 3"
plan changed test test; rc=$?
assert_eq 2 "$rc" "--shard with a step named twice is refused"
PLAN_SHARD="lint 1 2"
add_step lint
plan changed lint; rc=$?
assert_eq 2 "$rc" "--shard of a step with no runner is refused"
assert_ok "with a line that says so" grep -q "has no runner=" "$E"
# devbox ci matrix gives such a step the one shard 1/1, and CI passes it as it stands.
PLAN_SHARD="lint 1 1"
plan changed lint; rc=$?
assert_eq 0 "$rc" "--shard 1/1 of a step with no runner is the whole step"
assert_eq "lint" "$(awk -F'\t' '$1 == "step" { print $2 }' "$P")" "and plans that one step"
PLAN_SHARD=""

printf '%d %d\n' "$TESTS_RUN" "$TESTS_FAILED"
