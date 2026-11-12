#!/bin/bash
# The SECOND field of the version handshake, and the proof that every refusal
# stops before the host is touched.
#
# tests/test-protocol-handshake.sh pins the messages the client prints. This
# file pins the two things that message cannot show. The first is
# devbox_lib_fingerprint itself: it must refuse rather than return an empty
# string, because an empty string compares equal to another empty string, and
# `devbox doctor` would then report two different libraries as the same file.
# The second is WHERE a refusal lands: the fake ssh here records every argv it
# is handed, so a refusal is asserted to have opened no rsync and no
# ensure-workspace, not merely to have printed the right sentence.
#
# Only the protocol integer refuses. One protocol is one release major, so a
# host on another minor release loads another library and still runs the gate.
# A change that makes the two halves compute different slugs is a protocol bump,
# and tests/test-devbox-lib.sh pins the outputs that would show one.
#
# Hermetic. No ssh, no docker, no network, and everything written here lives
# under one mktemp -d.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
# shellcheck source=tests/lib.sh
source ./lib.sh
# shellcheck source=lib/devbox-lib.sh
source ../lib/devbox-lib.sh
REPO="$(cd .. && pwd)"
VERIFY="$REPO/client/libexec/devbox-verify"
LIB="$REPO/lib/devbox-lib.sh"

TMP="$(mktemp -d)" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

contains()     { case "$2" in *"$1"*) return 0 ;; esac; return 1; }
not_contains() { case "$2" in *"$1"*) return 1 ;; esac; return 0; }
is_hex64()     { [[ "$1" =~ ^[0-9a-f]{64}$ ]]; }

# ── devbox_lib_fingerprint, on its own ───────────────────────────────────────
#
# Every failure must be non-zero AND silent on stdout. Both halves matter: the
# status is what the client branches on, and an empty stdout is what stops a
# caller that ignored the status from carrying "" into a comparison that would
# then succeed against another "".
assert_fail "a library file that is not there is refused" \
  devbox_lib_fingerprint "$TMP/no-such-library.sh"
assert_eq "" "$(devbox_lib_fingerprint "$TMP/no-such-library.sh" 2>/dev/null)" \
  "and it prints no digest at all, so nothing can compare it to another empty one"

assert_fail "no argument at all is refused" devbox_lib_fingerprint
assert_eq "" "$(devbox_lib_fingerprint 2>/dev/null)" \
  "and an absent argument prints no digest either"

# A directory is readable and is not a library. It is the -f half of the guard,
# which a check written as `[ -r "$f" ]` alone would let through: sha256sum on a
# directory prints nothing and fails, and the digest would be the empty string.
assert_fail "a directory in place of a library file is refused" \
  devbox_lib_fingerprint "$TMP"

UNREADABLE="$TMP/unreadable-lib.sh"
cp "$LIB" "$UNREADABLE"
chmod 000 "$UNREADABLE"
# root reads a mode-000 file regardless, so this fixture cannot be built as
# root. It is asserted rather than skipped: a case that could not be built must
# fail loudly here, not disappear from the count and leave the suite green.
assert_ok "the unreadable fixture really is unreadable (this suite must not run as root)" \
  test ! -r "$UNREADABLE"
assert_fail "a library file that cannot be read is refused" \
  devbox_lib_fingerprint "$UNREADABLE"
assert_eq "" "$(devbox_lib_fingerprint "$UNREADABLE" 2>/dev/null)" \
  "and an unreadable file prints no digest either"

expected_fp="$(sha256sum <"$LIB" | cut -d' ' -f1)"
got_fp="$(devbox_lib_fingerprint "$LIB")"
assert_eq "$expected_fp" "$got_fp" \
  "a readable library fingerprints to the sha256 of its bytes"
assert_ok "the answer is hex and nothing else" is_hex64 "$got_fp"
# GNU sha256sum prints the filename beside the digest, and prefixes the WHOLE
# line with a backslash when that name holds a backslash or a newline. Either
# would travel over the handshake as part of the fingerprint and make a
# perfectly good library compare unequal to itself.
assert_ok "and carries no filename beside the digest" \
  not_contains " " "$got_fp"

# ── the fake host, which records ─────────────────────────────────────────────
#
# Answers the reachability probe and the version verb, and writes every argv it
# is handed to one log. The log is the point of this file: half of what is
# asserted below is that a round trip did NOT happen. rsync is stubbed into the
# same log, because the remote sync is the first thing that would write to
# another machine, and a handshake that ran after it would already have done
# the damage the handshake exists to prevent.
mkdir -p "$TMP/bin" "$TMP/home" "$TMP/run"
{ GATE_STUB_PREFIX='ssh ' gate_stub_head; cat <<'FAKE'
case "$GATE_CMD" in
  version) printf '%s\n' "${FAKE_SERVER_VERSION-}" ;;
  *) exit 0 ;;
