#!/bin/bash
# client/libexec/devbox-doctor, actually executed.
#
# No test in this suite ever ran that file. That is how it came to carry a
# second hand-written copy of the version handshake comparison with nothing
# noticing, which is the same drift the third copy in devbox-gc turned into a
# wrong diagnosis on every gc run. A program the gate never starts is a program
# the gate cannot say anything about.
#
# What is pinned here is doctor's contract rather than its wording:
#
#   every check reports ok, FAIL or skip, and nothing else
#   a check that cannot run says skip, and never ok
#   the fingerprint gets its own line, so it can be skipped on its own
#   DEVBOX_REQUIRES is reported one line per token
#   every check that CAN run does run, even after an earlier one failed
#
# The last one is doctor's whole purpose: a doctor that stopped at the first
# failure needs as many runs as the developer has problems.
#
# Hermetic. A fake ssh sits first on PATH and records every argv, the checkout
# is a `git init` under one mktemp -d, and doctor changes nothing anywhere by
# design. No real ssh, no docker, no network.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
# shellcheck source=tests/lib.sh
source ./lib.sh
REPO="$(cd .. && pwd)"
DOCTOR="$REPO/client/libexec/devbox-doctor"
LIB="$REPO/lib/devbox-lib.sh"

TMP="$(mktemp -d)" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

contains()     { case "$2" in *"$1"*) return 0 ;; esac; return 1; }
# grep -c exits 1 on no match, which would abort a $( ) under a caller that
# cared. The count is what is wanted, including zero.
count()   { printf '%s\n' "$2" | grep -cE "$1" || true; }
# A here-string and not `printf | grep -q`: grep -q exits at its first match, a
# printf still writing then dies of SIGPIPE, and pipefail reads that as no
# match. MEASURED on a loaded laptop: "DEVBOX_REQUIRES is skipped because the
# verb failed" failed with its line in the output.
has_line_matching() { grep -qE "$1" <<<"$2"; }

# The three status prefixes doctor prints, and the only three it may print. A
# line that starts at column 3 is a status line; `say` lines are indented
# further and are continuations of one.
strays() {
  printf '%s\n' "$1" | grep -n '^  [^ ]' | grep -vE '^[0-9]+:  (ok   |FAIL |skip )' || true
}
# The one status line a named check printed, status word included. Cases below
# assert on what a line CARRIES rather than on the sentence it is written in:
# the wording of these messages moved once already when the three copies of the
# handshake comparison were collapsed into one library function, and a test that
# pins prose fails on a rewrite that changed no behaviour.
status_line() {  # $1 status word, $2 check name, $3 the report
  printf '%s\n' "$3" | grep -E "^  $1 $2" | head -1
}

# ── the fake host ────────────────────────────────────────────────────────────
#
# Records every argv before it answers, so "this was never asked of the host"
# is a claim about the recorder and not about a message. Each answer is chosen
# by the gate verb doctor sent, the words after devbox-gate@<host>.
#
# One call is answered before the shared prelude: `ssh -V`, the OpenSSH version
# check. The master open's refusal goes to stderr, where devbox-transport reads
# the cause out of the text. The host key is recorded before that open, by the
# transport itself, from the stub ssh-keyscan, and only when it matches the
# pin, GATE_STUB_PIN, which every .devbox.env here names.
SSH_LOG="$TMP/ssh.log"
export SSH_LOG
mkdir -p "$TMP/bin" "$TMP/fakehome" "$TMP/run"
gate_stub_keyscan "$TMP/bin"
HOSTKEY_FP="$GATE_STUB_PIN"
PINS="DEVBOX_TARGET_FIXTURE_HOSTKEY=$GATE_STUB_PIN"
{ echo '#!/bin/bash'; cat <<'FAKE'
printf '%s\n' "$*" >>"$SSH_LOG"
[ "${1-}" = "-V" ] && { printf 'OpenSSH_%s fixture, OpenSSL 3.0.0\n' "${FAKE_SSH_VERSION-9.0p1}" >&2; exit 0; }
FAKE
gate_stub_prelude; cat <<'FAKE'
case "$GATE_CMD" in
  doctor)
    # The verb itself can fail: sudo refuses with no sudoers line, or a host on
    # protocol 4 answers "unknown verb". It prints that on stderr, and no state.
    if [ "${FAKE_DOCTOR_RC-0}" -ne 0 ]; then
      printf '%s\n' "${FAKE_DOCTOR_ERR-}" >&2
      exit "$FAKE_DOCTOR_RC"
    fi
    [ "${FAKE_DOCKER_RC-0}" -eq 0 ] && echo "docker ok" || echo "docker missing"
    [ "${FAKE_RUNNER_RC-0}" -eq 0 ] && echo "devbox-runner ok" || echo "devbox-runner missing"
    [ "${FAKE_POOL_RC-0}" -eq 0 ] && echo "devbox-pool ok" || echo "devbox-pool missing"
    exit 0 ;;
  version)           printf '%s\n' "${FAKE_VERSION-}"; exit 0 ;;
  pool-status)       printf '%s\n' "${FAKE_POOL_OUT-0/20 0/4}"; exit "${FAKE_POOL_STATUS_RC-0}" ;;
  "check-requires "*) printf '%s\n' "${FAKE_REQ_OUT-}"; exit "${FAKE_REQ_RC-0}" ;;
