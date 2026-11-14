#!/bin/bash
# The late-binding queue, client half: a run waits in the queue of every
# eligible target and runs on the first that grants
# (docs/specs/2026-11-13-late-binding-queue-design.md).
#
# MEASURED before it: tickets waited up to tens of minutes in the queue of a
# full target while a second target ran at about a third of its CPU, because the
# client chose one target from a probe and the choice was final. And several
# runs of one worktree waited on one host's lock for tens of minutes, because a
# worktree had one workspace per target.
#
# A fake ssh plays three targets, lan1, vps1 and vps2, with the lane lock and
# the held run of tests/gate-stub-hold.sh. Every step each fake host saw is a
# line in HOLD_LOG, so a case reads the order of verbs per target, and which
# queue still holds a ticket.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
# shellcheck source=tests/lib.sh
source ./lib.sh
# Every case runs the gate of one unchanged tree again, and the client carries
# a step from the last complete record of its key (client-owns-the-gate spec,
# D5), so a second case would run nothing. DEVBOX_RERUN=full runs every step
# each time, and tests/test-verify-steps.sh proves the carry.
export DEVBOX_RERUN=full
# shellcheck source=tests/gate-stub-hold.sh
source ./gate-stub-hold.sh

REPO="$(cd .. && pwd)"
TMP="$(mktemp -d)" || { echo "mktemp -d failed" >&2; exit 1; }
HOLDERS=()
cleanup() {
  local p
  for p in ${HOLDERS[@]+"${HOLDERS[@]}"}; do kill "$p" 2>/dev/null; done
  rm -rf "$TMP"
}
trap cleanup EXIT
mkdir -p "$TMP/bin" "$TMP/home" "$TMP/run" "$TMP/probes" "$TMP/lanes" "$TMP/tickets"

contains() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }

PROTO="$(sed -n 's/^DEVBOX_PROTOCOL_VERSION=\(.*\)$/\1/p' "$REPO/lib/devbox-lib.sh")"
FP="$(sha256sum <"$REPO/lib/devbox-lib.sh" | cut -d' ' -f1)"
HOLD_LOG="$TMP/hold.log"
SSH_LOG="$TMP/ssh.log"
CURL_LOG="$TMP/curl.log"
export HOLD_LOG SSH_LOG CURL_LOG
export FAKE_VERSION="$PROTO $FP" FAKE_LANES="$TMP/lanes" FAKE_TICKETS="$TMP/tickets"

# The three fake hosts, at RFC 5737 addresses.
A_LAN1=192.0.2.10
A_VPS1=192.0.2.11
A_VPS2=192.0.2.12

{ gate_stub_head; gate_stub_hold; cat <<'STUB'
case "$GATE_CMD" in
  version) printf '%s\n' "$FAKE_VERSION" ;;
  "queue-estimate "*) printf 'now 0 3 0/20 0/4 0\n' ;;
  "ensure-workspace "*)
    read -r _ _s _ <<<"$GATE_CMD"
    _hold_log ensure-workspace "$_s"
    printf 'postgresql://fixture:fixture@fixture/fixture\n' ;;
  "sync-finish "*) _hold_log sync-finish ;;
  "setup "*)
    while IFS= read -r _; do :; done
    _hold_log setup
    [ -z "${FAKE_SETUP_SECONDS-}" ] || read -r -t "$FAKE_SETUP_SECONDS" _ <>"$FAKE_SLEEP_FIFO"
    ;;
  "oom-count "*) printf '0\n' ;;
  # FAKE_LOCK_BARE answers as a protocol 2 host did: LOCKED with no lane.
  "lock "*)
    if [ -n "${FAKE_LOCK_BARE-}" ]; then
      printf 'LOCKED\n'
      while IFS= read -r _; do :; done
      exit 0
    fi
    _hold_lock ;;
  "run "*)
    _hold_run
    while IFS= read -r _; do :; done
    read -r _ _s _ <<<"$GATE_CMD"
    _hold_log gate "$_s"
    printf 'GATE RAN ON %s IN %s\n' "$GATE_HOST" "$_s"
    exit "${FAKE_GATE_RC:-0}" ;;
