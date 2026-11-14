#!/bin/bash
# One gate per checkout, end to end (docs/specs/2026-11-14-client-owns-the-gate-design.md,
# D7, D7a, D7c, R4 and section 6.5), with the D9 re-queue of a planned gate:
# the real devbox-verify, devbox-run and `devbox cancel` against a fake gate
# account.
#
# MEASURED before it, in a consumer's own wrapper: it reported every SIGTERM as a
# cancel by a newer gate, so a time limit's TERM read
# as another session's cancel, and its cancel of the older gate read a key the
# client refuses and cancelled nothing on every run. Here a real older client
# gets a real TERM, and its own exit code and line are read back.
#
# A fake ssh plays one target, lan1, with two lanes, the held run and the gate
# of tests/gate-stub-hold.sh. A step named in FAKE_HANG waits on a fifo, so a
# gate is mid-step when the next one starts. The client does not kill the fake
# workspace's runner when it ends, so each case kills the step it left.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
# shellcheck source=tests/lib.sh
source ./lib.sh
# shellcheck source=tests/gate-stub-hold.sh
source ./gate-stub-hold.sh
unset CI DEVBOX_RERUN DEVBOX_STRICT

REPO="$(cd .. && pwd)"
TMP="$(mktemp -d)" || { echo "mktemp -d failed" >&2; exit 1; }
LIVE=()
cleanup() {
  local p
  for p in ${LIVE[@]+"${LIVE[@]}"}; do kill "$p" 2>/dev/null; done
  [ ! -s "$TMP/hang.pid" ] || kill "$(cat "$TMP/hang.pid")" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT
mkdir -p "$TMP/bin" "$TMP/home" "$TMP/run" "$TMP/lanes" "$TMP/ws" "$TMP/tmp"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

contains() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }

PROTO="$(sed -n 's/^DEVBOX_PROTOCOL_VERSION=\(.*\)$/\1/p' "$REPO/lib/devbox-lib.sh")"
FP="$(sha256sum <"$REPO/lib/devbox-lib.sh" | cut -d' ' -f1)"
HOLD_LOG="$TMP/hold.log"
SSH_LOG="$TMP/ssh.log"
STEP_LOG="$TMP/steps.log"
HANG_PID="$TMP/hang.pid"
export HOLD_LOG SSH_LOG STEP_LOG HANG_PID
export FAKE_VERSION="$PROTO $FP" FAKE_LANES="$TMP/lanes" FAKE_WS="$TMP/ws"
export FAKE_SLEEP_FIFO="$TMP/sleep.fifo"
mkfifo "$FAKE_SLEEP_FIFO"

A_LAN1=192.0.2.10

# FAKE_CANCEL_OLD names hosts whose devbox-gate predates the cancel verb.
# FAKE_CANCEL_STOP makes the pool stop the gate with the cancel reason, as the
# verb of a newer gate does once this client can no longer answer its TERM.
{ gate_stub_head; gate_stub_hold; cat <<'STUB'
case "$GATE_CMD" in
  version) printf '%s\n' "$FAKE_VERSION" ;;
  "queue-estimate "*) printf 'now 0 3 0/20 0/4 0\n' ;;
  "ensure-workspace "*) printf 'postgresql://fixture:fixture@fixture/fixture\n' ;;
  "sync-finish "*) ;;
  "setup "*)
    while IFS= read -r _; do :; done
    [ -z "${FAKE_SETUP_SECONDS-}" ] || read -r -t "$FAKE_SETUP_SECONDS" _ <>"$FAKE_SLEEP_FIFO"
    ;;
  "oom-count "*) printf '0\n' ;;
  "lock "*) _hold_lock ;;
  "run "*)
    _hold_run
    if [ -n "${FAKE_CANCEL_STOP-}" ]; then
      while IFS= read -r _; do :; done
      echo "devbox-pool: the watchdog stopped this gate: cancelled by a newer gate of this checkout" >&2
      exit 79
    fi
    _hold_gate ;;
  "ledger "*) _hold_ledger ;;
  "cancel "*)
    _hold_log cancel "${GATE_CMD#cancel }"
    case " ${FAKE_CANCEL_OLD-} " in *" $GATE_HOST "*)
      echo "devbox-gate: unknown verb 'cancel'. This account runs devbox gate verbs only: a client older than protocol 3 sends raw commands, so update the devbox client" >&2
      exit 2 ;;
    esac
    echo "gate-root: no running gate of this run belongs to this machine"
    exit 1 ;;