esac
exit 0
FAKE
} >"$TMP/bin/ssh"
chmod +x "$TMP/bin/ssh"

# ── the fake checkout ────────────────────────────────────────────────────────
#
# doctor starts with `git rev-parse --show-toplevel`, so the fixture has to be a
# real repository. It needs no commit: doctor reads no history. The host name is
# one no resolver is ever asked about, because the fake ssh answers first.
CO="$TMP/checkout"
mkdir -p "$CO/.devbox"
git -C "$CO" init -q >/dev/null 2>&1
printf 'DEVBOX_TARGETS=fixture\nDEVBOX_TARGET_FIXTURE=devbox-doctor-fixture\nDEVBOX_GATE_PASSWORD=fixture-gate-password\n%s\n' "$PINS" >"$CO/.devbox.env"
: >"$CO/.devbox/exclude"
profile() {  # $1 is the DEVBOX_REQUIRES line, or empty for none
  {
    printf 'DEVBOX_PROJECT=doctor-fixture\n'
    # The token count is here because devbox-verify refuses a profile without
    # one, so a fixture missing it is not a project doctor can be asked about:
    # the memory budget check reports the ratio between this number and the
    # workspace's memory cap, and would skip on a profile that declares neither.
    printf 'DEVBOX_WANT_TOKENS=8\nDEVBOX_MIN_TOKENS=1\n'
    [ -z "${1-}" ] || printf 'DEVBOX_REQUIRES="%s"\n' "$1"
    printf 'DEVBOX_SETUP=:\nDEVBOX_VERIFY=:\n'
  } >"$CO/.devbox/config.env"
}
profile ""

# Read as text out of the shipped library, so a bump moves the fixture with the
# code rather than leaving a stale literal here.
proto="$(sed -n 's/^DEVBOX_PROTOCOL_VERSION=\(.*\)$/\1/p' "$LIB")"
local_fp="$(sha256sum <"$LIB" | cut -d' ' -f1)"
# The right shape and the wrong file: two copies of the library that drifted
# while both still claim the same protocol.
other_fp="$(printf 'a drifted library' | sha256sum | cut -d' ' -f1)"

out=""; rc=0
doctor() {  # every FAKE_* the caller set is already exported
  : >"$SSH_LOG"
  [ "${KEEP_KNOWN_HOSTS-}" = 1 ] || rm -f "$TMP/fakehome/.config/devbox/known_hosts"
  out="$(cd "$CO" && env PATH="$TMP/bin:$PATH" HOME="$TMP/fakehome" XDG_RUNTIME_DIR="$TMP/run" bash "$DOCTOR" 2>&1)"
  rc=$?
  return 0
}
export FAKE_OPEN_RC=0 FAKE_OPEN_ERR="" FAKE_DOCKER_RC=0 FAKE_RUNNER_RC=0 FAKE_POOL_RC=0
export FAKE_VERSION="$proto $local_fp" FAKE_REQ_OUT="" FAKE_REQ_RC=0 FAKE_POOL_STATUS_RC=0

# ── everything healthy ───────────────────────────────────────────────────────
doctor
assert_eq "0" "$rc" "a checkout with every prerequisite in place exits 0"
assert_ok "and says so" contains "doctor: every check passed" "$out"
# The format claim, made over the whole report at once. A check added tomorrow
# that printed its own shape would be caught here rather than by nobody.
assert_eq "" "$(strays "$out")" \
  "every status line is ok, FAIL or skip, and no check invents a fourth"
assert_eq "0" "$(count '^  (FAIL|skip) ' "$out")" \
  "nothing is failed or skipped when every check can run"