esac
FAKE
} >"$TMP/bin/ssh"
cat >"$TMP/bin/rsync" <<'FAKE'
#!/bin/bash
printf 'rsync %s\n' "$*" >>"$SSH_LOG"
exit 0
FAKE
chmod +x "$TMP/bin/ssh" "$TMP/bin/rsync"
gate_stub_keyscan "$TMP/bin"

# ── a sha256sum that cannot fingerprint the library ──────────────────────────
#
# It fails for the LIBRARY only and delegates every other input to the real
# program. devbox_slug hashes a machine id and a path with the same sha256sum a
# few lines above the handshake, so a stub that failed unconditionally would end
# the run before the fingerprint was ever computed, and the case below would
# assert nothing about the fingerprint at all. Keyed on the bytes rather than on
# the call order, so it keeps testing the right call if the client ever computes
# its slug somewhere else.
mkdir -p "$TMP/nosum"
cat >"$TMP/nosum/sha256sum" <<'FAKE'
#!/bin/bash
# Only the stdin form is intercepted, which is the form devbox_lib_fingerprint
# uses. A stub that read stdin before looking at its arguments HUNG for the
# whole test timeout the moment a caller passed a filename instead, because
# nothing was ever going to close that descriptor.
[ "$#" -gt 0 ] && exec "$FAKE_SUM_REAL" "$@"
cat >"$FAKE_SUM_IN"
cmp -s "$FAKE_SUM_IN" "$FAKE_SUM_LIB" && exit 1
"$FAKE_SUM_REAL" <"$FAKE_SUM_IN"
FAKE
chmod +x "$TMP/nosum/sha256sum"

# ── the fake checkout ────────────────────────────────────────────────────────
#
# devbox-verify starts with `git rev-parse --show-toplevel`, so the fixture has
# to be a real repository. It needs no commit: nothing before the handshake
# reads history. The host is a name no resolver is ever asked about, because the
# fake ssh answers first.
CO="$TMP/checkout"
mkdir -p "$CO/.devbox"
git -C "$CO" init -q >/dev/null 2>&1
printf 'DEVBOX_TARGETS=fixture\nDEVBOX_TARGET_FIXTURE=devbox-fingerprint-fixture\nDEVBOX_TARGET_FIXTURE_HOSTKEY=%s\nDEVBOX_GATE_PASSWORD=fixture-gate-password\n' "$GATE_STUB_PIN" >"$CO/.devbox.env"
# devbox_slug refuses a project that sanitizes to empty, and devbox-verify
# refuses a profile with no token counts, so both are set: this file is about
# the handshake, not about those refusals. DEVBOX_REQUIRES is deliberately
# absent, so nothing between the handshake and the workspace step can be
# mistaken for it.
cat >"$CO/.devbox/config.env" <<'PROFILE'
DEVBOX_PROJECT=fingerprint-fixture
DEVBOX_WANT_TOKENS=1
DEVBOX_MIN_TOKENS=1
DEVBOX_SETUP=:
DEVBOX_VERIFY=:
PROFILE

# Read as text rather than taken from the sourced copy, so this file compares
# against the literal the shipped library carries.
proto="$(sed -n 's/^DEVBOX_PROTOCOL_VERSION=\(.*\)$/\1/p' "$LIB")"
fp="$expected_fp"
# The right shape and the wrong file: two copies of the library that drifted
# while both still claim the same protocol.
other_fp="$(printf 'a drifted library' | sha256sum | cut -d' ' -f1)"
# The right shape in length only. Sixty-four characters that are not hex is
# what a server answers when something other than devbox-runner replied, and it
# must be refused rather than compared and hoped over.
not_hex_fp="zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"

out=""; rc=0
run_verify() {  # $1 is what the fake server answers to `devbox-runner version`
  : >"$TMP/ssh.log"
  out="$(cd "$CO" && env PATH="$TMP/bin:$PATH" HOME="$TMP/home" XDG_RUNTIME_DIR="$TMP/run" SSH_LOG="$TMP/ssh.log" \
    FAKE_SERVER_VERSION="$1" bash "$VERIFY" 2>&1)"
  rc=$?
  return 0
}
# The same run with a sha256sum that refuses to fingerprint the library, and
# with a server that would otherwise agree on both fields.
run_verify_nosum() {
  : >"$TMP/ssh.log"
  out="$(cd "$CO" && env PATH="$TMP/nosum:$TMP/bin:$PATH" HOME="$TMP/home" XDG_RUNTIME_DIR="$TMP/run" SSH_LOG="$TMP/ssh.log" \
    FAKE_SUM_IN="$TMP/sum.in" FAKE_SUM_LIB="$LIB" FAKE_SUM_REAL="$(command -v sha256sum)" \
    FAKE_SERVER_VERSION="$1" bash "$VERIFY" 2>&1)"
  rc=$?
  return 0
}
# What reached the fake host. Asserted with the log rather than with the
# message, because a refusal that printed the right sentence after the sync had
# already run is still a refusal that touched another machine.
logged() { grep -qF -- "$1" "$TMP/ssh.log"; }

