#!/bin/bash
# Three assertions and a counter. Deliberately not a framework: this repo
# tests pure shell functions that parse text, and anything larger would be
# more to maintain than the code under test.
#
# Sourced by tests/test-*.sh, which are run by run-tests.sh.

TESTS_RUN=0
TESTS_FAILED=0

_pass() { TESTS_RUN=$((TESTS_RUN + 1)); printf '  ok   %s\n' "$1"; }
_fail() {
  TESTS_RUN=$((TESTS_RUN + 1))
  TESTS_FAILED=$((TESTS_FAILED + 1))
  printf '  FAIL %s\n' "$1"
  shift
  printf '       %s\n' "$@"
}

assert_eq() {
  local expected="$1" actual="$2" desc="$3"
  if [ "$expected" = "$actual" ]; then
    _pass "$desc"
  else
    _fail "$desc" "expected: $expected" "actual:   $actual"
  fi
}

assert_ok() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    _pass "$desc"
  else
    _fail "$desc" "expected success, got failure" "command: $*"
  fi
}

assert_fail() {
  local desc="$1"; shift
  local status=0
  "$@" >/dev/null 2>&1 || status=$?
  # 127 is "command not found" and 126 is "found but not executable". Reading
  # either as the expected rejection is how seven of these assertions stayed
  # green with the function under test deleted outright: the shell, not the
  # code, produced the non-zero status. Both are a failure of the test itself.
  if [ "$status" -eq 0 ]; then
    _fail "$desc" "expected failure, got exit 0" "command: $*"
  elif [ "$status" -eq 127 ] || [ "$status" -eq 126 ]; then
    _fail "$desc" "command not found or not executable (exit $status), so it was never rejected" "command: $*"
  else
    _pass "$desc"
  fi
}

# ── a fake gate account ──────────────────────────────────────────────────────
#
# Since protocol 6 a client reaches a host as devbox-gate, through
# client/libexec/devbox-transport, and every remote call is one ssh whose last
# words are the verb and its arguments, after `devbox-gate@<host>`. A test's
# fake ssh starts with these lines, printed here so that eleven stubs do not
# each carry a copy of the parse:
#
#   GATE_CMD   the verb and its words, as one space-joined string
#   GATE_HOST  the address after devbox-gate@, so one stub can play several
#              targets
#   -O check   answers "no master", so the transport opens one
#   -O exit    the caller's EXIT trap closing its master: exits 0
#   -f -N      the master open: exits FAKE_OPEN_RC (default 0), and prints
#              FAKE_OPEN_ERR on stderr, as ssh prints its refusal. A host named
#              in FAKE_UNREACHABLE (space separated) answers as one that timed
#              out, so a test can make one target of several unreachable. A
#              host named in FAKE_STALL_OPEN accepts the connection and then
#              never finishes it, as an overloaded sshd does.
#   probe      since protocol 6 the client asks every target one `probe` before
#              it chooses. A stub that answers `version` and `queue-estimate`
#              answers `probe` too: the prelude asks the stub itself for those
#              two, and builds the line with the library's own
#              devbox_probe_line, the code gate-root runs. The health is
#              FAKE_HEALTH, `<epoch> ok` by default. $FAKE_PROBE_DIR/<host>.probe,
#              when it exists, is answered verbatim instead.
#   stall      a host named in FAKE_STALL never answers the verb named in
#              FAKE_STALL_VERB (default `probe`), as a path that dropped
#              mid-call does.
#   drop       a host named in FAKE_DROP fails the verb named in
#              FAKE_DROP_VERB (default `probe`) as ssh fails when the master
#              dies or the connection resets: a line on stderr and exit 255.
#
# ── a pinned host key ────────────────────────────────────────────────────────
#
# Every deployed target names the fingerprint of its ed25519 host key in
# DEVBOX_TARGET_<NAME>_HOSTKEY, and the transport runs ssh-keyscan before its
# first contact with a host and records the key only when it matches. A test
# writes GATE_STUB_PIN into its .devbox.env and puts gate_stub_keyscan's stub
# first on PATH, so no test ever scans a real address. GATE_STUB_OTHER_* is a
# second key: the one a man in the middle, or a reinstalled host, would show.
# Both pairs were made with `ssh-keygen -t ed25519`, and
# tests/test-gate-transport.sh proves each pin is ssh-keygen's fingerprint of
# its key.
GATE_STUB_HOSTKEY='AAAAC3NzaC1lZDI1NTE5AAAAIJehVVg5hAqvDxiDuGr6+xbLNXoKNBU03p8aBozaMjZV'
# shellcheck disable=SC2034  # read by the test files that source this one
GATE_STUB_PIN='SHA256:AxgZABtng1WaRtMoFRGUQhH6VAClAtM0YBtXnpRehaA'
GATE_STUB_OTHER_HOSTKEY='AAAAC3NzaC1lZDI1NTE5AAAAIN/7aa2XZE/Ux8+GMpPB+Y6ksvQRwL1vr9a/QM7IegiR'
# shellcheck disable=SC2034  # read by the test files that source this one
GATE_STUB_OTHER_PIN='SHA256:tl/XHkjgYd44QfiAPtqIAjshCF3n3aF+Kjercf6B4g0'

