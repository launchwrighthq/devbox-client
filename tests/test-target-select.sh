#!/bin/bash
# Target selection: every selection rule, every example of one, the skip lines,
# the unreachable cache and affinity.
#
# devbox_select is a pure function of the probe answers, so the rules are driven
# with probe lines and no host. The end-to-end cases at the bottom run the real
# devbox-verify against a fake ssh that plays two targets, which is what proves
# the probe, the cache and the affinity record are wired to the rules.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
# shellcheck source=tests/lib.sh
source ./lib.sh
REPO="$(cd .. && pwd)"
LIB="$REPO/lib/devbox-lib.sh"
# shellcheck source=lib/devbox-lib.sh
source "$LIB"
# shellcheck source=client/libexec/devbox-targets
source "$REPO/client/libexec/devbox-targets"

TMP="$(mktemp -d)" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
contains()     { case "$2" in *"$1"*) return 0 ;; esac; return 1; }
not_contains() { case "$2" in *"$1"*) return 1 ;; esac; return 0; }

PROTO="$DEVBOX_PROTOCOL_VERSION"
FP="$(sha256sum <"$LIB" | cut -d' ' -f1)"

# One probe fact. $1 name, $2 verdict, $3 seconds; HEALTH, AGE and REASON
# default to a healthy target, and P and F to this client's own handshake.
fact() {
  local reason="${REASON-}"
  printf '%s probe %s %s %s %s %s %s 4/20 1/4 0%s\n' "$1" "${P-$PROTO}" "${F-$FP}" \
    "${HEALTH-ok}" "${AGE-5}" "$2" "$3" "${reason:+ $reason}"
}

# The defaults every case starts from, one worked example: two deployed
# targets in this order, no rental, a 600-second ceiling, the fail action.
reset_select() {
  SELECT_TARGETS=(lan1 cloud1)
  SELECT_AFFINITY=""
  SELECT_RENT=()
  SELECT_MAX_WAIT=600
  SELECT_ACTION=fail
  SELECT_LIB="$LIB"
  SELECT_MIN=4
}
out=""
run_select() { out="$(printf '%s\n' "$@" | devbox_select)"; }
decision() { printf '%s\n' "$out" | tail -n1; }
skips() { printf '%s\n' "$out" | grep -c '^skip ' || true; }

# ── rule 1: the affinity target, when it can take the gate now ───────────────
reset_select
SELECT_AFFINITY=cloud1
run_select "$(fact lan1 now 0)" "$(fact cloud1 now 0)"
assert_eq "pick cloud1 1 now 0 4/20 1/4 0" "$(decision)" \
  "example 1: at home, both free, the last target wins (rule 1)"
assert_eq "0" "$(skips)" "and a target that only lost to affinity is not skipped"

# ── rule 2: the first target in list order that fits now ─────────────────────
reset_select
SELECT_AFFINITY=cloud1
run_select "$(fact lan1 now 0)" "$(fact cloud1 wait 240)"
assert_eq "pick lan1 2 now 0 4/20 1/4 0" "$(decision)" \
  "example 2: the last target has a 4-minute queue, the free one wins (rule 2)"
assert_ok "and the busy last target gets a skip line with its wait" \
  contains "skip cloud1 busy skipped: busy, about 240s of queuing" "$out"

reset_select
run_select "$(fact lan1 now 0)" "$(fact cloud1 now 0)"
assert_eq "pick lan1 2 now 0 4/20 1/4 0" "$(decision)" "with no affinity, list order decides"

reset_select
SELECT_TARGETS=(cloud1 lan1)
run_select "$(fact lan1 now 0)" "$(fact cloud1 now 0)"
assert_ok "and the order is DEVBOX_TARGETS', not the order of the answers" \
  contains "pick cloud1 2" "$(decision)"

reset_select
SELECT_AFFINITY=gone
run_select "$(fact lan1 now 0)" "$(fact cloud1 now 0)"
assert_ok "an affinity record naming a target no longer listed is passed over" \
  contains "pick lan1 2" "$(decision)"

# ── rule 3: the smallest wait under the ceiling ──────────────────────────────
reset_select
SELECT_AFFINITY=cloud1
run_select "lan1 unreachable no answer in 3s" "$(fact cloud1 wait 120)"
assert_eq "pick cloud1 3 wait 120 4/20 1/4 0" "$(decision)" \
  "example 3: in a cafe, the LAN target does not answer and the busy one is under the ceiling (rule 3)"
assert_ok "and the unreachable target is named with its reason" \
  contains "skip lan1 unreachable unreachable (no answer in 3s)" "$out"

reset_select
run_select "$(fact lan1 wait 300)" "$(fact cloud1 wait 100)"
assert_ok "the smallest wait wins, whatever the list order" contains "pick cloud1 3 wait 100" "$(decision)"
assert_ok "and the longer queue is named" contains "skip lan1 busy skipped: busy, about 300s of queuing" "$out"

