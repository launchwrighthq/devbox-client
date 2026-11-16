#!/bin/bash
# The setup skip of spec section 6.6: DEVBOX_SETUP runs again only when its
# inputs or its own text changed, or its outputs are gone. The hooks run the
# way gate-root runs them, a fresh bash that evals stdin, in a directory that
# stands in for the workspace project, with the key directory in this test's
# temp dir.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
# shellcheck source=tests/lib.sh
source ./lib.sh
REPO="$(cd .. && pwd)"
# shellcheck source=lib/devbox-lib.sh
source "$REPO/lib/devbox-lib.sh"
# shellcheck source=client/libexec/devbox-config
source "$REPO/client/libexec/devbox-config"

TMP="$(mktemp -d)" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
contains() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }

assert_eq "/home/dev/.devbox/setup" "$DEVBOX_SETUP_KEY_DIR" \
  "the key directory defaults to the workspace home volume"

WS="$TMP/ws"
mkdir -p "$WS"
DEVBOX_SETUP_KEY_DIR="$TMP/ws-home/.devbox/setup"
KEY="$DEVBOX_SETUP_KEY_DIR/app.key"
LOG="$TMP/setup.log"
export LOG
DEVBOX_PROJECT=app
DEVBOX_ENVIRONMENT=
# The setup counts its runs in $LOG and makes the outputs a real one makes.
# The setup text is the project's, expanded by the workspace bash, never here.
# shellcheck disable=SC2016
SETUP_OK='echo ran >>"$LOG"; mkdir -p node_modules; [ ! -f uv.lock ] || mkdir -p .venv'
DEVBOX_SETUP="$SETUP_OK"
DEVBOX_SETUP_INPUTS=package-lock.json
printf '{"lockfileVersion": 3}\n' >"$WS/package-lock.json"

# Emit the hooks from $WS, as devbox-verify does from the checkout root, then
# run them the way gate-root's setup entry does. $1, when given, goes before
# the entry, such as `set -e`. Prints the setup's output; returns its status.
setup_run() {
  local hooks
  hooks="$(cd "$WS" && devbox_hooks_script)" || return 99
  (cd "$WS" && printf '%s\n' "$hooks" | bash -c "${1:-:}"$'\n''eval "$(cat)" && devbox_environment && devbox_setup' 2>&1)
}
runs() { [ -f "$LOG" ] && wc -l <"$LOG" | tr -d ' ' || echo 0; }

# ── the first setup runs and writes the key ──────────────────────────────────
out="$(setup_run)"; rc=$?
assert_eq "0" "$rc" "the first setup passes"
assert_eq "1" "$(runs)" "and runs the project's setup"
assert_eq "==> setup: runs, this workspace has no key of a setup that passed" "$(head -n 1 <<<"$out")" \
  "and says why it runs, on the line before the setup's own output"
assert_eq "$(cd "$WS" && devbox_setup_key)" "$(head -n 1 "$KEY" 2>/dev/null)" \
  "and writes the laptop's key to <key dir>/<project>.key, on its first line"
assert_eq "$(cd "$WS" && devbox_setup_key_lines)" "$(tail -n +2 "$KEY" 2>/dev/null)" \
  "and the lines the key hashes after it"
assert_eq "$(cd "$WS" && devbox_setup_key)" \
  "$(tail -n +2 "$KEY" | sha256sum | cut -d ' ' -f 1)" \
  "and the key is the sha256 of those lines, the bytes it hashed before they were kept"

# ── unchanged inputs skip ────────────────────────────────────────────────────
out="$(setup_run)"; rc=$?
assert_eq "0" "$rc" "an unchanged setup passes"
assert_eq "==> setup: skipped, package-lock.json unchanged since the last setup here" "$out" \
  "and says it skipped, naming the inputs"
assert_eq "1" "$(runs)" "and does not run the project's setup"

