#!/bin/bash
# Runs on this laptop: the run file that `devbox verify` and
# `devbox run` keep in the private dir, and the block `devbox status` prints
# from it.
#
# A host sees a gate only from the moment it asks for tokens. Before that a run
# probes, syncs and runs DEVBOX_SETUP, which takes minutes on a cold workspace,
# and no view showed those minutes. The first half runs the real devbox-verify
# against a fake gate account that copies the run file at each verb, so each
# phase is read while the run is in it. The second half writes run files and
# runs the real devbox-status.
#
# Hermetic: the fake ssh, ssh-keyscan and rsync come first on PATH, HOME and
# XDG_RUNTIME_DIR point into one mktemp -d, and no address resolves (.invalid).
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
# shellcheck source=tests/lib.sh
source ./lib.sh
REPO="$(cd .. && pwd)"
VERIFY="$REPO/client/libexec/devbox-verify"
RUN="$REPO/client/libexec/devbox-run"
STATUS="$REPO/client/libexec/devbox-status"
# shellcheck source=lib/devbox-lib.sh
source "$REPO/lib/devbox-lib.sh"
# devbox_pid_identity, the identity the run file records.
# shellcheck source=client/libexec/devbox-transport
source "$REPO/client/libexec/devbox-transport"

TMP="$(mktemp -d)" || { echo "mktemp -d failed" >&2; exit 1; }
SLEEPERS=()
cleanup() {
  [ "${#SLEEPERS[@]}" -eq 0 ] || kill "${SLEEPERS[@]}" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

contains() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }

PROTO="$(sed -n 's/^DEVBOX_PROTOCOL_VERSION=\(.*\)$/\1/p' "$REPO/lib/devbox-lib.sh")"
FP="$(sha256sum <"$REPO/lib/devbox-lib.sh" | cut -d' ' -f1)"
RUNS="$TMP/run/devbox/runs"
SNAP="$TMP/snap"
mkdir -p "$TMP/bin" "$TMP/fakehome" "$TMP/run" "$TMP/replies" "$SNAP"

# The identity of a pid, read from /proc without the code under test: field 22
# of /proc/<pid>/stat, after the last ')'. Empty on a laptop with no /proc.
proc_ident() {
  [ -r "/proc/$1/stat" ] || return 0
  sed 's/.*) //' "/proc/$1/stat" | cut -d' ' -f20
}

# ── the fake gate account ────────────────────────────────────────────────────
#
# At each verb it copies every run file to $SNAP/<verb>, with the identity
# /proc gives for the file's pid at that moment. The lock answers with the
# first lane it was sent. The run verb plays the pool's hold mode: it waits up
# to 5 seconds for the run file to say queued, prints the pool's `held` line on
# stderr, as devbox-pool does at a grant, and reads one line. After `go` the
# snapshot shows the gate phase, which verify writes before it sends `go`.
{ gate_stub_head; cat <<'FAKE'
# Only the files named by a bare pid. The writer renames <pid>.<bashpid>.tmp
# onto <pid>, and a glob that also matched the tmp file saw "gate" there before
# the rename: the wait below ended early, the snapshot copied the real file
# while it still said queued, and the full suite failed at random.
run_files() {
  local f
  for f in "$XDG_RUNTIME_DIR"/devbox/runs/*; do
    case "${f##*/}" in ''|*[!0-9]*) continue ;; esac
    [ -e "$f" ] && printf '%s\n' "$f"
  done
}
snap() {
  local f pid
  while IFS= read -r f; do
    pid="${f##*/}"
    { cat "$f"; printf 'pid %s\n' "$pid"
      [ ! -r "/proc/$pid/stat" ] || printf 'proc %s\n' "$(sed 's/.*) //' "/proc/$pid/stat" | cut -d' ' -f20)"
    } >"$SNAP/$1"
  done < <(run_files)
}
# Up to 5 seconds for the run file to say phase $1. verify writes the lock and
# queued phases from a loop that polls its joins, a moment after the verb left.
wait_phase() {
  local _i
  for _i in $(seq 50); do
    [ -d "$XDG_RUNTIME_DIR/devbox/runs" ] || return 0
    run_files | while IFS= read -r f; do cat "$f" 2>/dev/null; done | grep -q "^[0-9]* [0-9]* $1 " && return 0
    sleep 0.1
  done
}
case "$GATE_CMD" in
  version) printf '%s %s\n' "$FAKE_PROTO" "$FAKE_FP" ;;
  "probe "*) ;;
  "ensure-workspace "*) snap ensure-workspace; printf 'postgresql://fixture:fixture@fixture/fixture\n' ;;
  "lock "*)
    read -r -a _w <<<"$GATE_CMD"
    wait_phase lock
    snap lock
    printf 'LOCKED %s\n' "${_w[2]}"
    cat >/dev/null ;;
  "sync-finish "*) snap sync-finish ;;
  "setup "*) cat >/dev/null; snap setup ;;
  "oom-count "*) printf '0\n' ;;
  "run "*)
    wait_phase queued
    snap run-before-grant
    echo "devbox-pool: held 1 1" >&2
    # The end of stdin is an abort, as `abort` is: the pool releases and exits 0.
    _go=""
    IFS= read -r _go || _go=""
    [ "$_go" = go ] || exit 0
    : >"$SNAP/ran"
    snap run-after-grant
    cat >/dev/null
    exit "${FAKE_GATE_RC:-0}" ;;