assert_ok "the checks are counted, so the assertion above is not over an empty report" \
  test "$(count '^  ok   ' "$out")" -ge 12

assert_ok "the handshake reports both halves on one protocol" \
  contains "ok   protocol handshake: both halves speak protocol $proto" "$out"
assert_ok "the fingerprint has its own line" \
  contains "ok   library fingerprint: both halves speak protocol $proto and load the same devbox-lib.sh" "$out"
assert_ok "and that line carries the digest, abbreviated" contains "${local_fp:0:12}" "$out"
assert_ok "the pool's own words are passed through rather than summarised" \
  contains "ok   devbox-pool status: 0/20 0/4" "$out"
assert_ok "a project that requires nothing is reported as requiring nothing" \
  contains "ok   DEVBOX_REQUIRES: this project declares no image requirement" "$out"

# ── a check that cannot run says skip, and never ok ──────────────────────────
#
# The host is unreachable, so every remote check is unrunnable. An ok on any of
# them would claim the remote half is proven when nothing was asked of it.
export FAKE_OPEN_RC=255 FAKE_OPEN_ERR="ssh: Could not resolve hostname devbox-doctor-fixture: Name or service not known"
# A name that does not resolve fails ssh-keyscan first, before any ssh.
export FAKE_KEYSCAN_NONE=devbox-doctor-fixture FAKE_KEYSCAN_ERR="getaddrinfo devbox-doctor-fixture: Name or service not known"
profile "jq shellcheck"
doctor
unset FAKE_KEYSCAN_NONE FAKE_KEYSCAN_ERR
assert_eq "1" "$rc" "an unreachable host fails the run"
assert_eq "" "$(strays "$out")" "and every line it prints is still ok, FAIL or skip"
assert_ok "the cause is read out of ssh's message rather than guessed from its exit code" \
  contains "FAIL ssh fixture (devbox-doctor-fixture) fails: DNS" "$out"
for check in "docker on fixture" "devbox-runner on fixture" "devbox-pool on fixture" \
             "protocol handshake" "library fingerprint" "devbox-pool status" "DEVBOX_REQUIRES"; do
  assert_ok "$check is skipped, not failed and not passed" \
    has_line_matching "^  skip $check" "$out"
done
assert_fail "docker is never reported ok when nothing asked it" contains "ok   docker responds" "$out"
assert_fail "nor is the handshake" contains "ok   protocol handshake" "$out"
assert_fail "nor the fingerprint" contains "ok   library fingerprint" "$out"
# The skip line still names the tokens, because a developer whose host is down
# still wants to know what this project will ask of it.
assert_ok "the skipped requirement check still names its tokens" \
  contains "skip DEVBOX_REQUIRES (fixture is not reachable): jq shellcheck" "$out"
assert_eq "0" "$(count 'devbox-gate@devbox-doctor-fixture [a-z]' "$(cat "$SSH_LOG")")" \
  "and no gate verb was sent after the one probe that failed"

# The summary has to agree with the lines above it, or the two disagree about
# what happened in the same run.
fails="$(count '^  FAIL ' "$out")"
skips="$(count '^  skip ' "$out")"
assert_ok "the closing summary counts exactly the FAIL and skip lines it printed" \
  contains "doctor: $fails failed, $skips skipped" "$out"

# A client reaches the host as the gate account with the gate password, so no
# ~/.ssh/config block is part of the fix any more, and none is printed.
assert_fail "an ssh failure prints no ~/.ssh/config Host block" contains "Host devbox-doctor-fixture" "$out"
assert_ok "and the unreachable host leaves the recorded-key check skipped, not ok" \
  has_line_matching '^  skip recorded host key' "$out"

# A refused password is named as one. Rotation leaves a client on the
# old value for a while, and that client must be told which line to change.
export FAKE_OPEN_RC=255 FAKE_OPEN_ERR="devbox-gate@devbox-doctor-fixture: Permission denied (password)."
doctor
assert_eq "1" "$rc" "a refused gate password fails the run"
assert_ok "and the line says the gate password was refused" \
  contains "FAIL ssh fixture (devbox-doctor-fixture) fails: the gate password was refused" "$out"
assert_ok "and names the key to change" contains "DEVBOX_GATE_PASSWORD" "$out"
assert_ok "the remote checks are skipped, not failed" \
  has_line_matching '^  skip docker on fixture' "$out"

export FAKE_OPEN_RC=0 FAKE_OPEN_ERR=""