esac
exit 0
STUB
} >"$TMP/bin/ssh"
# The rsync of the sync names its host in its last word.
cat >"$TMP/bin/rsync" <<'STUB'
#!/bin/bash
_dest="${*: -1}"; _h="${_dest#devbox-gate@}"; _h="${_h%%:*}"
[ -z "${HOLD_LOG-}" ] || printf '%s %s rsync\n' "${EPOCHREALTIME:-$(date +%s)}" "$_h" >>"$HOLD_LOG"
exit 0
STUB
# A rental would start with a provider call. This curl records its argv and
# rents nothing.
cat >"$TMP/bin/curl" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >>"$CURL_LOG"
exit 1
STUB
chmod +x "$TMP/bin/ssh" "$TMP/bin/rsync" "$TMP/bin/curl"
gate_stub_keyscan "$TMP/bin"
# A fifo that no one writes: a setup that must take some seconds waits on it
# with the read builtin, and leaves no child behind.
export FAKE_SLEEP_FIFO="$TMP/sleep.fifo"
mkfifo "$FAKE_SLEEP_FIFO"

CO="$TMP/checkout"
mkdir -p "$CO/.devbox"
git -C "$CO" init -q >/dev/null 2>&1
: >"$CO/.devbox/exclude"
write_config() {
  printf 'DEVBOX_PROJECT=app\nDEVBOX_WANT_TOKENS=4\nDEVBOX_MIN_TOKENS=2\nDEVBOX_SETUP=:\nDEVBOX_VERIFY=echo LOCAL GATE RAN\n' >"$CO/.devbox/config.env"
  printf '%s\n' "$@" >>"$CO/.devbox/config.env"
}
write_config
write_env() {
  {
    echo 'DEVBOX_TARGETS=lan1,vps1,vps2'
    echo "DEVBOX_TARGET_LAN1=$A_LAN1"; echo "DEVBOX_TARGET_LAN1_HOSTKEY=$GATE_STUB_PIN"
    echo "DEVBOX_TARGET_VPS1=$A_VPS1"; echo "DEVBOX_TARGET_VPS1_HOSTKEY=$GATE_STUB_PIN"
    echo "DEVBOX_TARGET_VPS2=$A_VPS2"; echo "DEVBOX_TARGET_VPS2_HOSTKEY=$GATE_STUB_PIN"
    echo 'DEVBOX_GATE_PASSWORD=fixture-gate-password'
    printf '%s\n' "$@"
  } >"$CO/.devbox.env"
}
write_env

out=""; rc=0
reset_logs() {
  : >"$HOLD_LOG"; : >"$SSH_LOG"; : >"$CURL_LOG"
  rm -f "$TMP/tickets/"* "$CO/.git/devbox/last-target" "$TMP/run/devbox/unreachable-"*
}
verify() {
  reset_logs
  rc=0
  out="$(cd "$CO" && env PATH="$TMP/bin:$PATH" HOME="$TMP/home" XDG_RUNTIME_DIR="$TMP/run" \
    DEVBOX_LOCK_WAIT="${LOCK_WAIT:-30}" bash "$REPO/client/libexec/devbox-verify" "$@" 2>&1)" || rc=$?
}
# The events of one host, in the order they were logged, as one line.
events() { awk -v h="$1" '$2 == h { printf "%s%s", sep, $3; sep = " " }' "$HOLD_LOG"; }
# The time of the first event $2 of host $1.
event_time() { awk -v h="$1" -v e="$2" '$2 == h && $3 == e { print $1; exit }' "$HOLD_LOG"; }
# A ticket goes when the host sees its session gone, a poll after the client
# killed that ssh, so the count is read once no ticket is left or after 3 s.
tickets_left() {
  local i=0
  while [ "$i" -lt 30 ] && [ -n "$(find "$TMP/tickets" -type f)" ]; do sleep 0.1; i=$((i + 1)); done
  find "$TMP/tickets" -type f | wc -l | tr -d ' '
}