reset_select
SELECT_AFFINITY=cloud1
run_select "$(fact lan1 wait 100)" "$(fact cloud1 wait 100)"
assert_ok "on a tie the affinity target wins" contains "pick cloud1 3" "$(decision)"

reset_select
run_select "$(fact lan1 unknown -)" "$(fact cloud1 wait 500)"
assert_ok "a wait the pool could not estimate ranks after every number" contains "pick cloud1 3" "$(decision)"
reset_select
run_select "$(fact lan1 unknown -)" "cloud1 unreachable no answer in 3s"
assert_ok "and is still taken when it is the only one left" contains "pick lan1 3 unknown -" "$(decision)"

reset_select
run_select "$(fact lan1 wait 600)" "$(fact cloud1 wait 900)"
assert_ok "a wait equal to the ceiling is under it" contains "pick lan1 3 wait 600" "$(decision)"

reset_select
SELECT_MAX_WAIT=0
run_select "$(fact lan1 wait 5000)" "$(fact cloud1 wait 9000)"
assert_ok "a ceiling of 0 is no ceiling" contains "pick lan1 3 wait 5000" "$(decision)"

# ── rule 4: the first rented target ──────────────────────────────────────────
reset_select
SELECT_RENT=(runpod)
HEALTH=down REASON="docker" run_select "lan1 unreachable no answer in 3s" "$(HEALTH=down REASON=docker fact cloud1 now 0)"
assert_eq "rent runpod" "$(decision)" "example 4: in a cafe, the public target is down and DEVBOX_RENT rents (rule 4)"
assert_ok "the down target is named with the watchdog's reason" \
  contains "skip cloud1 unhealthy skipped: down (docker)" "$out"
assert_ok "and the unreachable one too" contains "skip lan1 unreachable" "$out"

reset_select
SELECT_RENT=(runpod)
SELECT_ACTION=local
run_select "$(fact lan1 wait 900)" "$(fact cloud1 wait 700)"
assert_eq "rent runpod" "$(decision)" "a rental comes before the laptop"

reset_select
run_select "$(fact lan1 wait 900)" "$(fact cloud1 wait 700)"
assert_eq "fail 8 none" "$(decision)" "with no DEVBOX_RENT, nothing is rented"

# ── rule 5: the laptop, with DEVBOX_QUEUE_FULL_ACTION=local ──────────────────
reset_select
SELECT_ACTION=local
run_select "$(fact lan1 wait 900)" "$(fact cloud1 wait 700)"
assert_eq "local cloud1" "$(decision)" \
  "the laptop, naming the shortest queue over the ceiling in case it cannot run the gate"
assert_ok "and each target over the ceiling is named with both numbers" \
  contains "skip lan1 over skipped: busy, about 900s of queuing, over the DEVBOX_MAX_QUEUE_WAIT of 600s" "$out"
reset_select
SELECT_ACTION=local
run_select "lan1 unreachable no answer in 3s" "cloud1 unreachable no answer in 3s"
assert_eq "local" "$(decision)" "with nothing over the ceiling to wait on, the laptop alone"

# ── rule 6: no target can take this gate ─────────────────────────────────────
reset_select
run_select "$(fact lan1 wait 900)" "$(HEALTH=degraded REASON="disk 93%" fact cloud1 now 0)"
assert_eq "fail 8 none" "$(decision)" "a busy target and a degraded one exit 8"
assert_eq "2" "$(skips)" "with one line per target"
assert_ok "the degraded one names the watchdog's reason" \
  contains "skip cloud1 unhealthy skipped: degraded (disk 93%)" "$out"
reset_select
run_select "lan1 unreachable no answer in 3s" "cloud1 unreachable no answer in 3s"
assert_eq "fail 3 unreachable" "$(decision)" \
  "every target unreachable, and nothing to rent or fall back to, keeps the unreachable code 3"
reset_select
run_select "lan1 unreachable no answer in 3s" "$(fact cloud1 wait 900)"
assert_eq "fail 8 none" "$(decision)" "an unreachable target and a busy one are 8"

# ── a failure on EVERY target keeps its old code ─────────────────────────────
reset_select
SELECT_RENT=(runpod)
run_select "$(P=99 fact lan1 now 0)" "$(P=99 fact cloud1 now 0)"
assert_eq "fail 5 handshake" "$(decision)" \
  "a handshake mismatch on every target exits 5, before a rental, so the operator learns a deploy is due"
assert_ok "and each target names the two protocol integers" \
  contains "skip lan1 handshake skipped: the protocol integers differ: this client speaks $PROTO, the server speaks 99" "$out"
