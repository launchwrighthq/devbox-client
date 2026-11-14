#!/bin/bash
# client/libexec/devbox-cancel: one gate per checkout (client-owns-the-gate
# spec, D7 and section 6.5), the client half.
#
# Two failures of a consumer's own wrapper, both MEASURED, are what these cases
# hold the client to. The wrapper reported every SIGTERM as a cancel by a newer
# gate, so a time limit's TERM read as another session's
# cancel. And its cancel of the older gate could not name the checkout's
# workspace on any run, so it cancelled nothing while both gates ran. Here a
# real older process gets a real TERM, and its trap's own decision is read back
# with its exit code. A TERM from anything else must give 143 and
# `stopped by SIGTERM`.
#
# What is left to devbox-verify, and so not proved here: the traps that call
# these functions, the exit 14 of a pool exit 79 with the cancel reason, and the
# rule that `devbox run` (DEVBOX_RUN_MODE) neither writes a marker nor calls
# devbox_cancel_older. This file proves the marker half of that rule: a process
# that wrote no marker is never signalled by a newer gate and never claims a
# cancel.
#
# Hermetic. ssh and ssh-keyscan are stubs first on PATH; HOME and
# XDG_RUNTIME_DIR point under one mktemp -d.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
# shellcheck source=tests/lib.sh
source ./lib.sh
REPO="$(cd .. && pwd)"

TMP="$(mktemp -d)" || { echo "mktemp -d failed" >&2; exit 1; }
LIVE=()
cleanup() {
  [ "${#LIVE[@]}" -eq 0 ] || kill "${LIVE[@]}" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT
contains() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }
matches() { grep -qE "$1" <<<"$2"; }

SLUG=laptop-app-main-a1b2c3
SLUG2=laptop-app-topic-d4e5f6
MID=0123456789abcdef
RUN_OLD=0123456789abcdef.4242
RUN_NEW=0123456789abcdef.5151
MARKER="$TMP/run/devbox/gates/$SLUG.gate"

# ── the stubs ────────────────────────────────────────────────────────────────
#
# One ssh plays every target. A host named in FAKE_OLD_HOST refuses `cancel` as
# an older devbox-gate refuses a verb it does not know. Every other host answers
# `cancel` with FAKE_CANCEL_RC (default 0).
mkdir -p "$TMP/bin" "$TMP/run" "$TMP/home"
{
  gate_stub_head
  cat <<'STUB'
case "$GATE_CMD" in
  "cancel "*)
    case " ${FAKE_OLD_HOST-} " in *" $GATE_HOST "*)
      echo "devbox-gate: unknown verb 'cancel'. This account runs devbox gate verbs only: a client older than protocol 3 sends raw commands, so update the devbox client" >&2
      exit 2 ;;
    esac
    case "${FAKE_CANCEL_RC:-0}" in
      0) echo "gate-root: cancelled run ${GATE_CMD##* }: TERM sent to its pool process 4301" ;;
      1) echo "gate-root: no running gate of run ${GATE_CMD##* } belongs to this machine" ;;
      *) echo "gate-root: the pool gave no snapshot" >&2 ;;
    esac
    exit "${FAKE_CANCEL_RC:-0}" ;;
esac
exit 0
STUB
} >"$TMP/bin/ssh"
chmod +x "$TMP/bin/ssh"
gate_stub_keyscan "$TMP/bin"
SSH_LOG="$TMP/ssh.log"
export REPO SLUG SLUG2 MID SSH_LOG
export PIN="$GATE_STUB_PIN"

# The driver: a fresh bash that sources what devbox-verify sources, in its
# order, with two deployed targets, then runs its arguments. Each driver is its
# own process, so $$ in the code under test is that process.
cat >"$TMP/drive.sh" <<'DRIVE'
#!/bin/bash
set -uo pipefail
# shellcheck source=/dev/null
source "$REPO/lib/devbox-lib.sh"
# shellcheck source=/dev/null
source "$REPO/client/libexec/devbox-config"
# shellcheck source=/dev/null
source "$REPO/client/libexec/devbox-transport"
# shellcheck source=/dev/null
source "$REPO/client/libexec/devbox-targets"
# shellcheck source=/dev/null
source "$REPO/client/libexec/devbox-cancel"
DEVBOX_TARGET_LAN1=lan1.invalid
DEVBOX_TARGET_LAN1_HOSTKEY="$PIN"
DEVBOX_TARGET_VPS1=vps1.invalid
DEVBOX_TARGET_VPS1_HOSTKEY="$PIN"
DEVBOX_GATE_PASSWORD=gate-Pw-fixture
_DEVBOX_CANCEL_GRACE="${FAKE_GRACE:-30}"