# This checkout's lane slugs, as devbox-verify computes them on this machine.
# shellcheck source=/dev/null
source "$REPO/lib/devbox-lib.sh"
MID="$(devbox_machine_id)"
mapfile -t LANES < <(devbox_lane_slugs "$(devbox_machine_label)" "$MID" app "$CO" 4)
# Hold one lane of one host, as another run of this worktree would. The lock
# is held on an fd of the background shell itself, and its wait is the read
# builtin, so killing that one process releases the lane. `flock file sleep`
# left the sleep holding the lane after its flock was killed.
hold_lane() {
  mkdir -p "$TMP/lanes/$1"
  (exec 9>"$TMP/lanes/$1/$2.lock"; flock 9; read -r -t 60 _ <>"$FAKE_SLEEP_FIFO") &
  HOLDERS+=("$!")
  sleep 0.3
}
release_lanes() {
  local p
  for p in ${HOLDERS[@]+"${HOLDERS[@]}"}; do kill "$p" 2>/dev/null; done
  HOLDERS=()
  sleep 0.3
}

# ═══ D1: every eligible target is joined, and the first grant wins ═══════════
#
# lan1's pool is full and never grants; vps1 grants after a second; vps2 grants
# after five. The gate runs on vps1, and no queue keeps a ticket of this run.
FAKE_GRANT="$A_LAN1:never $A_VPS1:1 $A_VPS2:5" verify
assert_eq "0" "$rc" "D1: a run with three eligible targets completes"
assert_ok "D1: it joins lan1" contains "==> devbox: queuing on lan1: 0/20 tokens, 0/4 jobs, 0 waiting: this ask fits now" "$out"
assert_ok "D1: and vps1" contains "==> devbox: queuing on vps1: " "$out"
assert_ok "D1: and vps2" contains "==> devbox: queuing on vps2: " "$out"
assert_ok "D1: the gate runs on vps1, the first that granted" contains "GATE RAN ON $A_VPS1 IN ${LANES[0]}" "$out"
assert_fail "D1: and nowhere else" contains "GATE RAN ON $A_LAN1" "$out"
assert_ok "D1: the grant line names the target, the lane, the wait and the other queues" \
  grep -qE '^==> devbox: granted 4 tokens on vps1 lane 1 after [0-9]+s \(also queued on lan1, vps2\)$' <<<"$out"
assert_eq "0" "$(tickets_left)" "D1: no queue keeps a ticket of this run"
# A queued pool reads no stdin, so the client leaves it by killing that ssh.
assert_ok "D1: lan1's queue was left when its session ended" contains "left session" "$(grep " $A_LAN1 " "$HOLD_LOG")"
assert_eq "vps1" "$(cat "$CO/.git/devbox/last-target" 2>/dev/null)" "D1: the affinity record names the granted target"
# The run carries the lane slug, the history slug and the run id as its last words.
assert_ok "D1: run carries nine words: lane, project, want, min, max wait, limit, mode, history slug, run id" \
  grep -qE "devbox-gate@$A_VPS1 run ${LANES[0]} app 4 2 0 7200 verify ${LANES[0]} [0-9a-f]{8,32}\.[0-9]+$" "$SSH_LOG"
assert_ok "D1: lock carries the wait, then every lane slug, lane 1 first" \
  grep -qF "devbox-gate@$A_VPS1 lock 30 ${LANES[0]} ${LANES[1]}" "$SSH_LOG"

# ═══ D2: the preparation runs on the granted target, under the grant ═════════
assert_eq "lock run held ensure-workspace rsync sync-finish setup go gate" "$(events "$A_VPS1")" \
  "D2: on the granted target: lock, run, held, then the workspace, the sync and the setup, then go and the gate"