reset_select
run_select "$(P=99 fact lan1 now 0)" "$(fact cloud1 now 0)"
assert_ok "a handshake mismatch on ONE target skips it" contains "pick cloud1 2" "$(decision)"
assert_ok "with its own line" contains "skip lan1 handshake" "$out"
reset_select
run_select "$(F=0000 fact lan1 now 0)" "$(fact cloud1 wait 10)"
assert_ok "another library under one protocol is no handshake failure: lan1 is free now and is picked" \
  contains "pick lan1" "$(decision)"
reset_select
run_select "lan1 probe " "cloud1 probe "
assert_eq "fail 5 handshake" "$(decision)" \
  "a host whose devbox-gate predates the probe verb answers no probe line, which is a handshake failure on every target"
assert_ok "named as a server that reported no version" contains "did not report a protocol version" "$out"
reset_select
run_select "$(fact lan1 now 0)" "lan1 requires 1" "$(fact cloud1 now 0)" "cloud1 requires 1"
assert_eq "fail 6 requires" "$(decision)" "an image that lacks a DEVBOX_REQUIRES token on every target exits 6"
reset_select
run_select "$(fact lan1 now 0)" "lan1 requires 1" "$(fact cloud1 wait 30)"
assert_ok "an image short on ONE target skips it" contains "pick cloud1 3" "$(decision)"
assert_ok "with its own line" \
  contains "skip lan1 requires skipped: its workspace image does not satisfy DEVBOX_REQUIRES" "$out"
reset_select
SELECT_RENT=(runpod)
run_select "lan1 refused Permission denied (password)." "cloud1 refused Permission denied (password)."
assert_eq "fail 3 auth" "$(decision)" \
  "a refused gate password on every target exits 3, never a silent skip and never a rental"
reset_select
run_select "lan1 hostkey the host key of lan1 differs" "$(fact cloud1 now 0)"
assert_ok "a changed host key on one target skips it" contains "pick cloud1 2" "$(decision)"
assert_ok "and names it" contains "skip lan1 auth skipped: the host key of lan1 differs" "$out"
reset_select
SELECT_ACTION=local
SELECT_MIN=32
run_select "$(fact lan1 never -)" "$(fact cloud1 never -)"
assert_eq "fail 8 never" "$(decision)" \
  "a pool too small on every target exits 8, even with the local action"
assert_ok "and each line names the total and DEVBOX_MIN_TOKENS" \
  contains "skip lan1 never skipped: its pool holds 20 token(s) in all, and can never grant DEVBOX_MIN_TOKENS=32" "$out"
reset_select
SELECT_RENT=(runpod)
run_select "$(P=99 fact lan1 now 0)" "$(fact cloud1 now 0)" "cloud1 requires 1"
assert_eq "rent runpod" "$(decision)" \
  "two DIFFERENT failures are not the same failure on every target, so the rental still applies"
( unset DEVBOX_PROTOCOL_VERSION
  reset_select
  run_select "$(fact lan1 now 0)" "$(fact cloud1 now 0)"
  assert_eq "fail 5 handshake" "$(decision)" "a client library with no protocol version is a handshake failure everywhere"
  assert_ok "classed as this client's own" contains "skip lan1 client" "$out"
  printf '%d %d\n' "$TESTS_RUN" "$TESTS_FAILED" >"$TMP/sub.counts"
)
read -r TESTS_RUN TESTS_FAILED <"$TMP/sub.counts"

# ── health ───────────────────────────────────────────────────────────────────
reset_select
run_select "$(HEALTH=missing AGE=-1 fact lan1 now 0)" "$(fact cloud1 wait 10)"
assert_ok "a target with no health record is skipped" \
  contains "skip lan1 unhealthy skipped: it has no health record, so its watchdog is not running" "$out"
reset_select
run_select "$(AGE=91 fact lan1 now 0)" "$(fact cloud1 wait 10)"
assert_ok "an ok record 91s old means the watchdog stopped" \
  contains "skip lan1 unhealthy skipped: its health record is 91s old, so its watchdog is not running" "$out"
reset_select
run_select "$(AGE=90 fact lan1 now 0)" "$(fact cloud1 wait 10)"
assert_ok "and one 90s old is still fresh" contains "pick lan1 2" "$(decision)"
reset_select
run_select "$(HEALTH=invalid AGE=-1 fact lan1 now 0)" "$(fact cloud1 wait 10)"
assert_ok "a record that does not parse is not trusted" contains "skip lan1 unhealthy" "$out"

# A target with no fact at all is a probe that died, and never a silent pass.
reset_select
run_select "$(fact cloud1 now 0)"
assert_ok "a target that gave no answer is named" contains "skip lan1 unreachable unreachable (it gave no answer)" "$out"