esac
exit 0
FAKE
} >"$TMP/bin/ssh"
chmod +x "$TMP/bin/ssh"
gate_stub_keyscan "$TMP/bin"
# The sync reaches rsync, which copies nothing here.
cat >"$TMP/bin/rsync" <<'FAKE'
#!/bin/bash
for f in "$XDG_RUNTIME_DIR"/devbox/runs/*; do [ -e "$f" ] && cp "$f" "$SNAP/rsync"; done
exit 0
FAKE
chmod +x "$TMP/bin/rsync"

# ── the checkout: a main checkout and one linked worktree ───────────────────
CO="$TMP/fix-cache"
mkdir -p "$CO/.devbox"
git -C "$CO" init -q >/dev/null 2>&1
printf 'DEVBOX_PROJECT=local-fixture\nDEVBOX_WANT_TOKENS=1\nDEVBOX_MIN_TOKENS=1\nDEVBOX_SETUP=:\nDEVBOX_VERIFY=:\n' >"$CO/.devbox/config.env"
git -C "$CO" add .devbox/config.env >/dev/null 2>&1
git -C "$CO" -c user.email=t@fixture.invalid -c user.name=fixture commit -q -m init >/dev/null 2>&1
git -C "$CO" worktree add -q -b feat "$TMP/feat-login" >/dev/null 2>&1
printf 'DEVBOX_TARGETS=lan1,cloud1\nDEVBOX_TARGET_LAN1=lan1.invalid\nDEVBOX_TARGET_LAN1_HOSTKEY=%s\nDEVBOX_TARGET_CLOUD1=cloud1.invalid\nDEVBOX_TARGET_CLOUD1_HOSTKEY=%s\nDEVBOX_GATE_PASSWORD=fixture-gate-password\n' \
  "$GATE_STUB_PIN" "$GATE_STUB_PIN" >"$CO/.devbox.env"

# shellcheck disable=SC2119  # no argument is the point: the default candidates are the files devbox-status reads
MID="$(devbox_machine_id)"
LABEL="$(devbox_machine_label)"
top_main="$(git -C "$CO" rev-parse --show-toplevel)"
top_feat="$(git -C "$TMP/feat-login" rev-parse --show-toplevel)"
SLUG_MAIN="$(devbox_slug "$LABEL" "$MID" local-fixture "$top_main")"
SLUG_FEAT="$(devbox_slug "$LABEL" "$MID" local-fixture "$top_feat")"
SLUG_GONE="$(devbox_slug "$LABEL" "$MID" local-fixture "$TMP/removed-wt")"

out=""; err=""; rc=0
# EXTRA holds NAME=value words for one call's environment.
EXTRA=()
run_client() {  # $1 the program, then its arguments
  local prog="$1"
  shift
  rm -f "$SNAP"/*
  : >"$TMP/ssh.log"
  out="$(cd "$CO" && env LC_ALL=C PATH="$TMP/bin:$PATH" HOME="$TMP/fakehome" XDG_RUNTIME_DIR="$TMP/run" \
    SNAP="$SNAP" SSH_LOG="$TMP/ssh.log" FAKE_PROTO="$PROTO" FAKE_FP="$FP" FAKE_STATUS_DIR="$TMP/replies" DEVBOX_LOCK_WAIT=5 \
    ${EXTRA[@]+"${EXTRA[@]}"} bash "$prog" "$@" 2>"$TMP/err")"
  rc=$?
  err="$(cat "$TMP/err")"
  return 0
}
# The phase line of one snapshot, with the two epochs cut off.
phase_of() { [ -r "$SNAP/$1" ] && sed -n '1s/^[0-9]* [0-9]* //p' "$SNAP/$1"; }

# ═══ R23: devbox verify keeps one run file, phase by phase ═══════════════════
printf 'DEVBOX_TARGETS=lan1\nDEVBOX_TARGET_LAN1=lan1.invalid\nDEVBOX_TARGET_LAN1_HOSTKEY=%s\nDEVBOX_GATE_PASSWORD=fixture-gate-password\n' \
  "$GATE_STUB_PIN" >"$CO/.devbox.env"
run_client "$VERIFY"
assert_eq "0" "$rc" "devbox verify against a target that answers every verb exits 0"
# The order of spec section 3: the lane, the queue, the grant, then the
# workspace, the sync and the setup under the grant, then `go`.
assert_eq "lock lan1 $SLUG_MAIN $top_main" "$(phase_of lock)" \
  "the lane wait is a phase of its own, with the target, lane 1's slug and the worktree path"
assert_eq "queued lan1 $SLUG_MAIN $top_main" "$(phase_of run-before-grant)" "the run verb starts in the queued phase"
assert_eq "sync lan1 $SLUG_MAIN $top_main" "$(phase_of ensure-workspace)" \
  "the sync phase starts when the workspace is asked for, after the grant"
assert_eq "sync lan1 $SLUG_MAIN $top_main" "$(phase_of rsync)" "the rsync runs in the sync phase"
assert_eq "setup lan1 $SLUG_MAIN $top_main" "$(phase_of setup)" "the setup verb runs in the setup phase"
assert_eq "gate lan1 $SLUG_MAIN $top_main" "$(phase_of run-after-grant)" "the run file says gate when go reaches the held run"
# The file is named for the run's pid, and its second line holds that pid's
# identity, the command and the run id: a hash of this machine's id and that pid.
pid_line="$(sed -n 's/^pid //p' "$SNAP/setup")"
ident_line="$(sed -n 2p "$SNAP/setup")"
assert_ok "the file is named for a pid" test -n "$pid_line"
if [ -r /proc/self/stat ]; then
  assert_eq "$(sed -n 's/^proc //p' "$SNAP/setup") verify" "${ident_line% *}" \
    "its second line is the start time /proc gives for that pid, then verify"
fi
rid="${ident_line##* }"
assert_ok "then the run id, which require_run_id accepts" grep -qE '^[0-9a-f]{8,32}\.[0-9]{1,10}$' <<<"$rid"
assert_eq "$pid_line" "${rid#*.}" "and whose pid is the one that names the run file"
# The run id reaches every gate user of a target in the status reply, so its
# prefix is a hash of the machine id and never the id itself.
RID_PREFIX="$(printf '%s' "${MID,,}" | sha256sum | cut -c1-16)"
assert_eq "$RID_PREFIX" "${rid%.*}" "and whose prefix is the hash of this machine's id"
mid_lc="${MID,,}"
assert_fail "  and never the machine id itself" test "${mid_lc:0:16}" = "${rid%.*}"
assert_ok "the run id crossed to the host as the last word of run" \
  grep -qE "devbox-gate@lan1.invalid run .* ${rid//./\\.}\$" "$TMP/ssh.log"
started_setup="$(cut -d' ' -f1 "$SNAP/setup" | head -1)"
started_gate="$(cut -d' ' -f1 "$SNAP/run-after-grant" | head -1)"
assert_eq "$started_setup" "$started_gate" "the start epoch stays the same across phases"
assert_eq "" "$(ls -A "$RUNS" 2>/dev/null)" "the EXIT trap removes the run file"
assert_fail "and nothing about the run file reached stderr" contains "run's file" "$err"

# A gate that fails still removes its file.
EXTRA=(FAKE_GATE_RC=1)
run_client "$VERIFY"
EXTRA=()
assert_eq "1" "$rc" "a run whose gate fails exits with the gate's status"
assert_eq "gate lan1 $SLUG_MAIN $top_main" "$(phase_of run-after-grant)" "after it reached the gate phase"
assert_eq "" "$(ls -A "$RUNS" 2>/dev/null)" "and removes its file too"

# devbox run goes through devbox-verify, and says run.
run_client "$RUN" -- true
assert_eq "0" "$rc" "devbox run against the same target exits 0"
assert_eq "run" "$(sed -n '2s/^[^ ]* \([^ ]*\).*/\1/p' "$SNAP/setup")" "the run file of devbox run names the command run"
assert_eq "gate lan1 $SLUG_MAIN $top_main" "$(phase_of run-after-grant)" "and moves through the same phases"
assert_eq "" "$(ls -A "$RUNS" 2>/dev/null)" "and removes its file on exit"