# ── the doctor verb itself fails ─────────────────────────────────────────────
#
# An empty answer read as "docker does not respond" and "devbox-runner is not on
# PATH" names the wrong repair, the same kind of wrong diagnosis the gc
# handshake gave on every run. The verb's failure is named with its own stderr,
# and every later remote check is skipped with that reason.
export FAKE_DOCTOR_RC=1 FAKE_DOCTOR_ERR="sudo: a password is required"
profile "jq"
doctor
assert_eq "1" "$rc" "a failed doctor verb fails the run"
assert_eq "" "$(strays "$out")" "and every line it prints is still ok, FAIL or skip"
assert_ok "the line names the verb, its exit code and its first stderr line" \
  contains "FAIL the gate verb 'doctor' failed on fixture with exit 1: sudo: a password is required" "$out"
assert_ok "and the fix is a server install" contains "fix: devbox server install for fixture (devbox-doctor-fixture)" "$out"
assert_fail "docker is not reported as down" contains "docker does not respond" "$out"
assert_fail "and devbox-runner is not reported as missing" contains "devbox-runner is not on PATH" "$out"
for check in "docker on fixture" "devbox-runner on fixture" "devbox-pool on fixture" \
             "protocol handshake" "library fingerprint" "devbox-pool status" "DEVBOX_REQUIRES"; do
  assert_ok "$check is skipped because the verb failed" \
    has_line_matching "^  skip $check \\(the gate verb 'doctor' failed\\)" "$out"
done
assert_eq "1" "$(count '^  FAIL ' "$out")" "the verb's failure is the one FAIL line"
unset FAKE_DOCTOR_ERR
export FAKE_DOCTOR_RC=0
profile ""

# ── the two protocol fields are two checks ───────────────────────────────────
#
# Only the integer is a verdict. A host on another minor release of this
# protocol loads another library by design, so the fingerprint line reports
# both digests and the run passes.
export FAKE_VERSION="$proto $other_fp"
profile ""
doctor
assert_eq "0" "$rc" "another library under one protocol passes the run"
assert_ok "the protocol integer agrees, and says so on its own line" \
  contains "ok   protocol handshake: both halves speak protocol $proto" "$out"
fp_line="$(status_line "ok  " "library fingerprint" "$out")"
assert_ok "and the fingerprint is an ok line of its own" test -n "$fp_line"
assert_ok "which carries this laptop's digest" contains "${local_fp:0:12}" "$fp_line"
assert_ok "and the server's, so an operator can see which copy is which" \
  contains "${other_fp:0:12}" "$fp_line"

# A protocol mismatch makes the fingerprint comparison meaningless, so it is
# skipped rather than reported: two halves that already disagree about the
# protocol have nothing to say about each other's library bytes.
export FAKE_VERSION="99 $local_fp"
doctor
assert_eq "1" "$rc" "a protocol mismatch fails the run"
proto_line="$(status_line FAIL "protocol handshake" "$out")"
assert_ok "the handshake fails on its own line" test -n "$proto_line"
assert_ok "and that line names this client's number" contains "$proto" "$proto_line"
assert_ok "and the server's" contains "99" "$proto_line"
assert_ok "and the fingerprint is skipped rather than compared across protocols" \
  has_line_matching '^  skip library fingerprint ' "$out"
assert_fail "so it is never reported ok" contains "ok   library fingerprint" "$out"

# The server that answers nothing at all. This is the shape a pre-handshake
# devbox-runner produces: it prints `usage:` on stderr and exits 2, so stdout is
# empty. It must read as "no version reported", and the fingerprint check must
# say so is already reported rather than failing the server twice.
export FAKE_VERSION=""
doctor
assert_eq "1" "$rc" "a server that reports no version fails the run"
proto_line="$(status_line FAIL "protocol handshake" "$out")"
assert_ok "the handshake fails rather than reading an empty answer as agreement" \
  test -n "$proto_line"
assert_ok "and says the server reported no version" contains "version" "$proto_line"
assert_ok "the fingerprint defers to that line rather than failing the server twice" \
  has_line_matching '^  skip library fingerprint ' "$out"

# A server on this protocol that names no fingerprint. The integer agrees, and an
# empty second field is never compared: an empty string equals another empty
# string, which would report two different libraries as the same file.
export FAKE_VERSION="$proto"
doctor
assert_eq "0" "$rc" "a server that reports a protocol and no fingerprint passes the run"
fp_line="$(status_line "ok  " "library fingerprint" "$out")"
assert_ok "the line says the server reported no fingerprint" \
  contains "names no library fingerprint" "$fp_line"