# ── the probe line, built on the host and read on the laptop ─────────────────
line="$(devbox_probe_line "$PROTO $FP" $'wait 120 4 20/20 4/4 2\n       detail' "1000 degraded disk 93%" 1030)"
assert_eq "$PROTO $FP degraded 30 wait 120 20/20 4/4 2 disk 93%" "$line" \
  "the probe line carries the handshake, the health with its age and reason, and the queue"
devbox_probe_parse "$line"
assert_eq "degraded|30|wait|120|20/20|4/4|2|disk 93%" \
  "$PROBE_HEALTH|$PROBE_HEALTH_AGE|$PROBE_VERDICT|$PROBE_SECS|$PROBE_TOKENS|$PROBE_JOBS|$PROBE_QUEUED|$PROBE_REASON" \
  "and the parser reads every field back"
assert_eq "- - missing -1 unknown - - - -" "$(devbox_probe_line "" "" "" 1030)" \
  "a host with no runner, no pool and no watchdog answers every field as unknown, and health as missing"
assert_eq "$PROTO $FP invalid -1 now 0 0/20 0/4 0" "$(devbox_probe_line "$PROTO $FP" "now 0 3 0/20 0/4 0" "garbage" 1030)" \
  "a health file that does not parse is invalid, not ok"
assert_eq "$PROTO $FP ok 0 now 0 0/20 0/4 0" "$(devbox_probe_line "$PROTO $FP" "now 0 3 0/20 0/4 0" "2000 ok" 1030)" \
  "a health line from the future is age 0, a clock that moved and not a stale watchdog"
assert_eq "usage: devbox-runner ok 0 unknown - - - -" \
  "$(devbox_probe_line "usage: devbox-runner {gc|version}" "nonsense" "1030 ok" 1030)" \
  "an old runner's usage line still crosses as two words, so the handshake calls it not a version"
assert_fail "a line with a word missing does not parse" devbox_probe_parse "$PROTO $FP ok 5 now 0 0/20 0/4"
assert_fail "a wait with no number does not parse" devbox_probe_parse "$PROTO $FP ok 5 wait - 0/20 0/4 0"
assert_fail "an unknown health word does not parse" devbox_probe_parse "$PROTO $FP fine 5 now 0 0/20 0/4 0"
# A host writes the reason text, and verify, doctor and the Hetzner wait print it.
# A review on 2026-11-12 found the reason reached the terminal unfiltered, so a
# host could send escape sequences to every developer whose verify skipped it.
devbox_probe_parse "$PROTO $FP degraded 5 now 0 0/20 0/4 0 disk "$'\e]0;owned\a\e[2J'"93%"
assert_eq "disk ]0;owned[2J93%" "$PROBE_REASON" "a reason carrying ESC and BEL is parsed with every non-printable character removed"

# ── the unreachable cache ────────────────────────────────────────────────────
mkdir -p "$TMP/priv"
devbox_unreachable_set "$TMP/priv" lan1 lan1.invalid 1000
assert_eq "30" "$(devbox_unreachable_age "$TMP/priv" lan1 lan1.invalid 1030)" "a fresh record gives its age"
assert_fail "a record 60s old has expired" devbox_unreachable_age "$TMP/priv" lan1 lan1.invalid 1060
assert_fail "a record for another address does not apply" devbox_unreachable_age "$TMP/priv" lan1 lan2.invalid 1030
devbox_unreachable_clear "$TMP/priv" lan1
assert_fail "and a target that answers clears it" devbox_unreachable_age "$TMP/priv" lan1 lan1.invalid 1030

# ── affinity ─────────────────────────────────────────────────────────────────
git -C "$TMP" init -q aff >/dev/null 2>&1
git -C "$TMP/aff" -c user.email=t@fixture.invalid -c user.name=fixture commit -q --allow-empty -m init >/dev/null 2>&1
git -C "$TMP/aff" worktree add -q -b wt "$TMP/aff-wt" >/dev/null 2>&1
assert_eq "" "$(cd "$TMP/aff" && devbox_affinity_read)" "a worktree that never ran has no affinity"
(cd "$TMP/aff" && devbox_affinity_write cloud1)
assert_eq "cloud1" "$(cd "$TMP/aff" && devbox_affinity_read)" "the last target is read back"
assert_ok "from the worktree's own git dir" test -f "$TMP/aff/.git/devbox/last-target"
assert_eq "" "$(cd "$TMP/aff-wt" && devbox_affinity_read)" "a linked worktree keeps its own record"
printf 'not a name!\n' >"$TMP/aff/.git/devbox/last-target"
assert_eq "" "$(cd "$TMP/aff" && devbox_affinity_read)" "a record that is not a target name is ignored"