esac
exit 0
STUB
} >"$TMP/bin/ssh"
{
  printf '#!/bin/bash\n'
  printf '_real=%q\n' "$(command -v rsync)"
  cat <<'STUB'
case "${*: -1}" in devbox-gate@*) exit 0 ;; esac
exec "$_real" "$@"
STUB
} >"$TMP/bin/rsync"
chmod +x "$TMP/bin/ssh" "$TMP/bin/rsync"
gate_stub_keyscan "$TMP/bin"

# One step: it logs its name, and the step named FAKE_HANG writes its pid and
# waits on the fifo for FAKE_HANG_SECONDS before it exits FAKE_HANG_RC.
cat >"$TMP/step.sh" <<'STEP'
#!/bin/bash
printf '%s\n' "$1" >>"$STEP_LOG"
if [ "$1" = "${FAKE_HANG-}" ]; then
  echo "$$" >"$HANG_PID"
  read -r -t "${FAKE_HANG_SECONDS:-20}" _ <>"$FAKE_SLEEP_FIFO"
  exit "${FAKE_HANG_RC:-0}"
fi
echo "step $1 output"
STEP

CO="$TMP/checkout"
mkdir -p "$CO/.devbox" "$CO/src"
git -C "$CO" init -q
: >"$CO/.devbox/exclude"
printf 'one\n' >"$CO/src/a.ts"
printf 'DEVBOX_PROJECT=app\nDEVBOX_WANT_TOKENS=4\nDEVBOX_MIN_TOKENS=2\nDEVBOX_SETUP=:\n' >"$CO/.devbox/config.env"
{
  echo "lint   -- bash $TMP/step.sh lint"
  echo "test   after=lint -- bash $TMP/step.sh test"
} >"$CO/.devbox/steps"
{
  echo 'DEVBOX_TARGETS=lan1'
  echo "DEVBOX_TARGET_LAN1=$A_LAN1"; echo "DEVBOX_TARGET_LAN1_HOSTKEY=$GATE_STUB_PIN"
  echo 'DEVBOX_GATE_PASSWORD=fixture-gate-password'
  echo 'DEVBOX_AFFINITY_GRACE=0'
} >"$CO/.devbox.env"

# shellcheck source=/dev/null
source "$REPO/lib/devbox-lib.sh"
# shellcheck source=/dev/null
source "$REPO/client/libexec/devbox-transport"
mapfile -t LANES < <(devbox_lane_slugs "$(devbox_machine_label)" "$(devbox_machine_id)" app "$CO" 2)
MARKER="$TMP/run/devbox/gates/${LANES[0]}.gate"
RUN_PREFIX="$(devbox_run_id_prefix "$(devbox_machine_id)")"
RECORDS="$CO/.git/devbox/records"

ENVV=(env PATH="$TMP/bin:$PATH" HOME="$TMP/home" XDG_RUNTIME_DIR="$TMP/run" TMPDIR="$TMP/tmp" DEVBOX_LOCK_WAIT=30)
out=""; rc=0
reset() { : >"$HOLD_LOG"; : >"$SSH_LOG"; : >"$STEP_LOG"; rm -f "$HANG_PID"; }
verify() {
  rc=0
  out="$(cd "$CO" && "${ENVV[@]}" bash "$REPO/client/libexec/devbox-verify" "$@" 2>&1)" || rc=$?
}
# Start a gate in the background with its output in $TMP/<name>.out and its
# code in $TMP/<name>.rc, then wait until its hanging step runs. Sets BG, the
# subshell that waits for the client.
BG=""
start_hung_gate() {
  local name="$1" i
  shift
  rm -f "$TMP/$name.rc"
  (cd "$CO" && "${ENVV[@]}" FAKE_HANG=lint bash "$REPO/client/libexec/devbox-verify" "$@" \
    >"$TMP/$name.out" 2>&1; echo "$?" >"$TMP/$name.rc") &
  BG=$!
  LIVE+=("$BG")
  for ((i = 0; i < 150; i++)); do [ -s "$HANG_PID" ] && return 0; sleep 0.1; done
  echo "the gate $name never reached its hanging step" >&2
  return 1
}
# Wait for the background gate $1 to write its code, at most 40 s.
wait_code() {
  local i
  for ((i = 0; i < 400; i++)); do [ -s "$TMP/$1.rc" ] && break; sleep 0.1; done
  cat "$TMP/$1.rc" 2>/dev/null
}
kill_hang() { [ ! -s "$HANG_PID" ] || kill "$(cat "$HANG_PID")" 2>/dev/null; rm -f "$HANG_PID"; }
field() { awk -F'\t' -v k="$2" '$1 == k { print $2; exit }' "$1"; }