assert_fail "and never that the libraries match" contains "load the same devbox-lib.sh" "$fp_line"
export FAKE_VERSION="$proto $local_fp"

# ── DEVBOX_REQUIRES, one line per token ──────────────────────────────────────
#
# One remote call for the whole list, and one report line for each token. A
# summary of the list would hide which requirement the image is missing, which
# is the only thing the developer needs.
profile "jq shellcheck node"
export FAKE_REQ_OUT="  ok   jq
  FAIL shellcheck: shellcheck is not installed
  ok   node"
export FAKE_REQ_RC=1
doctor
assert_eq "1" "$rc" "a missing requirement fails the run"
assert_ok "the token the image carries is reported on its own line" \
  contains "ok   DEVBOX_REQUIRES jq: the workspace image on fixture carries it" "$out"
assert_ok "the token it does not carry is reported on its own line, with the reason" \
  contains "FAIL DEVBOX_REQUIRES shellcheck: the workspace image on fixture does not carry it (shellcheck is not installed)" "$out"
assert_ok "and the third token is reported too, rather than the run stopping at the failure" \
  contains "ok   DEVBOX_REQUIRES node" "$out"
assert_eq "3" "$(count '^  (ok   |FAIL )DEVBOX_REQUIRES ' "$out")" \
  "three tokens, three lines"
assert_eq "1" "$(count 'devbox-gate@devbox-doctor-fixture check-requires' "$(cat "$SSH_LOG")")" \
  "and one remote call for the whole list, not one container per token"

# A token the server said nothing about. Matching neither `ok` nor `FAIL` has to
# be a FAIL and never an ok: if that output format ever changes this turns into
# a loud failure of every token rather than a silent pass over all of them.
export FAKE_REQ_OUT="  ok   jq"
doctor
assert_ok "a token the server returned no verdict for is failed, not assumed satisfied" \
  contains "FAIL DEVBOX_REQUIRES shellcheck: fixture reported no verdict for this token" "$out"
assert_ok "and the report says how to run it by hand" \
  contains "run it by hand on the host: devbox-runner check-requires shellcheck" "$out"

# A token that may not reach a remote root shell. The list is committed, so any
# contributor edits it, and each token becomes part of a command that runs as
# root on the shared devbox. It is reported and DROPPED, and doctor carries on.
profile 'jq -rf shellcheck;id node'
export FAKE_REQ_OUT="  ok   jq
  ok   node"
export FAKE_REQ_RC=0
doctor
assert_eq "1" "$rc" "a token that fails the character rule fails the run"
assert_ok "the refused token is named, with the rule it broke" \
  contains "FAIL DEVBOX_REQUIRES token '-rf'" "$out"
assert_ok "so is the one holding a shell metacharacter" \
  contains "FAIL DEVBOX_REQUIRES token 'shellcheck;id'" "$out"
sent="$(grep 'check-requires' "$SSH_LOG" || true)"
assert_ok "the list was still sent, so the good tokens were still checked" contains "jq" "$sent"
assert_ok "and node with it" contains "node" "$sent"
assert_fail "the refused token never reached the host" contains -- "-rf" "$sent"
assert_fail "nor did the one holding a metacharacter" contains "shellcheck;id" "$sent"
assert_ok "and the tokens that were sent are still reported one line each" \
  contains "ok   DEVBOX_REQUIRES jq" "$out"

# ── every check that can run does run ────────────────────────────────────────
#
# This is doctor's entire purpose. Break the FIRST thing it looks at after the
# checkout and assert the LAST things it looks at still reported: a doctor that
# stopped at the first failure needs as many runs as the developer has problems.
profile "jq"
export FAKE_REQ_OUT="  ok   jq"
rm -f "$CO/.devbox/exclude"
export FAKE_DOCKER_RC=1
export FAKE_POOL_STATUS_RC=2 FAKE_POOL_OUT="pool_held: not a non-negative integer in /run/devbox-pool/grants/9"
doctor
assert_eq "1" "$rc" "a run with several problems fails"
assert_ok "the first problem is reported" contains "FAIL no .devbox/exclude" "$out"
assert_ok "and the one after it" contains "FAIL docker does not respond" "$out"
assert_ok "and the pool, further down still" \
  contains "FAIL devbox-pool status exited 2" "$out"