# ── a changed input runs ─────────────────────────────────────────────────────
printf '{"lockfileVersion": 3, "packages": {}}\n' >"$WS/package-lock.json"
old_key="$(cat "$KEY")"
out="$(setup_run)"; rc=$?
assert_eq "0" "$rc" "a changed input passes"
assert_eq "2" "$(runs)" "and runs the project's setup"
assert_ok "and writes a new key" test "$(cat "$KEY")" != "$old_key"
setup_run >/dev/null
assert_eq "2" "$(runs)" "and the next run skips again"

# ── an equal key with no node_modules/ runs ──────────────────────────────────
rm -rf "$WS/node_modules"
out="$(setup_run)"; rc=$?
assert_eq "0" "$rc" "a setup whose node_modules/ is gone passes"
assert_eq "3" "$(runs)" "and runs even though the key is equal"
assert_ok "and makes node_modules/ again" test -d "$WS/node_modules"

# ── a uv.lock wants .venv/ ───────────────────────────────────────────────────
DEVBOX_SETUP_INPUTS="package-lock.json uv.lock"
printf 'version = 1\n' >"$WS/uv.lock"
setup_run >/dev/null
assert_eq "4" "$(runs)" "a new input in the list runs the setup"
out="$(setup_run)"
assert_eq "==> setup: skipped, package-lock.json uv.lock unchanged since the last setup here" "$out" \
  "and with .venv/ in place the next run skips, naming both inputs"
rm -rf "$WS/.venv"
setup_run >/dev/null
assert_eq "5" "$(runs)" "an equal key with a uv.lock and no .venv/ runs"
rm -f "$WS/uv.lock"
DEVBOX_SETUP_INPUTS=package-lock.json

# ── no lock file: the outputs check passes ───────────────────────────────────
mv "$WS/package-lock.json" "$TMP/lock.saved"
rm -rf "$WS/node_modules"
setup_run >/dev/null
assert_eq "6" "$(runs)" "a missing input file is part of the key, never an error, and the setup runs"
rm -rf "$WS/node_modules"
out="$(setup_run)"
assert_eq "6" "$(runs)" "with no lock file, no output is required, so the next run skips"
assert_ok "and says so" contains "==> setup: skipped" "$out"
mv "$TMP/lock.saved" "$WS/package-lock.json"
setup_run >/dev/null
assert_eq "7" "$(runs)" "the lock file coming back changes the key and runs the setup"

# ── a changed DEVBOX_SETUP runs ──────────────────────────────────────────────
DEVBOX_SETUP="$SETUP_OK; echo second-line"
out="$(setup_run)"
assert_eq "8" "$(runs)" "a changed DEVBOX_SETUP text runs the setup with unchanged inputs"
assert_eq "==> setup: runs, DEVBOX_SETUP changed since the setup that wrote this workspace's key
second-line" "$out" "and the new text is what runs, after the line that names DEVBOX_SETUP"

# ── a failed setup leaves no key and returns non-zero ────────────────────────
assert_ok "a key exists before the failing setup" test -f "$KEY"
# The setup text is the project's, expanded by the workspace bash, never here.
# shellcheck disable=SC2016
DEVBOX_SETUP='echo ran >>"$LOG"; return 7'
out="$(setup_run)"; rc=$?
assert_eq "7" "$rc" "a failed setup returns its own status"
assert_fail "and leaves no key file" test -f "$KEY"
assert_eq "9" "$(runs)" "and it did run"
setup_run >/dev/null
assert_eq "10" "$(runs)" "so the next run tries the setup again"
# The setup text is the project's, expanded by the workspace bash, never here.
# shellcheck disable=SC2016
DEVBOX_SETUP='echo ran >>"$LOG"; false; echo after-false >>"$LOG"'
out="$(setup_run 'set -e')"; rc=$?
assert_ok "under set -e a failed line stops the setup with a non-zero status" test "$rc" -ne 0
assert_fail "and the line after it never runs" grep -q after-false "$LOG"
assert_fail "and no key is written" test -f "$KEY"

