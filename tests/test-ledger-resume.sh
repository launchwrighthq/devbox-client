#!/bin/bash
# Resumable gates, client half (docs/specs/2026-11-13-resumable-gates-design.md):
# the key, the marker, the fetch, the resume and its limits, driven through the
# real devbox-verify against fake hosts.
#
# MEASURED before it: one project's full gate was stopped at its time limit
# several times in one day, each time with only its test suite unfinished, and
# each rerun repeated every passed step. A landing that wrapped the gate in its
# own time limit lost the same work when that limit killed the client.
#
# A fake ssh plays two targets, lan1 and vps1, with the lane lock, the held run,
# the gate and the `ledger` verb of tests/gate-stub-hold.sh. The gate is a
# script that plays a project's gate: two steps through the real devbox-ledger
# tool the hooks write into the fake workspace, then two test files it records
# itself. Each unit it runs is a line in GATE_LOG.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
# shellcheck source=tests/lib.sh
source ./lib.sh
# shellcheck source=tests/gate-stub-hold.sh
source ./gate-stub-hold.sh

REPO="$(cd .. && pwd)"
TMP="$(mktemp -d)" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/home" "$TMP/run" "$TMP/lanes" "$TMP/ws" "$TMP/tmp"

contains() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }

PROTO="$(sed -n 's/^DEVBOX_PROTOCOL_VERSION=\(.*\)$/\1/p' "$REPO/lib/devbox-lib.sh")"
FP="$(sha256sum <"$REPO/lib/devbox-lib.sh" | cut -d' ' -f1)"
HOLD_LOG="$TMP/hold.log"
SSH_LOG="$TMP/ssh.log"
GATE_LOG="$TMP/gate.log"
export HOLD_LOG SSH_LOG GATE_LOG
export FAKE_VERSION="$PROTO $FP" FAKE_LANES="$TMP/lanes" FAKE_WS="$TMP/ws"
export FAKE_STOP_FILE="$TMP/stops" FAKE_GRANT_FILE="$TMP/grants"
export FAKE_SLEEP_FIFO="$TMP/sleep.fifo" HANG_PID="$TMP/hang.pid"
mkfifo "$FAKE_SLEEP_FIFO"

# The two fake hosts, at RFC 5737 addresses.
A_LAN1=192.0.2.10
A_VPS1=192.0.2.11

{ gate_stub_head; gate_stub_hold; cat <<'STUB'
case "$GATE_CMD" in
  version) printf '%s\n' "$FAKE_VERSION" ;;
  "queue-estimate "*) printf 'now 0 3 0/20 0/4 0\n' ;;
  "ensure-workspace "*) printf 'postgresql://fixture:fixture@fixture/fixture\n' ;;
  "sync-finish "*) ;;
  "setup "*) while IFS= read -r _; do :; done ;;
  "oom-count "*) printf '0\n' ;;
  "lock "*) _hold_lock ;;
  "run "*) _hold_run; _hold_gate ;;
  "ledger "*) _hold_ledger ;;
esac
exit 0
STUB
} >"$TMP/bin/ssh"
# The sync's rsync to a host records nothing and sends nothing. The ledger key
# lists the files with a local rsync dry run, which must be the real rsync.
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

# The project's gate. Two steps through the devbox-ledger the hooks wrote into
# the workspace, then two test files, each a `start` line and then a `pass` or
# a `fail`. FAKE_FAIL names units that fail. FAKE_STOP_AT names the file the
# watchdog stops when the stub says it will (FAKE_STOPPING=1). FAKE_HANG_AT
# names a file that hangs until the test kills the client.
cat >"$TMP/gate.sh" <<'GATE'
#!/bin/bash
set -u
printf 'run host=%s resume=%s key=%s tools=%s ledger=%s\n' "${GATE_HOST-local}" "${DEVBOX_RESUME-unset}" \
  "${DEVBOX_LEDGER_KEY-unset}" "${DEVBOX_LEDGER_TOOLS-unset}" "${DEVBOX_LEDGER-unset}" >>"$GATE_LOG"
