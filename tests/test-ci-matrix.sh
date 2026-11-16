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

# ── devbox ci cache ──────────────────────────────────────────────────────────
#
# The shared workflow caches what the setup made, together with the key file
# that skips it, under the key this prints. A key restored without every
# output would skip a setup whose outputs are missing, so a setup whose
# outputs are unknown gets no path at all.
echo "-- ci cache"
# A repository with a config.env of stdin, the steps file of one step and the
# lock files named after it, each tracked.
cache_repo() {
  local name="$1" lock
  shift
  new_repo "$name" <<<'verify -- :'
  cat >.devbox/config.env
  for lock in "$@"; do
    mkdir -p "$(dirname "$lock")"
    printf 'lock of %s\n' "$lock" >"$lock"
  done
  git add -A
}
# The key `devbox ci cache` must print: the key file's value, from the same
# devbox_setup_key of this tree, and the machine.
want_key() {
  local k s
  # shellcheck disable=SC2016  # expanded by the bash -c, never here
  k="$(bash -c 'source "$1/lib/devbox-lib.sh" && source "$1/client/libexec/devbox-config" &&
    devbox_config_load && devbox_setup_key' key "$REPO")" || return 1
  s="$(printf 'setup %s\nmachine %s\n' "$k" "$(uname -s -m)" | sha256sum)"
  printf 'devbox-setup-%s' "${s%% *}"
}
paths_of() { sed -n 's/.*"paths":\(\[.*\]\)}$/\1/p' <<<"$1"; }
key_of() { sed -n 's/^{"key":"\([^"]*\)".*/\1/p' <<<"$1"; }

cache_repo default-locks app/uv.lock web/package-lock.json pnpm-lock.yaml ui/yarn.lock <<<'DEVBOX_PROJECT=app'
run_ci bash "$CI" cache
assert_eq 0 "$rc" "devbox ci cache exits 0 for the default setup"
assert_eq "" "$err" "and prints nothing on stderr"
assert_eq '["app/.venv","node_modules","ui/node_modules","web/node_modules",".git/devbox/setup"]' "$(paths_of "$out")" \
  "the default setup caches .venv/ beside a uv.lock, node_modules/ beside the other three, and the key directory"
assert_ok "the key is devbox-setup- and 64 hex digits" grep -qE '^devbox-setup-[0-9a-f]{64}$' <<<"$(key_of "$out")"
assert_eq "$(want_key)" "$(key_of "$out")" "and it hashes the key file's value and the machine"
assert_eq "{\"key\":\"$(want_key)\",\"paths\":$(paths_of "$out")}" "$out" "the object is the key and the paths, on one line"
if command -v python3 >/dev/null 2>&1; then
  assert_eq 5 "$(printf '%s' "$out" | python3 -I -c 'import json, sys; print(len(json.load(sys.stdin)["paths"]))')" \
    "python3 json.load reads five paths"
fi
old="$(key_of "$out")"
printf 'a changed lock\n' >app/uv.lock
run_ci bash "$CI" cache
assert_ok "a changed lock file changes the key" test "$(key_of "$out")" != "$old"
mkdir -p sub && cd sub || exit 1
run_ci bash "$CI" cache
assert_eq '["app/.venv","node_modules","ui/node_modules","web/node_modules",".git/devbox/setup"]' "$(paths_of "$out")" \
  "a subfolder prints the same paths, relative to the checkout root"

cache_repo explicit-default app/uv.lock <<<'DEVBOX_PROJECT=app
DEVBOX_SETUP=devbox_install_locks'
run_ci bash "$CI" cache
assert_eq '["app/.venv",".git/devbox/setup"]' "$(paths_of "$out")" \
  "DEVBOX_SETUP=devbox_install_locks, written out, is the default install"

cache_repo composed app/uv.lock <<<'DEVBOX_PROJECT=app
DEVBOX_SETUP="devbox_install_locks && make models"'
run_ci bash "$CI" cache
assert_eq 0 "$rc" "a composed setup with no DEVBOX_SETUP_OUTPUTS exits 0"
assert_eq '[]' "$(paths_of "$out")" \
  "and caches nothing: its second part writes outputs no lock file names"
assert_ok "and still prints a key" grep -qE '^devbox-setup-[0-9a-f]{64}$' <<<"$(key_of "$out")"

