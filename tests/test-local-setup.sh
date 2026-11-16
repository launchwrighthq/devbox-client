#!/bin/bash
# `devbox verify --local --setup` runs DEVBOX_SETUP before the steps, with the
# setup skip of DEVBOX_SETUP_INPUTS and its key in this worktree's git dir, and
# without the symlink repair of a synced workspace. Under CI `--local` runs it
# by default and `--no-setup` turns it off; on a laptop it runs only with
# `--setup`. `devbox setup` runs the same setup, with the same skip and key,
# and no step.
#
# MEASURED before it: a local gate never ran the setup, so every consumer's CI
# job repeated its install commands in the workflow, a second copy of the
# setup that drifts from the config. The CI default needs the key file in the
# same cache as the outputs: without it a fresh runner would run `npm ci` and
# wipe the node_modules/ a job restored from its cache. `devbox setup` then
# `devbox verify --local` below is that flow.
#
# The fixture's setup is the default, devbox_install_locks, with fake uv and
# npm on PATH that log each call. The real devbox-verify runs the gate here;
# no ssh is reachable.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
# shellcheck source=tests/lib.sh
source ./lib.sh
# A CI job sets CI. Every case here names its own.
unset CI DEVBOX_RERUN DEVBOX_STRICT

REPO="$(cd .. && pwd)"
# shellcheck source=lib/devbox-lib.sh
source "$REPO/lib/devbox-lib.sh"
# shellcheck source=client/libexec/devbox-config
source "$REPO/client/libexec/devbox-config"
TMP="$(mktemp -d)" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/fakehome" "$TMP/run" "$TMP/tmp"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
contains() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }

LOG="$TMP/setup.log"
STEP_LOG="$TMP/steps.log"
export LOG STEP_LOG
# The stubs' text is expanded by the bash that runs them, never here.
# shellcheck disable=SC2016
printf '#!/bin/bash\necho "uv $*" >>"$LOG"\nmkdir -p "${5:-.}/.venv"\n' >"$TMP/bin/uv"
# shellcheck disable=SC2016
printf '#!/bin/bash\necho "npm $*" >>"$LOG"\nmkdir -p "${3:-.}/node_modules"\n' >"$TMP/bin/npm"
# A gate on this machine must reach no host.
# shellcheck disable=SC2016
printf '#!/bin/bash\necho "ssh $*" >>"$LOG"\nexit 255\n' >"$TMP/bin/ssh"
chmod +x "$TMP/bin/uv" "$TMP/bin/npm" "$TMP/bin/ssh"

CO="$TMP/checkout"
mkdir -p "$CO/.devbox" "$CO/app"
git -C "$CO" init -q
printf 'version = 1\n' >"$CO/app/uv.lock"
printf 'DEVBOX_PROJECT=app\n' >"$CO/.devbox/config.env"
# shellcheck disable=SC2016  # expanded by the step's bash, never here
printf 'check -- bash -c '\''echo check >>"$STEP_LOG"'\''\n' >"$CO/.devbox/steps"
: >"$CO/.devbox/exclude"
git -C "$CO" add -A
git -C "$CO" -c user.name=t -c user.email=t@example.com commit -qm fixture

verify() {
  rc=0
  rm -f "$LOG" "$STEP_LOG"
  out="$(cd "${IN:-$CO}" && env PATH="$TMP/bin:$PATH" HOME="$TMP/fakehome" XDG_RUNTIME_DIR="$TMP/run" TMPDIR="$TMP/tmp" \
    bash "$REPO/client/libexec/devbox-verify" "$@" 2>&1)" || rc=$?
}
logged() { [ -f "$LOG" ] && cat "$LOG"; }
stepped() { [ -f "$STEP_LOG" ] && cat "$STEP_LOG"; }
KEY="$CO/.git/devbox/setup/app.key"

# ── on a laptop a local gate runs no setup without --setup ──────────────────
verify --local --full
assert_eq "0" "$rc" "--local with no --setup passes"
assert_eq "" "$(logged)" "and runs no setup, as a local gate did before --setup"
assert_eq "check" "$(stepped)" "and runs the step"
assert_fail "and prints no setup line" contains "==> setup" "$out"

# ── under CI a local gate runs the setup, unless --no-setup ─────────────────
export CI=true
verify --local --full
assert_eq "0" "$rc" "--local under CI passes"
assert_eq "uv sync --locked --all-packages --directory app" "$(logged)" \
  "and runs the setup by default: the workflow caches the key with the outputs"