assert_fail "D2: no workspace was asked for on a target that did not grant" \
  contains "ensure-workspace" "$(events "$A_LAN1") $(events "$A_VPS2")"

# ═══ R3: two grants in one moment end with one gate ══════════════════════════
FAKE_GRANT="" verify
assert_eq "0" "$rc" "R3: three targets that grant at once: the run completes"
assert_eq "1" "$(grep -c ' go $' "$HOLD_LOG")" "R3: exactly one target got go"
assert_eq "1" "$(grep -c ' gate ' "$HOLD_LOG")" "R3: and exactly one gate ran"
# A join that reported its grant before the winner was chosen gets the abort
# line; one still starting under load sees its session end instead, logged as
# `abort eof`. This assertion once demanded two `abort abort` lines and failed
# about once in a full-suite run on a loaded laptop, while every grant was
# released. The requirement is that no grant stays held.
assert_eq "$(grep -c ' held ' "$HOLD_LOG")" "$(( $(grep -c ' go $' "$HOLD_LOG") + $(grep -c ' abort ' "$HOLD_LOG") ))" \
  "R3: every grant ended in go or an abort, so none stays held"

# ═══ D3: a target whose lanes are all busy does not hold the run ═════════════
FAKE_LANES_BUSY="$A_LAN1 $A_VPS2" FAKE_GRANT="$A_VPS1:1" verify
assert_eq "0" "$rc" "D3: every lane busy on lan1 and vps2: the run completes"
assert_ok "D3: on vps1" contains "GATE RAN ON $A_VPS1" "$out"
assert_fail "D3: lan1 never ran a run" contains "run" "$(events "$A_LAN1")"

# ═══ D6: a second run of one worktree runs at once in lane 2 ═════════════════
hold_lane "$A_LAN1" "${LANES[0]}"
verify --target lan1
assert_eq "0" "$rc" "D6: lane 1 busy on lan1: the run completes"
assert_ok "D6: in lane 2" contains "GATE RAN ON $A_LAN1 IN ${LANES[1]}" "$out"
assert_ok "D6: the grant line names lane 2" contains "==> devbox: granted 4 tokens on lan1 lane 2 after" "$out"
assert_ok "D6: the workspace asked for is lane 2's" contains "ensure-workspace ${LANES[1]}" "$(grep " $A_LAN1 " "$HOLD_LOG")"
assert_ok "D6: and lane 2's run carries lane 1's slug as its history" \
  grep -qE "devbox-gate@$A_LAN1 run ${LANES[1]} app 4 2 0 7200 verify ${LANES[0]} " "$SSH_LOG"

# ═══ R7 and R8: no lane anywhere within DEVBOX_LOCK_WAIT ═════════════════════
#
# DEVBOX_LANES=2 and both lanes held: a third run waits for a lane, and its run
# file says `lock`, the phase of its own, never `sync`.
hold_lane "$A_LAN1" "${LANES[1]}"
reset_logs
(cd "$CO" && env PATH="$TMP/bin:$PATH" HOME="$TMP/home" XDG_RUNTIME_DIR="$TMP/run" DEVBOX_LOCK_WAIT=3 \
  bash "$REPO/client/libexec/devbox-verify" --target lan1 >"$TMP/r7.out" 2>&1; echo "$?" >"$TMP/r7.rc") &
r7=$!
phase=""
for _ in $(seq 1 30); do
  phase="$(awk 'NR == 1 { print $3, $4 }' "$TMP/run/devbox/runs/"* 2>/dev/null | head -n1)"
  [ "${phase%% *}" != lock ] || break
  sleep 0.1