# ── the body keeps the shell context it has today ────────────────────────────
#
# The same body, under the unmodified function: today's text has no skip. A
# body run under `||` or `if` would ignore set -e, so its later lines would
# run, and a body run in a subshell would lose what it exports.
today() {  # $1 the entry prefix; the hooks with no inputs, run the same way
  local hooks
  hooks="$(cd "$WS" && DEVBOX_SETUP_INPUTS='' devbox_hooks_script)"
  (cd "$WS" && printf '%s\n' "$hooks" | bash -c "${1:-:}"$'\n''eval "$(cat)" && devbox_environment && devbox_setup' 2>&1)
}
for prefix in : 'set -e'; do
  DEVBOX_SETUP='false; echo after-false'
  rm -f "$KEY"
  want="$(today "$prefix"; echo "rc=$?")"
  got="$(setup_run "$prefix" >"$TMP/got"; echo "rc=$?")"
  got="$(sed '1{/^==> setup: runs, this workspace has no key of a setup that passed$/d;}' "$TMP/got"; echo "$got")"
  assert_eq "$want" "$got" "a failing line in the body behaves as today under '$prefix', after the line that says why it runs"
done
DEVBOX_SETUP='export SETUP_MARK=set; mkdir -p node_modules'
hooks="$(cd "$WS" && devbox_hooks_script)"
out="$(cd "$WS" && printf '%s\n' "$hooks" | bash -c 'eval "$(cat)" && devbox_environment && devbox_setup && printf %s "$SETUP_MARK"')"
assert_eq "set" "$(tail -n 1 <<<"$out")" "what the setup exports is still set after devbox_setup"

# ── a key directory that cannot be written ───────────────────────────────────
DEVBOX_SETUP="$SETUP_OK"
saved_dir="$DEVBOX_SETUP_KEY_DIR"
printf 'a file\n' >"$TMP/blocker"
DEVBOX_SETUP_KEY_DIR="$TMP/blocker/setup"
out="$(setup_run)"; rc=$?
assert_eq "0" "$rc" "a setup that passed still passes when its key cannot be written"
assert_ok "and says the next gate runs the setup again" \
  contains "could not be written, so the next gate here runs the setup again" "$out"
DEVBOX_SETUP_KEY_DIR="$saved_dir"

# ── the key ──────────────────────────────────────────────────────────────────
key_of() { (cd "$WS" && DEVBOX_SETUP_INPUTS="$1" devbox_setup_key); }
key="$(key_of package-lock.json)"
assert_eq "64" "${#key}" "the key is 64 characters"
assert_eq "" "${key//[0-9a-f]/}" "of lowercase hex"
printf 'a\n' >"$WS/one"; printf 'b\n' >"$WS/two"; : >"$WS/empty"
assert_ok "the order of the inputs is part of the key" test "$(key_of "one two")" != "$(key_of "two one")"
assert_ok "a missing file and an empty file give two keys" test "$(key_of "empty")" != "$(key_of "absent")"
assert_eq "$(key_of "one absent")" "$(key_of "one absent")" "the key is the same for the same files"
mkdir -p "$WS/adir"
rc=0
err="$(key_of adir 2>&1)" || rc=$?
assert_eq "1" "$rc" "an input that is a directory is refused"
assert_ok "naming it" contains "DEVBOX_SETUP_INPUTS names adir, which is not a file" "$err"
rc=0
(cd "$WS" && DEVBOX_SETUP_INPUTS=adir devbox_hooks_script) >/dev/null 2>&1 || rc=$?
assert_eq "1" "$rc" "and devbox_hooks_script fails with it"
assert_eq "" "$(cd "$WS" && DEVBOX_SETUP_INPUTS=adir devbox_hooks_script 2>/dev/null)" \
  "before it prints a line of the hooks"

