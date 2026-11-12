#!/bin/bash
# The client refuses a server that speaks a different protocol, proven with no
# host, no network and no docker.
#
# The damage a mismatch does is silent and shared, which is why the client
# refuses instead of warning. devbox_slug names the container, the volume, the
# Postgres role and the database, and devbox_pg_ident truncates that slug from
# the left to fit Postgres's 63-byte limit, keeping the last seven characters
# because they are the only part that tells two worktrees apart. A client and a
# server that disagree about either algorithm put two checkouts on ONE Postgres
# role while their container names stay distinct. devbox_pg_ident's own comment
# records that collision as already having happened once.
#
# The whole handshake is one ssh call, so a fake `ssh` first on PATH is enough
# to drive every outcome. Everything this file writes lives under one mktemp -d.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
# shellcheck source=tests/lib.sh
source ./lib.sh
REPO="$(cd .. && pwd)"
VERIFY="$REPO/client/libexec/devbox-verify"

TMP="$(mktemp -d)" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

# ── the fake host ────────────────────────────────────────────────────────────
#
# Answers the two things devbox-verify asks before it syncs anything, and
# nothing else. The master open (`-f -N`) is the reachability probe, which must
# succeed or the run exits 3 long before the handshake. The version verb answers
# whatever the scenario chose. Every later call (ensure-workspace, the lock)
# gets a silent exit 0, so a run that passes the handshake stops at the next
# step instead of reaching rsync or docker.
mkdir -p "$TMP/bin" "$TMP/home" "$TMP/run"
{ gate_stub_head; cat <<'FAKE'
case "$GATE_CMD" in
  version) printf '%s\n' "${FAKE_SERVER_VERSION-}" ;;
  *) exit 0 ;;
esac
FAKE
} > "$TMP/bin/ssh"
chmod +x "$TMP/bin/ssh"
gate_stub_keyscan "$TMP/bin"

# ── the fake checkout ────────────────────────────────────────────────────────
#
# devbox-verify starts with `git rev-parse --show-toplevel`, so the fixture has
# to be a real repository. It needs no commit: nothing before the handshake
# reads history.
CO="$TMP/checkout"
mkdir -p "$CO/.devbox"
git -C "$CO" init -q >/dev/null 2>&1
# One deployed target and the gate password, and nothing else. The host is a
# name no resolver will ever be asked about, because the fake ssh answers first.
printf 'DEVBOX_TARGETS=fixture\nDEVBOX_TARGET_FIXTURE=devbox-handshake-fixture\nDEVBOX_TARGET_FIXTURE_HOSTKEY=%s\nDEVBOX_GATE_PASSWORD=fixture-gate-password\n' "$GATE_STUB_PIN" >"$CO/.devbox.env"
# devbox_slug refuses a project that sanitizes to empty, so the config must set
# DEVBOX_PROJECT for the run to reach the handshake at all.
cat >"$CO/.devbox/config.env" <<'PROFILE'
DEVBOX_PROJECT=handshake-fixture
DEVBOX_WANT_TOKENS=1
DEVBOX_MIN_TOKENS=1
DEVBOX_SETUP=:
DEVBOX_VERIFY=:
PROFILE

# Read as text rather than sourced, so this test compares against the literal
# the shipped library carries.
proto="$(sed -n 's/^DEVBOX_PROTOCOL_VERSION=\(.*\)$/\1/p' "$REPO/lib/devbox-lib.sh")"
# The handshake's second field, computed the way devbox-runner computes it on a
# real host: the sha256 of the ONE shipped library, hex only, with no filename.
# The client fingerprints the copy it sourced, which is that same file, so this
# is the value that makes the two halves agree.
fp="$(sha256sum <"$REPO/lib/devbox-lib.sh" | cut -d' ' -f1)"
# A digest that is the right shape and another file: a host on another minor
# release of this protocol.
other_fp="$(printf 'a drifted library' | sha256sum | cut -d' ' -f1)"