[ -z "${FAKE_NO_LEDGER-}" ] || exit "${FAKE_GATE_RC:-0}"
rc=0
for s in lint build; do
  "$DEVBOX_LEDGER_TOOLS/devbox-ledger" step "$s" -- bash -c \
    'echo "ran $1" >>"$GATE_LOG"; case " ${FAKE_FAIL-} " in *" $1 "*) exit 1 ;; esac' _ "$s" >/dev/null || rc=1
done
for f in a.test.ts b.test.ts; do
  if [ "${DEVBOX_RESUME:-0}" = 1 ] && awk -F'\t' -v f="$f" '$1 == "file" && $3 == f { last = $4 } END { exit last != "pass" }' "$DEVBOX_LEDGER"; then
    continue
  fi
  echo "ran $f" >>"$GATE_LOG"
  printf 'file\tvitest\t%s\tstart\n' "$f" >>"$DEVBOX_LEDGER"
  stop_at="${FAKE_STOP_AT-}"
  [ "${DEVBOX_RESUME:-0}" = 0 ] || stop_at="${FAKE_STOP_AT_RESUME:-$stop_at}"
  if [ "${FAKE_STOPPING:-0}" = 1 ] && [ "$f" = "$stop_at" ]; then
    [ -z "${FAKE_GRANT_AFTER_STOP-}" ] || printf '%s\n' "$FAKE_GRANT_AFTER_STOP" >"$FAKE_GRANT_FILE"
    exit 0
  fi
  if [ "$f" = "${FAKE_HANG_AT-}" ]; then
    echo "$$" >"$HANG_PID"
    read -r -t 20 _ <>"$FAKE_SLEEP_FIFO"
    exit 0
  fi
  case " ${FAKE_FAIL-} " in
    *" $f "*) printf 'file\tvitest\t%s\tfail\t1\n' "$f" >>"$DEVBOX_LEDGER"; rc=1 ;;
    *) printf 'file\tvitest\t%s\tpass\t1\n' "$f" >>"$DEVBOX_LEDGER" ;;
  esac
done
exit "$rc"
GATE

CO="$TMP/checkout"
mkdir -p "$CO/.devbox"
git -C "$CO" init -q >/dev/null 2>&1
: >"$CO/.devbox/exclude"
printf 'one\n' >"$CO/src.txt"
write_config() {
  printf 'DEVBOX_PROJECT=app\nDEVBOX_WANT_TOKENS=4\nDEVBOX_MIN_TOKENS=2\nDEVBOX_SETUP=:\nDEVBOX_VERIFY=bash %s\nDEVBOX_FORWARD_ENV=FIXTURE_SWITCH\n' \
    "$TMP/gate.sh" >"$CO/.devbox/config.env"
  printf '%s\n' "$@" >>"$CO/.devbox/config.env"
}
write_config
{
  echo 'DEVBOX_TARGETS=lan1,vps1'
  echo "DEVBOX_TARGET_LAN1=$A_LAN1"; echo "DEVBOX_TARGET_LAN1_HOSTKEY=$GATE_STUB_PIN"
  echo "DEVBOX_TARGET_VPS1=$A_VPS1"; echo "DEVBOX_TARGET_VPS1_HOSTKEY=$GATE_STUB_PIN"
  echo 'DEVBOX_GATE_PASSWORD=fixture-gate-password'
  echo 'DEVBOX_AFFINITY_GRACE=0'
} >"$CO/.devbox.env"

# This checkout's lane slugs, as devbox-verify computes them on this machine.
# shellcheck source=/dev/null
source "$REPO/lib/devbox-lib.sh"
mapfile -t LANES < <(devbox_lane_slugs "$(devbox_machine_label)" "$(devbox_machine_id)" app "$CO" 2)
LDIR="$TMP/run/devbox/ledgers"
MARK="$LDIR/${LANES[0]}.open"
COPY="$LDIR/${LANES[0]}.ledger"
WS_LAN1="$TMP/ws/$A_LAN1/${LANES[0]}"
WS_VPS1="$TMP/ws/$A_VPS1/${LANES[0]}"