# ── no inputs: the text before the skip, and the key file removed ───────────
#
# A host and a test that read the hooks see the text the function printed
# before the skip, unless a project sets DEVBOX_SETUP_INPUTS, calls
# devbox_install_locks or holds a lock file below its root. The one line more
# removes the key file of an earlier keyed setup, so a workspace whose setup
# ran with no inputs is no seed source (D9 of the 4.0.1 spec).
DEVBOX_ENVIRONMENT='export A=1'
DEVBOX_PROVISION='apt-get install -y x'
DEVBOX_SETUP='npm ci'
want="$(printf 'devbox_environment() {\nexport A=1\n}\ndevbox_provision() {\napt-get install -y x\n}\ndevbox_setup() {\nrm -f -- %s || return\nnpm ci\n}\ndevbox_verify() {\necho "devbox: no step plan reached the workspace, so nothing ran" >&2\nreturn 2\n}\n' "$KEY")"
assert_eq "$want" "$(DEVBOX_SETUP_INPUTS='' devbox_hooks_script)" \
  "with DEVBOX_SETUP_INPUTS empty the hooks are the text before the skip, after a removal of the key file"
assert_eq "$want" "$(unset DEVBOX_SETUP_INPUTS; devbox_hooks_script)" "and with it unset"
assert_fail "and they write no key" contains "_devbox_setup_want" "$(DEVBOX_SETUP_INPUTS='' devbox_hooks_script)"
# A probe's setup, which devbox-probe sends with no inputs, in a workspace a
# keyed setup left a key in.
DEVBOX_PROVISION=
DEVBOX_SETUP="$SETUP_OK"
DEVBOX_SETUP_INPUTS=package-lock.json
setup_run >/dev/null
assert_ok "a keyed setup leaves a key file" test -f "$KEY"
before="$(runs)"
hooks="$(cd "$WS" && DEVBOX_SETUP_INPUTS='' devbox_hooks_script)"
# The hooks are the workspace's text, expanded by its bash, never here.
# shellcheck disable=SC2016
out="$(cd "$WS" && printf '%s\n' "$hooks" | bash -c 'eval "$(cat)" && devbox_environment && devbox_setup' 2>&1)"; rc=$?
assert_eq "0" "$rc" "a setup with no inputs passes"
assert_eq "$((before + 1))" "$(runs)" "and runs the project's setup"
assert_fail "and no key file survives it" test -e "$KEY"
setup_run >/dev/null
assert_eq "$((before + 2))" "$(runs)" "so the next keyed setup runs, and writes a key again"
assert_ok "  the key" test -f "$KEY"
DEVBOX_PROVISION='apt-get install -y x'
DEVBOX_PROVISION=
assert_ok "with inputs set, the hooks name the key file" \
  contains "$DEVBOX_SETUP_KEY_DIR/app.key" "$(cd "$WS" && devbox_hooks_script)"

# ── a lock file the inputs do not name asks for no output ───────────────────
# A lock file the setup does not install gets no output, and the skip once
# tested every root lock file, so the whole setup ran on every gate.
DEVBOX_SETUP="$SETUP_OK"
DEVBOX_SETUP_INPUTS=package-lock.json
printf 'version = 1\n' >"$WS/uv.lock"
setup_run >/dev/null
rm -rf "$WS/.venv"
before="$(runs)"
out="$(setup_run)"
assert_eq "$before" "$(runs)" "a uv.lock the inputs do not name asks for no .venv/, so the setup skips"
assert_eq "==> setup: skipped, package-lock.json unchanged since the last setup here" "$out" "and says so"

# ── a setup that runs says why ───────────────────────────────────────────────
# D9 of docs/specs/2026-11-15-gate-fixes-4-0-1-design.md. Projects ran their
# whole setup after a seed with the lock files of the seed's source, and
# a key of one hash could not say which input differed. The first line of each
# run names it, from the lines the key file keeps after the key.
why() { local o; o="$(setup_run)"; head -n 1 <<<"$o"; }
rm -rf "$WS/node_modules"
assert_eq "==> setup: runs, the key matches, and ./node_modules is missing" "$(why)" \
  "an equal key with node_modules/ gone names the missing output"
DEVBOX_SETUP_INPUTS="package-lock.json uv.lock"
setup_run >/dev/null
rm -rf "$WS/node_modules" "$WS/.venv"
assert_eq "==> setup: runs, the key matches, and ./node_modules ./.venv are missing" "$(why)" \
  "and two missing outputs are both named"
printf '{"lockfileVersion": 3, "name": "changed"}\n' >"$WS/package-lock.json"
assert_eq "==> setup: runs, package-lock.json changed since the setup that wrote this workspace's key" "$(why)" \
  "a changed input is named"