out=""; rc=0
run_verify() {  # $1 is what the fake server answers to `devbox-runner version`
  out="$(cd "$CO" && FAKE_SERVER_VERSION="$1" PATH="$TMP/bin:$PATH" HOME="$TMP/home" XDG_RUNTIME_DIR="$TMP/run" bash "$VERIFY" 2>&1)"
  rc=$?
  return 0
}

contains()     { case "$2" in *"$1"*) return 0 ;; esac; return 1; }
not_contains() { case "$2" in *"$1"*) return 1 ;; esac; return 0; }

# ── a server that agrees ─────────────────────────────────────────────────────
#
# Asserted on the message, not on exit 0: the run is expected to fail a few
# lines later, when the fake host answers ensure-workspace with nothing. What
# matters is that it got past the handshake to reach that failure.
run_verify "$proto $fp"
assert_ok "a matching server gets past the handshake, to the workspace step" \
  contains "==> workspace" "$out"
assert_ok "a matching server is not called a mismatch" \
  not_contains "protocol mismatch" "$out"
assert_ok "a matching server is not called missing" \
  not_contains "did not report a protocol version" "$out"
assert_ok "a matching server's library is not called drifted" \
  not_contains "copies of devbox-lib.sh differ" "$out"

# ── a server that disagrees ──────────────────────────────────────────────────
#
# The message has to name BOTH numbers. A refusal that says only "mismatch"
# leaves the reader unable to tell which half is behind, and the fix differs:
# one is `devbox server install`, the other is a client upgrade.
run_verify "99 $fp"
assert_eq "5" "$rc" "a differing protocol version exits 5"
assert_ok "the refusal names this client's version" \
  contains "client speaks $proto" "$out"
assert_ok "the refusal names the server's version" \
  contains "server speaks 99" "$out"
assert_ok "and nothing was synced: the refusal comes before the workspace step" \
  not_contains "==> workspace" "$out"

# ── a server that answers nothing ────────────────────────────────────────────
#
# An older server has no version verb at all: devbox-runner prints its usage to
# stderr and exits 2, so the client reads an empty string. That is a server that
# predates the handshake, not one that disagrees, and it gets its own message.
run_verify ""
assert_eq "5" "$rc" "an empty answer exits 5"
assert_ok "the empty answer is reported as a missing or older server" \
  contains "predates the handshake" "$out"

# ── a server that answers something that is not a number ─────────────────────
#
# The same case in practice: a usage line on stdout, or any answer with a word
# in it. The client compares protocol versions as strings, so anything but
# digits is refused rather than compared.
run_verify "usage: devbox-runner {ensure-workspace|gc}"
assert_eq "5" "$rc" "a non-integer answer exits 5"
assert_ok "the non-integer answer is reported as a missing or older server" \
  contains "predates the handshake" "$out"

# ── one protocol, another library ────────────────────────────────────────────
#
# One protocol is one release major, and a host on another minor or patch
# release loads other library bytes. The run goes on: a refusal here forced
# every consumer to move its pin on every release that touched the library. A
# host that names no fingerprint is the same case.
run_verify "$proto $other_fp"
assert_ok "a host on another release of this protocol gets past the handshake" \
  contains "==> workspace" "$out"
assert_ok "and the run is not refused as a drifted library" \
  not_contains "differ" "$out"
run_verify "$proto"
assert_ok "a host that names no fingerprint gets past the handshake too" \
  contains "==> workspace" "$out"

# ── the gate password, before any handshake ──────────────────────────────────
#
# Between a password rotation and the update of each .devbox.env, a
# client with the old value gets exit 3 and this sentence, never a silent skip
# and never a handshake failure that sends the reader to reinstall a server.
export FAKE_OPEN_RC=255 FAKE_OPEN_ERR="devbox-gate@devbox-handshake-fixture: Permission denied (password)."
run_verify "$proto $fp"
unset FAKE_OPEN_RC FAKE_OPEN_ERR
assert_eq "3" "$rc" "a refused gate password exits 3"
assert_ok "and says the gate password was refused" contains "the gate password was refused" "$out"
assert_ok "and names the key to change" contains "DEVBOX_GATE_PASSWORD" "$out"
assert_ok "and nothing was synced" not_contains "==> workspace" "$out"

