#!/bin/bash
# `devbox result --failed-steps` and `devbox result --json`
# (docs/specs/2026-11-14-learned-selection-design.md, D9 and section 9).
#
# A landing script parsed the `devbox: red (...)` text for the failed steps, and
# each copy broke on another wording. These two forms are the machine-readable
# answer. The JSON is built with awk's printf, so this file checks it with grep
# and awk, and with python3's json.loads where python3 exists: a hand-built JSON
# that one parser reads and another refuses is the failure this guards.
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

new_repo() {
  local dir="$TMP/$1"
  mkdir -p "$dir" && cd "$dir" || exit 1
  git init -q -b main . && printf 'x\n' >a.txt && git add a.txt && git commit -qm init
}

# Write one record: $1 run id, $2 complete, then the step and file lines, each
# one argument with fields separated by `|`, so a field may hold a space.
write_record() {
  local run="$1" complete="$2" line
  shift 2
  {
    printf 'run\t%s\nat\t1700000000\nclient\t3.4.0\nbranch\tmain\ncommit\t%s\ntarget\tlan1\nscope\tfull\ncomplete\t%s\n' \
      "$run" 0123456789abcdef0123456789abcdef01234567 "$complete"
    for line in "$@"; do printf '%s\n' "${line//|/$'\t'}"; done
  } >"$TMP/rec.txt"
  devbox_record_write "$run" "$TMP/rec.txt" ""
}

# Parse the JSON on stdin with python3 and print what the Python expression $1
# makes of it as `d`. Exits 3 when python3 is missing, so a caller can tell.
# The expression is this file's own text, never input, so eval runs nothing a
# fixture wrote.
py_json() {
  command -v python3 >/dev/null 2>&1 || return 3
  python3 -I -c 'import json, sys; d = json.loads(sys.stdin.read()); print(eval(sys.argv[1]))' "$1"
}

R1=0123456789abcdef.2001
R2=0123456789abcdef.2002

echo "-- a red gate"
new_repo red
write_record "$R1" 1 "step|lint|k-lint|pass|4|0|full" "step|test|k-test|fail|30|1|full" \
  "step|typecheck|k-tc|fail|9|2|full" "step|build|k-b|carried|0|0|full" \
  "file|test|vitest|src/a.test.ts|fail" "file|test|vitest|src/b.test.ts|pass" \
  "file|test|vitest|src/c d.test.ts|fail" "file|test|vitest|src/e.test.ts|open"

out="$(bash "$RESULT" --failed-steps)"; rc=$?
assert_eq 0 "$rc" "--failed-steps exits 0"
assert_eq "test
typecheck" "$out" "--failed-steps prints the failed steps in record order, one per line"

json="$(bash "$RESULT" --json)"; rc=$?
assert_eq 0 "$rc" "--json exits 0"
assert_eq 1 "$(printf '%s\n' "$json" | grep -c .)" "--json prints one line"
assert_ok "it is one object" grep -qE '^\{.*\}$' <<<"$json"
assert_ok "it names the run" grep -qF "\"run\":\"$R1\"" <<<"$json"
assert_ok "the epoch second is a whole number, never 1.7e+09" grep -qF '"at":1700000000,' <<<"$json"
assert_ok "complete is a JSON boolean" grep -qF '"complete":true,' <<<"$json"
assert_ok "a failed step carries outcome, seconds, code and its failed files" \
  grep -qF '{"name":"test","key":"k-test","outcome":"fail","seconds":30,"code":1,"mode":"full","failed_files":["src/a.test.ts","src/c d.test.ts"]}' <<<"$json"
assert_ok "a failed step with no failed file has an empty list" \
  grep -qF '{"name":"typecheck","key":"k-tc","outcome":"fail","seconds":9,"code":2,"mode":"full","failed_files":[]}' <<<"$json"
assert_ok "a carried step is listed too" grep -qF '"name":"build","key":"k-b","outcome":"carried"' <<<"$json"
# A brace or bracket the printf left open is the commonest hand-built JSON bug.
balance="$(printf '%s' "$json" | awk '{ o = gsub(/[{[]/, ""); c = gsub(/[]}]/, ""); print o - c }')"
assert_eq 0 "$balance" "every brace and bracket closes (no string here holds one)"

if py_json 'len(d["steps"])' <<<"$json" >/dev/null 2>&1; then
  assert_eq 4 "$(py_json 'len(d["steps"])' <<<"$json")" "python3 json.loads reads four steps"
  assert_eq "['src/a.test.ts', 'src/c d.test.ts']" "$(py_json 'd["steps"][1]["failed_files"]' <<<"$json")" \
    "and the failed files of test"
  assert_eq "True" "$(py_json 'd["complete"] is True' <<<"$json")" "and a boolean complete"
else
  rc=0; py_json 1 </dev/null >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 3 ]; then
    echo "  note python3 is missing, so json.loads did not read the output; the grep checks above still ran"
  else
    assert_ok "python3 json.loads reads the --json output" false
  fi
fi

echo "-- a path that needs escaping"
new_repo escape
q='"'
write_record "$R1" 0 "step|test|k|fail|-|143|full" \
  "file|test|pytest|tests/a${q}quote.py|fail" 'file|test|pytest|tests/back\slash.py|fail' \
  "file|test|pytest|tests/bell$(printf '\a')x.py|fail"
json="$(bash "$RESULT" --json)"
assert_ok "a quote in a path is escaped" grep -qF 'tests/a\"quote.py' <<<"$json"
assert_ok "a backslash in a path is escaped" grep -qF 'tests/back\\slash.py' <<<"$json"
assert_ok "a control character becomes \\u00XX" grep -qF 'tests/bell\u0007x.py' <<<"$json"
assert_ok "seconds that are not a number become null" grep -qF '"seconds":null,"code":143' <<<"$json"
assert_ok "complete 0 is false" grep -qF '"complete":false,' <<<"$json"
if command -v python3 >/dev/null 2>&1; then
  assert_eq "tests/a\"quote.py|tests/back\\slash.py|tests/bell$(printf '\a')x.py" \
    "$(py_json '"|".join(d["steps"][0]["failed_files"])' <<<"$json")" "python3 reads every escaped path back byte for byte"
fi

echo "-- a green gate and no record"
new_repo green
write_record "$R2" 1 "step|lint|k|pass|1|0|full"
assert_eq "" "$(bash "$RESULT" --failed-steps)" "--failed-steps of a green gate prints nothing"
assert_ok "and exits 0" bash "$RESULT" --failed-steps
new_repo none
rc=0; bash "$RESULT" --json >/dev/null 2>&1 || rc=$?
assert_eq 1 "$rc" "--json with no record exits 1"
rc=0; bash "$RESULT" --failed-steps >/dev/null 2>&1 || rc=$?
assert_eq 1 "$rc" "--failed-steps with no record exits 1"

echo "-- usage"
rc=0; bash "$RESULT" --json extra >/dev/null 2>&1 || rc=$?
assert_eq 2 "$rc" "--json takes no argument"
rc=0; bash "$RESULT" --failed-steps test >/dev/null 2>&1 || rc=$?
assert_eq 2 "$rc" "--failed-steps takes no argument"
assert_ok "the usage line names both" sh -c "bash '$RESULT' --nope 2>&1 | grep -qF -- '--failed-steps | --failed-files [<step>] | --log <step> | --json'"

printf '%d %d\n' "$TESTS_RUN" "$TESTS_FAILED"