DEVBOX_SETUP_INPUTS="uv.lock package-lock.json"
assert_eq "==> setup: runs, the order of DEVBOX_SETUP_INPUTS changed since the setup that wrote this workspace's key" "$(why)" \
  "the same inputs in another order name the order"
printf 'echo setup\n' >"$WS/setup.sh"
DEVBOX_SETUP_INPUTS="uv.lock package-lock.json setup.sh"
assert_eq "==> setup: runs, setup.sh changed since the setup that wrote this workspace's key" "$(why)" \
  "an input new to the list is named"
DEVBOX_SETUP_INPUTS="uv.lock package-lock.json"
assert_eq "==> setup: runs, setup.sh changed since the setup that wrote this workspace's key" "$(why)" \
  "and so is an input that left the list"
rm -f "$WS/uv.lock"
assert_eq "==> setup: runs, uv.lock changed since the setup that wrote this workspace's key" "$(why)" \
  "an input deleted from the checkout is named once"
printf 'version = 1\n' >"$WS/uv.lock"
setup_run >/dev/null
printf '{"lockfileVersion": 3, "name": "changed again"}\n' >"$WS/package-lock.json"
DEVBOX_SETUP="$SETUP_OK; echo third-line"
assert_eq "==> setup: runs, DEVBOX_SETUP package-lock.json changed since the setup that wrote this workspace's key" "$(why)" \
  "a changed DEVBOX_SETUP and a changed input are both named"
# A key file that an older client wrote holds the key alone. It still skips
# when it matches, and when it does not, the line says that nothing names why.
DEVBOX_SETUP="$SETUP_OK"
setup_run >/dev/null
(cd "$WS" && devbox_setup_key) >"$KEY"
out="$(setup_run)"
assert_eq "==> setup: skipped, uv.lock package-lock.json unchanged since the last setup here" "$out" \
  "a key file of the key alone, as an older client wrote it, still skips when it matches"
printf '0000000000000000000000000000000000000000000000000000000000000000\n' >"$KEY"
assert_eq "==> setup: runs, the key in this workspace differs, and the client that wrote it kept no inputs to compare" "$(why)" \
  "and when it differs the line says no input can be named"
DEVBOX_SETUP_INPUTS=package-lock.json

# ── no DEVBOX_SETUP: the client installs the lock files ─────────────────────
#
# Every project wrote `uv sync` and `npm ci` beside each lock file in a setup
# of its own. A checkout with app/uv.lock and web/package-lock.json, a third
# lock file under node_modules/ that is never installed, and stubs of uv and
# npm that log their arguments and make the outputs a real install makes.
CO="$TMP/checkout"
mkdir -p "$CO/.devbox" "$CO/app" "$CO/web/node_modules/dep" "$TMP/bin"
printf 'DEVBOX_PROJECT=app\n' >"$CO/.devbox/config.env"
printf 'verify -- :\n' >"$CO/.devbox/steps"
printf 'version = 1\n' >"$CO/app/uv.lock"
printf '{"lockfileVersion": 3}\n' >"$CO/web/package-lock.json"
printf '{"lockfileVersion": 3}\n' >"$CO/web/node_modules/dep/package-lock.json"
git -C "$CO" init -q
git -C "$CO" add -f .devbox/config.env app/uv.lock web/package-lock.json web/node_modules/dep/package-lock.json
# The stubs' text is expanded by the bash that runs them, never here.
# shellcheck disable=SC2016
printf '#!/bin/bash\necho "uv $*" >>"$LOG"\nmkdir -p "${5:-.}/.venv"\n' >"$TMP/bin/uv"
# shellcheck disable=SC2016
printf '#!/bin/bash\necho "npm $*" >>"$LOG"\nmkdir -p "${3:-.}/node_modules"\n' >"$TMP/bin/npm"
chmod +x "$TMP/bin/uv" "$TMP/bin/npm"
rm -f "$LOG"
DEVBOX_SETUP_KEY_DIR="$TMP/co-home/.devbox/setup"
default_load() {  # prints DEVBOX_SETUP|DEVBOX_SETUP_INPUTS after a load in $CO
  (cd "$CO" && unset DEVBOX_SETUP DEVBOX_SETUP_INPUTS && devbox_config_load &&
    printf '%s|%s' "$DEVBOX_SETUP" "$DEVBOX_SETUP_INPUTS")
}
default_run() {
  local hooks
  hooks="$(cd "$CO" && unset DEVBOX_SETUP DEVBOX_SETUP_INPUTS && devbox_config_load && devbox_hooks_script)" || return 99
  (cd "$CO" && printf '%s\n' "$hooks" | PATH="$TMP/bin:$PATH" bash -c 'set -e'$'\n''eval "$(cat)" && devbox_environment && devbox_setup' 2>&1)
}
assert_eq "devbox_install_locks|app/uv.lock web/package-lock.json" "$(default_load)" \
  "a config with no DEVBOX_SETUP installs its lock files, and keys the skip on them"