# A gate of mode $1 (verify or run): verify writes its marker with run id $2
# and target $3, run writes none. Both arm the TERM trap devbox-verify will
# arm, and exit with the code it decides.
gate() {
  GATE_MODE="$1" GATE_RUN="$2" GATE_TARGET="$3" GATE_SLUG="${4:-$SLUG}"
  if [ "$GATE_MODE" = verify ]; then
    devbox_gate_marker_write "$GATE_SLUG" "$GATE_RUN" "$GATE_TARGET" || exit 1
  fi
  trap on_term TERM
  : >"$READY"
  while :; do sleep 0.1; done
}
on_term() {
  local rc=0
  devbox_cancel_own_run "$GATE_TARGET" "$GATE_SLUG" "$MID" "$GATE_RUN"
  devbox_cancel_on_term "$GATE_SLUG" || rc=$?
  exit "$rc"
}
eval_code() { eval "$1"; }
show_self() { printf '%s %s\n' "$$" "$(devbox_pid_identity "$$")"; }
"$@"
DRIVE
chmod +x "$TMP/drive.sh"

out=""; err=""; rc=0
drive() {
  : >"$SSH_LOG"
  out="$(env PATH="$TMP/bin:$PATH" HOME="$TMP/home" XDG_RUNTIME_DIR="$TMP/run" \
    bash "$TMP/drive.sh" "$@" 2>"$TMP/err" </dev/null)"
  rc=$?
  err="$(cat "$TMP/err")"
  return 0
}
# Start one gate in the background, its stderr in $TMP/<name>.err, and wait for
# it to arm its trap. Sets GPID.
GPID=""
start_gate() {  # $1 a name, then the gate's words
  local name="$1" i
  shift
  rm -f "$TMP/$name.ready"
  env PATH="$TMP/bin:$PATH" HOME="$TMP/home" XDG_RUNTIME_DIR="$TMP/run" READY="$TMP/$name.ready" \
    bash "$TMP/drive.sh" gate "$@" 2>"$TMP/$name.err" </dev/null &
  GPID=$!
  LIVE+=("$GPID")
  for ((i = 0; i < 100; i++)); do [ -e "$TMP/$name.ready" ] && return 0; sleep 0.05; done
  echo "the gate $name never armed its trap" >&2
  return 1
}
# In this shell, never in $(...): a subshell cannot wait for its parent's child.
WRC=""
wait_rc() { WRC=0; wait "$1" || WRC=$?; }
identity_of() { drive devbox_pid_identity "$1"; printf '%s' "$out"; }

# ── the marker ───────────────────────────────────────────────────────────────
drive devbox_gate_marker_path "$SLUG"
assert_eq "0" "$rc" "the marker path is printed"
assert_eq "$MARKER" "$out" "  as <private dir>/gates/<lane-1 slug>.gate"
assert_eq "700" "$(stat -c %a "$TMP/run/devbox/gates")" "  and the gates directory is mode 0700"

drive eval_code 'devbox_gate_marker_write laptop-app-main-a1b2c3 0123456789abcdef.4242 && show_self'
assert_eq "0" "$rc" "a marker is written"
assert_eq "$out 0123456789abcdef.4242 -" "$(cat "$MARKER")" \
  "  as <pid> <pid identity> <run-id> <target or ->, naming the writer"
drive eval_code 'devbox_gate_marker_write laptop-app-main-a1b2c3 0123456789abcdef.4242 lan1 && show_self'
assert_eq "$out 0123456789abcdef.4242 lan1" "$(cat "$MARKER")" "  and written again with the target the grant named"
assert_eq "" "$(find "$TMP/run/devbox/gates" -name '*.tmp')" "  by rename, with no temp file left"

before="$(cat "$MARKER")"
drive devbox_gate_marker_write '../x' "$RUN_OLD"
assert_fail "a slug that walks out of the gates directory is refused" test "$rc" -eq 0
drive devbox_gate_marker_write "$SLUG" 'not-a-run'
assert_fail "a run id of another shape is refused" test "$rc" -eq 0
drive devbox_gate_marker_write "$SLUG" "$RUN_OLD" 'lan1;id'
assert_fail "a target name of another shape is refused" test "$rc" -eq 0
assert_eq "$before" "$(cat "$MARKER")" "  and none of the three touched the marker"