assert_eq "check" "$(stepped)" "and then the step"
rm -f "$KEY"
verify --local --no-setup --full
assert_eq "0" "$rc" "--local --no-setup under CI passes"
assert_eq "" "$(logged)" "and runs no setup, with no key"
assert_eq "check" "$(stepped)" "and runs the step"
CI='' verify --local --full
assert_eq "" "$(logged)" "an empty CI is a laptop: no setup"
unset CI

# ── --setup runs the setup before the steps, and writes the key ─────────────
verify --local --setup --full
assert_eq "0" "$rc" "--local --setup passes"
assert_eq "uv sync --locked --all-packages --directory app" "$(logged)" \
  "and runs the default setup, uv sync beside the tracked uv.lock"
assert_eq "check" "$(stepped)" "and then the step"
assert_ok "and prints the setup line of a remote gate" contains $'==> setup\n==> setup: runs, this workspace has no key of a setup that passed\n==> setup: uv sync --locked --all-packages in app/' "$out"
setup_at="$(printf '%s\n' "$out" | grep -n -m1 '^==> setup$' | cut -d: -f1)"
step_at="$(printf '%s\n' "$out" | grep -n -m1 'check started' | cut -d: -f1)"
assert_ok "and the setup comes before the first step" test "${setup_at:-99}" -lt "${step_at:-0}"
assert_ok "the key sits in this worktree's git dir" test -s "$KEY"
assert_fail "and never in the workspace path" test -e "$TMP/fakehome/.devbox/setup/app.key"

# ── unchanged lock files skip the setup on the next --setup ─────────────────
verify --local --setup --full
assert_eq "0" "$rc" "a second --setup passes"
assert_eq "" "$(logged)" "and does not run uv again"
assert_ok "and says it skipped, naming the input" \
  contains "==> setup: skipped, app/uv.lock unchanged since the last setup here" "$out"
assert_eq "check" "$(stepped)" "and the step runs"
printf 'version = 2\n' >"$CO/app/uv.lock"
verify --local --setup --full
assert_eq "uv sync --locked --all-packages --directory app" "$(logged)" "a changed uv.lock runs the setup again"
git -C "$CO" checkout -q -- app/uv.lock

# ── a .venv symlink below the root is the developer's own, and stays ────────
mkdir -p "$TMP/shared-venv"
rm -rf "$CO/app/.venv"
ln -s "$TMP/shared-venv" "$CO/app/.venv"
rm -f "$KEY"
verify --local --setup --full
assert_eq "0" "$rc" "a setup beside a .venv symlink passes"
assert_eq "uv sync --locked --all-packages --directory app" "$(logged)" "and runs, with no key"
assert_ok "and the app/.venv symlink survives: a local setup has no repair" test -L "$CO/app/.venv"
# The hooks of the checkout, built as devbox-verify builds them. $1, when
# given, is the DEVBOX_HOOKS_TARGET of the call.
hooks_of() {
  (cd "$CO" && devbox_config_load && DEVBOX_HOOKS_TARGET="${1-}" devbox_hooks_script)
}
hooks="$(hooks_of local)"
assert_fail "the local hooks define no _devbox_repair_links" contains "_devbox_repair_links" "$hooks"
hooks="$(hooks_of)"
assert_ok "and a workspace's hooks still do" contains "_devbox_repair_links" "$hooks"
# A client program sources devbox-config with the environment it started in.
# shellcheck disable=SC2016  # expanded by the bash -c, never here
hooks="$(DEVBOX_HOOKS_TARGET=local bash -c 'source "$1/lib/devbox-lib.sh" && source "$1/client/libexec/devbox-config" &&
  cd "$2" && devbox_config_load && devbox_hooks_script' hooks "$REPO" "$CO")"
assert_ok "an exported DEVBOX_HOOKS_TARGET never strips the repair from a workspace's hooks" \
  contains "_devbox_repair_links" "$hooks"
rm "$CO/app/.venv"

# ── a linked worktree keeps a key of its own ────────────────────────────────
git -C "$CO" worktree add -q "$TMP/wt"
IN="$TMP/wt"
verify --local --setup --full
unset IN
assert_eq "0" "$rc" "--setup in a linked worktree passes"
assert_eq "uv sync --locked --all-packages --directory app" "$(logged)" \
  "and runs the setup there: the main checkout's key does not skip it"
assert_ok "and its key sits in that worktree's git dir" test -s "$CO/.git/worktrees/wt/devbox/setup/app.key"