out=""; rc=0
reset() {
  : >"$HOLD_LOG"; : >"$SSH_LOG"; : >"$GATE_LOG"
  rm -rf "${TMP:?}/ws/"* "$LDIR" "$FAKE_STOP_FILE" "$FAKE_GRANT_FILE" "$HANG_PID" "$CO/.git/devbox/last-target"
}
# Every case but D6 runs on lan1: vps1 never grants.
verify() {
  rc=0
  [ -f "$FAKE_GRANT_FILE" ] || printf '%s:never\n' "$A_VPS1" >"$FAKE_GRANT_FILE"
  out="$(cd "$CO" && env PATH="$TMP/bin:$PATH" HOME="$TMP/home" XDG_RUNTIME_DIR="$TMP/run" TMPDIR="$TMP/tmp" \
    DEVBOX_LOCK_WAIT=30 bash "$REPO/client/libexec/devbox-verify" "$@" 2>&1)" || rc=$?
}
stops() { printf '%s\n' "$1" >"$FAKE_STOP_FILE"; }
# The number of gate runs, and the units run number $1 ran, as one line.
runs() { grep -c '^run ' "$GATE_LOG"; }
ran() { awk -v n="$1" '/^run / { k++; next } k == n { printf "%s%s", sep, $2; sep = " " }' "$GATE_LOG"; }
# The field $2 of the `run` line of run $1, such as resume or key.
run_field() { awk -v n="$1" -v f="$2" '/^run / { k++; if (k == n) for (i = 2; i <= NF; i++) if (index($i, f "=") == 1) print substr($i, length(f) + 2) }' "$GATE_LOG"; }
# The key a fresh run on lan1 wrote at the top of its ledger.
key_of() { awk -F'\t' 'NR == 1 && $1 == "key" { print $2 }' "$1"; }
# Write a marker and a local copy by hand: a gate of key $1 on lan1 that never
# returned, with lint and build passed and a.test.ts open. $2 is 1 when the
# local copy is the fetched one.
craft() {
  mkdir -p "$LDIR"
  printf 'target\tlan1\nlane\t%s\nrun\t0123456789abcdef.1\nkey\t%s\nbase\t2\n' "${LANES[0]}" "$1" >"$MARK"
  [ "$2" = 0 ] || printf 'fetched\n' >>"$MARK"
  printf 'key\t%s\nresume\t0\nstep\tlint\tstart\nstep\tlint\tpass\t1\nstep\tbuild\tstart\nstep\tbuild\tpass\t1\nfile\tvitest\ta.test.ts\tstart\n' "$1" >"$COPY"
}

# ═══ D1 and D5: a stop resumes at once, and runs only the unpassed units ════
#
# lint fails, build passes, and the watchdog stops a.test.ts mid-file. The
# resume runs lint (failed), a.test.ts (open) and b.test.ts (never started),
# and not build.
reset
stops 1
FAKE_FAIL=lint FAKE_STOP_AT=a.test.ts verify --target lan1
assert_eq "1" "$rc" "D5: the resume's own code is the run's code (lint fails again)"
assert_ok "D5: the stop is reported" contains "the watchdog on lan1 stopped this gate" "$out"
assert_ok "D5: the resume line names the passed units, the total and the count" \
  contains "devbox: resuming, 1 of 3 units passed earlier, resume 1 of 1" "$out"
assert_eq "2" "$(runs)" "D5: the gate ran twice in one devbox verify"
assert_eq "lint build a.test.ts" "$(ran 1)" "D1: the first run ran up to the stop"
assert_eq "lint a.test.ts b.test.ts" "$(ran 2)" "D1: the resume ran the failed, the open and the unstarted units, and not build"
assert_eq "0" "$(run_field 1 resume)" "D1: the first run had DEVBOX_RESUME=0"
assert_eq "1" "$(run_field 2 resume)" "D1: the resume had DEVBOX_RESUME=1"
assert_eq "$(key_of "$WS_LAN1/ledger/app.ledger")" "$(run_field 2 key)" "D1: DEVBOX_LEDGER_KEY in the env header is the ledger's key"
assert_eq "$WS_LAN1/ledger-tools" "$(run_field 1 tools)" "D1: DEVBOX_LEDGER_TOOLS names the tools directory of the workspace"
assert_eq "$WS_LAN1/ledger/app.ledger" "$(run_field 1 ledger)" "D1: DEVBOX_LEDGER names the ledger of the project in the workspace"
assert_ok "D1: the step helper is in the workspace, mode 0755" test "$(stat -c %a "$WS_LAN1/ledger-tools/devbox-ledger")" = 755
for t in devbox-ledger vitest-ledger.mjs ledger-core.mjs devbox_ledger.py; do
  assert_ok "D1: $t in the workspace is this client's own" cmp -s "$REPO/client/share/ledger/$t" "$WS_LAN1/ledger-tools/$t"