# The marker of a gate that ended stays; a later process removes only its own.
drive devbox_gate_marker_remove "$SLUG"
assert_eq "$before" "$(cat "$MARKER")" "a process removes no marker that names another pid"
drive eval_code 'devbox_gate_marker_write laptop-app-main-a1b2c3 0123456789abcdef.5151 && devbox_gate_marker_remove laptop-app-main-a1b2c3'
assert_fail "and removes the marker that names itself" test -e "$MARKER"

# ── a recycled pid is not the older gate ─────────────────────────────────────
#
# The marker names a live process whose identity is not the one recorded: the
# older gate ended and its pid went to a stranger. The stranger gets no TERM.
sleep 300 &
STRANGER=$!
LIVE+=("$STRANGER")
printf '%s %s - -\n' "$STRANGER" 999999999 >"$MARKER"
drive devbox_cancel_older "$SLUG" "$MID" "$RUN_NEW"
assert_eq "0" "$rc" "a marker that names a recycled pid is not an error"
assert_ok "  and the process that holds the pid now is not signalled" kill -0 "$STRANGER"
assert_eq "" "$err" "  and nothing is said about an older gate"
read -r npid _ _ _ <"$MARKER"
assert_eq "$RUN_NEW -" "$(awk '{print $3, $4}' "$MARKER")" "  and the marker now names the new gate's run"
assert_fail "  and not the stranger" test "$npid" = "$STRANGER"

# ── a newer gate cancels the older one (D7, D7a) ─────────────────────────────
rm -f "$MARKER"
start_gate old verify "$RUN_OLD" -
OLD=$GPID
drive devbox_cancel_older "$SLUG" "$MID" "$RUN_NEW"
assert_eq "0" "$rc" "a newer gate's cancel of the older one returns 0"
assert_eq "devbox verify: cancelling the older gate of this checkout (pid $OLD)" "$err" \
  "  and names the older gate's pid"
wait_rc "$OLD"; assert_eq "14" "$WRC" "the older gate's TERM trap decides 14"
read -r npid _ <"$MARKER"
assert_eq "devbox verify: cancelled by a newer gate of this checkout (pid $npid)" "$(cat "$TMP/old.err")" \
  "  and says it was cancelled by the newer gate, by that gate's pid"
assert_eq "" "$(cat "$SSH_LOG")" "  and an older gate with no target sends no verb"

# A TERM from anything else: a time limit, a person, a supervisor.
start_gate other verify "$RUN_OLD" -
kill -TERM "$GPID"
wait_rc "$GPID"; assert_eq "143" "$WRC" "a TERM from outside decides 143"
assert_eq "devbox verify: stopped by SIGTERM" "$(cat "$TMP/other.err")" \
  "  and says stopped by SIGTERM, never a newer gate"

# The marker names another pid, but that gate is gone: no newer gate runs, so a
# TERM is not a cancel.
start_gate gone verify "$RUN_OLD" -
printf '%s %s %s -\n' 4194304 1 "$RUN_NEW" >"$MARKER"
kill -TERM "$GPID"
wait_rc "$GPID"; assert_eq "143" "$WRC" "a marker that names a gone gate gives 143"
assert_ok "  and never claims a newer gate" test "$(cat "$TMP/gone.err")" = "devbox verify: stopped by SIGTERM"

# ── the verb to the older gate's target ──────────────────────────────────────
#
# The older client is gone and its gate is not. The marker names its run id
# and its target, and the newer gate sends the verb there.
printf '%s %s %s lan1\n' 4194304 1 "$RUN_OLD" >"$MARKER"
drive devbox_cancel_older "$SLUG" "$MID" "$RUN_NEW"
assert_eq "0" "$rc" "the older target's cancel returns 0"
assert_ok "  and sends cancel <slug> <machine-id> <old run id> to the older target" \
  grep -qxF "devbox-gate@lan1.invalid cancel $SLUG $MID $RUN_OLD" <(sed 's/.* \(devbox-gate@[^ ]*\)/\1/' "$SSH_LOG")
assert_eq "1" "$(grep -c ' cancel ' "$SSH_LOG")" "  once"
assert_eq "devbox verify: cancelled the older gate $RUN_OLD on lan1" "$err" "  and says so in one line"

