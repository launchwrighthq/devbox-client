#!/bin/bash
# require_safe_name, extracted from the shipped lib/devbox-lib.sh and RUN, one
# value at a time. It lived in client/libexec/devbox-verify until protocol 6,
# when devbox-gate and gate-root started applying it on the host as well.
#
# It guards four values that once reached a remote ROOT shell, and WORKTREE is
# the one nobody types: it is `basename $(git rev-parse --git-dir)`, so whoever
# ran `git worktree add` chose it, and two `cat >` lines in devbox-verify
# interpolated it UNQUOTED. git is not a guard there. The function's own comment
# records the measurement: `a;id`, `a|b`, a backquote and `$(...)` all reach
# that name verbatim.
#
# So this file holds both halves. The injection characters stay refused, and a
# legitimate git name is accepted. MEASURED: `+` was refused, which
# is legal in a git branch and a worktree directory, `make verify`'s `| tail`
# hid the exit 2, and the session read a refused gate as a gate that never ran
# and started a local one. A guard that refuses a real name costs the devbox the
# run it exists to take, which is the same failure as one that accepts a bad
# name, reached from the other side.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
# shellcheck source=tests/lib.sh
source ./lib.sh
VERIFY="$(cd .. && pwd)/lib/devbox-lib.sh"

# Extracted and run rather than matched as text: a grep for the character
# class keeps reporting green over a case branch that has stopped refusing.
contains() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }
# devbox_guard_exit is extracted beside it: every guard leaves through it, and a
# function extracted alone would die on "command not found", exit 127, which
# reads as a refusal of every value.
GUARD_EXIT="$(awk '/^devbox_guard_exit\(\) \{/,/^\}/' "$VERIFY")"
assert_ok "devbox_guard_exit was found in the shipped library" test -n "$GUARD_EXIT"
FN="$GUARD_EXIT"$'\n'"$(awk '/^require_safe_name\(\) \{/,/^\}/' "$VERIFY")"
assert_ok "require_safe_name was found in the shipped library" contains "require_safe_name()" "$FN"

# Each value runs in its own bash, because the function exits rather than
# returns: a refusal ends the shell it runs in.
accepts() { bash -c "$FN"$'\n''require_safe_name L "$1" O >/dev/null 2>&1' _ "$1"; }

# A refusal exits 2 and sets OWN_EXIT, the mark devbox-verify's strict mode
# reads to call that 2 a refused config (66) rather than a step that died (65).
# The EXIT trap prints the mark as the refusal leaves.
# shellcheck disable=SC2016  # expanded by the inner bash, not here
mark_out="$(bash -c "$FN"$'\n''trap '\''echo "mark=${OWN_EXIT-unset}"'\'' EXIT; require_safe_name L ".." O 2>/dev/null' 2>/dev/null)"
mark_rc=$?
assert_eq 2 "$mark_rc" "a refusal exits 2"
assert_eq "mark=1" "$mark_out" "and sets OWN_EXIT=1 for strict mode"

# ── what must be accepted ────────────────────────────────────────────────────
for good in \
  my-app \
  fix+example-branch \
  feat.v2_x \
  a \
  A-Z0-9 \
  worktree-fix+example \
  1+1
do
  assert_ok "accepts '$good'" accepts "$good"
done

# ── what must stay refused ───────────────────────────────────────────────────
#
# Every one of these is a shell metacharacter or an expansion in the unquoted
# position WORKTREE lands in, except the dot cases, which are the path the
# function's own comment names.
# The dollar expressions are literal shell source under test.
# shellcheck disable=SC2016
for bad in \
  'a;id' \
  'a|b' \
  'a&b' \
  'a`id`' \
  'a$(id)' \
  'a>b' \
  'a b' \
  'a*' \
  'a/b' \
  '$HOME' \
  '-rf' \
  '..' \
  '.' \
  '...' \
  ''
do
  assert_fail "refuses '$bad'" accepts "$bad"
done

# The refusal names the set it applies, so a developer whose worktree is
# rejected can see which character did it without reading this source.
msg="$(bash -c "$FN"$'\n''require_safe_name WORKTREE "a;id" /some/origin' _ 2>&1)"
# The dollar expressions are literal shell source under test.
# shellcheck disable=SC2016
assert_ok "the refusal names the allowed characters" \
  bash -c 'case "$1" in *"A-Za-z0-9._+-"*) exit 0 ;; *) exit 1 ;; esac' _ "$msg"

printf '%d %d\n' "$TESTS_RUN" "$TESTS_FAILED"