# ═══ D7: a second devbox verify of one worktree cancels the first ════════════
reset
start_hung_gate first --target lan1
assert_ok "D7: the first gate is mid-step" test -s "$HANG_PID"
first_pid="$(awk '{ print $1 }' "$MARKER" 2>/dev/null)"
assert_ok "D7: its marker names the first client, its run id and lan1" \
  grep -qE "^[0-9]+ [^ ]+ $RUN_PREFIX\.[0-9]+ lan1$" "$MARKER"
verify --target lan1
first_rc="$(wait_code first)"
first_out="$(cat "$TMP/first.out")"
kill_hang
assert_eq "0" "$rc" "D7: the second gate passes"
assert_ok "D7: and says it cancelled the older gate" contains "devbox verify: cancelling the older gate of this checkout (pid $first_pid)" "$out"
assert_eq "14" "$first_rc" "D7: the first gate exits 14"
assert_ok "D7: and says a newer gate cancelled it" contains "devbox verify: cancelled by a newer gate of this checkout (pid " "$first_out"
assert_fail "D7: never that it was stopped by SIGTERM" contains "stopped by SIGTERM" "$first_out"
assert_ok "D7: the cancel verb named the first gate's run on lan1" grep -qE " $A_LAN1 cancel ${LANES[0]} [0-9a-f]+ $RUN_PREFIX\.$first_pid$" "$HOLD_LOG"
first_rec="$RECORDS/$RUN_PREFIX.$first_pid.record"
assert_eq "0" "$(field "$first_rec" complete)" "D10: the cancelled gate's record is complete 0"
assert_fail "D7: the second gate's marker went with it" test -e "$MARKER"

# ═══ D7a: a SIGTERM from anything else exits 143 ══════════════════════════════
reset
start_hung_gate term --target lan1 --full
# The client's own pid, from its marker: BG is the subshell that waits for it.
kill -TERM "$(awk '{ print $1 }' "$MARKER")"
term_rc="$(wait_code term)"
term_out="$(cat "$TMP/term.out")"
kill_hang
assert_eq "143" "$term_rc" "D7a: a TERM from outside exits 143"
assert_ok "D7a: with stopped by SIGTERM" contains "devbox verify: stopped by SIGTERM" "$term_out"
assert_fail "D7a: and never claims a newer gate" contains "cancelled by a newer gate" "$term_out"
assert_fail "D7a: its marker went with it" test -e "$MARKER"

# A gate on this laptop runs as a background job of the client, so the TERM
# reaches its trap at once, and the trap stops the steps it started.
reset
start_hung_gate localterm --local --full
local_pid="$(awk '{ print $1 }' "$MARKER")"
hung="$(cat "$HANG_PID")"
kill -TERM "$local_pid"
localterm_rc="$(wait_code localterm)"
localterm_out="$(cat "$TMP/localterm.out")"
assert_eq "143" "$localterm_rc" "D7a: a local gate stopped by a TERM exits 143"
assert_ok "D7a: with stopped by SIGTERM" contains "devbox verify: stopped by SIGTERM" "$localterm_out"
assert_fail "D7a: and sends no cancel verb from a local gate" contains "could not cancel" "$localterm_out"
assert_fail "D7a: the hanging step was stopped with it" kill -0 "$hung"
kill_hang

# ═══ devbox cancel: the same path, from the command line ═════════════════════
reset
start_hung_gate bycmd --target lan1 --full
cancel_out="$(cd "$CO" && "${ENVV[@]}" "$REPO/client/bin/devbox" cancel 2>&1)"
cancel_rc=$?
bycmd_rc="$(wait_code bycmd)"
kill_hang
assert_eq "0" "$cancel_rc" "devbox cancel exits 0 when it stopped a gate"
assert_ok "devbox cancel names the gate it stopped" contains "devbox cancel: cancelling the older gate of this checkout (pid " "$cancel_out"
assert_eq "14" "$bycmd_rc" "the gate devbox cancel stopped exits 14"
cancel_out="$(cd "$CO" && "${ENVV[@]}" "$REPO/client/bin/devbox" cancel 2>&1)"
cancel_rc=$?
assert_eq "1" "$cancel_rc" "devbox cancel with no running gate exits 1"
assert_ok "and says so" contains "devbox cancel: no gate of this checkout is running" "$cancel_out"