# ── both fields agree ────────────────────────────────────────────────────────
#
# Asserted on the step reached, not on exit 0: the run is expected to fail a few
# lines later, when the fake host answers ensure-workspace with nothing. What
# matters is that the handshake let it get that far. This case is also the
# positive control for the log, since a recorder that never records anything
# would make every "nothing was sent" assertion below pass for free.
run_verify "$proto $fp"
assert_ok "a matching pair gets past the handshake, to the workspace step" \
  contains "==> workspace" "$out"
# Since protocol 6 the version crosses as the first two words of the probe line.
assert_ok "the handshake did happen: the probe verb was asked" \
  logged "devbox-gate@devbox-fingerprint-fixture probe"
assert_ok "and the run went on to ensure-workspace, which the refusals below must not" \
  logged "ensure-workspace"
assert_ok "a matching pair is not called drifted" \
  not_contains "copies of devbox-lib.sh differ" "$out"

# ── the client cannot fingerprint its own library ────────────────────────────
#
# The fingerprint is a report, so a laptop whose sha256sum cannot read the
# library still runs the gate on a host of its protocol. The slug is computed
# with the same program, which the stub lets through.
run_verify_nosum "$proto $fp"
assert_ok "a client that cannot fingerprint its own library still reaches the workspace step" \
  contains "==> workspace" "$out"
assert_ok "and it did probe the server" logged "devbox-gate@devbox-fingerprint-fixture probe"

# ── the protocol integers differ ─────────────────────────────────────────────
#
# The message has to name BOTH numbers. A refusal that says only "mismatch"
# leaves the reader unable to tell which half is behind, and the fix differs:
# one is `devbox server install`, the other is a client upgrade.
run_verify "99 $fp"
assert_eq "5" "$rc" "a differing protocol integer exits 5"
assert_ok "the refusal names this client's integer" \
  contains "client speaks $proto" "$out"
assert_ok "the refusal names the server's integer" \
  contains "server speaks 99" "$out"
assert_fail "no workspace was created on the host" logged "ensure-workspace"
assert_fail "and nothing was synced" logged "rsync"

# ── the integers agree and the libraries do not ──────────────────────────────
#
# A host on another minor release of this protocol. The run goes on to the
# workspace: a refusal here forced every consumer to move its pin on every
# release that touched the library. A host that names no fingerprint is the
# same case.
run_verify "$proto $other_fp"
assert_ok "another library under one protocol reaches the workspace step" \
  contains "==> workspace" "$out"
assert_ok "and the run went on to ensure-workspace" logged "ensure-workspace"
run_verify "$proto"
assert_ok "a bare integer on this protocol reaches the workspace step" \
  contains "==> workspace" "$out"

# ── the server answers nothing ───────────────────────────────────────────────
#
# An older server has no version verb at all: devbox-runner prints its usage to
# stderr and exits 2, so the client reads an empty string.
run_verify ""
assert_eq "5" "$rc" "an empty answer exits 5"
assert_ok "the empty answer is reported as a missing or older server" \
  contains "did not report a protocol version" "$out"
assert_fail "no workspace was created on the host" logged "ensure-workspace"
assert_fail "and nothing was synced" logged "rsync"

# ── the server answers a fingerprint that is not hex ──────────────────────────
#
# Something other than devbox-runner wrote the second field. It is not a
# protocol question, so the integer decides, and the field is never compared as
# though it were a digest.
run_verify "$proto $not_hex_fp"
assert_ok "a non-hex fingerprint on this protocol reaches the workspace step" \
  contains "==> workspace" "$out"
run_verify "$proto not-a-digest"
assert_ok "a short non-hex fingerprint does too" contains "==> workspace" "$out"
run_verify "99 $not_hex_fp"
assert_eq "5" "$rc" "the protocol integer still refuses whatever the second field holds"
assert_fail "and no workspace was created on the host" logged "ensure-workspace"

printf '%d %d\n' "$TESTS_RUN" "$TESTS_FAILED"
