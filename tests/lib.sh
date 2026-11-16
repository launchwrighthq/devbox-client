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
#              never finishes it, as an overloaded sshd does. A host named in
#              FAKE_REFUSE refuses the gate password. A host with a file in the
#              directory FAKE_UNREACHABLE_ONCE times out once, and the file
#              goes, so the next open answers. FAKE_OPEN_LOG, when set, gets
#              `<time> <host>` for each open, the time from EPOCHREALTIME.
#   probe      since protocol 6 the client asks every target one `probe` before
#              it chooses. A stub that answers `version` and `queue-estimate`
#              answers `probe` too: the prelude asks the stub itself for those
#              two, and builds the line with the library's own
#              devbox_probe_line, the code gate-root runs. The health is
#              FAKE_HEALTH, `<epoch> ok` by default. $FAKE_PROBE_DIR/<host>.probe,
#              when it exists, is answered verbatim instead, and
#              $FAKE_PROBE_DIR/<host>.once is answered verbatim once, then goes.
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
GATE_STUB_HOSTKEY='AAAAC3NzaC1lZDI1NTE5AAAAIJehVVg5hAqvDxiDuGr6+xbLNXoKNBU03p8aBozaMjZV'  # a fixture public host key: gitleaks:allow
# shellcheck disable=SC2034  # read by the test files that source this one
GATE_STUB_PIN='SHA256:AxgZABtng1WaRtMoFRGUQhH6VAClAtM0YBtXnpRehaA'
GATE_STUB_OTHER_HOSTKEY='AAAAC3NzaC1lZDI1NTE5AAAAIN/7aa2XZE/Ux8+GMpPB+Y6ksvQRwL1vr9a/QM7IegiR'  # a fixture public host key: gitleaks:allow
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
    [ -z "${FAKE_OPEN_LOG-}" ] || printf '%s %s\n' "${EPOCHREALTIME/,/.}" "$GATE_HOST" >>"$FAKE_OPEN_LOG"
    case " ${FAKE_UNREACHABLE-} " in *" $GATE_HOST "*)
      printf 'ssh: connect to host %s port 22: Connection timed out\n' "$GATE_HOST" >&2; exit 255 ;;
    esac
    if [ -n "${FAKE_UNREACHABLE_ONCE-}" ] && [ -e "$FAKE_UNREACHABLE_ONCE/$GATE_HOST" ]; then
      rm -f "$FAKE_UNREACHABLE_ONCE/$GATE_HOST"
      printf 'ssh: connect to host %s port 22: Connection timed out\n' "$GATE_HOST" >&2; exit 255
    fi
    case " ${FAKE_REFUSE-} " in *" $GATE_HOST "*)
      printf 'devbox-gate@%s: Permission denied (keyboard-interactive,password).\n' "$GATE_HOST" >&2; exit 255 ;;
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
    if [ -n "${FAKE_PROBE_DIR-}" ] && [ -f "$FAKE_PROBE_DIR/$GATE_HOST.once" ]; then
      cat "$FAKE_PROBE_DIR/$GATE_HOST.once"; rm -f "$FAKE_PROBE_DIR/$GATE_HOST.once"; exit 0
    fi
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

# ── a fake /proc/stat that moves ─────────────────────────────────────────────
#
# devbox-pool judges CPU by the idle share of all cores, as the difference of
# two readings of the `cpu` line of /proc/stat. A file that never changes is no
# reading at all, so a test that admits on it needs one that moves.
# proc_stat_writer <file> <idle percent> starts a writer in the background that
# adds <idle percent> idle and the rest user time every 0.1 s, each write by
# rename, and sets PROC_STAT_WRITER to its pid. The caller kills it. The writer
# also ends by itself once the test shell that started it is gone, because a
# KILL to that shell runs no EXIT trap and the writer would loop forever.
proc_stat_writer() {
  local file="$1" idle="$2"
  (
    i=0; b=0
    # $$ in this subshell is the test shell's pid.
    while kill -0 "$$" 2>/dev/null; do
      i=$((i + idle)); b=$((b + 100 - idle))
      printf 'cpu  %s 0 0 %s 0 0 0 0 0 0\ncpu0 %s 0 0 %s 0 0 0 0 0 0\n' "$b" "$i" "$b" "$i" >"$file.tmp" \
        && mv -f "$file.tmp" "$file"
      sleep 0.1
    done
  ) </dev/null >/dev/null 2>&1 &
  # shellcheck disable=SC2034  # read by the test files that source this one
  PROC_STAT_WRITER=$!
}

# ── fixture gates that end with their test ───────────────────────────────────
#
# The pool tests run fake pool runs in the background, each around a gate that
# loops until a stop file exists. MEASURED: hundreds of such gate loops and dozens
# of fake pool runs outlived their test files, the oldest by almost two days,
# and their load made timing tests on the same machine fail. Three
# faults combined. The EXIT trap created the stop file and removed the temp
# directory a few milliseconds later, so a gate that polls every 0.1 s missed
# the file and then polled a deleted directory forever. A pool runs a gate
# without --run-id in the foreground, and bash defers a trapped TERM until a
# foreground child ends, so the TERM the trap sent left the pool waiting on
# that gate. And the loop had no other way out.
#
# FIXTURE_GATE is that gate. It writes the DEVBOX_TOKENS it got to
# $OUT/tokens-$NAME, then loops until $OUT/stop-$NAME or $OUT/stop-all exists,
# its pool ($PPID) is gone, the test shell FIXTURE_TEST_PID is gone, or 120 s,
# the limit run-tests.sh gives a whole file, have passed. A test that does not
# set FIXTURE_TEST_PID gets gates that end at once, and its checks fail.
# shellcheck disable=SC2016,SC2034  # expanded by the gate's own shell; read by the test files that source this one
FIXTURE_GATE='printf "%s\n" "$DEVBOX_TOKENS" >"$OUT/tokens-$NAME"; until [ -e "$OUT/stop-$NAME" ] || [ -e "$OUT/stop-all" ] || [ "$SECONDS" -ge 120 ] || ! kill -0 "$PPID" 2>/dev/null || ! kill -0 "$FIXTURE_TEST_PID" 2>/dev/null; do sleep 0.1; done'

# stop_fixture_jobs <out dir> [<pid>...] creates <out dir>/stop-all, sends TERM
# to each pid, gives them 5 s to end, then sends KILL to the rest and reaps
# them. A pool still queued ends on the TERM; a granted pool ends once its gate
# sees the stop file. The caller removes the directory after this returns,
# never before, or the gates never see the stop file.
stop_fixture_jobs() {
  local out="$1" n=0 p
  local -a fixture_live
  shift
  # The directory is missing when the test failed before it made it, and then
  # no gate waits on it either.
  touch "$out/stop-all" 2>/dev/null
  [ "$#" -gt 0 ] || return 0
  # A pid that already ended has nothing to signal.
  kill "$@" 2>/dev/null
  while :; do
    fixture_live=()
    for p in "$@"; do
      if kill -0 "$p" 2>/dev/null; then fixture_live+=("$p"); fi
    done
    if [ "${#fixture_live[@]}" -eq 0 ] || [ "$n" -ge 50 ]; then break; fi
    sleep 0.1
    n=$((n + 1))
  done
  # The same: one may end between the check above and this line.
  [ "${#fixture_live[@]}" -eq 0 ] || kill -KILL "${fixture_live[@]}" 2>/dev/null
  # Reaps them, and a pid that is not this shell's child is no error here.
  wait "$@" 2>/dev/null
  return 0
}