printf '%s %s %s lan1\n' 4194304 1 "$RUN_OLD" >"$MARKER"
FAKE_CANCEL_RC=1 drive devbox_cancel_older "$SLUG" "$MID" "$RUN_NEW"
assert_eq "0" "$rc" "a target with no such gate is not an error"
assert_eq "" "$err" "  and says nothing: the older gate's own trap cancelled it, or it ended"

# R4: an older host refuses the verb, and the newer gate goes on.
printf '%s %s %s lan1\n' 4194304 1 "$RUN_OLD" >"$MARKER"
FAKE_OLD_HOST=lan1.invalid drive devbox_cancel_older "$SLUG" "$MID" "$RUN_NEW"
assert_eq "0" "$rc" "an older host without cancel is not an error (R4)"
assert_eq "devbox verify: lan1 has no cancel verb; the older gate there runs to its end" "$err" \
  "  and gets the one line of section 8"
assert_eq "$RUN_NEW -" "$(awk '{print $3, $4}' "$MARKER")" "  and the newer gate's marker stands"

printf '%s %s %s lan1\n' 4194304 1 "$RUN_OLD" >"$MARKER"
FAKE_CANCEL_RC=3 drive devbox_cancel_older "$SLUG" "$MID" "$RUN_NEW"
assert_eq "0" "$rc" "a host that cannot answer the cancel is not an error"
assert_eq "devbox verify: could not cancel the older gate $RUN_OLD on lan1: gate-root: the pool gave no snapshot" "$err" \
  "  and the line carries the host's reason"

printf '%s %s %s lan1\n' 4194304 1 "$RUN_OLD" >"$MARKER"
FAKE_UNREACHABLE=lan1.invalid drive devbox_cancel_older "$SLUG" "$MID" "$RUN_NEW"
assert_eq "0" "$rc" "an unreachable older target is not an error"
assert_ok "  and one line says the cancel could not reach it" \
  matches "^devbox verify: could not cancel the older gate $RUN_OLD on lan1: .*timed out$" "$err"

printf '%s %s %s cloud9\n' 4194304 1 "$RUN_OLD" >"$MARKER"
drive devbox_cancel_older "$SLUG" "$MID" "$RUN_NEW"
assert_eq "0" "$rc" "an older target this checkout no longer names is not an error"
assert_ok "  and one line names it" contains "could not cancel the older gate $RUN_OLD on cloud9" "$err"
assert_eq "" "$(cat "$SSH_LOG")" "  and nothing is sent"

# A live older gate with a target: its own trap cancels its run there, the
# newer gate's verb finds nothing left, and the older gate still exits 14.
rm -f "$MARKER"
start_gate oldt verify "$RUN_OLD" lan1
OLD=$GPID
drive devbox_cancel_older "$SLUG" "$MID" "$RUN_NEW"
wait_rc "$OLD"; assert_eq "14" "$WRC" "a live older gate with a target exits 14"
assert_ok "  and its trap sent the verb for its own run to its own target" \
  grep -qF "devbox-gate@lan1.invalid cancel $SLUG $MID $RUN_OLD" "$SSH_LOG"

# ── devbox_cancel_own_run ────────────────────────────────────────────────────
drive devbox_cancel_own_run - "$SLUG" "$MID" "$RUN_NEW"
assert_eq "0" "$rc" "own run with no target returns 0"
assert_eq "" "$(cat "$SSH_LOG")" "  and sends nothing"
drive devbox_cancel_own_run vps1 "$SLUG" "$MID" "$RUN_NEW"
assert_ok "own run sends cancel for this run id to this gate's target" \
  grep -qF "devbox-gate@vps1.invalid cancel $SLUG $MID $RUN_NEW" "$SSH_LOG"
FAKE_OLD_HOST=vps1.invalid drive devbox_cancel_own_run vps1 "$SLUG" "$MID" "$RUN_NEW"
assert_eq "0" "$rc" "own run on an older host returns 0"
assert_eq "devbox verify: vps1 has no cancel verb; this gate there ends when its ssh session drops" "$err" \
  "  with one line about this gate"

