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
DEVBOX_VERIFY=:
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
assert_eq "$(cd "$WS" && devbox_setup_key)" "$(cat "$KEY" 2>/dev/null)" \
  "and writes the laptop's key to <key dir>/<project>.key"

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
assert_eq "second-line" "$out" "and the new text is what runs"

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
  got="$(setup_run "$prefix"; echo "rc=$?")"
  assert_eq "$want" "$got" "a failing line in the body behaves as today under '$prefix'"
done
DEVBOX_SETUP='export SETUP_MARK=set; mkdir -p node_modules'
hooks="$(cd "$WS" && devbox_hooks_script)"
out="$(cd "$WS" && printf '%s\n' "$hooks" | bash -c 'eval "$(cat)" && devbox_environment && devbox_setup && printf %s "$SETUP_MARK"')"
assert_eq "set" "$out" "what the setup exports is still set after devbox_setup"

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

# ── no inputs: the text is today's, byte for byte ────────────────────────────
#
# A host and a test that read the hooks see no change unless a project sets
# DEVBOX_SETUP_INPUTS. This is the text the function printed before the skip.
DEVBOX_ENVIRONMENT='export A=1'
DEVBOX_PROVISION='apt-get install -y x'
DEVBOX_SETUP='npm ci'
DEVBOX_VERIFY='npm test'
want="$(printf 'devbox_environment() {\nexport A=1\n}\ndevbox_provision() {\napt-get install -y x\n}\ndevbox_setup() {\nnpm ci\n}\ndevbox_verify() {\nnpm test\n}\n')"
assert_eq "$want" "$(DEVBOX_SETUP_INPUTS='' devbox_hooks_script)" "with DEVBOX_SETUP_INPUTS empty the hooks are today's text"
assert_eq "$want" "$(unset DEVBOX_SETUP_INPUTS; devbox_hooks_script)" "and with it unset"
assert_fail "and they name no key directory" contains "$DEVBOX_SETUP_KEY_DIR" "$(DEVBOX_SETUP_INPUTS='' devbox_hooks_script)"
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

printf '%d %d\n' "$TESTS_RUN" "$TESTS_FAILED"