done
wait "$r7"
assert_eq "lock lan1" "$phase" "R8: the run file of a run that waits for a lane reads lock, on its target"
assert_eq "4" "$(cat "$TMP/r7.rc")" "R7: every lane held past DEVBOX_LOCK_WAIT exits 4"
assert_ok "R7: and says no lane could be taken" contains "could not take the lock of a lane of ${LANES[0]}" "$(cat "$TMP/r7.out")"
assert_fail "R7: and no run was sent" contains " run " "$(cat "$SSH_LOG")"
LOCK_WAIT=2 FAKE_LANES_BUSY="$A_VPS1 $A_VPS2" verify
assert_eq "4" "$rc" "R7: no lane on any eligible target within the wait exits 4"
release_lanes
# A lock that answers with no lane name, as a host of protocol 2 did, ends the
# join at once. Waiting for a name that never comes held the run forever.
t0="$SECONDS"
FAKE_LOCK_BARE=1 verify --target vps1
assert_eq "4" "$rc" "a lock that answers LOCKED with no lane exits 4"
assert_ok "naming the answer" contains "the lock answered 'LOCKED', which names no lane of this worktree" "$out"
assert_ok "at once, not after DEVBOX_LOCK_WAIT" test "$((SECONDS - t0))" -lt 10

# R8: a run that waits in two queues names both in its run file.
reset_logs
(cd "$CO" && env PATH="$TMP/bin:$PATH" HOME="$TMP/home" XDG_RUNTIME_DIR="$TMP/run" DEVBOX_LOCK_WAIT=30 \
  FAKE_GRANT="$A_LAN1:4 $A_VPS1:4 $A_VPS2:4" \
  bash "$REPO/client/libexec/devbox-verify" >"$TMP/r8.out" 2>&1; echo "$?" >"$TMP/r8.rc") &
r8=$!
phase=""
for _ in $(seq 1 30); do
  phase="$(awk 'NR == 1 { print $3, $4, $5 }' "$TMP/run/devbox/runs/"* 2>/dev/null | head -n1)"
  case "$phase" in "queued lan1+vps1+vps2 "*) break ;; esac
  sleep 0.1
done
runid="$(awk 'NR == 2 { print $3 }' "$TMP/run/devbox/runs/"* 2>/dev/null | head -n1)"
wait "$r8"
assert_eq "queued lan1+vps1+vps2 ${LANES[0]}" "$phase" "R8: queued names every target the run waits on, with lane 1's slug"
assert_ok "R8: the run file's second line carries the run id" grep -qE '^[0-9a-f]{8,32}\.[0-9]+$' <<<"$runid"
assert_eq "0" "$(cat "$TMP/r8.rc")" "R8: and that run completes"

# ═══ D8: the affinity target gets a head start ═══════════════════════════════
#
# lan1 ran this worktree last and fits now, but never grants. With a 2-second
# grace the run joins lan1 alone, and the others only after the grace.
reset_logs
mkdir -p "$CO/.git/devbox"
d8() {
  printf 'lan1\n' >"$CO/.git/devbox/last-target"
  rc=0
  out="$(cd "$CO" && env PATH="$TMP/bin:$PATH" HOME="$TMP/home" XDG_RUNTIME_DIR="$TMP/run" DEVBOX_LOCK_WAIT=30 \
    bash "$REPO/client/libexec/devbox-verify" 2>&1)" || rc=$?
}
write_env 'DEVBOX_AFFINITY_GRACE=2'
FAKE_GRANT="$A_LAN1:never" d8
assert_eq "0" "$rc" "D8: the run completes"
assert_ok "D8: it says it waits on lan1 alone first" \
  contains "==> devbox: waiting up to 2s on lan1 alone, where this worktree's workspace is warm, before joining vps1 vps2" "$out"