# Write a stub ssh-keyscan into the directory $1. It answers every host with
# GATE_STUB_HOSTKEY, a host named in FAKE_KEYSCAN_OTHER (space separated) with
# GATE_STUB_OTHER_HOSTKEY, and a host named in FAKE_KEYSCAN_NONE with no key,
# as a host that does not answer, and FAKE_KEYSCAN_ERR on stderr, as
# ssh-keyscan prints a name that does not resolve. When KEYSCAN_LOG is set, each
# argv is appended to it.
gate_stub_keyscan() {
  {
    printf '#!/bin/bash\n'
    printf '_good=%q\n_other=%q\n' "$GATE_STUB_HOSTKEY" "$GATE_STUB_OTHER_HOSTKEY"
    cat <<'KEYSCAN'
[ -z "${KEYSCAN_LOG-}" ] || printf '%s\n' "$*" >>"$KEYSCAN_LOG"
_host="${*: -1}"
case " ${FAKE_KEYSCAN_NONE-} " in *" $_host "*)
  [ -z "${FAKE_KEYSCAN_ERR-}" ] || printf '%s\n' "$FAKE_KEYSCAN_ERR" >&2
  exit 1 ;;
esac
_key="$_good"
case " ${FAKE_KEYSCAN_OTHER-} " in *" $_host "*) _key="$_other" ;; esac
printf '# %s:22 SSH-2.0-OpenSSH_9.0 fixture\n' "$_host" >&2
printf '%s ssh-ed25519 %s\n' "$_host" "$_key"
KEYSCAN
  } >"$1/ssh-keyscan"
  chmod +x "$1/ssh-keyscan"
}

# gate_stub_head prints the shebang, a line that appends the whole argv to
# $SSH_LOG when the stub's environment names one (after GATE_STUB_PREFIX, if the
# caller set it), and then the prelude.
_GATE_STUB_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/devbox-lib.sh"
gate_stub_head() {
  printf '#!/bin/bash\n'
  printf '_log_prefix=%q\n' "${GATE_STUB_PREFIX-}"
  cat <<'HEAD'
[ -z "${SSH_LOG-}" ] || printf '%s%s\n' "$_log_prefix" "$*" >>"$SSH_LOG"
HEAD
  gate_stub_prelude
}
gate_stub_prelude() {
  printf '_gate_stub_lib=%q\n' "$_GATE_STUB_LIB"
  cat <<'PRELUDE'
GATE_CMD=""; GATE_HOST=""; _seen=0; _pre=()
for _a in "$@"; do
  if [ "$_seen" = 1 ]; then GATE_CMD="$GATE_CMD${GATE_CMD:+ }$_a"; else _pre+=("$_a"); fi
  case "$_a" in devbox-gate@*) _seen=1; GATE_HOST="${_a#devbox-gate@}" ;; esac
done
case " $* " in
  *" -O check "*) exit 1 ;;
  *" -O exit "*) exit 0 ;;
  *" -f -N "*)
    for _a in "$@"; do case "$_a" in devbox-gate@*) GATE_HOST="${_a#devbox-gate@}" ;; esac; done
    case " ${FAKE_UNREACHABLE-} " in *" $GATE_HOST "*)
      printf 'ssh: connect to host %s port 22: Connection timed out\n' "$GATE_HOST" >&2; exit 255 ;;
    esac
    case " ${FAKE_STALL_OPEN-} " in *" $GATE_HOST "*) exec sleep 60 ;; esac
    [ -z "${FAKE_OPEN_ERR-}" ] || printf '%s\n' "$FAKE_OPEN_ERR" >&2; exit "${FAKE_OPEN_RC:-0}" ;;
esac
case " ${FAKE_STALL-} " in *" $GATE_HOST "*)
  case "$GATE_CMD" in "${FAKE_STALL_VERB:-probe} "*) exec sleep 60 ;; esac ;;
esac
case " ${FAKE_DROP-} " in *" $GATE_HOST "*)
  case "$GATE_CMD" in "${FAKE_DROP_VERB:-probe} "*)
    printf 'Connection reset by %s port 22\n' "$GATE_HOST" >&2; exit 255 ;;
  esac ;;
esac
case "$GATE_CMD" in
  "probe "*)
    if [ -n "${FAKE_PROBE_DIR-}" ] && [ -f "$FAKE_PROBE_DIR/$GATE_HOST.probe" ]; then
      cat "$FAKE_PROBE_DIR/$GATE_HOST.probe"; exit 0
    fi
    read -r _ _pw _pm <<<"$GATE_CMD"
    _pv="$(SSH_LOG='' "$0" "${_pre[@]}" version 2>/dev/null)"
    _pe="$(SSH_LOG='' "$0" "${_pre[@]}" queue-estimate "$_pw" "$_pm" 2>/dev/null)"
    # shellcheck source=/dev/null
    . "$_gate_stub_lib"
    devbox_probe_line "$_pv" "$_pe" "${FAKE_HEALTH-$(date +%s) ok}" "$(date +%s)"
    exit 0 ;;
esac
PRELUDE
}