# ═══ the real devbox-verify, against a fake ssh that plays two targets ═══════
#
# lan1 sits at lan-fixture and cloud1 at cloud-fixture. FAKE_UNREACHABLE
# makes one of them time out at the master open, and FAKE_PROBE_DIR holds a
# probe line per address when a case needs one target busy.
mkdir -p "$TMP/bin" "$TMP/fakehome" "$TMP/run" "$TMP/probes"
{ gate_stub_head; cat <<'STUB'
case "$GATE_CMD" in
  version) printf '%s\n' "$FAKE_VERSION" ;;
  "queue-estimate "*) printf 'now 0 3 0/20 0/4 0\n' ;;
  "ensure-workspace "*) printf 'postgresql://fixture:fixture@fixture/fixture\n' ;;
  "lock "*) printf 'LOCKED\n'; cat >/dev/null ;;
  "run "*) cat >"${RUN_STDIN:-/dev/null}"; printf 'GATE RAN ON %s\n' "$GATE_HOST" ;;
esac
exit 0
STUB
} >"$TMP/bin/ssh"
printf '#!/bin/bash\nexit 0\n' >"$TMP/bin/rsync"
chmod +x "$TMP/bin/ssh" "$TMP/bin/rsync"
gate_stub_keyscan "$TMP/bin"
export FAKE_VERSION="$PROTO $FP"

CO="$TMP/checkout"
mkdir -p "$CO/.devbox"
git -C "$CO" init -q >/dev/null 2>&1
: >"$CO/.devbox/exclude"
printf 'DEVBOX_PROJECT=select-fixture\nDEVBOX_WANT_TOKENS=2\nDEVBOX_MIN_TOKENS=1\nDEVBOX_SETUP=:\nDEVBOX_VERIFY=echo LOCAL GATE RAN\n' \
  >"$CO/.devbox/config.env"
printf 'DEVBOX_TARGETS=lan1,cloud1\nDEVBOX_TARGET_LAN1=lan-fixture\nDEVBOX_TARGET_LAN1_HOSTKEY=%s\nDEVBOX_TARGET_CLOUD1=cloud-fixture\nDEVBOX_TARGET_CLOUD1_HOSTKEY=%s\nDEVBOX_GATE_PASSWORD=fixture-gate-password\nDEVBOX_MAX_QUEUE_WAIT=600\n' "$GATE_STUB_PIN" "$GATE_STUB_PIN" \
  >"$CO/.devbox.env"
SSH_LOG="$TMP/ssh.log"
export SSH_LOG
rc=0
verify() {
  : >"$SSH_LOG"
  rc=0
  out="$(cd "$CO" && env PATH="$TMP/bin:$PATH" HOME="$TMP/fakehome" XDG_RUNTIME_DIR="$TMP/run" DEVBOX_LOCK_WAIT=5 \
    bash "$REPO/client/libexec/devbox-verify" "$@" 2>&1)" || rc=$?
}
last_target() { cat "$CO/.git/devbox/last-target" 2>/dev/null || true; }
opened() { grep -F -- "-f -N" "$SSH_LOG" | grep -cF "devbox-gate@$1" || true; }

verify
assert_eq "0" "$rc" "two healthy targets: the gate runs"
assert_ok "on the first in DEVBOX_TARGETS, by rule 2" \
  contains "==> devbox: running on lan1 (the first target in DEVBOX_TARGETS that can take it now)" "$out"
assert_ok "and the gate really ran there" contains "GATE RAN ON lan-fixture" "$out"
assert_eq "lan1" "$(last_target)" "the run records lan1 as this worktree's last target"
assert_eq "1" "$(opened lan-fixture)" "every target was probed: lan1"
assert_eq "1" "$(opened cloud-fixture)" "and cloud1"
assert_ok "with a 3-second connect timeout" grep -qF "ConnectTimeout=3" "$SSH_LOG"
# A connection whose far end went away with no reset held a verify run for
# over an hour, and the host had no grant for it. The keepalive is on the run
# verb too, which takes its own connection with no master.
assert_ok "the run verb's ssh sends a keepalive every 15 seconds" \
  grep -qE -- "ControlPath=none .*-o ServerAliveInterval=15 -o ServerAliveCountMax=4 .*devbox-gate@lan-fixture run " "$SSH_LOG"

# Affinity: the next run prefers the target that ran this worktree last.
printf 'cloud1\n' >"$CO/.git/devbox/last-target"
verify
assert_ok "a worktree that last ran on cloud1 runs there again, by rule 1" \
  contains "==> devbox: running on cloud1 (the last run of this worktree was here)" "$out"
assert_ok "and the gate ran there" contains "GATE RAN ON cloud-fixture" "$out"

# Example 2 end to end: the last target is busy, the other is free.
printf '%s\n' "$(devbox_probe_line "$PROTO $FP" "wait 240 4 20/20 4/4 2" "$(date +%s) ok" "$(date +%s)")" \
  >"$TMP/probes/cloud-fixture.probe"
export FAKE_PROBE_DIR="$TMP/probes"
verify
assert_ok "the busy last target is skipped with one named line" \
  contains "==> devbox: cloud1 skipped: busy, about 240s of queuing" "$out"