t_lan="$(event_time "$A_LAN1" lock)"; t_vps="$(event_time "$A_VPS1" lock)"
gap_ok() { awk -v a="$1" -v b="$2" -v lo="$3" -v hi="$4" 'BEGIN { d = b - a; exit !(d >= lo && d < hi) }'; }
assert_ok "D8: vps1 took its lane about 2 seconds after lan1 ($t_lan, $t_vps)" gap_ok "$t_lan" "$t_vps" 1.5 6
assert_ok "D8: and the gate ran" contains "GATE RAN ON " "$out"
assert_fail "D8: on a target that granted, never lan1" contains "GATE RAN ON $A_LAN1" "$out"
# The same with lan1's estimate above the grace: every target at once.
printf '%s\n' "$(devbox_probe_line "$PROTO $FP" "wait 240 4 20/20 4/4 2" "$(date +%s) ok" "$(date +%s)")" \
  >"$TMP/probes/$A_LAN1.probe"
reset_logs
FAKE_PROBE_DIR="$TMP/probes" FAKE_GRANT="$A_LAN1:never $A_VPS1:2 $A_VPS2:2" d8
rm -f "$TMP/probes/$A_LAN1.probe"
assert_eq "0" "$rc" "D8: an affinity estimate above the grace: the run completes"
assert_fail "D8: with no head start" contains "alone, where" "$out"
t_lan="$(event_time "$A_LAN1" lock)"; t_vps="$(event_time "$A_VPS1" lock)"
assert_ok "D8: every target took its lane at once ($t_lan, $t_vps)" gap_ok "$t_lan" "$t_vps" -1 1
assert_ok "D8: lan1's busy queue is named with its estimate" \
  contains "==> devbox: queuing on lan1 (the last run of this worktree was here): 20/20 tokens, 4/4 jobs, 2 waiting: about 240s of queuing" "$out"

# ═══ R5: --target joins that one target, with no grace ═══════════════════════
reset_logs
printf 'lan1\n' >"$CO/.git/devbox/last-target"
verify_keep() {
  rc=0
  out="$(cd "$CO" && env PATH="$TMP/bin:$PATH" HOME="$TMP/home" XDG_RUNTIME_DIR="$TMP/run" DEVBOX_LOCK_WAIT=30 \
    bash "$REPO/client/libexec/devbox-verify" "$@" 2>&1)" || rc=$?
}
verify_keep --target vps2
assert_eq "0" "$rc" "R5: --target vps2 completes"
assert_ok "R5: it joins vps2, naming why" contains "==> devbox: queuing on vps2 (--target vps2): " "$out"
assert_eq "" "$(events "$A_LAN1")$(events "$A_VPS1")" "R5: and no other target saw a lock or a run"
assert_fail "R5: no grace" contains "alone, where" "$out"
write_env

# ═══ R4: the ceiling counts from the first join ══════════════════════════════
write_env 'DEVBOX_MAX_QUEUE_WAIT=3'
t0="$SECONDS"
FAKE_GRANT="$A_LAN1:never $A_VPS1:never $A_VPS2:never" verify
assert_eq "8" "$rc" "R4: no grant within a 3-second ceiling, nothing to rent, the fail action: exit 8"
assert_ok "R4: it names the ceiling and every queue it left" \
  contains "gave up waiting for tokens on lan1 vps1 vps2 after 3s. The gate did not run, here or there." "$out"
assert_ok "R4: within seconds of the ceiling" test "$((SECONDS - t0))" -lt 15
assert_eq "0" "$(tickets_left)" "R4: no queue keeps a ticket of this run"
assert_fail "R4: and no gate ran" contains "GATE RAN" "$out"
# The local action, with a laptop that can run the gate: the fallback takes it.
write_env 'DEVBOX_MAX_QUEUE_WAIT=2' 'DEVBOX_QUEUE_FULL_ACTION=local'
FAKE_GRANT="$A_LAN1:never $A_VPS1:never $A_VPS2:never" verify
assert_eq "0" "$rc" "R4: the local action after the ceiling runs the gate here"
assert_ok "R4: the local gate ran" contains "LOCAL GATE RAN" "$out"
assert_ok "R4: and the reason names the queues" \
  contains "the queue on lan1 vps1 vps2 did not free up within your DEVBOX_MAX_QUEUE_WAIT of 2s" "$out"