# ═══ D7c: devbox run is never cancelled by a gate of the same worktree ═══════
reset
cat >"$TMP/runcmd.sh" <<'RUN'
#!/bin/bash
echo "$$" >"$RUN_PID"
read -r -t 4 _ <>"$FAKE_SLEEP_FIFO"
exit 7
RUN
export RUN_PID="$TMP/run.pid"
rm -f "$RUN_PID" "$TMP/runbg.rc"
(cd "$CO" && "${ENVV[@]}" bash "$REPO/client/libexec/devbox-run" --target lan1 -- bash "$TMP/runcmd.sh" \
  >"$TMP/runbg.out" 2>&1; echo "$?" >"$TMP/runbg.rc") &
LIVE+=("$!")
for ((i = 0; i < 150; i++)); do [ -s "$RUN_PID" ] && break; sleep 0.1; done
assert_ok "D7c: the run's command is running" test -s "$RUN_PID"
assert_fail "D7c: a devbox run writes no gate marker" test -e "$MARKER"
verify --target lan1 --full
assert_eq "0" "$rc" "D7c: a gate beside the run passes"
assert_fail "D7c: and cancels nothing" contains "cancelling the older gate" "$out"
run_rc="$(wait_code runbg)"
assert_eq "7" "$run_rc" "D7c: the run ends with its own code"
assert_fail "D7c: and was never cancelled or stopped" grep -qE "cancelled|stopped by SIGTERM" "$TMP/runbg.out"

# ═══ R4: an older host without the cancel verb: one line, the gate runs ══════
reset
mkdir -p "$(dirname "$MARKER")"
printf '999999 - 0123456789abcdef.1 lan1\n' >"$MARKER"
FAKE_CANCEL_OLD="$A_LAN1" verify --target lan1 --full
assert_eq "0" "$rc" "R4: the newer gate still runs and passes"
assert_eq "1" "$(grep -c 'devbox verify: lan1 has no cancel verb; the older gate there runs to its end' <<<"$out")" \
  "R4: one line says the host has no cancel verb"
assert_ok "R4: the verb was asked for the older run" grep -qE " $A_LAN1 cancel ${LANES[0]} [0-9a-f]+ 0123456789abcdef\.1$" "$HOLD_LOG"
assert_ok "R4: and the gate ran its steps" grep -qx lint "$STEP_LOG"

# ═══ a pool stop with the cancel reason exits 14, never 10 ═══════════════════
reset
FAKE_CANCEL_STOP=1 verify --target lan1 --full
assert_eq "14" "$rc" "a pool exit 79 with the cancel reason exits 14"
assert_ok "naming the cancel" contains "devbox verify: cancelled by a newer gate of this checkout: the pool on lan1 stopped this gate" "$out"
assert_fail "and not the watchdog" contains "the watchdog on lan1 stopped this gate" "$out"
rc=0
out="$(cd "$CO" && "${ENVV[@]}" DEVBOX_STRICT=1 FAKE_CANCEL_STOP=1 bash "$REPO/client/libexec/devbox-verify" --target lan1 --full 2>&1)" || rc=$?
assert_eq "79" "$rc" "under DEVBOX_STRICT=1 a cancel is 79"
assert_ok "with ::devbox-infra::cancelled" contains "::devbox-infra::cancelled" "$out"

# ═══ D9: a planned gate whose grant was released once queues once more ══════
reset
printf '1\n' >"$TMP/prep-once"
before="$(find "$RECORDS" -name '*.record' | wc -l | tr -d ' ')"
FAKE_PREP_ONCE="$TMP/prep-once" FAKE_SETUP_SECONDS=3 verify --target lan1 --full
assert_eq "0" "$rc" "D9: released once, the second try passes"
assert_ok "D9: it said why it queued again" contains "this run queues once more" "$out"
assert_eq "1" "$(grep -c ' go $' "$HOLD_LOG")" "D9: exactly one run got go"
assert_eq "$((before + 1))" "$(find "$RECORDS" -name '*.record' | wc -l | tr -d ' ')" "D9: one record for the one gate"
assert_fail "D9: no marker outlives the retried gate" test -e "$MARKER"
assert_ok "D9: its last line is the green verdict" test "$(printf '%s\n' "$out" | tail -n 1)" = "devbox: green (2 steps: 2 ran, 0 carried)"

printf '%d %d\n' "$TESTS_RUN" "$TESTS_FAILED"