assert_ok "and the gate runs on the free one" contains "GATE RAN ON lan-fixture" "$out"
assert_eq "lan1" "$(last_target)" "which is now this worktree's last target"
rm -f "$TMP/probes/cloud-fixture.probe"

# Example 3 end to end: lan1 does not answer, so the run says so and goes on.
export FAKE_UNREACHABLE=lan-fixture
verify
assert_eq "0" "$rc" "an unreachable target does not stop the run"
assert_ok "it is named, never skipped in silence" \
  contains "==> devbox: lan1 unreachable (no answer in 3s)" "$out"
assert_ok "and the gate runs on cloud1" contains "GATE RAN ON cloud-fixture" "$out"
assert_ok "the cache records it in the private dir" test -f "$TMP/run/devbox/unreachable-lan1"

# The cache: back-to-back runs do not each wait for lan1 again.
verify
# A here-string, never `printf | grep -q`: grep -q exits at its first match, the
# printf still writing dies of SIGPIPE, and pipefail reads that as no match.
matches() { grep -qE "$1" <<<"$2"; }
assert_ok "the next run reads the cache, and names the cached answer with its age" \
  matches '^==> devbox: lan1 unreachable \(no answer [0-9]+s ago, kept for 60s\)$' "$out"
assert_ok "and still runs on cloud1" contains "GATE RAN ON cloud-fixture" "$out"
assert_eq "0" "$(opened lan-fixture)" "and opens no connection to lan1 at all"

# A forced target ignores the cache: a person who names it wants it asked.
unset FAKE_UNREACHABLE
verify --target lan1
assert_eq "0" "$rc" "--target lan1 runs while the cache still holds it"
assert_ok "on lan1" contains "GATE RAN ON lan-fixture" "$out"
assert_ok "naming why" contains "==> devbox: running on lan1 (--target lan1)" "$out"
assert_eq "0" "$(opened cloud-fixture)" "and cloud1 is not even probed"
assert_fail "and a target that answered clears its cache record" test -f "$TMP/run/devbox/unreachable-lan1"

# A stalled target. ConnectTimeout bounds only the connect, so a
# host that accepted TCP and then never answered held the probe's `wait`, and
# with it the whole run, with no skip line. Each ssh of the probe now has a
# limit; the stub stalls for 60 seconds and the limit here is 1.
elapsed_ok() { [ "$1" -lt 20 ]; }
t0="$(date +%s)"
FAKE_STALL=lan-fixture DEVBOX_PROBE_ANSWER_SECONDS=1 verify
assert_eq "0" "$rc" "a target that never answers its probe does not stop the run"
assert_ok "and does not hold it for the stub's 60 seconds" elapsed_ok "$(($(date +%s) - t0))"
assert_ok "it is named with the verb and the limit" \
  contains "==> devbox: lan1 unreachable (no answer to probe in 1s)" "$out"
assert_ok "and the gate runs on the other target" contains "GATE RAN ON cloud-fixture" "$out"
assert_ok "the cache records it, so the next run does not wait on it again" \
  test -f "$TMP/run/devbox/unreachable-lan1"
rm -f "$TMP/run/devbox/unreachable-"*

t0="$(date +%s)"
FAKE_STALL_OPEN=lan-fixture DEVBOX_PROBE_OPEN_SECONDS=1 verify
assert_eq "0" "$rc" "a target that accepts the connection and stalls in authentication does not stop the run"
assert_ok "and does not hold it either" elapsed_ok "$(($(date +%s) - t0))"
assert_ok "it is named with the limit" contains "==> devbox: lan1 unreachable (no answer in 1s)" "$out"
assert_ok "and the gate runs on the other target" contains "GATE RAN ON cloud-fixture" "$out"
rm -f "$TMP/run/devbox/unreachable-"*

cp "$CO/.devbox/config.env" "$TMP/config.keep"
printf 'DEVBOX_REQUIRES=node\n' >>"$CO/.devbox/config.env"
FAKE_STALL=lan-fixture FAKE_STALL_VERB=check-requires DEVBOX_PROBE_ANSWER_SECONDS=1 verify
cp "$TMP/config.keep" "$CO/.devbox/config.env"
assert_eq "0" "$rc" "a target whose check-requires never answers does not stop the run"
assert_ok "it is named with that verb" \
  contains "==> devbox: lan1 unreachable (no answer to check-requires in 1s)" "$out"
assert_ok "and the gate runs on the other target" contains "GATE RAN ON cloud-fixture" "$out"
rm -f "$TMP/run/devbox/unreachable-"*

