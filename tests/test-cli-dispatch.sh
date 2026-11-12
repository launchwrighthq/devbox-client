#!/bin/bash
# The dispatcher, run as a real process.
#
# Every subcommand is exec'd, so the dispatcher's exit code IS the gate's exit
# code, and `make verify` reads it. Exit 2 for a usage error and a usage text on
# stderr are therefore part of the contract, not cosmetics: a usage message on
# stdout would be captured as output by a caller that pipes this command, and an
# exit 0 for a misspelled subcommand would report a gate that never ran as green.
#
# Nothing here reaches a network. verify, compare, gc and doctor all open an ssh
# connection, so this file runs none of them: it runs the two verbs the
# dispatcher answers itself, and reads the rest out of the source.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
# shellcheck source=tests/lib.sh
source ./lib.sh
REPO="$(cd .. && pwd)"
DEVBOX="$REPO/client/bin/devbox"

# One private directory for the captured stderr, removed however this file
# exits. Nothing is written anywhere else.
TMP="$(mktemp -d)" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

# Run the dispatcher and split its three results, so an assertion can name the
# stream it is about. Stdout and stderr are kept apart on purpose: which stream
# the usage text lands on is one of the things under test.
out=""; err=""; rc=0
run_devbox() {
  out="$("$DEVBOX" "$@" 2>"$TMP/err")"; rc=$?
  err="$(cat "$TMP/err")"
  return 0
}

# Substring test as a command, so the three assertions in lib.sh are all this
# file needs. $2 is the haystack, and a failure prints it.
contains() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }

# ── no arguments ─────────────────────────────────────────────────────────────
run_devbox
assert_eq "2" "$rc" "no arguments exits 2"
assert_ok "no arguments prints the usage text on stderr" \
  contains "usage: devbox" "$err"
# A gate guard runs `$(DEVBOX) verify`; anything this program writes to stdout
# is data to whoever wrapped it. A usage text is a diagnostic, so it belongs on
# stderr even when it is the whole answer.
assert_eq "" "$out" "no arguments writes nothing to stdout"

# ── an unknown subcommand ────────────────────────────────────────────────────
run_devbox definitely-not-a-subcommand
assert_eq "2" "$rc" "an unknown subcommand exits 2"
assert_ok "an unknown subcommand is named back, so a typo is readable" \
  contains "unknown command: definitely-not-a-subcommand" "$err"

# ── version ──────────────────────────────────────────────────────────────────
#
# Two lines, because they answer two questions: which devbox this is, and which
# servers it can talk to. Each is one name and one value so a script can read
# either.
run_devbox version
assert_eq "0" "$rc" "version exits 0"
assert_eq "1" "$(printf '%s\n' "$out" | grep -cE '^devbox [0-9]+\.[0-9]+\.[0-9]+')" \
  "version prints one release line"
assert_eq "1" "$(printf '%s\n' "$out" | grep -cE '^protocol [0-9]+$')" \
  "version prints one protocol line"

# ── help ─────────────────────────────────────────────────────────────────────
run_devbox help
assert_eq "0" "$rc" "help exits 0"
usage_text="$out"
assert_ok "help prints the usage text on stdout, where a reader asked for it" \
  contains "usage: devbox" "$usage_text"

# ── server needs a second word ───────────────────────────────────────────────
#
# Installing a server is an explicit operator action, so a bare
# `devbox server` must not guess at install: clients are pinned per project, and
# a guess would let one project's pin decide every other project's server.
run_devbox server
assert_eq "2" "$rc" "server with no second word exits 2"
assert_ok "and says which second word it wants" \
  contains "server needs a subcommand" "$err"

# ── server install in a client-only tree ─────────────────────────────────────
#
# This client carries client/, lib/ and VERSION, and not the server
# installer. Before the dispatcher checked for it, that tree answered
# "reinstall the devbox client", and a reinstall brings back the same tree. The
# copy below is that tree, so the refusal is proven in a full checkout too.
mkdir -p "$TMP/client-only"
cp -R "$REPO/client" "$REPO/lib" "$REPO/VERSION" "$TMP/client-only/"
client_only_out="$("$TMP/client-only/client/bin/devbox" server install example-host 2>&1)"
client_only_rc=$?
assert_eq "1" "$client_only_rc" "server install in a client-only tree exits 1"
assert_ok "and says the tree carries no server half" \
  contains "carries no server half" "$client_only_out"