# A changed host key is exit 3 too, because the password must not go to
# whoever answered in its place.
export FAKE_OPEN_RC=255 FAKE_OPEN_ERR="Host key verification failed."
run_verify "$proto $fp"
unset FAKE_OPEN_RC FAKE_OPEN_ERR
assert_eq "3" "$rc" "a changed host key exits 3"
assert_ok "and names the pin it is not" \
  contains "is not the key DEVBOX_TARGET_FIXTURE_HOSTKEY in $CO/.devbox.env pins ($GATE_STUB_PIN)" "$out"

# The first contact with a host whose key is not its pin: a man in the middle on
# a cafe network, or a reinstalled host. The first build recorded whatever
# answered and sent it the gate password, which opens every target. Now the
# run exits 3 before any ssh that carries the password: the stub ssh records
# every argv, and none of them is the master open, a verb or the password path.
# The transport's own known_hosts, under the HOME every run here gets. Built in
# two steps so a path check does not read it as a home directory.
FAKE_HOME="$TMP/home"
KNOWN_HOSTS="$FAKE_HOME/.config/devbox/known_hosts"
rm -f "$KNOWN_HOSTS"
: >"$TMP/ssh.log"
export FAKE_KEYSCAN_OTHER=devbox-handshake-fixture SSH_LOG="$TMP/ssh.log"
run_verify "$proto $fp"
assert_eq "3" "$rc" "a first contact whose key is not the pin exits 3"
assert_ok "and names the target and both fingerprints" \
  contains "fixture: the host key of devbox-handshake-fixture is $GATE_STUB_OTHER_PIN, and DEVBOX_TARGET_FIXTURE_HOSTKEY in $CO/.devbox.env pins $GATE_STUB_PIN" "$out"
assert_ok "and says it may be an attack or a reinstalled host" \
  contains "It may be an attack on this network, or a reinstalled host" "$out"
assert_fail "no master was opened, so ssh never asked for the password" grep -qF -- "-f -N" "$TMP/ssh.log"
assert_fail "and no verb was sent" grep -qE "devbox-gate@devbox-handshake-fixture [a-z]" "$TMP/ssh.log"
assert_fail "and the key was not recorded" grep -qF "$GATE_STUB_OTHER_HOSTKEY" "$KNOWN_HOSTS"
out="$(cd "$CO" && DEVBOX_STRICT=1 FAKE_SERVER_VERSION="$proto $fp" PATH="$TMP/bin:$PATH" HOME="$TMP/home" XDG_RUNTIME_DIR="$TMP/run" bash "$VERIFY" 2>&1)"; rc=$?
assert_eq "75" "$rc" "under DEVBOX_STRICT=1 it is 75, the code of a refused password and a changed key"
unset FAKE_KEYSCAN_OTHER SSH_LOG
rm -f "$KNOWN_HOSTS"

# A .devbox.env with no gate password is refused before any ssh starts.
cp "$CO/.devbox.env" "$TMP/env.keep"
printf 'DEVBOX_TARGETS=fixture\nDEVBOX_TARGET_FIXTURE=devbox-handshake-fixture\nDEVBOX_TARGET_FIXTURE_HOSTKEY=%s\n' "$GATE_STUB_PIN" >"$CO/.devbox.env"
run_verify "$proto $fp"
assert_eq "2" "$rc" "a .devbox.env with no gate password exits 2"
assert_ok "and names the key" contains "sets no DEVBOX_GATE_PASSWORD" "$out"
# An older value that names root is refused by name.
printf 'DEVBOX_TARGETS=fixture\nDEVBOX_TARGET_FIXTURE=root@devbox-handshake-fixture\nDEVBOX_TARGET_FIXTURE_HOSTKEY=%s\nDEVBOX_GATE_PASSWORD=x\n' "$GATE_STUB_PIN" >"$CO/.devbox.env"
run_verify "$proto $fp"
assert_eq "2" "$rc" "a target address that names a user exits 2"
assert_ok "and says the user is always devbox-gate" contains "the user is always devbox-gate" "$out"
cp "$TMP/env.keep" "$CO/.devbox.env"

printf '%d %d\n' "$TESTS_RUN" "$TESTS_FAILED"