# ── devbox run is never cancelled (D7c, the marker half) ─────────────────────
#
# A `devbox run` writes no marker. A newer gate of the same worktree reads the
# verify gate's marker and signals that gate alone, and a run that later gets a
# TERM says stopped by SIGTERM even while the marker names another live gate.
rm -f "$MARKER"
start_gate run1 run "$RUN_OLD" -
RUNP=$GPID
start_gate ver1 verify "$RUN_OLD" -
VERP=$GPID
drive devbox_cancel_older "$SLUG" "$MID" "$RUN_NEW"
wait_rc "$VERP"; assert_eq "14" "$WRC" "a newer gate cancels the verify gate of its worktree"
assert_ok "  and the devbox run beside it still runs" kill -0 "$RUNP"
sleep 300 &
HOLDER=$!
LIVE+=("$HOLDER")
printf '%s %s %s -\n' "$HOLDER" "$(identity_of "$HOLDER")" "$RUN_NEW" >"$MARKER"
kill -TERM "$RUNP"
wait_rc "$RUNP"; assert_eq "143" "$WRC" "a devbox run's TERM gives 143 while the marker names another live gate"
assert_eq "devbox verify: stopped by SIGTERM" "$(cat "$TMP/run1.err")" "  and it never claims a cancel"

# The marker is per lane-1 slug: a gate of another worktree is not touched.
start_gate wt2 verify "$RUN_OLD" - "$SLUG2"
WT2=$GPID
drive devbox_cancel_older "$SLUG" "$MID" "$RUN_NEW"
assert_ok "a newer gate of one worktree leaves the gate of another worktree running" kill -0 "$WT2"
assert_ok "  which keeps its own marker" test -s "$TMP/run/devbox/gates/$SLUG2.gate"
kill -TERM "$WT2"
wait_rc "$WT2"; assert_eq "143" "$WRC" "  and a TERM to it later is stopped by SIGTERM"

# ── the pool's stop line ─────────────────────────────────────────────────────
printf 'output\ndevbox-pool: the watchdog stopped this gate: cancelled by a newer gate of this checkout\n' >"$TMP/pool.err"
drive devbox_cancel_reason_is_newer "$TMP/pool.err"
assert_eq "0" "$rc" "the pool's stop line with the cancel reason is a cancel"
printf 'devbox-pool: the watchdog stopped this gate: ran 3601s, past DEVBOX_GATE_MAX_SECONDS=3600\n' >"$TMP/pool.err"
drive devbox_cancel_reason_is_newer "$TMP/pool.err"
assert_eq "1" "$rc" "a watchdog stop with another reason is not"
printf 'devbox-pool: the watchdog stopped this gate: cancelled by a newer gate of this checkout, and more\n' >"$TMP/pool.err"
drive devbox_cancel_reason_is_newer "$TMP/pool.err"
assert_eq "1" "$rc" "the reason must be the exact text, not a prefix of a longer one"
printf 'cancelled by a newer gate of this checkout\n' >"$TMP/pool.err"
drive devbox_cancel_reason_is_newer "$TMP/pool.err"
assert_eq "1" "$rc" "the reason printed by the gate itself, without the pool's line, is not"
drive devbox_cancel_reason_is_newer "$TMP/no-such-file"
assert_eq "1" "$rc" "a missing stderr file is not"

# ── devbox cancel ────────────────────────────────────────────────────────────
rm -f "$MARKER"
drive devbox_cancel_command "$SLUG" "$MID"
assert_eq "1" "$rc" "devbox cancel with no gate running returns 1"
assert_eq "devbox cancel: no gate of this checkout is running" "$err" "  with one line"

start_gate dc verify "$RUN_OLD" lan1
DC=$GPID
drive devbox_cancel_command "$SLUG" "$MID"
assert_eq "0" "$rc" "devbox cancel stops the running gate and returns 0"
wait_rc "$DC"; assert_eq "14" "$WRC" "  and the gate exits 14, the code of a cancel"
assert_ok "  and the gate says it was cancelled" contains "cancelled by a newer gate of this checkout" "$(cat "$TMP/dc.err")"
assert_fail "  and devbox cancel leaves no marker of its own" test -e "$MARKER"
assert_ok "  and the verb went to the gate's target" \
  grep -qF "devbox-gate@lan1.invalid cancel $SLUG $MID $RUN_OLD" "$SSH_LOG"

printf '%s %s %s -\n' 4194304 1 "$RUN_OLD" >"$MARKER"
drive devbox_cancel_command "$SLUG" "$MID"
assert_eq "1" "$rc" "devbox cancel with only a stale marker returns 1"
assert_fail "  and removes that marker" test -e "$MARKER"

printf '%d %d\n' "$TESTS_RUN" "$TESTS_FAILED"
