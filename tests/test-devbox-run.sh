#!/bin/bash
# `devbox run -- <command>`: one command in the workspace, never on the laptop.
#
# Agents re-running one test had no remote route and ran pytest locally, with a
# load average far above the core count. A run that fell back to the laptop
# would put that load straight back, so the refusals are RUN here, and the
# remote plumbing is read from devbox-verify because it opens an ssh
# connection.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
# shellcheck source=tests/lib.sh
source ./lib.sh
REPO="$(cd .. && pwd)"
DEVBOX="$REPO/client/bin/devbox"
VERIFY="$REPO/client/libexec/devbox-verify"

TMP="$(mktemp -d)" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
contains() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }

# A checkout with no .devbox.env, which is where a gate falls back to local.
git -C "$TMP" init -q checkout
mkdir -p "$TMP/checkout/.devbox"
printf 'DEVBOX_PROJECT=run-fixture\nDEVBOX_SETUP=:\nDEVBOX_VERIFY=echo GATE-RAN\n' >"$TMP/checkout/.devbox/config.env"

rc=0
err="$(cd "$TMP/checkout" && "$DEVBOX" run 2>&1 >/dev/null)" || rc=$?
assert_eq "2" "$rc" "a run with no command exits 2"
assert_ok "and says how to name one" contains "devbox run [--target <name>] -- <command>" "$err"

rc=0
out="$(cd "$TMP/checkout" && "$DEVBOX" run -- touch "$TMP/ran-here" 2>"$TMP/err")" || rc=$?
assert_eq "2" "$rc" "a run with no devbox enabled exits 2"
assert_ok "and says it did not run here" contains "NOT running" "$(cat "$TMP/err")"
assert_fail "the command never ran on this machine" test -e "$TMP/ran-here"
assert_fail "and neither did the gate" contains "GATE-RAN" "$out"

# A .devbox.env that names no target replaces the removed DEVBOX_ENABLED=0.
printf '# no target\n' >"$TMP/checkout/.devbox.env"
rc=0
(cd "$TMP/checkout" && "$DEVBOX" run -- touch "$TMP/ran-here" >/dev/null 2>&1) || rc=$?
assert_eq "2" "$rc" "a run with a .devbox.env that names no target exits 2"
assert_fail "and runs nothing here" test -e "$TMP/ran-here"
rc=0
err="$(cd "$TMP/checkout" && "$DEVBOX" run --local -- true 2>&1 >/dev/null)" || rc=$?
assert_eq "2" "$rc" "a run refuses --local"
assert_ok "and says a run never runs here" contains "never runs on this machine" "$err"

# ── the command crosses intact ───────────────────────────────────────────────
#
# The client quotes with %q and the workspace evals stdin. Round-trip the same
# two steps over words a naive join would split or expand.
# A literal $HOME is one of the words under test.
# shellcheck disable=SC2016
script="$(printf '%q ' printf '<%s>' 'two words' '$HOME' "it's" 'a;b')"
got="$(printf '%s\n' "$script" | bash -c 'eval "$(cat)"')"
assert_eq "<two words><\$HOME><it's><a;b>" "$got" "every word reaches the workspace unchanged"

src="$(cat "$VERIFY")"
assert_ok "the client quotes the command with %q" contains "RUN_SCRIPT=\"\$(printf '%q ' \"\$@\")\"" "$src"
# RUN_SCRIPT is the literal source expression being checked.
# shellcheck disable=SC2016
assert_ok "the command travels on stdin after go, never in the ssh argv" \
  contains "printf 'go\\n%s\\n%s\\n' \"\$GATE_HEADER\" \"\$GATE_STDIN\"" "$src"
# shellcheck disable=SC2016
assert_ok "and stdin carries it after the hooks" \
  contains '"devbox_environment && $RUN_SCRIPT"' "$src"
assert_ok "a run sends the command mode, not the verify mode" \
  contains 'GATE_MODE="command"' "$src"
# Both are source text to find, not expansions.
# shellcheck disable=SC2016
assert_ok "a run asks the pool for its floor, not the gate's want" \
  contains 'devbox_gate_spawn run "$slug" "$DEVBOX_PROJECT" "$GRANT_WANT" "$DEVBOX_MIN_TOKENS"' "$src"
# shellcheck disable=SC2016
assert_ok "and GRANT_WANT is the floor in a run" \
  contains '[ "$RUN_MODE" = "1" ] && GRANT_WANT="$DEVBOX_MIN_TOKENS"' "$src"
# shellcheck disable=SC2016
assert_ok "a run has no queue ceiling, so no local fallback" \
  contains '[ "$RUN_MODE" = "1" ] && QUEUE_WAIT=0' "$src"

printf '%d %d\n' "$TESTS_RUN" "$TESTS_FAILED"