# ── --setup needs --local ───────────────────────────────────────────────────
verify --setup
assert_eq "2" "$rc" "--setup without --local exits 2"
assert_ok "and says a target runs the setup on every run" \
  contains "--setup and --no-setup choose the setup of a gate on this machine, so they need --local" "$out"
assert_eq "" "$(logged)" "and nothing ran, no setup and no ssh"
assert_eq "" "$(stepped)" "and no step"
verify --no-setup
assert_eq "2" "$rc" "--no-setup without --local exits 2"
assert_eq "" "$(logged)" "and nothing ran"
verify --local --setup --no-setup
assert_eq "2" "$rc" "--setup and --no-setup together exit 2"
assert_ok "and say they name two choices" contains "--setup and --no-setup name two choices" "$out"
assert_eq "" "$(stepped)" "and no step ran"

# ── --plan prints the plan and runs no setup ────────────────────────────────
verify --local --setup --plan --full
assert_eq "0" "$rc" "--plan with --local --setup exits 0"
assert_eq "" "$(logged)" "and runs no setup"
assert_eq "" "$(stepped)" "and no step"

# ── devbox setup: the same setup, skip and key, and no step ─────────────────
# Through the dispatcher, as the shared workflow's setup job calls it.
setup_cmd() {
  rc=0
  rm -f "$LOG" "$STEP_LOG"
  out="$(cd "${IN:-$CO}" && env PATH="$TMP/bin:$PATH" HOME="$TMP/fakehome" XDG_RUNTIME_DIR="$TMP/run" TMPDIR="$TMP/tmp" \
    bash "$REPO/client/bin/devbox" setup "$@" 2>&1)" || rc=$?
}
rm -f "$KEY"
setup_cmd
assert_eq "0" "$rc" "devbox setup passes"
assert_eq "uv sync --locked --all-packages --directory app" "$(logged)" "and runs the default setup"
assert_eq "" "$(stepped)" "and no step"
assert_ok "and prints the setup line" contains $'==> setup\n==> setup: runs, this workspace has no key of a setup that passed\n==> setup: uv sync --locked --all-packages in app/' "$out"
assert_ok "its key is the key of devbox verify --local" test -s "$KEY"
setup_cmd
assert_eq "0" "$rc" "a second devbox setup passes"
assert_eq "" "$(logged)" "and runs nothing"
assert_ok "and says it skipped" contains "==> setup: skipped, app/uv.lock unchanged since the last setup here" "$out"
# The CI flow: the setup job runs devbox setup, and a step job that restored
# its outputs and key skips the setup in devbox verify --local.
CI=true verify --local --full
assert_eq "0" "$rc" "devbox verify --local under CI after devbox setup passes"
assert_eq "" "$(logged)" "and its setup skips on the key devbox setup wrote"
assert_eq "check" "$(stepped)" "and the step runs"
rm -rf "$CO/app/.venv"
setup_cmd
assert_eq "uv sync --locked --all-packages --directory app" "$(logged)" \
  "devbox setup with an equal key and no app/.venv runs the setup"
setup_cmd extra
assert_eq "2" "$rc" "devbox setup with an argument exits 2"
assert_ok "with its usage line" contains "usage: devbox setup" "$out"
assert_eq "" "$(logged)" "and runs nothing"
mkdir -p "$TMP/nogit"
IN="$TMP/nogit" GIT_CEILING_DIRECTORIES="$TMP" setup_cmd
assert_eq "2" "$rc" "devbox setup outside a git checkout exits 2"

# ── a failed setup ends the gate with its own status ────────────────────────
printf 'DEVBOX_PROJECT=app\nDEVBOX_SETUP="echo SETUP-FAILED; exit 7"\n' >"$CO/.devbox/config.env"
setup_cmd
assert_eq "7" "$rc" "a failed devbox setup exits with the setup's own status"
assert_ok "after its own output" contains $'==> setup\nSETUP-FAILED' "$out"
verify --local --setup --full
assert_eq "7" "$rc" "a failed setup exits with its own status, as a failed remote setup does"
assert_ok "after its own output" contains $'==> setup\nSETUP-FAILED' "$out"
assert_eq "" "$(stepped)" "and no step runs"
assert_fail "and devbox adds no line of its own" contains "devbox verify:" "$out"
export DEVBOX_STRICT=1
verify --local --setup --full
unset DEVBOX_STRICT
assert_eq "65" "$rc" "under DEVBOX_STRICT=1 it is 65, as a failed remote setup is"
assert_ok "with the strict line of a step before the gate" \
  contains "devbox verify: a step before the gate stopped with status 7" "$out"

printf '%d %d\n' "$TESTS_RUN" "$TESTS_FAILED"
