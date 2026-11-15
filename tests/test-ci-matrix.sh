#!/bin/bash
# `devbox ci matrix` (docs/specs/2026-11-14-learned-selection-design.md, D10 and
# section 9): one matrix entry per step of .devbox/steps, one per shard for a
# step with shards=, and exit 2 for a steps file that verify refuses.
#
# Every consumer's CI wrote its step list a second time, and the copies drifted
# from the gate. The matrix is read from the one steps file instead.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
# shellcheck source=tests/lib.sh
source ./lib.sh

REPO="$(cd .. && pwd)"
TMP="$(mktemp -d)" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
CI="$REPO/client/libexec/devbox-ci"

# A git repository at $TMP/$1 whose .devbox/steps is stdin, as the current
# directory.
new_repo() {
  local dir="$TMP/$1"
  mkdir -p "$dir/.devbox" && cd "$dir" || exit 1
  git init -q -b main .
  cat >.devbox/steps
}

out=""; err=""; rc=0
run_ci() {
  out="$("$@" 2>"$TMP/err")"; rc=$?
  err="$(cat "$TMP/err")"
}

echo "-- one entry per step"
new_repo plain <<'EOF'
# the gate
typecheck -- npx tsc -b --noEmit
lint      -- npx eslint .
test runner=vitest narrow=failed -- npx vitest run
EOF
run_ci bash "$CI" matrix
assert_eq 0 "$rc" "devbox ci matrix exits 0"
assert_eq '{"include":[{"step":"typecheck","shard":"1/1"},{"step":"lint","shard":"1/1"},{"step":"test","shard":"1/1"}]}' \
  "$out" "it prints one entry per step in file order, shard 1/1 each"
assert_eq "" "$err" "and nothing on stderr"
mkdir -p sub && cd sub || exit 1
run_ci bash "$CI" matrix
assert_eq 0 "$rc" "it reads the steps file of the checkout root from a subfolder"
if command -v python3 >/dev/null 2>&1; then
  assert_eq 3 "$(printf '%s' "$out" | python3 -I -c 'import json, sys; print(len(json.load(sys.stdin)["include"]))')" \
    "python3 json.load reads three entries"
fi

echo "-- each= steps"
new_repo each <<'EOF'
test:{name} each=packages/*/ -- npx vitest run --root {dir}
EOF
mkdir -p packages/a packages/b && touch packages/a/x packages/b/x
run_ci bash "$CI" matrix
assert_eq '{"include":[{"step":"test:a","shard":"1/1"},{"step":"test:b","shard":"1/1"}]}' \
  "$out" "an each= line gives one entry per expanded step"

# The shard count comes from STEP_SHARDS, which devbox-steps-file fills from
# shards= (section 5.6). This copy of the client wraps the parser to set it, so
# the expansion is proven whatever the parser in this tree reads.
echo "-- shards"
cp -R "$REPO/client" "$REPO/lib" "$TMP/"
cat >>"$TMP/client/libexec/devbox-steps-file" <<'EOF'
eval "$(declare -f devbox_steps_load | sed '1s/^devbox_steps_load/_fixture_steps_load/')"
devbox_steps_load() { _fixture_steps_load "$@" || return; STEP_SHARDS[test]="${FIXTURE_SHARDS:-3}"; }
EOF
new_repo shards <<'EOF'
lint -- npx eslint .
test runner=vitest -- npx vitest run
EOF
run_ci bash "$TMP/client/libexec/devbox-ci" matrix
assert_eq '{"include":[{"step":"lint","shard":"1/1"},{"step":"test","shard":"1/3"},{"step":"test","shard":"2/3"},{"step":"test","shard":"3/3"}]}' \
  "$out" "a step with three shards gives entries 1/3, 2/3 and 3/3"
FIXTURE_SHARDS=0 run_ci bash "$TMP/client/libexec/devbox-ci" matrix
assert_eq 2 "$rc" "shards=0 is refused with exit 2"
assert_ok "and the refusal names the step" grep -qF "step test has shards=0" <<<"$err"
assert_eq "" "$out" "and prints no partial matrix"

# The same through the parser of this tree, once it reads shards=.
new_repo shards-real <<'EOF'
test runner=vitest shards=2 -- npx vitest run
EOF
run_ci bash "$CI" matrix
if [ "$rc" -eq 0 ]; then
  assert_eq '{"include":[{"step":"test","shard":"1/2"},{"step":"test","shard":"2/2"}]}' \
    "$out" "shards=2 in the steps file gives two entries"
else
  assert_ok "the parser of this tree refuses shards= by name, the only accepted failure" \
    grep -qF 'unknown attribute "shards"' <<<"$err"
  echo "  note devbox-steps-file reads no shards= yet, so the shards= line was proven through the wrapped copy only"
fi

echo "-- refusals"
new_repo broken <<'EOF'
lint npx eslint .
EOF
run_ci bash "$CI" matrix
assert_eq 2 "$rc" "a broken steps file exits 2"
assert_ok "with the parser's line" grep -qF '.devbox/steps line 1' <<<"$err"
assert_eq "" "$out" "and no matrix"
new_repo empty </dev/null
run_ci bash "$CI" matrix
assert_eq 2 "$rc" "a steps file of no step exits 2"
assert_ok "and says so" grep -qF 'names no step' <<<"$err"
new_repo none </dev/null
rm .devbox/steps
run_ci bash "$CI" matrix
assert_eq 2 "$rc" "no steps file exits 2"
mkdir -p "$TMP/nogit" && cd "$TMP/nogit" || exit 1
run_ci env GIT_CEILING_DIRECTORIES="$TMP" bash "$CI" matrix
assert_eq 2 "$rc" "outside a git checkout exits 2"
run_ci bash "$CI"
assert_eq 2 "$rc" "no subcommand exits 2"
run_ci bash "$CI" matrix extra
assert_eq 2 "$rc" "an extra word exits 2"
assert_ok "with the usage line" grep -qF 'usage: devbox ci matrix' <<<"$err"

printf '%d %d\n' "$TESTS_RUN" "$TESTS_FAILED"