assert_ok "with the pool's own words, because a corrupt grant file is what it is saying" \
  contains "pool_held: not a non-negative integer" "$out"
assert_ok "and the requirement check at the very end still ran" \
  contains "ok   DEVBOX_REQUIRES jq" "$out"
assert_ok "three problems named in one run, rather than one run per problem" \
  test "$(count '^  FAIL ' "$out")" -ge 3
assert_eq "" "$(strays "$out")" "and the report is still nothing but ok, FAIL and skip lines"
: >"$CO/.devbox/exclude"
export FAKE_DOCKER_RC=0 FAKE_POOL_STATUS_RC=0 FAKE_POOL_OUT="0/20 0/4"

# A missing devbox-runner is a FAIL of that tool and a SKIP of everything that
# needed it. Reported separately, because installing the runner and fixing a
# drifted library are different jobs.
export FAKE_RUNNER_RC=1
doctor
assert_ok "a missing devbox-runner is failed by name" \
  contains "FAIL devbox-runner is not on PATH" "$out"
assert_ok "and the handshake that needed it is skipped" \
  has_line_matching '^  skip protocol handshake \(no devbox-runner' "$out"
assert_ok "as is the fingerprint" \
  has_line_matching '^  skip library fingerprint \(no devbox-runner' "$out"
assert_ok "as is the requirement check" \
  has_line_matching '^  skip DEVBOX_REQUIRES \(no devbox-runner' "$out"
assert_ok "while the pool, which does not need the runner, still reports" \
  contains "ok   devbox-pool status" "$out"
export FAKE_RUNNER_RC=0

# ── the gate transport ───────────────────────────────────────────────────────
#
# The recorded host key is printed after the first contact, so a person can
# compare it once with the fingerprint the deploy printed. A man in the middle
# on that first contact would have received the gate password.
profile ""
export FAKE_REQ_OUT="" FAKE_REQ_RC=0
doctor
assert_eq "0" "$rc" "the healthy fixture still passes with the gate checks in place"
assert_ok "the pin is printed, with the line it came from" \
  contains "host key pin: $HOSTKEY_FP (DEVBOX_TARGET_FIXTURE_HOSTKEY in $CO/.devbox.env)" "$out"
assert_ok "the recorded host key is printed, with its fingerprint and the match" \
  contains "ok   recorded host key for devbox-doctor-fixture: $HOSTKEY_FP, which matches the pin" "$out"

assert_ok "the password is reported as present" contains "ok   DEVBOX_GATE_PASSWORD is set" "$out"
assert_fail "and its value is never printed" contains "fixture-gate-password" "$out"
assert_ok "the OpenSSH version is checked" contains "ok   OpenSSH 9.0 is 8.4 or later" "$out"
assert_ok "and the remote checks came from the one doctor verb" \
  contains "devbox-gate@devbox-doctor-fixture doctor" "$(cat "$SSH_LOG")"

# A recorded entry that is not the pin, from before the pin changed or written
# by something else, is named with both values, and the transport sends nothing.
mkdir -p "$TMP/fakehome/.config/devbox"
printf 'devbox-doctor-fixture ssh-ed25519 %s\n' "$GATE_STUB_OTHER_HOSTKEY" >"$TMP/fakehome/.config/devbox/known_hosts"
KEEP_KNOWN_HOSTS=1 doctor
assert_eq "1" "$rc" "a recorded host key that is not the pin fails the run"
assert_ok "the recorded line names the stale fingerprint, and that it does not match" \
  contains "FAIL recorded host key for devbox-doctor-fixture: $GATE_STUB_OTHER_PIN, which does NOT match the pin $GATE_STUB_PIN" "$out"
assert_ok "and the repair names the entry to remove" \
  contains "ssh-keygen -R 'devbox-doctor-fixture' -f $TMP/fakehome/.config/devbox/known_hosts" "$out"
assert_ok "the ssh line says no password was sent" contains "fails, and no password was sent" "$out"
assert_fail "and no ssh to the host carried a verb or opened a master" grep -qE -- '-f -N|devbox-gate@devbox-doctor-fixture [a-z]' "$SSH_LOG"

# SSH_ASKPASS_REQUIRE arrived in OpenSSH 8.4. An older ssh asks for the gate
# password on a terminal that an agent's shell does not have.
export FAKE_SSH_VERSION=8.2p1
doctor
assert_eq "1" "$rc" "an OpenSSH older than 8.4 fails the run"
assert_ok "and the line names the version and the floor" \
  contains "FAIL OpenSSH 8.2 is older than 8.4" "$out"