# ── status ───────────────────────────────────────────────────────────────────
#
# `devbox status` is the one read-only view of every target.
# It is run through the dispatcher with an option it refuses, which it does
# before it reads any file or opens any connection, so the run proves the arm
# reaches the program and passes its arguments on.
assert_ok "the usage text names status" contains "  status " "$usage_text"
# shellcheck disable=SC2016  # the `$LIBEXEC` and `$@` are the dispatcher's literal text, matched as written
assert_ok "the status arm asks runnable for its program first" \
  grep -qE '^[[:blank:]]*status\)[[:blank:]]+shift; runnable "\$LIBEXEC/devbox-status" "\$@"; exec "\$LIBEXEC/devbox-status" "\$@"' "$DEVBOX"
run_devbox status --definitely-not-an-option
assert_eq "2" "$rc" "devbox status with an unknown option exits 2, through the dispatcher"
assert_ok "and the refusal is the status program's own" \
  contains "devbox status: unknown option: --definitely-not-an-option" "$err"
assert_eq "" "$out" "and nothing reaches stdout"

# ── every promised subcommand reaches something real ─────────────────────────
#
# The list comes OUT of the usage text rather than being written again here. A
# subcommand added to that text without an implementation has to fail this test,
# and a list copied into this file would pass it. Each usage line is two spaces,
# the subcommand, then its description.
subs="$(printf '%s\n' "$usage_text" | awk '/^  [a-z]/ {print $1}' | sort -u)"
assert_ok "the usage text lists subcommands to check" \
  test "$(printf '%s\n' "$subs" | grep -c .)" -ge 5

# The path the dispatcher hands to exec, with its own $LIBEXEC and $REPO
# expanded to this checkout. Read from the source instead of run, because every
# subcommand with a program of its own opens an ssh connection.
exec_target() {
  local cmd="$1" t
  t="$(grep -oE 'exec "[^"]+"' "$DEVBOX" | grep -E "devbox-${cmd}\"|/${cmd}/" | head -1)"
  [ -n "$t" ] || return 1
  t="${t#exec \"}"; t="${t%\"}"
  t="${t//\$LIBEXEC/$REPO/client/libexec}"
  t="${t//\$REPO/$REPO}"
  printf '%s' "$t"
}

# The two verbs the dispatcher answers itself, named here rather than inferred,
# because both were run as real processes above and that run is their proof.
# Every OTHER subcommand the usage text names has a program of its own, so a
# verb added to this list without a run of its own fails the loop below instead
# of buying itself a weaker check.
answered_inline() { case "$1" in version|help) return 0 ;; esac; return 1; }

for cmd in $subs; do
  if answered_inline "$cmd"; then
    # No exec means the dispatcher answers this verb itself, which is what
    # version and help are. Both were run above, so the proof they work is
    # already made; what is left to prove is that the verb is matched by an arm
    # of its own rather than falling through to the unknown-command arm.
    assert_ok "usage names $cmd, and the dispatcher answers it itself" \
      grep -qE "^[[:blank:]]*\"?${cmd}\"?[)|]" "$DEVBOX"
    continue
  fi
  # A client-only tree has no server installer by design. Its server arm must
  # refuse by name, which the client-only copy above proves on the same code.
  if [ "$cmd" = server ] && [ ! -e "$REPO/server/install.sh" ]; then
    run_devbox server install example-host
    assert_ok "usage names server, and this client-only tree refuses it by name" \
      contains "carries no server half" "$err"
    continue
  fi
  # An exec target this file cannot read is a FAILING assertion. Downgrading
  # here to the arm-exists check is what let a dispatcher exec a program that
  # does not exist and still pass: the arm was there, and nothing looked on disk.
  if ! target="$(exec_target "$cmd")"; then
    assert_ok "usage names $cmd, and its exec target is readable from the dispatcher" false
    continue
  fi
  assert_ok "usage names $cmd, and ${target#"$REPO"/} exists and is executable" \
    test -x "$target"
done

printf '%d %d\n' "$TESTS_RUN" "$TESTS_FAILED"