out="$(default_run)"; rc=$?
assert_eq "0" "$rc" "the default setup passes"
assert_eq "uv sync --locked --all-packages --directory app
npm ci --prefix web --no-audit --no-fund" "$(cat "$LOG")" \
  "and runs uv sync in app/ and npm ci in web/, and nothing under node_modules/"
assert_ok "and names each install" contains "==> setup: uv sync --locked --all-packages in app/" "$out"
out="$(default_run)"
assert_eq "==> setup: skipped, app/uv.lock web/package-lock.json unchanged since the last setup here" "$out" \
  "an unchanged checkout skips the default setup"
# The key file a client that installed another way wrote: another install line,
# and so another key.
co_key="$DEVBOX_SETUP_KEY_DIR/app.key"
{ printf '%064d\n' 0; tail -n +2 "$co_key" | sed 's/^install .*/install 0000/'; } >"$co_key.new"
mv "$co_key.new" "$co_key"
out="$(default_run)"
assert_eq "==> setup: runs, the client's install of the lock files changed since the setup that wrote this workspace's key" \
  "$(head -n 1 <<<"$out")" "a key a client with another install wrote names the install"

# ── a .venv symlink below the root is removed before the setup ──────────────
rm -rf "$CO/app/.venv"
ln -s /nonexistent/laptop/venv "$CO/app/.venv"
rm -f "$LOG"
default_run >/dev/null
assert_fail "a .venv symlink in a lock file's folder is removed" test -L "$CO/app/.venv"
assert_ok "and the setup builds a real one, because the skip saw no output" test -d "$CO/app/.venv"
assert_ok "with uv sync" grep -qx "uv sync --locked --all-packages --directory app" "$LOG"

# ── a project's own setup keeps its text, and gains the repair ──────────────
hooks="$(cd "$CO" && DEVBOX_SETUP='make deps' DEVBOX_SETUP_INPUTS='' devbox_hooks_script)"
assert_ok "a project's own setup keeps its command" contains $'_devbox_repair_links\nmake deps\n}' "$hooks"
assert_fail "and gets no install function it does not call" contains "devbox_install_locks()" "$hooks"
hooks="$(cd "$CO" && DEVBOX_SETUP='devbox_install_locks && make models' DEVBOX_SETUP_INPUTS='' \
  DEVBOX_SETUP_LOCKS=$'app/uv.lock\n' devbox_hooks_script)"
assert_ok "a setup that composes the install gets it" contains "_devbox_install_lock app/uv.lock || return" "$hooks"
rc=0
(cd "$CO" && unset DEVBOX_SETUP_LOCKS && DEVBOX_SETUP=devbox_install_locks devbox_hooks_script) >/dev/null 2>&1 || rc=$?
assert_eq "1" "$rc" "an install whose lock files no config load listed is refused"

# ── DEVBOX_SETUP_INPUTS chooses the lock files the default installs ─────────
# A project may track a lock file its setup never installed.
printf 'DEVBOX_PROJECT=app\nDEVBOX_SETUP_INPUTS=app/uv.lock\n' >"$CO/.devbox/config.env"
rm -f "$LOG"
default_run >/dev/null
assert_eq "uv sync --locked --all-packages --directory app" "$(cat "$LOG")" \
  "a lock file DEVBOX_SETUP_INPUTS names is installed, and one it does not name is not"