# ssh's own failure on a verb after the master opened (exit 255: the master
# died, or the connection reset) is no answer from the host. Read as one, the
# empty probe line was a handshake failure and a failed check-requires was an
# image that lacks a token, so on every target the run exited 5 or 6 and named
# a deploy for a network fault.
FAKE_DROP=lan-fixture verify
assert_eq "0" "$rc" "a connection that fails during the probe does not stop the run"
assert_ok "the target is unreachable, named with the verb" \
  contains "==> devbox: lan1 unreachable (the connection failed during probe)" "$out"
assert_fail "and is never read as a handshake failure" contains "protocol" "$out"
assert_ok "and the gate runs on the other target" contains "GATE RAN ON cloud-fixture" "$out"
assert_ok "the cache records it" test -f "$TMP/run/devbox/unreachable-lan1"
rm -f "$TMP/run/devbox/unreachable-"*
FAKE_DROP="lan-fixture cloud-fixture" verify
assert_eq "3" "$rc" "a connection that fails during the probe of every target exits 3, never 5"
rm -f "$TMP/run/devbox/unreachable-"*

printf 'DEVBOX_REQUIRES=node\n' >>"$CO/.devbox/config.env"
FAKE_DROP=lan-fixture FAKE_DROP_VERB=check-requires verify
assert_eq "0" "$rc" "a connection that fails during check-requires does not stop the run"
assert_ok "the target is unreachable, named with that verb" \
  contains "==> devbox: lan1 unreachable (the connection failed during check-requires)" "$out"
assert_fail "and is never read as an image that lacks a token" contains "does not satisfy DEVBOX_REQUIRES" "$out"
assert_ok "and the gate runs on the other target" contains "GATE RAN ON cloud-fixture" "$out"
rm -f "$TMP/run/devbox/unreachable-"*
FAKE_DROP="lan-fixture cloud-fixture" FAKE_DROP_VERB=check-requires verify
cp "$TMP/config.keep" "$CO/.devbox/config.env"
assert_eq "3" "$rc" "a connection that fails during check-requires on every target exits 3, never 6"
rm -f "$TMP/run/devbox/unreachable-"*

# GNU timeout bounds every ssh of the probe. A laptop without it (stock macOS)
# saw every master open exit 127: each target read as unreachable and entered
# the cache, and rule 4 rented a paid server on every run. The missing tool is
# a refused setup, exit 2, before anything is cached or rented.
mkdir -p "$TMP/notimeout"
IFS=: read -ra _path_dirs <<<"$TMP/bin:$PATH"
for _d in "${_path_dirs[@]}"; do
  for _f in "$_d"/*; do
    _n="${_f##*/}"
    if [ "$_n" != timeout ] && [ -x "$_f" ] && [ ! -e "$TMP/notimeout/$_n" ]; then ln -s "$_f" "$TMP/notimeout/$_n"; fi
  done
done
cp "$CO/.devbox.env" "$TMP/env.keep"
printf 'DEVBOX_RENT=runpod\nRUNPOD_KEY=fixture-runpod-key\n' >>"$CO/.devbox.env"
: >"$SSH_LOG"
rc=0
out="$(cd "$CO" && env PATH="$TMP/notimeout" HOME="$TMP/fakehome" XDG_RUNTIME_DIR="$TMP/run" DEVBOX_LOCK_WAIT=5 \
  bash "$REPO/client/libexec/devbox-verify" 2>&1)" || rc=$?
cp "$TMP/env.keep" "$CO/.devbox.env"
assert_eq "2" "$rc" "a laptop with no timeout command is refused with exit 2"
assert_ok "and the refusal names the tool and the fix" contains "brew install coreutils" "$out"
assert_fail "nothing is rented" contains "renting" "$out"
assert_fail "and no target enters the unreachable cache" test -e "$TMP/run/devbox/unreachable-lan1"
assert_fail "and no connection was opened, and no verb sent" grep -qE -- "-f -N| probe " "$SSH_LOG"

# DEVBOX_FORWARD_ENV is committed, so any contributor edits it. The loader keeps
# the gate password as an unexported shell variable, and the old test of a
# forwarded name, `${!name+x}`, matched it anyway, so the password crossed into
# the env file of every target's gate.
printf 'DEVBOX_FORWARD_ENV=FIXTURE_SWITCH DEVBOX_GATE_PASSWORD\n' >>"$CO/.devbox/config.env"
FIXTURE_SWITCH=on RUN_STDIN="$TMP/run.stdin" verify
cp "$TMP/config.keep" "$CO/.devbox/config.env"
assert_eq "2" "$rc" "DEVBOX_FORWARD_ENV naming the gate password is refused"
assert_ok "by name" \
  contains "refusing DEVBOX_GATE_PASSWORD in DEVBOX_FORWARD_ENV from $CO/.devbox/config.env: it is a .devbox.env key" "$out"