export FAKE_SSH_VERSION=8.4p1
doctor
assert_ok "OpenSSH 8.4 itself passes" contains "ok   OpenSSH 8.4 is 8.4 or later" "$out"
unset FAKE_SSH_VERSION

# The value is an address now. An older value that names root@ is refused by name,
# rather than reaching the gate account and failing as a refused password.
cp "$CO/.devbox.env" "$TMP/env.keep"
printf 'DEVBOX_TARGETS=fixture\nDEVBOX_TARGET_FIXTURE=root@devbox-doctor-fixture\nDEVBOX_GATE_PASSWORD=fixture-gate-password\n%s\n' "$PINS" >"$CO/.devbox.env"
doctor
assert_eq "1" "$rc" "a target address that names a user fails the run"
assert_ok "and says the user is always devbox-gate" contains "the user is always devbox-gate" "$out"
assert_fail "and no ssh to the host was attempted" grep -q 'devbox-gate@' "$SSH_LOG"
printf 'DEVBOX_TARGETS=fixture\nDEVBOX_TARGET_FIXTURE=devbox-doctor-fixture\n%s\n' "$PINS" >"$CO/.devbox.env"
doctor
assert_ok "a missing gate password is failed by name" \
  contains "FAIL $CO/.devbox.env lists deployed targets and sets no DEVBOX_GATE_PASSWORD" "$out"
assert_ok "and the targets are skipped rather than tried without one" \
  has_line_matching '^  skip deployed targets \(no .devbox.env that parses\)' "$out"
assert_fail "and no ssh to the host was attempted" grep -q 'devbox-gate@' "$SSH_LOG"
# An older file is refused by name, with the key that replaced each line.
printf 'DEVBOX_HOST=devbox-doctor-fixture\nDEVBOX_ENABLED=1\n' >"$CO/.devbox.env"
doctor
assert_ok "an older DEVBOX_HOST is failed by name, with its replacement" \
  contains "DEVBOX_HOST is no longer read. Name each host in DEVBOX_TARGETS" "$out"
cp "$TMP/env.keep" "$CO/.devbox.env"

# ── the health record ────────────────────────────────────────────────────────
#
# verify skips a target whose watchdog record is not ok, or is older than 90
# seconds, so doctor names the same verdict on the target's own line.
doctor
assert_ok "a fresh ok record passes" has_line_matching '^  ok   health record: ok, [0-9]+s old' "$out"
export FAKE_HEALTH=""
doctor
assert_eq "1" "$rc" "a target with no health record fails the run"
assert_ok "and the line says no watchdog runs there" \
  contains "FAIL health record: missing on fixture, so no watchdog is running there; verify skips this target" "$out"
FAKE_HEALTH="$(( $(date +%s) - 600 )) ok"
export FAKE_HEALTH
doctor
assert_ok "an ok record ten minutes old is failed as a watchdog that stopped" \
  has_line_matching '^  FAIL health record: ok, but [0-9]+s old, so the watchdog on fixture is not running' "$out"
FAKE_HEALTH="$(date +%s) degraded disk 93%"
export FAKE_HEALTH
doctor
assert_ok "a degraded record is failed with its reason" \
  contains "FAIL health record: degraded (disk 93%); verify skips this target" "$out"
unset FAKE_HEALTH

# ── one block per target ─────────────────────────────────────────────────────
#
# Two targets, the second unreachable. Each gets a block of its own, and the
# first is still checked in full: a doctor that stopped at the target that did
# not answer would hide whether the other one works.
printf 'DEVBOX_TARGETS=fixture,cloud\nDEVBOX_TARGET_FIXTURE=devbox-doctor-fixture\nDEVBOX_TARGET_CLOUD=cloud-fixture\nDEVBOX_GATE_PASSWORD=fixture-gate-password\n%s\nDEVBOX_TARGET_CLOUD_HOSTKEY=%s\n' "$PINS" "$GATE_STUB_PIN" >"$CO/.devbox.env"
export FAKE_UNREACHABLE=cloud-fixture
doctor
unset FAKE_UNREACHABLE
assert_eq "1" "$rc" "one unreachable target of two fails the run"
assert_ok "the first target has its block" contains "target fixture (devbox-doctor-fixture)" "$out"
assert_ok "and the second its own" contains "target cloud (cloud-fixture)" "$out"
assert_ok "the first is checked in full" contains "ok   protocol handshake: both halves speak protocol $proto" "$out"
assert_ok "the second is named as unreachable" \
  contains "FAIL ssh cloud (cloud-fixture) fails: network, the name resolves but nothing answers" "$out"