assert_eq "0" "$(tickets_left)" "R4: no queue keeps a ticket after the fallback"
write_env

# ═══ D1: a target whose estimate is over the ceiling is still joined ═════════
#
# The estimate is an upper bound: it counts tickets that another target will
# grant first. A selection that skipped such a target waited on a 200s queue
# alone while a 400s estimate under a 300s ceiling granted first, and exited 8
# at once when every target was over the ceiling.
over_probe() {
  printf '%s\n' "$(devbox_probe_line "$PROTO $FP" "wait $2 4 20/20 4/4 2" "$(date +%s) ok" "$(date +%s)")" \
    >"$TMP/probes/$1.probe"
}
over_probe "$A_LAN1" 400; over_probe "$A_VPS1" 200; over_probe "$A_VPS2" 200
write_env 'DEVBOX_MAX_QUEUE_WAIT=300'
FAKE_PROBE_DIR="$TMP/probes" FAKE_GRANT="$A_LAN1:1 $A_VPS1:never $A_VPS2:never" verify
assert_eq "0" "$rc" "D1: a target estimated over the ceiling that grants first: the run completes"
assert_ok "D1: it was joined, with its estimate" \
  contains "==> devbox: queuing on lan1: 20/20 tokens, 4/4 jobs, 2 waiting: about 400s of queuing" "$out"
assert_fail "D1: and not skipped" contains "lan1 skipped" "$out"
assert_ok "D1: the gate runs on it" contains "GATE RAN ON $A_LAN1 IN ${LANES[0]}" "$out"
assert_eq "0" "$(tickets_left)" "D1: no queue keeps a ticket of this run"
# Every target over a 5-second ceiling, the fail action: the run waits up to
# the ceiling, and a grant within it runs the gate.
over_probe "$A_VPS1" 400; over_probe "$A_VPS2" 400
write_env 'DEVBOX_MAX_QUEUE_WAIT=5'
FAKE_PROBE_DIR="$TMP/probes" FAKE_GRANT="$A_LAN1:1 $A_VPS1:never $A_VPS2:never" verify
assert_eq "0" "$rc" "D1: every target over the ceiling, one grants within it: the run completes"
assert_ok "D1: on that target" contains "GATE RAN ON $A_LAN1" "$out"
assert_fail "D1: and no target was skipped for the ceiling" contains "DEVBOX_MAX_QUEUE_WAIT of" "$out"
rm -f "$TMP/probes/"*.probe
write_env

# ═══ R6: a rented target is never joined ═════════════════════════════════════
write_env 'DEVBOX_RENT=runpod' 'RUNPOD_KEY=fixture-runpod-key'
FAKE_GRANT="$A_VPS1:1 $A_VPS2:1" verify
assert_eq "0" "$rc" "R6: DEVBOX_RENT set and free deployed targets: the run completes"
assert_ok "R6: on a deployed target" contains "GATE RAN ON $A_LAN1" "$out"
assert_eq "0" "$(wc -l <"$CURL_LOG" | tr -d ' ')" "R6: no provider call was made"
assert_fail "R6: nothing was rented" contains "renting" "$out"
write_env