printf 'DEVBOX_PROJECT=app\n' >"$CO/.devbox/config.env"

# ── pnpm and yarn lock files: the default installs them ─────────────────────
#
# A pnpm-lock.yaml or a yarn.lock with no DEVBOX_SETUP was refused, so every
# such project wrote its own install. pnpm at the root, yarn berry (a
# .yarnrc.yml beside the lock file) in berry/, yarn classic in classic/. The
# stubs log their arguments and the folder they ran in, and make node_modules/
# there, as a real install does.
printf 'lockfileVersion: 9\n' >"$CO/pnpm-lock.yaml"
mkdir -p "$CO/berry" "$CO/classic"
printf '# yarn lockfile v1\n' >"$CO/berry/yarn.lock"
printf 'nodeLinker: node-modules\n' >"$CO/berry/.yarnrc.yml"
printf '# yarn lockfile v1\n' >"$CO/classic/yarn.lock"
git -C "$CO" add pnpm-lock.yaml berry/yarn.lock berry/.yarnrc.yml classic/yarn.lock
# shellcheck disable=SC2016  # expanded by the bash that runs the stub, never here
printf '#!/bin/bash\necho "pnpm $*" >>"$LOG"\nmkdir -p "${4:-.}/node_modules"\n' >"$TMP/bin/pnpm"
# shellcheck disable=SC2016  # expanded by the bash that runs the stub, never here
printf '#!/bin/bash\necho "yarn $* in ${PWD##*/}" >>"$LOG"\nmkdir -p node_modules\n' >"$TMP/bin/yarn"
chmod +x "$TMP/bin/pnpm" "$TMP/bin/yarn"
assert_eq "devbox_install_locks|app/uv.lock berry/yarn.lock classic/yarn.lock pnpm-lock.yaml web/package-lock.json" \
  "$(default_load)" "a tracked pnpm-lock.yaml and yarn.lock join the default install and its skip key"
rm -f "$LOG"
out="$(default_run)"; rc=$?
assert_eq "0" "$rc" "the default setup with pnpm and yarn lock files passes"
assert_ok "pnpm installs beside pnpm-lock.yaml, frozen" grep -qx "pnpm install --frozen-lockfile --dir ." "$LOG"
assert_ok "yarn berry installs in its folder with --immutable" grep -qx "yarn install --immutable in berry" "$LOG"
assert_ok "yarn classic installs in its folder with --frozen-lockfile" grep -qx "yarn install --frozen-lockfile in classic" "$LOG"
assert_ok "and the setup names each install" contains "==> setup: yarn install --immutable in berry/" "$out"
out="$(default_run)"
assert_ok "an unchanged checkout skips the setup" contains "==> setup: skipped," "$out"
rm -rf "$CO/classic/node_modules"
rm -f "$LOG"
out="$(default_run)"
assert_ok "a yarn.lock whose node_modules/ is gone runs the setup again" \
  grep -qx "yarn install --frozen-lockfile in classic" "$LOG"
rm -rf "$CO/node_modules"
rm -f "$LOG"
default_run >/dev/null
assert_ok "and so does a pnpm-lock.yaml whose node_modules/ is gone" grep -qx "pnpm install --frozen-lockfile --dir ." "$LOG"