done
assert_eq $'resume\t1' "$(sed -n 2p "$WS_LAN1/ledger/app.ledger")" "D1: the resumed ledger's resume line was raised by one"
assert_fail "D5: a gate that returned its own code leaves no marker" test -e "$MARK"
assert_fail "D5: and no local copy" test -e "$COPY"
assert_fail "D7: a gate with records gets no warning" contains "wrote no ledger" "$out"
assert_eq "2" "$(grep -c " $A_LAN1 ledger " "$HOLD_LOG")" "D5: one fetch after the stop and one after the resume returned"

# ═══ D5 and R2: a second stop ends the resumes, and names a file open twice ══
reset
stops 2
FAKE_STOP_AT=a.test.ts verify --target lan1
assert_eq "10" "$rc" "D5: a gate stopped twice exits 10 with the default of one resume"
assert_eq "2" "$(runs)" "D5: one resume, then no more"
assert_ok "D5: it says why it does not resume again" \
  contains "this gate resumed 1 time(s), and DEVBOX_MAX_RESUMES in $CO/.devbox/config.env is 1, so it does not resume again" "$out"
assert_ok "R2: a file open at both stops is named" contains "devbox verify: a.test.ts was running at both stops; it may hang" "$out"
assert_ok "D5: the marker stays after exit 10" test -f "$MARK"
stops 0
verify --target lan1
assert_eq "0" "$rc" "D5: the next verify completes"
assert_ok "D5: it discards the ledger whose count is spent, and says why" \
  contains "the unfinished gate of this worktree resumed 1 time(s), and DEVBOX_MAX_RESUMES in $CO/.devbox/config.env is 1, so its ledger is discarded and the gate runs in full" "$out"
assert_eq "lint build a.test.ts b.test.ts" "$(ran 3)" "D5: and runs the gate in full"
assert_eq "0" "$(run_field 3 resume)" "D5: with DEVBOX_RESUME=0"
# A file open at the first stop and finished before the second is not named.
reset
stops 2
FAKE_STOP_AT=a.test.ts FAKE_STOP_AT_RESUME=b.test.ts verify --target lan1
assert_eq "10" "$rc" "R2: two stops at two files exit 10"
assert_fail "R2: a file open at one stop only is not named" contains "was running at both stops" "$out"

# ═══ D5: DEVBOX_MAX_RESUMES=0 turns resuming off, and the ledger is written ══
reset
write_config 'DEVBOX_MAX_RESUMES=0'
stops 1
FAKE_STOP_AT=b.test.ts verify --target lan1
assert_eq "10" "$rc" "D5: with DEVBOX_MAX_RESUMES=0 a stop exits 10"
assert_eq "1" "$(runs)" "D5: and nothing resumes"
assert_fail "D5: no resume line" contains "devbox: resuming" "$out"
assert_ok "D5: the gate still wrote its ledger" grep -qE $'^step\tbuild\tpass\t[0-9]+$' "$WS_LAN1/ledger/app.ledger"
write_config

# ═══ R4: DEVBOX_MAX_RESUMES outside 0 to 9 is refused before any host ═══════
for bad in 10 -1 one; do
  reset
  write_config "DEVBOX_MAX_RESUMES=$bad"
  verify --target lan1
  assert_eq "2" "$rc" "R4: DEVBOX_MAX_RESUMES=$bad exits 2"
  assert_ok "R4: naming the file and the value" \
    contains "devbox: $CO/.devbox/config.env: refusing DEVBOX_MAX_RESUMES '$bad': write a whole number from 0 to 9" "$out"
  assert_eq "" "$(cat "$SSH_LOG")" "R4: and no ssh call was made for $bad"
done
write_config