cache_repo composed-outputs app/uv.lock <<<'DEVBOX_PROJECT=app
DEVBOX_SETUP="devbox_install_locks && make models"
DEVBOX_SETUP_INPUTS="app/uv.lock Makefile"
DEVBOX_SETUP_OUTPUTS="models ~/.cache/ms-playwright"'
run_ci bash "$CI" cache
assert_eq '["app/.venv","models","~/.cache/ms-playwright",".git/devbox/setup"]' "$(paths_of "$out")" \
  "a composed setup with DEVBOX_SETUP_OUTPUTS caches the lock outputs, its outputs as written, and the key directory"
assert_eq "$(want_key)" "$(key_of "$out")" "and its key is the key file's value over DEVBOX_SETUP_INPUTS"
old="$(key_of "$out")"
printf 'models:\n' >Makefile
run_ci bash "$CI" cache
assert_ok "a changed DEVBOX_SETUP_INPUTS file changes the key" test "$(key_of "$out")" != "$old"

cache_repo custom app/uv.lock <<<'DEVBOX_PROJECT=app
DEVBOX_SETUP="make deps"'
run_ci bash "$CI" cache
assert_eq '[]' "$(paths_of "$out")" "a setup of its own with no DEVBOX_SETUP_OUTPUTS caches nothing"
cache_repo custom-outputs app/uv.lock <<<'DEVBOX_PROJECT=app
DEVBOX_SETUP="make deps"
DEVBOX_SETUP_OUTPUTS=vendor'
run_ci bash "$CI" cache
assert_eq '["vendor",".git/devbox/setup"]' "$(paths_of "$out")" \
  "a setup of its own caches its DEVBOX_SETUP_OUTPUTS and the key directory, and no lock output it never installs"

# A workspace member keeps node_modules/ of its own: npm for a package two
# members need in two versions, pnpm for every member with dependencies. A key
# restored without them skips a setup whose member folders are missing.
cache_repo workspaces <<<'DEVBOX_PROJECT=app'
cat >package-lock.json <<'EOF'
{
  "lockfileVersion": 3,
  "packages": {
    "": {
      "workspaces": ["apps/*"]
    },
    "pkgs/one": {
      "version": "1.0.0"
    },
    "pkgs/one/node_modules/react": {
      "version": "18.0.0"
    },
    "pkgs/one/node_modules/react/node_modules/loose": {
      "version": "1.0.0"
    },
    "node_modules/react": {
      "version": "19.0.0"
    },
    "node_modules/react/node_modules/loose": {
      "version": "2.0.0"
    }
  }
}
EOF
mkdir -p ui
cat >ui/pnpm-lock.yaml <<'EOF'
lockfileVersion: '9.0'

importers:

  .:
    devDependencies:
      typescript:
        specifier: ^5.0.0
        version: 5.0.0

  cli:
    dependencies:
      zod:
        specifier: ^3.0.0
        version: 3.0.0

  'modules/a b':
    devDependencies:
      vitest:
        specifier: ^3.0.0
        version: 3.0.0

  modules/empty: {}

packages:

  zod@3.0.0:
    resolution: {integrity: sha512-x}
EOF
git add -A
run_ci bash "$CI" cache
assert_eq 0 "$rc" "a checkout with npm and pnpm workspaces exits 0"
assert_eq '["node_modules","pkgs/one/node_modules","ui/node_modules","ui/cli/node_modules","ui/modules/a b/node_modules",".git/devbox/setup"]' "$(paths_of "$out")" \
  "it caches each member's own node_modules: an npm member copy, and each pnpm importer with dependencies, none inside the root node_modules"

cache_repo no-setup <<<'DEVBOX_PROJECT=app'
run_ci bash "$CI" cache
assert_eq 0 "$rc" "a checkout with no lock file and no DEVBOX_SETUP exits 0"
assert_eq '[]' "$(paths_of "$out")" "and caches nothing"

cache_repo refused <<<'DEVBOX_PROJECT=app
DEVBOX_SETUP_OUTPUTS=/var/cache'
run_ci bash "$CI" cache
assert_eq 2 "$rc" "a DEVBOX_SETUP_OUTPUTS path outside the checkout and the home is refused with exit 2"
assert_ok "naming the key and the path" grep -qF "refusing DEVBOX_SETUP_OUTPUTS '/var/cache'" <<<"$err"
assert_eq "" "$out" "and prints no partial object"
cache_repo no-config </dev/null
rm .devbox/config.env
run_ci bash "$CI" cache
assert_eq 2 "$rc" "no config.env exits 2"
run_ci bash "$CI" cache extra
assert_eq 2 "$rc" "an extra word exits 2"
assert_ok "with the usage line" grep -qF 'usage: devbox ci matrix|cache' <<<"$err"

printf '%d %d\n' "$TESTS_RUN" "$TESTS_FAILED"