# A machine without pnpm: a PATH of the stubs but pnpm, and the few system
# tools the hooks call. The setup must fail by name, never run the gate with
# no dependencies.
mkdir -p "$TMP/nopnpm"
for tool in bash cat mkdir rm mv; do ln -sf "$(command -v "$tool")" "$TMP/nopnpm/$tool"; done
cp "$TMP/bin/uv" "$TMP/bin/npm" "$TMP/bin/yarn" "$TMP/nopnpm/"
rm -rf "$CO/node_modules"
hooks="$(cd "$CO" && unset DEVBOX_SETUP DEVBOX_SETUP_INPUTS && devbox_config_load && devbox_hooks_script)"
rc=0
# shellcheck disable=SC2016  # the hooks text is expanded by the bash -c, never here
out="$(cd "$CO" && printf '%s\n' "$hooks" | PATH="$TMP/nopnpm" "$(command -v bash)" -c 'set -e'$'\n''eval "$(cat)" && devbox_environment && devbox_setup' 2>&1)" || rc=$?
assert_ok "a pnpm-lock.yaml on a machine without pnpm fails the setup" test "$rc" -ne 0
assert_ok "naming the lock file and the tool" \
  contains "devbox: pnpm-lock.yaml needs pnpm, which this machine does not have" "$out"
assert_fail "and writes no key" test -f "$DEVBOX_SETUP_KEY_DIR/app.key"

# ── DEVBOX_SETUP_OUTPUTS ─────────────────────────────────────────────────────
#
# The outputs a setup writes beside no lock file. A CI cache restores them
# with the key file, so the skip asks for each of them, as it asks for
# node_modules/ beside a lock file.
outputs_load() {  # prints DEVBOX_SETUP_OUTPUTS after a load of the config.env on stdin
  cat >"$CO/.devbox/config.env"
  (cd "$CO" && devbox_config_load && printf '%s' "$DEVBOX_SETUP_OUTPUTS")
}
assert_eq "models ~/.cache/ms-playwright" "$(outputs_load <<<'DEVBOX_PROJECT=app
DEVBOX_SETUP_OUTPUTS="models ~/.cache/ms-playwright"')" "a path of the checkout and a path under ~/ are read"
assert_eq "" "$(DEVBOX_SETUP_OUTPUTS=models outputs_load <<<'DEVBOX_PROJECT=app')" \
  "an exported DEVBOX_SETUP_OUTPUTS is not read: the committed file alone names the outputs"
# shellcheck disable=SC2088  # each word is the literal text of a config line, never a path to expand
for bad in /var/cache ../up '~' '~/../x' '-x' 'a*b'; do
  rc=0
  err="$(outputs_load <<<"DEVBOX_PROJECT=app
DEVBOX_SETUP_OUTPUTS='$bad'" 2>&1)" || rc=$?
  assert_eq "2" "$rc" "DEVBOX_SETUP_OUTPUTS '$bad' is refused with exit 2"
  assert_ok "naming it" contains "refusing DEVBOX_SETUP_OUTPUTS '$bad'" "$err"
done
cat >"$CO/.devbox/config.env" <<'EOF'
DEVBOX_PROJECT=app
DEVBOX_SETUP='echo ran >>"$LOG"; mkdir -p models "$HOME/cache"'
DEVBOX_SETUP_INPUTS=app/uv.lock
DEVBOX_SETUP_OUTPUTS="models ~/cache"
EOF
mkdir -p "$TMP/outhome"
outputs_run() {
  local hooks
  hooks="$(cd "$CO" && devbox_config_load && devbox_hooks_script)" || return 99
  (cd "$CO" && printf '%s\n' "$hooks" | HOME="$TMP/outhome" bash -c 'eval "$(cat)" && devbox_environment && devbox_setup' 2>&1)
}
rm -f "$LOG"
outputs_run >/dev/null
assert_eq "1" "$(runs)" "a setup with DEVBOX_SETUP_OUTPUTS runs"
out="$(outputs_run)"
assert_eq "1" "$(runs)" "and with every output in place the next run skips"
assert_ok "and says so" contains "==> setup: skipped, app/uv.lock unchanged" "$out"
rm -rf "$CO/models"
outputs_run >/dev/null
assert_eq "2" "$(runs)" "an equal key with an output of the checkout gone runs the setup"
rm -rf "$TMP/outhome/cache"
outputs_run >/dev/null
assert_eq "3" "$(runs)" "and so does an equal key with an output under ~/ gone"
printf 'DEVBOX_PROJECT=app\n' >"$CO/.devbox/config.env"

printf '%d %d\n' "$TESTS_RUN" "$TESTS_FAILED"