# ═══ R1: a gate whose client died resumes from the marker ════════════════════
reset
printf '%s:never\n' "$A_VPS1" >"$FAKE_GRANT_FILE"
(cd "$CO" && exec env PATH="$TMP/bin:$PATH" HOME="$TMP/home" XDG_RUNTIME_DIR="$TMP/run" TMPDIR="$TMP/tmp" \
  DEVBOX_LOCK_WAIT=30 FAKE_HANG_AT=a.test.ts bash "$REPO/client/libexec/devbox-verify" --target lan1 >"$TMP/r1.out" 2>&1) &
r1=$!
for _ in $(seq 1 100); do [ -s "$HANG_PID" ] && break; sleep 0.1; done
assert_ok "R1: the gate reached a.test.ts" test -s "$HANG_PID"
kill -TERM "$r1" 2>/dev/null
wait "$r1" 2>/dev/null
kill "$(cat "$HANG_PID")" 2>/dev/null
sleep 0.5
assert_ok "R1: the marker stays when the client dies" test -f "$MARK"
assert_ok "R1: it names lan1, lane 1 and the key" grep -qx $'target\tlan1' "$MARK"
rm -f "$HANG_PID"
verify --target lan1
assert_eq "0" "$rc" "R1: the next verify completes"
assert_ok "R1: it resumes from the marker" contains "devbox: resuming, 2 of 3 units passed earlier, resume 1 of 1" "$out"
assert_eq "a.test.ts b.test.ts" "$(ran 2)" "R1: and runs only the open and the unstarted files"
assert_fail "R1: the completed resume leaves no marker" test -e "$MARK"

# ═══ D6: the resume lands on another target and carries the ledger there ═════
reset
printf '%s:never\n' "$A_VPS1" >"$FAKE_GRANT_FILE"
stops 1
FAKE_STOP_AT=a.test.ts FAKE_GRANT_AFTER_STOP="$A_LAN1:never" verify
assert_eq "0" "$rc" "D6: a stop on lan1, then a resume elsewhere: the run completes"
assert_eq "$A_LAN1" "$(run_field 1 host)" "D6: the first gate ran on lan1"
assert_eq "$A_VPS1" "$(run_field 2 host)" "D6: the resume ran on vps1"
assert_eq "1" "$(grep -c " $A_LAN1 ledger " "$HOLD_LOG")" "D6: the ledger was fetched from lan1 after the stop"
assert_ok "D6: the ledger written into vps1's workspace holds lan1's records" \
  grep -qE $'^step\tbuild\tpass\t[0-9]+$' "$WS_VPS1/ledger/app.ledger"
assert_eq $'resume\t1' "$(sed -n 2p "$WS_VPS1/ledger/app.ledger")" "D6: with the resume count raised"
assert_eq "a.test.ts b.test.ts" "$(ran 2)" "D6: and the resume skipped what passed on lan1"

# ═══ D3: a ledger written under other inputs is discarded ════════════════════
reset
verify --target lan1
assert_eq "0" "$rc" "D3: a fresh gate completes"
K0="$(key_of "$WS_LAN1/ledger/app.ledger")"
assert_ok "D3: its ledger carries a sha256 key" grep -qE '^[0-9a-f]{64}$' <<<"$K0"
craft "$K0" 1
verify --target lan1
assert_ok "D3: with unchanged inputs a marker resumes" contains "devbox: resuming, 2 of 3 units passed earlier" "$out"
d3_full() {
  craft "$K0" 1
  : >"$GATE_LOG"
  verify --target lan1
  assert_ok "D3: $1: the marker is discarded, saying why" contains "ran on other inputs (its ledger key differs)" "$out"
  assert_eq "lint build a.test.ts b.test.ts" "$(ran 1)" "D3: $1: the gate runs in full"
}
printf 'two\n' >"$CO/src.txt"
d3_full "one synced byte changed"
printf 'one\n' >"$CO/src.txt"
write_config '# a comment changes the bytes of config.env'
d3_full "config.env changed"
write_config
FIXTURE_SWITCH=on verify --target lan1
K_ON="$(key_of "$WS_LAN1/ledger/app.ledger")"
assert_ok "D3: a forwarded value changes the key" test "$K_ON" != "$K0"
K0="$K_ON"
export FIXTURE_SWITCH=off
d3_full "a forwarded value changed"
unset FIXTURE_SWITCH
# A file the sync never sends is not an input.
printf 'X=1\n' >"$CO/.env"
craft "$K0" 1
FIXTURE_SWITCH=on verify --target lan1
assert_ok "D3: a file the sync excludes does not change the key" contains "devbox: resuming" "$out"
rm -f "$CO/.env"