# ═══ D11: a preparation past the prep limit queues once more ════════════════
# The first release starts the run again; the second try, past the limit as
# well, exits 12, and 78 under strict.
FAKE_PREP=1 FAKE_SETUP_SECONDS=3 verify --target vps1
assert_eq "12" "$rc" "D11: the grant released before go, twice, exits 12"
assert_ok "D11: naming the pool's line" contains "released this run's grant before the gate started (released the grant: no go within 1s)" "$out"
assert_eq "2" "$(grep -c "released this run's grant" <<<"$out")" "D11: the run was released twice, once per try"
assert_ok "D11: the first release says the run queues once more" contains "this run queues once more" "$out"
assert_ok "D11: the second says it was the second try" contains "on the second try too" "$out"
assert_eq "2" "$(grep -c ' released prep$' "$HOLD_LOG")" "D11: the pool saw two runs, each released"
assert_fail "D11: and no gate ran" contains "GATE RAN" "$out"
reset_logs
# Released once, then granted: the second try runs the gate and its code is
# the gate's.
printf '1\n' >"$TMP/prep-once"
FAKE_PREP_ONCE="$TMP/prep-once" FAKE_SETUP_SECONDS=3 verify --target vps1
assert_eq "0" "$rc" "D11: released once, the second try passes"
assert_ok "D11: the second try ran the gate" contains "GATE RAN" "$out"
assert_ok "D11: and said why it queued again" contains "this run queues once more" "$out"
assert_eq "1" "$(grep -c ' go $' "$HOLD_LOG")" "D11: exactly one run got go"
assert_eq "0" "$(find "$TMP/run" -path '*/runs/*' -type f 2>/dev/null | wc -l | tr -d ' ')" "D11: no run file outlives the retried run"
reset_logs
rc=0
out="$(cd "$CO" && env PATH="$TMP/bin:$PATH" HOME="$TMP/home" XDG_RUNTIME_DIR="$TMP/run" DEVBOX_LOCK_WAIT=30 \
  DEVBOX_STRICT=1 FAKE_PREP=1 FAKE_SETUP_SECONDS=3 bash "$REPO/client/libexec/devbox-verify" --target vps1 2>&1)" || rc=$?
assert_eq "78" "$rc" "D11: under DEVBOX_STRICT=1 it is 78"
assert_ok "D11: with the strict line" contains "::devbox-infra::prep-limit" "$out"
# A gate that exits 80 of its own, with no such line, keeps its code.
FAKE_GATE_RC=80 verify --target vps1
assert_eq "80" "$rc" "D11: a gate's own 80 keeps its code"

# ═══ R13: DEVBOX_LANES outside 1 to 4 is refused ═════════════════════════════
for bad in 0 5 two; do
  write_config "DEVBOX_LANES=$bad"
  verify
  assert_eq "2" "$rc" "R13: DEVBOX_LANES=$bad is refused with exit 2"
  assert_ok "R13: by name, with the file" contains "refusing DEVBOX_LANES '$bad' from $CO/.devbox/config.env" "$out"
  assert_fail "R13: before any target is asked" contains " probe " "$(cat "$SSH_LOG")"
done
write_config 'DEVBOX_LANES=1'
verify --target lan1
assert_eq "0" "$rc" "DEVBOX_LANES=1 runs"
assert_ok "DEVBOX_LANES=1 sends one lane slug" grep -qE "devbox-gate@$A_LAN1 lock 30 ${LANES[0]}$" "$SSH_LOG"
write_config

# ═══ the env header crosses after go ═════════════════════════════════════════
write_config 'DEVBOX_FORWARD_ENV=FIXTURE_SWITCH' 'DEVBOX_NEEDS_POSTGRES=1' 'DEVBOX_DB_URL_VAR=APP_DB_URL'
: >"$TMP/header"
FIXTURE_SWITCH=on FAKE_HEADER_FILE="$TMP/header" verify --target vps1
assert_eq "0" "$rc" "a run with a forwarded switch and a DSN completes"
assert_ok "the DSN crossed in the env header after go" grep -qxF "APP_DB_URL=postgresql://fixture:fixture@fixture/fixture" "$TMP/header"
assert_ok "and the switch beside it" grep -qxF "FIXTURE_SWITCH=on" "$TMP/header"
assert_fail "and neither is in any argv" grep -qE "FIXTURE_SWITCH|postgresql://" "$SSH_LOG"
write_config

printf '%d %d\n' "$TESTS_RUN" "$TESTS_FAILED"