# The run never fails because the file cannot be written. A file where the
# runs dir should be makes every write fail: the run says so once, and goes on.
rm -rf "$RUNS"
: >"$RUNS"
run_client "$VERIFY"
assert_eq "0" "$rc" "a run whose file cannot be written still exits 0"
assert_eq "1" "$(grep -c "cannot write this run's file" "$TMP/err")" "and says so on stderr exactly once"
assert_ok "and the gate still ran" test -e "$SNAP/ran"
rm -f "$RUNS"

# A run forced to RunPod writes its rent phase before the provider is sourced.
# The provider is a stub here that copies the file and ends the run, as
# tests/test-runpod.sh does for the dispatch.
CLIENT="$TMP/client"
mkdir -p "$CLIENT/client/libexec" "$CLIENT/lib"
for f in devbox-verify devbox-run devbox-config devbox-transport devbox-targets devbox-askpass; do
  cp "$REPO/client/libexec/$f" "$CLIENT/client/libexec/"
done
cp "$REPO/lib/devbox-lib.sh" "$CLIENT/lib/"
cat >"$CLIENT/client/libexec/devbox-runpod" <<'BACKEND'
for f in "$XDG_RUNTIME_DIR"/devbox/runs/*; do [ -e "$f" ] && cp "$f" "$SNAP/runpod"; done
exit 0
BACKEND
printf 'DEVBOX_RENT=runpod\nRUNPOD_KEY=fixture-key\n' >"$CO/.devbox.env"
run_client "$CLIENT/client/libexec/devbox-verify" --target runpod
assert_eq "0" "$rc" "devbox verify --target runpod reaches the provider"
assert_eq "rent runpod - $top_main" "$(phase_of runpod)" "a forced RunPod run is in its rent phase when the provider starts"
assert_eq "" "$(ls -A "$RUNS" 2>/dev/null)" "and the EXIT trap removes its file"
# devbox runpod status manages the rental and runs no gate: no run file.
run_client "$CLIENT/client/libexec/devbox-verify" --runpod-action status
assert_fail "devbox runpod status keeps no run file" test -e "$SNAP/runpod"

# ═══ R24: devbox status shows the runs, removes stale files, joins one clock ═
printf 'DEVBOX_TARGETS=lan1\nDEVBOX_TARGET_LAN1=lan1.invalid\nDEVBOX_TARGET_LAN1_HOSTKEY=%s\nDEVBOX_GATE_PASSWORD=fixture-gate-password\n' \
  "$GATE_STUB_PIN" >"$CO/.devbox.env"
# The fake status verb answers from a reply file, as tests/test-devbox-status.sh
# does. The host's epoch is three years behind this laptop, so a duration that
# mixed the two clocks would print years.
{ gate_stub_head; cat <<'FAKE'
case "$GATE_CMD" in
  "status "*) cat "$FAKE_STATUS_DIR/$GATE_HOST.status" 2>/dev/null; exit 0 ;;
  version) printf '%s %s\n' "$FAKE_PROTO" "$FAKE_FP"; exit 0 ;;
esac
exit 9
FAKE
} >"$TMP/bin/ssh"
E=1700000000
GIB=1073741824
{
  printf '%s %s %s\n' "$PROTO" "$FP" "$E"
  printf 'host ok 12 20 32 1 3 0 2.0 32 %s %s 0 %s\n' "$((24 * GIB))" "$((64 * GIB))" "$((16 * GIB))"
  printf 'run 1234.5678 me %s 20 %s 3600 552 5 1830 %s %s 0 running\n' "$SLUG_FEAT" "$((E - 372))" "$GIB" "$((12 * GIB))"
  printf 'end\n'
} >"$TMP/replies/lan1.invalid.status"

# Live processes for the runs that exist. Each one is a sleep this file kills.
sleeper() { sleep 300 & SLEEPERS+=("$!"); }
sleeper; P_GATE="${SLEEPERS[-1]}"
sleeper; P_SETUP="${SLEEPERS[-1]}"
sleeper; P_QUEUED="${SLEEPERS[-1]}"
sleeper; P_RECYCLED="${SLEEPERS[-1]}"
sleeper; P_LOST="${SLEEPERS[-1]}"
# A pid that is gone: a process that ran and was reaped.
bash -c 'exit 0' & P_DEAD=$!
wait "$P_DEAD"
now="$(date +%s)"
mkdir -p "$RUNS"
write_run() {  # $1 pid, $2 identity, $3 started, $4 phase epoch, then phase target slug path mode
  printf '%s %s %s %s %s %s\n%s %s\n' "$3" "$4" "$5" "$6" "$7" "$8" "$2" "$9" >"$RUNS/$1"
}
ident() { devbox_pid_identity "$1"; }
write_run "$P_GATE" "$(ident "$P_GATE")" $((now - 500)) $((now - 400)) gate lan1 "$SLUG_FEAT" "$top_feat" verify
write_run "$P_SETUP" "$(ident "$P_SETUP")" $((now - 200)) $((now - 70)) setup lan1 "$SLUG_MAIN" "$top_main" run
write_run "$P_QUEUED" "$(ident "$P_QUEUED")" $((now - 100)) $((now - 30)) queued lan1 "$SLUG_GONE" "$TMP/removed-wt" verify
# A run in its gate phase for over an hour that lan1 answers without: its
# connection's far end is gone, and the run waits on it.
SLUG_LOST="$(devbox_slug "$LABEL" "$MID" local-fixture "$TMP/lost-wt")"
write_run "$P_LOST" "$(ident "$P_LOST")" $((now - 4000)) $((now - 3900)) gate lan1 "$SLUG_LOST" "$TMP/lost-wt" verify
# A recycled pid: alive, but its start time is not the one recorded.
write_run "$P_RECYCLED" 1 $((now - 900)) $((now - 900)) setup lan1 "$SLUG_MAIN" "$top_main" verify
write_run "$P_DEAD" 1 $((now - 900)) $((now - 900)) probe - "$SLUG_MAIN" "$top_main" verify
# A file a run is writing right now, before its rename: never read, never removed.
printf 'partial' >"$RUNS/$P_SETUP.4242.tmp"

assert_ok "the identity a run file records for a live pid is readable" test -n "$(ident "$P_GATE")"
if [ -r /proc/self/stat ]; then
  assert_eq "$(proc_ident "$P_GATE")" "$(ident "$P_GATE")" "and it is the start time in /proc/<pid>/stat"
fi

run_client "$STATUS"
# A duration on this laptop is this laptop's now minus the phase epoch, and a
# few seconds may pass between the write above and the read under the load of the
# full suite: 70 reads 1m10s to 1m19s, and 30 reads 30s to 39s.
view="$(printf '%s\n' "$out" | sed -e 's/1m1[0-9]s$/1m10s/' -e 's/  3[0-9]s$/  30s/')"
# The worktrees of this checkout carry the mark, named <repository>/<worktree>,
# and the main checkout by its repository alone. A path that is no worktree
# any more is named by its directory, with no mark.
expected="$(cat <<EOF
lan1      ok        tokens #####... 20/32    load #....... 2.0/32   mem #####... 40G/64G    jobs 1/3

  STATE    TASK                  TARGET  TOKENS   TIME  LEFT  CORES  MEM
> running  fix-cache/feat-login  lan1        20  6m12s  ~3m    18.3  1.0G/12G
> setup    fix-cache             lan1            1m10s
  queued   removed-wt            lan1              30s
  lost     lost-wt               lan1            1h05m  lan1 has no such gate
EOF
)"
assert_eq "0" "$rc" "a view with runs on this laptop exits 0"
assert_eq "$expected" "$view" \
  "one table: the gate lan1 runs, then this laptop's runs that lan1 does not hold, then the lost one"
assert_fail "a dead pid's file is removed" test -e "$RUNS/$P_DEAD"
assert_fail "a recycled pid's file is removed" test -e "$RUNS/$P_RECYCLED"
assert_ok "a live run's file stays" test -e "$RUNS/$P_SETUP"
assert_ok "a lost run's file stays: status reports it and removes nothing of a live process" test -e "$RUNS/$P_LOST"
assert_ok "a file in the middle of its write stays" test -e "$RUNS/$P_SETUP.4242.tmp"
# One gate, one clock: the run file of the gate lan1 holds gets no row, and
# the host's clock prints once.
assert_eq "1" "$(printf '%s\n' "$out" | grep -c 'fix-cache/feat-login')" "the gate lan1 holds is one row"
assert_ok "with the host's clock" contains "  6m12s  " "$out"
assert_fail "and not this laptop's, 6m40s since its phase began" contains "6m40s" "$out"
# A queued run that lan1 does not show yet, for under a minute, is not lost:
# the ticket follows the queued phase by a moment.
assert_ok "a queued run that the target does not show yet keeps its laptop clock" \
  grep -qE '^  queued   removed-wt +lan1 +3[0-9]s$' <<<"$out"

# --target shows only the runs on that target.
printf 'DEVBOX_TARGETS=lan1,cloud1\nDEVBOX_TARGET_LAN1=lan1.invalid\nDEVBOX_TARGET_LAN1_HOSTKEY=%s\nDEVBOX_TARGET_CLOUD1=cloud1.invalid\nDEVBOX_TARGET_CLOUD1_HOSTKEY=%s\nDEVBOX_GATE_PASSWORD=fixture-gate-password\n' \
  "$GATE_STUB_PIN" "$GATE_STUB_PIN" >"$CO/.devbox.env"
{
  printf '%s %s %s\n' "$PROTO" "$FP" "$E"
  printf 'host ok 5 0 20 0 3 0 0.31 8 %s %s 0 %s\n' "$((30 * GIB))" "$((32 * GIB))" "$((16 * GIB))"
  printf 'end\n'
} >"$TMP/replies/cloud1.invalid.status"
run_client "$STATUS" --target cloud1
assert_fail "--target cloud1 shows no run of lan1" contains "fix-cache" "$out"
assert_ok "and says that no gate runs or waits on cloud1" contains "no gate runs or waits" "$out"
run_client "$STATUS" --target lan1
assert_ok "--target lan1 shows the runs on lan1" contains "> setup    fix-cache" "$out"

# A run whose target did not answer keeps its own clock: the join needs the
# target's answer to show the gate. Nor is it lost: nothing said the gate is
# gone.
EXTRA=(FAKE_UNREACHABLE=lan1.invalid)
run_client "$STATUS"
EXTRA=()
assert_eq "3" "$rc" "with lan1 unreachable, status exits 3"
# The phase began 400 seconds before the run files were written, and the cases
# above take seconds of their own: a pattern that allowed 6m40s and 6m41s alone
# failed under the load of the full suite, where this case read 6m42s or later.
assert_ok "and the gate row shows its laptop clock, the only clock left" \
  grep -qE '^> running  fix-cache/feat-login  lan1 +6m4[0-9]s  no answer from lan1$' <<<"$out"
assert_fail "and no run is called lost" grep -qE '^  lost ' <<<"$out"

# Watch mode draws the same table under its header, and joins a run once its
# target has answered. It runs on a pseudo-terminal from util-linux `script`,
# as tests/test-devbox-status.sh does.
if command -v script >/dev/null 2>&1 && script -qec true /dev/null >/dev/null 2>&1 && infocmp xterm >/dev/null 2>&1; then
  cmd="stty cols 120 rows 40 && cd $(printf '%q' "$CO") && env PATH=$(printf '%q' "$TMP/bin:$PATH") HOME=$(printf '%q' "$TMP/fakehome") XDG_RUNTIME_DIR=$(printf '%q' "$TMP/run") FAKE_STATUS_DIR=$(printf '%q' "$TMP/replies") FAKE_PROTO=$PROTO FAKE_FP=$FP TERM=xterm LC_ALL=C.UTF-8 DEVBOX_STATUS_FRAMES=12 bash $(printf '%q' "$STATUS") --watch"
  watch_out="$(script -qec "$cmd" /dev/null </dev/null 2>&1 | tr -d '\r' | sed 's/\x1b\[[0-9;?]*[A-Za-z]//g')"
  assert_ok "watch mode shows this laptop's runs in the table" grep -qE '^▶ setup    fix-cache  ' <<<"$watch_out"
  assert_ok "and joins the gate once lan1 has answered, with the host's clock" \
    grep -qE '^▶ running  fix-cache/feat-login  lan1 +20  6m12s' <<<"$watch_out"
  assert_ok "and shows the lost run" grep -qE '^  lost     lost-wt  .* lan1 has no such gate$' <<<"$watch_out"
else
  echo "  note: util-linux script or xterm terminfo is missing, so the watch case is not run"
fi

# No run file at all: no laptop block, and the view starts with the first target.
kill "${SLEEPERS[@]}" 2>/dev/null
wait "${SLEEPERS[@]}" 2>/dev/null
SLEEPERS=()
run_client "$STATUS"
assert_eq "$(printf '%s\n' "$expected" | head -1)" "$(printf '%s\n' "$out" | head -1)" "with every run gone, the server lines come first"
assert_eq "> running  fix-cache/feat-login  lan1        20  6m12s  ~3m    18.3  1.0G/12G" "$(printf '%s\n' "$out" | sed -n 5p)" \
  "then the table, with the gate lan1 still reports"
assert_fail "and no run of this laptop is in it" grep -qE '^. (setup|queued|lost) ' <<<"$out"
assert_eq "" "$(find "$RUNS" -maxdepth 1 -name '[0-9]*' ! -name '*.tmp' | head -1)" \
  "and status removed every file whose pid is gone"

# ═══ R8, R9: the lane wait, and one run queued on several targets ═══════════
#
# A run waits for a free lane on every eligible target, then in the queue of
# every one of them (docs/specs/2026-11-13-late-binding-queue-design.md
# section 3). Its run file names every target it waits on, joined by `+`, and
# its second line carries the run id its tickets carry. A lane wait read as
# `sync` before, because the sync phase covered the lock wait too.
printf 'DEVBOX_TARGETS=lan1,cloud1\nDEVBOX_TARGET_LAN1=lan1.invalid\nDEVBOX_TARGET_LAN1_HOSTKEY=%s\nDEVBOX_TARGET_CLOUD1=cloud1.invalid\nDEVBOX_TARGET_CLOUD1_HOSTKEY=%s\nDEVBOX_GATE_PASSWORD=fixture-gate-password\n' \
  "$GATE_STUB_PIN" "$GATE_STUB_PIN" >"$CO/.devbox.env"
sleeper; P_MULTI="${SLEEPERS[-1]}"
sleeper; P_LOCK="${SLEEPERS[-1]}"
RID_MULTI="$RID_PREFIX.$P_MULTI"
RID_LOCK="$RID_PREFIX.$P_LOCK"
now="$(date +%s)"
write_run "$P_MULTI" "$(ident "$P_MULTI")" $((now - 100)) $((now - 20)) queued lan1+cloud1 "$SLUG_MAIN" "$top_main" "verify $RID_MULTI"
write_run "$P_LOCK" "$(ident "$P_LOCK")" $((now - 50)) $((now - 10)) lock lan1+cloud1 "$SLUG_FEAT" "$top_feat" "verify $RID_LOCK"
# The run's tickets. Neither host could prove the owner: the run joined their
# queues before its workspace existed there, so each says `other` and `-`.
tickets() {  # $1 the run id lan1's ticket carries, $2 cloud1's
  {
    printf '%s %s %s\n' "$PROTO" "$FP" "$E"
    printf 'host ok 12 20 32 1 3 0 2.0 32 %s %s 0 %s\n' "$((24 * GIB))" "$((64 * GIB))" "$((16 * GIB))"
    [ -z "$1" ] || printf 'ticket 2 other - 8 4 %s 300 %s\n' "$((E - 15))" "$1"
    printf 'end\n'
  } >"$TMP/replies/lan1.invalid.status"
  {
    printf '%s %s %s\n' "$PROTO" "$FP" "$E"
    printf 'host ok 5 0 20 0 3 0 0.31 8 %s %s 0 %s\n' "$((30 * GIB))" "$((32 * GIB))" "$((16 * GIB))"
    [ -z "$2" ] || printf 'ticket 1 other - 8 4 %s 60 %s\n' "$((E - 12))" "$2"
    printf 'end\n'
  } >"$TMP/replies/cloud1.invalid.status"
}
tickets "$RID_MULTI" "$RID_MULTI"
run_client "$STATUS"
view="$(printf '%s\n' "$out" | sed -e 's/  1[0-9]s$/  10s/')"
assert_eq "0" "$rc" "a run queued on two targets: exit 0"
assert_eq "1" "$(grep -c 'lan1+cloud1  ' <<<"$(grep '^. queued' <<<"$view")")" \
  "the run's two tickets and its run file are one queued row"
assert_ok "with this checkout's mark and name from the run file, both targets, and the soonest ticket" \
  grep -qE '^> queued #1  fix-cache +lan1\+cloud1 +4-8 +12s  starts ~1m$' <<<"$view"
assert_fail "it is never called another laptop's" contains "other laptop" "$out"
assert_fail "and the laptop clock of its run file, 20s, shows nowhere" grep -qE ' 2[0-9]s$' <<<"$view"
assert_ok "the lane wait is its own phase, on both targets" \
  grep -qE '^> lock +fix-cache/feat-login +lan1\+cloud1 +10s$' <<<"$view"
assert_fail "and no run reads as syncing" grep -qE '^. sync ' <<<"$view"

# --target names one of the targets the run waits on, and shows it.
run_client "$STATUS" --target cloud1
assert_ok "--target cloud1 shows the run that waits on lan1 and cloud1" contains "lan1+cloud1" "$out"

# One target answers with the ticket, the other answered without it: the run
# is still there, on one queue.
tickets "" "$RID_MULTI"
run_client "$STATUS"
assert_ok "one ticket of the run, on cloud1, is still the run's row" \
  grep -qE '^> queued #1  fix-cache +cloud1 ' <<<"$out"
assert_fail "and it is not lost" grep -qE '^  lost ' <<<"$out"

# Both targets answered, neither holds the run, for over a minute: it is lost.
now="$(date +%s)"
write_run "$P_MULTI" "$(ident "$P_MULTI")" $((now - 200)) $((now - 100)) queued lan1+cloud1 "$SLUG_MAIN" "$top_main" "verify $RID_MULTI"
tickets "" ""
run_client "$STATUS"
assert_ok "a run neither target holds after a minute is lost, naming both" \
  grep -qE '^> lost +fix-cache +lan1\+cloud1 +1m4[0-9]s  lan1, cloud1 hold no such gate$' <<<"$out"
# One of them did not answer: nothing says the run is gone.
EXTRA=(FAKE_UNREACHABLE=cloud1.invalid)
run_client "$STATUS"
EXTRA=()
assert_fail "with cloud1 unreachable, it is not lost" grep -qE '^  lost ' <<<"$out"
assert_ok "and the row names the target that did not answer" contains "no answer from cloud1" "$out"
kill "${SLEEPERS[@]}" 2>/dev/null
wait "${SLEEPERS[@]}" 2>/dev/null
SLEEPERS=()

printf '%d %d\n' "$TESTS_RUN" "$TESTS_FAILED"