# ═══ R7: a forwarded value enters the key only as a hash ════════════════════
reset
SECRET="fixture-forwarded-value-7f3a"
FIXTURE_SWITCH="$SECRET" verify --target lan1
assert_eq "0" "$rc" "R7: a run with a forwarded value completes"
key_input="$(cd "$CO" && FIXTURE_SWITCH="$SECRET" bash -c '
  set -euo pipefail
  source "$1/lib/devbox-lib.sh"; source "$1/client/libexec/devbox-config"; source "$1/client/libexec/devbox-sync"
  ROOT="$PWD"; devbox_config_load
  devbox_ledger_key_input "$1/VERSION" "$2/none" FIXTURE_SWITCH' _ "$REPO" "$TMP/tmp")"
assert_fail "R7: the key input does not hold the forwarded value" contains "$SECRET" "$key_input"
assert_ok "R7: it holds the name and the sha256 of the value" \
  contains "FIXTURE_SWITCH $(printf '%s' "$SECRET" | sha256sum | cut -d' ' -f1)" "$key_input"
assert_eq "$(key_of "$WS_LAN1/ledger/app.ledger")" "$(printf '%s\n' "$key_input" | sha256sum | cut -d' ' -f1)" \
  "R7: the run's key is the sha256 of that input"
assert_fail "R7: no file of the private dir holds the value" grep -rqF "$SECRET" "$TMP/run"
assert_fail "R7: the ledger does not hold it" grep -qF "$SECRET" "$WS_LAN1/ledger/app.ledger"
assert_fail "R7: no argv holds it" grep -qF "$SECRET" "$SSH_LOG"

# ═══ R3: --fresh ignores and discards an unfinished ledger ═══════════════════
craft "$(key_of "$WS_LAN1/ledger/app.ledger")" 1
: >"$GATE_LOG"
verify --target lan1 --fresh
assert_eq "0" "$rc" "R3: --fresh completes"
assert_ok "R3: it says the unfinished gate is discarded" \
  contains "devbox verify: --fresh, so the unfinished gate of this worktree is discarded and the gate runs in full" "$out"
assert_eq "lint build a.test.ts b.test.ts" "$(ran 1)" "R3: and runs in full"
assert_eq "0" "$(run_field 1 resume)" "R3: with DEVBOX_RESUME=0"
assert_fail "R3: devbox run takes no --fresh" bash -c "cd '$CO' && bash '$REPO/client/libexec/devbox-run' --fresh -- true >/dev/null 2>&1"

# ═══ R6: a host without the ledger verb runs the gate in full ════════════════
reset
verify --target lan1
craft "$(key_of "$WS_LAN1/ledger/app.ledger")" 0
: >"$GATE_LOG"
FAKE_LEDGER_OLD="$A_LAN1" verify --target lan1
assert_eq "0" "$rc" "R6: an older host: the run completes"
assert_ok "R6: one line says the host predates the verb" \
  contains "devbox verify: lan1 predates the ledger verb, so the gate runs in full. Run 'devbox server install' for lan1" "$out"
assert_eq "lint build a.test.ts b.test.ts" "$(ran 1)" "R6: and the gate runs in full"
# A workspace that holds no ledger, as a collected volume does.
craft "$(key_of "$WS_LAN1/ledger/app.ledger")" 0
rm -f "$WS_LAN1/ledger/app.ledger"
: >"$GATE_LOG"
verify --target lan1
assert_ok "R6: a workspace with no ledger: one line names it" \
  contains "devbox verify: lan1 holds no ledger of this worktree's gate (gate-root: no ledger for project app in workspace ws-${LANES[0]}), so the gate runs in full" "$out"