assert_ok "and its remote checks are skipped with its name" \
  has_line_matching '^  skip docker on cloud \(cloud is not reachable\)' "$out"
assert_eq "" "$(strays "$out")" "and every line is still ok, FAIL or skip"
cp "$TMP/env.keep" "$CO/.devbox.env"

# ── a rented Hetzner target ──────────────────────────────────────────────────
#
# Doctor names the token by its length, never its value, and reports the
# worktree's server from its record, never the server's gate password.
printf 'DEVBOX_RENT=hetzner\nHCLOUD_TOKEN=fixtureDoctorToken42\n' >"$CO/.devbox.env"
mkdir -p "$CO/.git/devbox-hetzner"
printf '{"name":"devbox-hz-x","id":701,"ip":"203.0.113.1","deleted":false}\n' >"$CO/.git/devbox-hetzner/server.json"
printf 'rental-password-not-for-doctor' >"$CO/.git/devbox-hetzner/gate-password"
doctor
assert_ok "DEVBOX_RENT=hetzner is reported with the token's length" \
  contains "ok   DEVBOX_RENT names hetzner: verify rents it when no deployed target can take the gate (HCLOUD_TOKEN is set, 20 characters)" "$out"
assert_ok "and the worktree's server from its record" \
  contains "this worktree rents Hetzner server 701 at 203.0.113.1" "$out"
assert_fail "the token never appears" contains "fixtureDoctorToken42" "$out"
assert_fail "and neither does the server's password" contains "rental-password-not-for-doctor" "$out"
assert_eq "" "$(strays "$out")" "and every line is still ok, FAIL or skip"
printf '{"name":"devbox-hz-x","id":701,"deleted":true}\n' >"$CO/.git/devbox-hetzner/server.json"
doctor
assert_ok "a record marked deleted says so" contains "ok   this worktree's last Hetzner server is deleted" "$out"
assert_eq "0" "$rc" "and passes"
printf '{"name":"devbox-hz-x","id":7' >"$CO/.git/devbox-hetzner/server.json"
doctor
assert_eq "1" "$rc" "a record that does not parse fails the run"
assert_ok "and is named, never read as deleted" \
  contains "FAIL the Hetzner record $CO/.git/devbox-hetzner/server.json does not parse; run devbox hetzner status" "$out"
assert_fail "it never prints the deleted line" contains "last Hetzner server is deleted" "$out"
rm -rf "$CO/.git/devbox-hetzner"
cp "$TMP/env.keep" "$CO/.devbox.env"

# ── no checkout at all ───────────────────────────────────────────────────────
#
# Everything doctor reads about the project comes from the checkout root, so
# outside one every project check is unrunnable. Each says skip, and the run
# still reaches the checks that do not need a checkout.
mkdir -p "$TMP/not-a-checkout"
: >"$SSH_LOG"
out="$(cd "$TMP/not-a-checkout" && env PATH="$TMP/bin:$PATH" HOME="$TMP/fakehome" XDG_RUNTIME_DIR="$TMP/run" bash "$DOCTOR" 2>&1)"
rc=$?
assert_eq "1" "$rc" "outside a git checkout the run fails"
assert_ok "and says which one thing is missing" contains "FAIL not inside a git checkout" "$out"
for check in ".devbox/config.env (no checkout root)" ".devbox/exclude (no checkout root)" \
             ".devbox.env (no checkout root)" "DEVBOX_REQUIRES (no checkout root)"; do
  assert_ok "$check is skipped rather than failed a second time" \
    contains "skip $check" "$out"
done
assert_ok "the tools on this laptop are still checked, because they need no checkout" \
  contains "ok   git is installed" "$out"
assert_eq "" "$(strays "$out")" "and the report is still nothing but ok, FAIL and skip lines"

# ── doctor takes no arguments ────────────────────────────────────────────────
usage_out="$(cd "$CO" && env PATH="$TMP/bin:$PATH" bash "$DOCTOR" --fix 2>&1)"
usage_rc=$?
assert_eq "2" "$usage_rc" "an argument is a usage error, because doctor has nothing to switch on"
assert_ok "and the usage line says so" contains "usage: devbox doctor" "$usage_out"

printf '%d %d\n' "$TESTS_RUN" "$TESTS_FAILED"