assert_fail "and no gate ran" contains "GATE RAN" "$out"
assert_fail "so no run stdin carried the password" grep -qF fixture-gate-password "$TMP/run.stdin"
assert_fail "and the output never shows it" contains fixture-gate-password "$out"
printf 'DEVBOX_FORWARD_ENV=FIXTURE_SWITCH\n' >>"$CO/.devbox/config.env"
FIXTURE_SWITCH=on RUN_STDIN="$TMP/run.stdin" verify
cp "$TMP/config.keep" "$CO/.devbox/config.env"
assert_eq "0" "$rc" "an exported switch named in DEVBOX_FORWARD_ENV still runs"
assert_ok "and crosses on the run verb's stdin" grep -qxF "FIXTURE_SWITCH=on" "$TMP/run.stdin"
assert_fail "with no password beside it" grep -qF fixture-gate-password "$TMP/run.stdin"
rm -f "$TMP/run.stdin"

DEVBOX_PROBE_ANSWER_SECONDS=soon verify
assert_eq "2" "$rc" "a probe limit that is not a number is refused"
assert_ok "by name" contains "DEVBOX_PROBE_ANSWER_SECONDS is 'soon' in the environment" "$out"
assert_eq "0" "$(opened lan-fixture)" "before any target is asked"

# Rule 6 end to end: both over the ceiling, no rental, the fail action.
printf '%s\n' "$(devbox_probe_line "$PROTO $FP" "wait 900 4 20/20 4/4 2" "$(date +%s) ok" "$(date +%s)")" \
  | tee "$TMP/probes/lan-fixture.probe" >"$TMP/probes/cloud-fixture.probe"
verify
assert_eq "8" "$rc" "no target can take the gate: exit 8"
assert_ok "with the sentence that says no target can take it" contains "devbox verify: no target can take this gate:" "$out"
assert_ok "and one line per target" \
  contains "  lan1 skipped: busy, about 900s of queuing, over the DEVBOX_MAX_QUEUE_WAIT of 600s" "$out"
assert_ok "the second target too" \
  contains "  cloud1 skipped: busy, about 900s of queuing, over the DEVBOX_MAX_QUEUE_WAIT of 600s" "$out"
assert_fail "and nothing ran, here or there" contains "GATE RAN" "$out"
assert_fail "not even locally" contains "LOCAL GATE RAN" "$out"
rm -f "$TMP/probes/"*.probe
unset FAKE_PROBE_DIR

# A handshake failure on every target exits 5, naming each one.
FAKE_VERSION="99 $FP" verify
assert_eq "5" "$rc" "a protocol mismatch on every target exits 5"
assert_ok "naming the first target and its repair" contains "devbox verify: lan1: the protocol integers differ" "$out"
assert_ok "and the second" contains "devbox verify: cloud1: the protocol integers differ" "$out"

# Every target unreachable, nothing to rent, the fail action: exit 3, the code
# an unreachable host had when a client knew one, with one line per target.
export FAKE_UNREACHABLE="lan-fixture cloud-fixture"
verify
unset FAKE_UNREACHABLE
assert_eq "3" "$rc" "no target answered: exit 3"
assert_ok "with one line per target" contains "  lan1 unreachable (no answer in 3s)" "$out"
assert_ok "the second too" contains "  cloud1 unreachable (no answer in 3s)" "$out"
assert_ok "and the way to run here" contains "devbox verify --local" "$out"

# The local action with nothing to wait on: the laptop cannot run this gate
# (it needs a database only a target provisions), so the run exits 8 and does
# not promise a wait that will not happen. The cache from the case above still
# holds both targets, so neither is asked again.
cp "$CO/.devbox.env" "$TMP/env.keep"
cp "$CO/.devbox/config.env" "$TMP/config.keep"
printf 'DEVBOX_QUEUE_FULL_ACTION=local\n' >>"$CO/.devbox.env"
printf 'DEVBOX_NEEDS_POSTGRES=1\nDEVBOX_DB_URL_VAR=SELECT_DB_URL\n' >>"$CO/.devbox/config.env"
verify
assert_eq "8" "$rc" "the local action refused, with no target to wait on, exits 8"
assert_ok "the refusal says the gate runs nowhere" \
  contains "so the gate does not run here, and no target can take it either." "$out"
assert_fail "and never says it keeps waiting" contains "keeps waiting on" "$out"
assert_fail "and the local gate did not run" contains "LOCAL GATE RAN" "$out"
assert_eq "0" "$(opened lan-fixture)" "the cached targets were not asked again"
cp "$TMP/env.keep" "$CO/.devbox.env"
cp "$TMP/config.keep" "$CO/.devbox/config.env"

# A forced target that is not listed is refused before anything is sent.
verify --target nowhere
assert_eq "2" "$rc" "an unlisted --target is refused"
assert_ok "and no ssh started" test ! -s "$SSH_LOG"

printf '%d %d\n' "$TESTS_RUN" "$TESTS_FAILED"