assert_eq "lint build a.test.ts b.test.ts" "$(ran 1)" "R6: and the gate runs in full"

# ═══ D7: a verify gate that writes no ledger is warned, with its own code ═══
reset
FAKE_NO_LEDGER=1 FAKE_GATE_RC=3 verify --target lan1
assert_eq "3" "$rc" "D7: the gate's own code passes unchanged"
assert_ok "D7: with the warning line" contains "devbox verify: this gate wrote no ledger, so a stop cannot resume it" "$out"
FAKE_NO_LEDGER=1 FAKE_LEDGER_OLD="$A_LAN1" verify --target lan1
assert_eq "0" "$rc" "D7: a fetch that fails changes no code"
assert_fail "D7: and prints no warning" contains "wrote no ledger" "$out"
# `devbox run` is not a gate: no ledger in its environment, no marker, no warning.
rc=0
out="$(cd "$CO" && env PATH="$TMP/bin:$PATH" HOME="$TMP/home" XDG_RUNTIME_DIR="$TMP/run" TMPDIR="$TMP/tmp" \
  DEVBOX_LOCK_WAIT=30 bash "$REPO/client/libexec/devbox-run" --target lan1 -- printenv DEVBOX_RESUME 2>&1)" || rc=$?
assert_eq "1" "$rc" "D7: devbox run's command sees no DEVBOX_RESUME"
assert_fail "D7: devbox run gets no warning" contains "wrote no ledger" "$out"
assert_fail "D7: and leaves no marker" test -e "$MARK"

# ═══ strict mode: the resume's code passes through, and a spent stop is 76 ══
reset
stops 1
rc=0
out="$(cd "$CO" && env PATH="$TMP/bin:$PATH" HOME="$TMP/home" XDG_RUNTIME_DIR="$TMP/run" TMPDIR="$TMP/tmp" \
  DEVBOX_LOCK_WAIT=30 DEVBOX_STRICT=1 FAKE_STOP_AT=a.test.ts bash "$REPO/client/libexec/devbox-verify" --target lan1 2>&1)" || rc=$?
assert_eq "0" "$rc" "D5: under DEVBOX_STRICT=1 a resumed gate that passes exits 0"
reset
stops 2
rc=0
out="$(cd "$CO" && env PATH="$TMP/bin:$PATH" HOME="$TMP/home" XDG_RUNTIME_DIR="$TMP/run" TMPDIR="$TMP/tmp" \
  DEVBOX_LOCK_WAIT=30 DEVBOX_STRICT=1 FAKE_STOP_AT=a.test.ts bash "$REPO/client/libexec/devbox-verify" --target lan1 2>&1)" || rc=$?
assert_eq "76" "$rc" "D5: under DEVBOX_STRICT=1 a second stop is 76"
assert_eq "1" "$(grep -c '::devbox-infra::watchdog' <<<"$out")" "D5: with one watchdog line per stop that ends the run"

# ═══ a gate that ends before it reads its stdin ends the run ═════════════════
#
# The stdin carries the tools and the ledger, more than a pipe's buffer holds.
# MEASURED: before the write moved to a background job, this run blocked in
# the write for good.
reset
t0="$SECONDS"
FAKE_SKIP_STDIN=9 verify --target lan1
assert_eq "9" "$rc" "a gate that reads no stdin: its code is the run's"
assert_ok "and the run ends within seconds" test "$((SECONDS - t0))" -lt 20

# ═══ the local fallback: the client's own tools, a ledger in the private dir ═
reset
: >"$GATE_LOG"
verify --local
assert_eq "0" "$rc" "a local gate completes"
assert_eq "$REPO/client/share/ledger" "$(run_field 1 tools)" "a local gate's DEVBOX_LEDGER_TOOLS is this client's client/share/ledger"
local_ledger="$(run_field 1 ledger)"
assert_ok "its ledger sits in the private dir" contains "$LDIR/local-" "$local_ledger"
assert_ok "and holds its records" grep -qE $'^step\tbuild\tpass\t[0-9]+$' "$local_ledger"
assert_ok "under a fresh key and resume line" grep -qx $'resume\t0' "$local_ledger"

printf '%d %d\n' "$TESTS_RUN" "$TESTS_FAILED"
