#!/bin/bash
# `devbox status`, the one-shot view and watch mode, run as a real process
# against a fake gate account that plays two targets, lan1 and cloud1.
#
# The fake host answers the `status` verb with a reply file this file writes.
# Every reply carries a host epoch that is years away from this laptop's clock,
# and every duration in the expected view is computed from that epoch. A view
# that subtracted on the laptop clock would print durations of years, so each
# exact comparison below is also the proof that the host clock is used.
#
# Hermetic: the fake ssh and ssh-keyscan come first on PATH, HOME and
# XDG_RUNTIME_DIR point into one mktemp -d, and no address resolves (.invalid).
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
# shellcheck source=tests/lib.sh
source ./lib.sh
REPO="$(cd .. && pwd)"
STATUS="$REPO/client/libexec/devbox-status"
# shellcheck source=lib/devbox-lib.sh
source "$REPO/lib/devbox-lib.sh"

TMP="$(mktemp -d)" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

contains() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }
ESC=$'\033'

# Read as text, not taken from the sourced variable, so the replies carry the
# number the shipped library declares.
PROTO="$(sed -n 's/^DEVBOX_PROTOCOL_VERSION=\(.*\)$/\1/p' "$REPO/lib/devbox-lib.sh")"
FP="$(sha256sum <"$REPO/lib/devbox-lib.sh" | cut -d' ' -f1)"

# ── the fake gate account ────────────────────────────────────────────────────
#
# Beside the shared prelude of tests/lib.sh: a host named in FAKE_REFUSE refuses
# the gate password at the master open, a host named in FAKE_OPEN_ERROR_HOST
# fails the master open with FAKE_OPEN_ERROR on stderr, a host named in FAKE_NO_STATUS answers
# `status` as a protocol 6 gate does (an unknown verb, exit 2, nothing on
# stdout) and `version` with FAKE_OLD_VERSION. Every other verb is unexpected,
# and the stub says so with exit 9, so a view that sent one shows it.
#
# For watch mode, FAKE_MASTER_DIR makes the stub keep a master as a file: a
# master open that succeeds writes $FAKE_MASTER_DIR/<host>, `-O check` answers
# yes while it exists, and `-O exit` removes it. The prelude alone answers every
# check with "no master", which would hide a watch that opens a master at each
# refresh. A host named in FAKE_STALL_SECOND answers its first `status` and
# never finishes the second, so a view has a block that grows old. A host named
# in FAKE_HOST_LIMIT answers `status` as gate-root does when its own
# `timeout 20` cuts the runner: the first line of the reply, then exit 124.
mkdir -p "$TMP/bin" "$TMP/fakehome" "$TMP/run" "$TMP/replies"
{
  printf '#!/bin/bash\n'
  cat <<'PRE'
[ -z "${SSH_LOG-}" ] || printf '%s\n' "$*" >>"$SSH_LOG"
_h=""
for _a in "$@"; do case "$_a" in devbox-gate@*) _h="${_a#devbox-gate@}" ;; esac; done
case " $* " in *" -f -N "*)
  case " ${FAKE_REFUSE-} " in *" $_h "*)
    printf 'devbox-gate@%s: Permission denied (password).\n' "$_h" >&2; exit 255 ;;
  esac
  case " ${FAKE_OPEN_ERROR_HOST-} " in *" $_h "*)
    printf '%s\n' "$FAKE_OPEN_ERROR" >&2; exit 255 ;;
  esac ;;
esac
if [ -n "${FAKE_MASTER_DIR-}" ]; then
  case " $* " in
    *" -O check "*) [ -e "$FAKE_MASTER_DIR/$_h" ] && exit 0; exit 1 ;;
    *" -O exit "*) rm -f "$FAKE_MASTER_DIR/$_h"; exit 0 ;;
    *" -f -N "*)
      case " ${FAKE_UNREACHABLE-} ${FAKE_STALL_OPEN-} " in *" $_h "*) ;; *) : >"$FAKE_MASTER_DIR/$_h" ;; esac ;;
    *" devbox-gate@$_h status "*)
      case " ${FAKE_STALL_SECOND-} " in *" $_h "*)
        [ ! -e "$FAKE_MASTER_DIR/$_h.answered" ] || exec sleep 60
        : >"$FAKE_MASTER_DIR/$_h.answered" ;;
      esac ;;
  esac
fi
PRE
  gate_stub_prelude
  cat <<'STUB'
case "$GATE_CMD" in
  "status "*)
    case " ${FAKE_HOST_LIMIT-} " in *" $GATE_HOST "*)
      head -1 "$FAKE_STATUS_DIR/$GATE_HOST.status" 2>/dev/null; exit 124 ;;
    esac
    case " ${FAKE_NO_STATUS-} " in *" $GATE_HOST "*)
      echo "devbox-gate: refusing the verb 'status'" >&2; exit 2 ;;
    esac
    cat "$FAKE_STATUS_DIR/$GATE_HOST.status" 2>/dev/null
    exit 0 ;;
  version)
    case " ${FAKE_NO_STATUS-} " in *" $GATE_HOST "*) printf '%s\n' "${FAKE_OLD_VERSION-}"; exit 0 ;; esac
    printf '%s %s\n' "$FAKE_PROTO" "$FAKE_FP"; exit 0 ;;
esac
echo "fake gate: unexpected verb: $GATE_CMD" >&2
exit 9
STUB
} >"$TMP/bin/ssh"
chmod +x "$TMP/bin/ssh"
gate_stub_keyscan "$TMP/bin"

# ── the checkout: a main checkout and one linked worktree ───────────────────
#
# Named like the gates of the status spec's mockup, so the view's names read as
# the worktree directory names a developer knows.
CO="$TMP/fix-cache"
mkdir -p "$CO/.devbox"
git -C "$CO" init -q >/dev/null 2>&1
printf 'DEVBOX_PROJECT=status-fixture\nDEVBOX_SETUP=:\nDEVBOX_VERIFY=:\n' >"$CO/.devbox/config.env"
git -C "$CO" add .devbox/config.env >/dev/null 2>&1
git -C "$CO" -c user.email=t@fixture.invalid -c user.name=fixture commit -q -m init >/dev/null 2>&1
git -C "$CO" worktree add -q -b feat "$TMP/feat-login" >/dev/null 2>&1
ENV_BOTH="$(printf 'DEVBOX_TARGETS=lan1,cloud1\nDEVBOX_TARGET_LAN1=lan1.invalid\nDEVBOX_TARGET_LAN1_HOSTKEY=%s\nDEVBOX_TARGET_CLOUD1=cloud1.invalid\nDEVBOX_TARGET_CLOUD1_HOSTKEY=%s\nDEVBOX_GATE_PASSWORD=fixture-gate-password\n' "$GATE_STUB_PIN" "$GATE_STUB_PIN")"
printf '%s\n' "$ENV_BOTH" >"$CO/.devbox.env"

# The slugs `devbox verify` builds for the two worktrees. The library's own
# devbox_slug is the right source here: this file tests how status maps a slug
# back to a name, and tests/test-devbox-gc.sh proves the slug itself.
# shellcheck disable=SC2119  # no argument is the point: the default candidates are the files devbox-status reads
MID="$(devbox_machine_id)"
LABEL="$(devbox_machine_label)"
top_main="$(git -C "$CO" rev-parse --show-toplevel)"
top_feat="$(git -C "$TMP/feat-login" rev-parse --show-toplevel)"
SLUG_MAIN="$(devbox_slug "$LABEL" "$MID" status-fixture "$top_main")"
SLUG_FEAT="$(devbox_slug "$LABEL" "$MID" status-fixture "$top_feat")"
SLUG_GONE="$(devbox_slug "$LABEL" "$MID" status-fixture "$TMP/removed-wt")"

# ── replies ──────────────────────────────────────────────────────────────────
#
# E is the host's epoch: 2023-11-14, three years behind this laptop.
E=1700000000
GIB=1073741824
reply_lan1() {  # $1 the host epoch; every other epoch is relative to it
  local e="$1"
  printf '%s %s %s\n' "$PROTO" "$FP" "$e"
  printf 'host ok 12 28 32 2 3 1 21.4 32 %s %s %s %s\n' "$((24 * GIB))" "$((64 * GIB))" 0 "$((16 * GIB))"
  # mine: 6m12s in, a median of 9m12s, 60m limit, 7.1G of 12G.
  printf 'run 1234.5678 me %s 20 %s 3600 552 5 1830 %s %s 0 running\n' "$SLUG_FEAT" "$((e - 372))" "7623566950" "$((12 * GIB))"
  # other: 1m03s in, a median of 12m03s, one OOM kill.
  printf 'run 2345.6789 other - 8 %s - 723 3 710 %s %s 1 running\n' "$((e - 63))" "$((4 * GIB))" "$((12 * GIB))"
  printf 'ticket 1 me %s 20 10 %s 180 0123456789abcdef.4242\n' "$SLUG_MAIN" "$((e - 50))"
  printf 'end\n'
}
reply_cloud1() {
  local e="$1"
  printf '%s %s %s\n' "$PROTO" "$FP" "$e"
  printf 'host ok 5 0 20 0 3 0 0.31 8 %s %s 0 0\n' "$((30 * GIB))" "$((32 * GIB))"
  printf 'end\n'
}
reply_lan1 "$E" >"$TMP/replies/lan1.invalid.status"
reply_cloud1 "$E" >"$TMP/replies/cloud1.invalid.status"

# ── running the real program ─────────────────────────────────────────────────
out=""; err=""; rc=0
SSH_LOG="$TMP/ssh.log"
# LC_ALL=C: the bars are ASCII outside a UTF-8 charmap, so every expected view
# below is the same on any machine. One case below checks the block characters.
run_status() {
  : >"$SSH_LOG"
  out="$(cd "$CO" && env LC_ALL=C PATH="$TMP/bin:$PATH" HOME="$TMP/fakehome" XDG_RUNTIME_DIR="$TMP/run" \
    SSH_LOG="$SSH_LOG" FAKE_STATUS_DIR="$TMP/replies" FAKE_PROTO="$PROTO" FAKE_FP="$FP" \
    "$@" bash "$STATUS" ${STATUS_ARGS[@]+"${STATUS_ARGS[@]}"} 2>"$TMP/err")"
  rc=$?
  err="$(cat "$TMP/err")"
  return 0
}
STATUS_ARGS=()

# ═══ R11, R12: the view ══════════════════════════════════════════════════════
#
# The bars, worked by hand: 28 of 32 tokens is 7 of 8 cells. 21.4 busy cores of
# 32 is 5.35 cells, so 5, and prints with its decimal at every size. 64G less
# 24G available is 40G in use, 5 cells. On cloud1, 0.31 of 8 cores is 0.3
# cells, and any use above 0 shows one. 1830% of one core is 18.3 cores. The
# mark `>` is this checkout's: both slugs are worktrees of this repository,
# named <repository>/<worktree>, and the main checkout by its repository alone.
expected_view="$(cat <<EOF
lan1      ok        tokens #######. 28/32    cpu #####... 21.4/32  mem #####... 40G/64G    jobs 2/3
cloud1    ok        tokens ........ 0/20     cpu #....... 0.3/8    mem #....... 2.0G/32G   jobs 0/3  no swap

  STATE      TASK                  TARGET  TOKENS   TIME  LEFT        CORES  MEM
> running    fix-cache/feat-login  lan1        20  6m12s  ~3m          18.3  7.1G/12G
  running    other laptop          lan1         8  1m03s  ~11m          7.1  4.0G/12G  1 OOM kill
> queued #1  fix-cache             lan1     10-20    50s  starts ~3m
EOF
)"
run_status
assert_eq "0" "$rc" "two targets that answer: exit 0"
assert_eq "$expected_view" "$out" "one line per server in DEVBOX_TARGETS order, then one table of every gate"
assert_eq "" "$err" "and nothing on stderr"

# R12. The same state at another host epoch, one million seconds later, gives
# the same view: every duration is the host's now minus a host epoch.
reply_lan1 "$((E + 1000000))" >"$TMP/replies/lan1.invalid.status"
reply_cloud1 "$((E + 1000000))" >"$TMP/replies/cloud1.invalid.status"
run_status
assert_eq "$expected_view" "$out" "a host clock a million seconds off this laptop's changes no duration"
reply_lan1 "$E" >"$TMP/replies/lan1.invalid.status"

# The order of the view is DEVBOX_TARGETS order, not the order of the answers.
sed -i 's/^DEVBOX_TARGETS=lan1,cloud1$/DEVBOX_TARGETS=cloud1,lan1/' "$CO/.devbox.env"
run_status
assert_ok "with DEVBOX_TARGETS=cloud1,lan1, cloud1 is the first block" \
  test "$(printf '%s\n' "$out" | head -1 | cut -c1-6)" = cloud1
printf '%s\n' "$ENV_BOTH" >"$CO/.devbox.env"

# --target reads one deployed target.
STATUS_ARGS=(--target cloud1)
run_status
assert_eq "0" "$rc" "--target cloud1 exits 0"
assert_ok "and shows cloud1" contains "cloud1    ok" "$out"
assert_fail "and no other target" contains "lan1" "$out"
# The EXIT trap closes the master of every listed target, and `-O exit` with
# no master up sends nothing. Every other call to lan1 would be a contact.
assert_eq "0" "$(grep -v -- ' -O exit ' "$SSH_LOG" | grep -c 'devbox-gate@lan1.invalid')" "and never contacts lan1"
STATUS_ARGS=()

# ── the run line's other states ──────────────────────────────────────────────
#
# A run past its median, a run with no history, a run the watchdog stopped, a
# run 4 minutes from its limit, a slug of this laptop that no worktree has, a
# second ticket, a ticket the pool cannot estimate, and fields the host could
# not read.
{
  printf '%s %s %s\n' "$PROTO" "$FP" "$E"
  printf 'host degraded 12 28 32 3 3 2 9.5 32 - - %s %s disk 91%%\n' "$((3 * GIB / 2))" "$((16 * GIB))"
  printf 'run 11.12 me %s 8 %s 3600 540 4 90 %s max 0 running\n' "$SLUG_FEAT" "$((E - 3360))" "$((512 * 1048576))"
  printf 'run 13.14 me %s 8 %s - - 0 - - - - running\n' "$SLUG_GONE" "$((E - 30))"
  printf 'run 15.16 other - 8 %s 3600 600 2 0 %s %s 2 stopping no work for 1200s\n' "$((E - 4000))" "$GIB" "$((2 * GIB))"
  printf 'ticket 1 other - 32 16 %s - -\n' "$((E - 3725))"
  printf 'ticket 2 me %s 4 2 - 0 -\n' "$SLUG_MAIN"
  printf 'end\n'
} >"$TMP/replies/lan1.invalid.status"
run_status
# The task column widens to the longest name, here the slug that no worktree
# has, cut at 36 characters with `~` in this locale. The fixed columns follow.
gone="$SLUG_GONE"
[ "${#gone}" -le 36 ] || gone="${gone:0:35}~"
tw=20
[ "${#gone}" -le "$tw" ] || tw="${#gone}"
row() { printf '%s %-9s  %-*s  %s\n' "$1" "$2" "$tw" "$3" "$4" | sed 's/ *$//'; }
expected_other="$(
  echo "lan1      degraded  tokens #######. 28/32    cpu ##...... 9.5/32   mem ........ -          jobs 3/3  swap 1.5G/16G  disk 91%"
  echo "cloud1    ok        tokens ........ 0/20     cpu #....... 0.3/8    mem #....... 2.0G/32G   jobs 0/3  no swap"
  echo
  row " " STATE TASK "TARGET  TOKENS    TIME  LEFT           CORES  MEM"
  row " " stopping "other laptop" "lan1         8   1h06m                   0.0  1.0G/2.0G  no work for 1200s, 2 OOM kills"
  row ">" running fix-cache/feat-login "lan1         8  56m00s  47m over         0.9  512M       the watchdog stops it in 4m"
  row " " running "$gone" "lan1         8     30s  -                  -  -"
  row " " "queued #1" "other laptop" "lan1     16-32   1h02m  start unknown"
  row ">" "queued #2" fix-cache "lan1       2-4       -  starts now"
)"
assert_eq "$expected_other" "$out" \
  "past its usual, no history, stopping, the watchdog's stop, an unknown slug and unread fields"
assert_eq "0" "$rc" "a degraded host is still an answer: exit 0"
reply_lan1 "$E" >"$TMP/replies/lan1.invalid.status"

# ═══ R9: one run queued on several targets is one row ════════════════════════
#
# A run waits in the queue of every eligible target and takes the first grant
# (docs/specs/2026-11-13-late-binding-queue-design.md section 3). Its tickets
# carry one run id on every target, and the view shows them as one row with
# every target the run waits on. The row is the ticket that starts soonest:
# cloud1's, at 1 minute, over lan1's at 5.
RUN_A=0123456789abcdef.4242
RUN_B=0123456789abcdef.4343
two_snapshots() {  # $1 the run id of cloud1's ticket
  {
    printf '%s %s %s\n' "$PROTO" "$FP" "$E"
    printf 'host ok 12 28 32 2 3 1 21.4 32 %s %s 0 %s\n' "$((24 * GIB))" "$((64 * GIB))" "$((16 * GIB))"
    printf 'ticket 2 other - 8 4 %s 300 %s\n' "$((E - 90))" "$RUN_A"
    printf 'end\n'
  } >"$TMP/replies/lan1.invalid.status"
  {
    printf '%s %s %s\n' "$PROTO" "$FP" "$E"
    printf 'host ok 5 0 20 0 3 0 0.31 8 %s %s 0 0\n' "$((30 * GIB))" "$((32 * GIB))"
    printf 'ticket 1 other - 8 4 %s 60 %s\n' "$((E - 85))" "$1"
    printf 'end\n'
  } >"$TMP/replies/cloud1.invalid.status"
}
two_snapshots "$RUN_A"
run_status
assert_eq "0" "$rc" "two snapshots with one run id: exit 0"
assert_eq "1" "$(printf '%s\n' "$out" | grep -c '^  queued')" "the run's two tickets are one row"
assert_ok "naming both targets, in DEVBOX_TARGETS order, with the soonest ticket's place and estimate" \
  grep -qE '^  queued #1  other laptop  lan1\+cloud1     4-8  1m25s  starts ~1m$' <<<"$out"
two_snapshots "$RUN_B"
run_status
assert_eq "2" "$(printf '%s\n' "$out" | grep -c '^  queued')" "two run ids on two targets are two rows"
assert_fail "and no row joins their targets" contains "lan1+cloud1" "$out"

# A ticket whose run id is this laptop's is this laptop's row, though the host
# could not prove it: a run joins a target's queue before its workspace there
# exists, and the host proves an owner only from that workspace's label.
# The prefix is a hash of the machine id, computed here on its own, so a client
# that sent the machine id itself again would fail this case.
MINE_RUN="$(printf '%s' "${MID,,}" | sha256sum | cut -c1-16).4242"
two_snapshots "$MINE_RUN"
sed -i "s/ $RUN_A\$/ $MINE_RUN/" "$TMP/replies/lan1.invalid.status"
run_status
assert_eq "1" "$(printf '%s\n' "$out" | grep -c '^  queued')" "this laptop's run on two targets is one row"
assert_fail "and it is never called another laptop's" contains "other laptop" "$out"
assert_ok "it waits on both targets" grep -qE '^  queued #1  - +lan1\+cloud1 ' <<<"$out"
reply_lan1 "$E" >"$TMP/replies/lan1.invalid.status"
reply_cloud1 "$E" >"$TMP/replies/cloud1.invalid.status"

# ═══ R13, R14: the lines that replace a block, and the exit code ═════════════
#
# Each case breaks lan1 alone. cloud1 answers, so its line must follow lan1's
# one line, in its place. cloud1 runs nothing, and it answered, so the table
# says that no gate runs or waits. The gates of lan1 are not in the table:
# nothing this client could read said they exist.
cloud1_block="$(printf '%s\n\n%s' "cloud1    ok        tokens ........ 0/20     cpu #....... 0.3/8    mem #....... 2.0G/32G   jobs 0/3  no swap" "no gate runs or waits")"
case_line() {  # $1 the expected lan1 line, $2 the expected exit code, $3 the case
  assert_eq "$2" "$rc" "$3: exit $2"
  assert_eq "$1" "$(printf '%s\n' "$out" | head -1)" "$3: lan1 keeps its place, with its reason"
  assert_eq "$cloud1_block" "$(printf '%s\n' "$out" | tail -n +2)" "$3: cloud1 still shows its line"
}

run_status FAKE_UNREACHABLE=lan1.invalid
case_line "lan1      unreachable (no answer in 3s)" 3 "a target that does not answer"

run_status FAKE_STALL=lan1.invalid FAKE_STALL_VERB=status DEVBOX_PROBE_ANSWER_SECONDS=1
case_line "lan1      no answer to status in 1s" 3 "a target that opened and never answered the verb"

# gate-root's own limit exits 124 through ssh before this client's limit. It
# read as "no answer to status in 25s" and marked a target that answered as
# unreachable, so the next verify skipped it and could rent a paid server.
rm -f "$TMP/run/devbox/unreachable-lan1"
run_status FAKE_HOST_LIMIT=lan1.invalid
case_line "lan1      incomplete answer" 3 "the host's own limit cut the verb"
assert_fail "and the target that answered is not written to the unreachable cache" \
  test -e "$TMP/run/devbox/unreachable-lan1"

run_status FAKE_DROP=lan1.invalid FAKE_DROP_VERB=status
case_line "lan1      unreachable (the connection failed during status)" 3 "a connection that dropped during the verb"

run_status FAKE_REFUSE=lan1.invalid
case_line "lan1      the gate password was refused" 3 "a refused gate password"

# A changed key is checked before any password is sent. The key recorded on the
# first contact is removed so the scan answers with the other key.
rm -f "$TMP/fakehome/.config/devbox/known_hosts"
run_status FAKE_KEYSCAN_OTHER=lan1.invalid
assert_eq "3" "$rc" "a host key off its pin: exit 3"
assert_eq "lan1      host key changed" "$(printf '%s\n' "$out" | head -1)" "a host key off its pin: lan1 keeps its place"
assert_ok "and the next line names the repair" contains "ssh-keygen -R" "$(printf '%s\n' "$out" | sed -n 2p)"
assert_eq "0" "$(grep -c 'devbox-gate@lan1.invalid status' "$SSH_LOG")" "and nothing is sent to that host"
rm -f "$TMP/fakehome/.config/devbox/known_hosts"

run_status FAKE_NO_STATUS=lan1.invalid FAKE_OLD_VERSION="6 $FP"
case_line "lan1      protocol 6, this client speaks $PROTO: deploy is due" 5 "a protocol 6 host that refuses the verb"

# A host writes the version answer and the ssh error text, and the view prints
# both. ESC and BEL bytes in either would drive the developer's terminal: a
# window title, a cleared screen. Every control byte is removed before printing.
CTL=$'\033]0;owned\a\033[2J'
run_status FAKE_NO_STATUS=lan1.invalid FAKE_OLD_VERSION="6${CTL} $FP"
case_line "lan1      the server answered '6]0;owned[2J $FP', which is not a protocol version: deploy is due" 5 \
  "a version answer that carries control bytes"
assert_fail "  and the view carries no ESC" contains "$ESC" "$out"
assert_fail "  and no BEL" contains $'\a' "$out"
run_status FAKE_OPEN_ERROR_HOST=lan1.invalid FAKE_OPEN_ERROR="kex_exchange_identification: ${CTL}banner"
case_line "lan1      unreachable (kex_exchange_identification: ]0;owned[2Jbanner)" 3 \
  "an ssh error that carries control bytes"
assert_fail "  and the view carries no ESC" contains "$ESC" "$out"
assert_fail "  and no BEL" contains $'\a' "$out"

sed "1s/^$PROTO /6 /" "$TMP/replies/lan1.invalid.status" >"$TMP/replies/old"
mv "$TMP/replies/old" "$TMP/replies/lan1.invalid.status"
run_status
case_line "lan1      protocol 6, this client speaks $PROTO: deploy is due" 5 "a reply on another protocol"
reply_lan1 "$E" >"$TMP/replies/lan1.invalid.status"

sed "1s/ $FP / $(printf '%064d' 0) /" "$TMP/replies/lan1.invalid.status" >"$TMP/replies/old"
mv "$TMP/replies/old" "$TMP/replies/lan1.invalid.status"
run_status
# Another minor release of this protocol: its block renders, and nothing is due.
assert_eq "0" "$rc" "a host library of another release under one protocol: exit 0"
assert_ok "  and lan1 shows its block" contains "lan1      ok" "$(printf '%s\n' "$out" | head -1)"
reply_lan1 "$E" >"$TMP/replies/lan1.invalid.status"

sed '$d' "$TMP/replies/lan1.invalid.status" >"$TMP/replies/cut"
mv "$TMP/replies/cut" "$TMP/replies/lan1.invalid.status"
run_status
case_line "lan1      incomplete answer" 3 "a reply with no end record"
assert_fail "and no run of the cut reply is shown" contains "feat-login" "$out"
reply_lan1 "$E" >"$TMP/replies/lan1.invalid.status"

# The first non-zero code in target order wins.
run_status FAKE_NO_STATUS=lan1.invalid FAKE_OLD_VERSION="6 $FP" FAKE_UNREACHABLE=cloud1.invalid
assert_eq "5" "$rc" "lan1 needs a deploy and cloud1 is unreachable: lan1's 5"
assert_ok "and both are a line in the view" contains "cloud1    unreachable (no answer in 3s)" "$out"
run_status FAKE_UNREACHABLE=lan1.invalid FAKE_NO_STATUS=cloud1.invalid FAKE_OLD_VERSION="6 $FP"
assert_eq "3" "$rc" "lan1 is unreachable and cloud1 needs a deploy: lan1's 3"
assert_ok "and both are a line in the view" contains "cloud1    protocol 6, this client speaks $PROTO: deploy is due" "$out"

# ═══ R25: the unreachable cache is written and never read ═══════════════════
run_status FAKE_UNREACHABLE=lan1.invalid
assert_ok "an unreachable target is written to the cache" test -f "$TMP/run/devbox/unreachable-lan1"
run_status
assert_eq "0" "$rc" "the next status asks lan1 again, cache or no cache"
assert_ok "and shows its block" contains "lan1      ok" "$out"
assert_fail "and the cache entry it disproved is gone" test -e "$TMP/run/devbox/unreachable-lan1"

# Status changes nothing but that cache. The tree of every file this client may
# write is compared before and after one run with lan1 unreachable: the
# known_hosts entry is already recorded, so the only change is the cache file.
snapshot_tree() {
  (cd "$TMP" && find fakehome run "$CO/.git" -type f ! -name 'index' -print0 2>/dev/null | sort -z | xargs -0 sha256sum)
}
before="$(snapshot_tree)"
run_status FAKE_UNREACHABLE=lan1.invalid
after="$(snapshot_tree)"
assert_eq "run/devbox/unreachable-lan1" \
  "$(diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") | sed -n 's/^> [0-9a-f]*  //p')" \
  "one run adds the cache file of the unreachable target, and nothing else"
assert_eq "" "$(diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") | grep '^<')" \
  "and changes or removes no file"
assert_fail "no affinity record is written" test -e "$CO/.git/devbox/last-target"
# Every call is the master open, its check and close, or the status verb with
# this machine's id. No lock, no workspace, nothing else.
verbs="$(grep -vE -- ' -O (check|exit) | -f -N ' "$SSH_LOG" | sed 's/.*devbox-gate@[^ ]* //' | sort -u)"
assert_eq "status $MID" "$verbs" "the only verb sent is status <machine-id>"

# ═══ the worktree name ═══════════════════════════════════════════════════════
#
# A slug of this repository is shown as its worktree's directory name, from the
# linked worktree as from the main checkout.
# The first case above already shows both names from the main checkout.
cd_out="$(cd "$TMP/feat-login" && env LC_ALL=C PATH="$TMP/bin:$PATH" HOME="$TMP/fakehome" XDG_RUNTIME_DIR="$TMP/run" \
  FAKE_STATUS_DIR="$TMP/replies" FAKE_PROTO="$PROTO" FAKE_FP="$FP" bash "$STATUS" 2>&1)"
assert_eq "$expected_view" "$cd_out" "run from the linked worktree, which borrows the main checkout's .devbox.env, the view is the same"

# ═══ the block characters ════════════════════════════════════════════════════
#
# With a UTF-8 charmap the bars are full and light blocks and the mark is a
# triangle. The ASCII view above, with each bar and the mark replaced, is the
# expected one, so the two forms cannot drift apart.
if locale -a 2>/dev/null | grep -qixE 'c\.utf-?8'; then
  utf_view="$(printf '%s\n' "$expected_view" \
    | sed -E -e ':b' -e 's/((tokens|cpu|mem) (█|░)*)#/\1█/' -e 's/((tokens|cpu|mem) (█|░)*)\./\1░/' -e 'tb' -e 's/^> /▶ /')"
  utf_out="$(cd "$CO" && env LC_ALL=C.UTF-8 PATH="$TMP/bin:$PATH" HOME="$TMP/fakehome" XDG_RUNTIME_DIR="$TMP/run" \
    FAKE_STATUS_DIR="$TMP/replies" FAKE_PROTO="$PROTO" FAKE_FP="$FP" bash "$STATUS" 2>&1)"
  assert_eq "$utf_view" "$utf_out" "with a UTF-8 charmap, the bars are blocks and this checkout's mark is a triangle"
  assert_ok "and the expected view did change: it holds a full block" contains "tokens ███████░ 28/32" "$utf_view"
else
  echo "  note: no C.UTF-8 locale on this machine, so the block character case did not run"
fi

# ═══ DEVBOX_STRICT=1 ═════════════════════════════════════════════════════════
run_status DEVBOX_STRICT=1 DEVBOX_TARGETS=cloud1
assert_eq "0" "$rc" "DEVBOX_STRICT=1 with DEVBOX_TARGETS=cloud1 in the environment: exit 0"
assert_fail "and the environment's list wins over the file's" contains "lan1" "$out"
run_status DEVBOX_TARGETS=cloud1
assert_ok "without strict mode, the file's list wins" contains "lan1      ok" "$out"

# ═══ the cpu bar ═════════════════════════════════════════════════════════════
#
# The host record's <cpu-busy> word is the cores busy over the host's 1-second
# sample. Through 3.0.0 it was the 1-minute load average, which counts every
# task a cgroup CPU limit throttles: a host whose gates used nearly all of its
# cores showed a load of several times its core count, and another showed
# red with much of its CPU idle. 8.0 of 16 is 4 cells, 12.0 of 16 is 6
# cells, and 15.7 of 16 is 7.9, so 8. A 3.0.0 host still sends its load
# average in that word, and 40.00 of 16 fills the bar and stops there.
cpu_reply() {  # $1 the <cpu-busy> word, of 16 cores
  {
    printf '%s %s %s\n' "$PROTO" "$FP" "$E"
    printf 'host ok 5 0 20 0 3 0 %s 16 %s %s 0 0\n' "$1" "$((30 * GIB))" "$((32 * GIB))"
    printf 'end\n'
  } >"$TMP/replies/cloud1.invalid.status"
}
STATUS_ARGS=(--target cloud1)
for case in "8.0 ####.... 8.0/16 " "12.0 ######.. 12.0/16" "15.7 ######## 15.7/16" "40.00 ######## 40.0/16"; do
  read -r word bar shown <<<"$case"
  cpu_reply "$word"
  run_status
  assert_ok "busy $word of 16 cores: cpu $bar $shown" \
    grep -qE "^cloud1    ok        tokens \.{8} 0/20     cpu ${bar//./\\.} ${shown//./\\.} +mem " <<<"$out"
done
assert_fail "and no target line names load" grep -q ' load ' <<<"$out"
STATUS_ARGS=()
reply_cloud1 "$E" >"$TMP/replies/cloud1.invalid.status"

# ═══ R15: colour ═════════════════════════════════════════════════════════════
assert_fail "a non-terminal output has no escape byte" contains "$ESC" "$out"
# A terminal needs a pseudo-terminal, which util-linux `script` gives. Where the
# tool is another `script`, these cases cannot run, and the file says so.
# $1 holds the environment words; $2, when given, the program and its
# arguments, each already quoted. util-linux `script -e` exits with the
# command's own status.
on_tty() {
  local cmd
  cmd="cd $(printf '%q' "$CO") && env PATH=$(printf '%q' "$TMP/bin:$PATH") HOME=$(printf '%q' "$TMP/fakehome") XDG_RUNTIME_DIR=$(printf '%q' "$TMP/run") FAKE_STATUS_DIR=$(printf '%q' "$TMP/replies") FAKE_PROTO=$PROTO FAKE_FP=$FP $1 bash ${2:-$(printf '%q' "$STATUS")}"
  script -qec "$cmd" /dev/null 2>&1
}
if script --version 2>/dev/null | grep -q util-linux; then
  tty_out="$(on_tty TERM=xterm)"
  assert_ok "on a terminal, the view has colour" contains "${ESC}[32mok" "$tty_out"
  assert_ok "and the OOM kill is red" contains "${ESC}[31m1 OOM kill" "$tty_out"
  assert_ok "a gate of this checkout has a bold name" contains "${ESC}[1mfix-cache/feat-login${ESC}[0m" "$tty_out"
  assert_ok "a gate of another laptop is dim" contains "${ESC}[2mother laptop${ESC}[0m" "$tty_out"
  # The cpu bar's bands: plain below 70% of the cores, yellow from 70%, red
  # from 90%. Half the cores busy is a host with room, and must not read as a
  # warning.
  for case in "8.0 8.0/16 plain" "12.0 12.0/16 yellow" "15.7 15.7/16 red"; do
    read -r word shown band <<<"$case"
    cpu_reply "$word"
    tty_out="$(on_tty TERM=xterm)"
    case "$band" in
      plain)  assert_ok "busy $word of 16 cores on a terminal: cpu $shown, no colour" \
                grep -qE "cpu [^${ESC}]+ ${shown//./\\.} " <<<"$tty_out" ;;
      yellow) assert_ok "busy $word of 16 cores on a terminal: cpu $shown in yellow" \
                grep -qE "cpu ${ESC}\[33m[^ ]+ ${shown//./\\.}${ESC}\[0m" <<<"$tty_out" ;;
      red)    assert_ok "busy $word of 16 cores on a terminal: cpu $shown in red" \
                grep -qE "cpu ${ESC}\[31m[^ ]+ ${shown//./\\.}${ESC}\[0m" <<<"$tty_out" ;;
    esac
  done
  reply_cloud1 "$E" >"$TMP/replies/cloud1.invalid.status"
  tty_out="$(on_tty "TERM=xterm NO_COLOR=1")"
  assert_ok "NO_COLOR on a terminal: the view is there" contains "lan1      ok" "$tty_out"
  assert_fail "and it has no escape byte" contains "$ESC" "$tty_out"
  tty_out="$(on_tty TERM=dumb)"
  assert_ok "TERM=dumb on a terminal: the view is there" contains "lan1      ok" "$tty_out"
  assert_fail "and it has no escape byte" contains "$ESC" "$tty_out"
  # A terminal that cannot move its cursor cannot hold a view that redraws in
  # place, so --watch refuses it before any target is asked.
  : >"$SSH_LOG"
  tty_rc=0
  tty_out="$(on_tty "TERM=dumb SSH_LOG=$SSH_LOG" "$(printf '%q' "$STATUS") --watch")" || tty_rc=$?
  assert_eq "2" "$tty_rc" "--watch with TERM=dumb: exit 2"
  assert_ok "and the refusal names the terminal" contains "can move its cursor" "$tty_out"
  assert_eq "0" "$(grep -c 'devbox-gate@' "$SSH_LOG")" "and no target is contacted"
else
  echo "  note: no util-linux script on this machine, so the terminal colour cases did not run"
fi

# ═══ R17, R18: watch mode ════════════════════════════════════════════════════
#
# Watch mode runs on a pseudo-terminal from util-linux `script`, sized with
# stty, with DEVBOX_STATUS_FRAMES bounding the frames it draws.
# The fake host keeps a master as a file, so the ssh log shows every password
# authentication (`-f -N`) and every verb of the whole session.
#
# $1 the keys to type: empty for none, `q`, or `int` for Ctrl-C. Each is typed
# once the watch has opened cloud1's master, so its traps are in place. $2 the
# environment words. The arguments of devbox status follow. Sets out and rc.
watch_tty() {
  local keys="$1" envw="$2" cmd res
  shift 2
  : >"$SSH_LOG"
  rm -rf "$TMP/masters"
  mkdir -p "$TMP/masters"
  cmd="env PATH=$(printf '%q' "$TMP/bin:$PATH") HOME=$(printf '%q' "$TMP/fakehome") XDG_RUNTIME_DIR=$(printf '%q' "$TMP/run") SSH_LOG=$(printf '%q' "$SSH_LOG") FAKE_STATUS_DIR=$(printf '%q' "$TMP/replies") FAKE_MASTER_DIR=$(printf '%q' "$TMP/masters") FAKE_PROTO=$PROTO FAKE_FP=$FP TERM=xterm LC_ALL=C.UTF-8 $envw bash $(printf '%q' "$STATUS") --watch $*"
  # `term` sends the watch SIGTERM, as a closing tab or a `kill` does. The
  # watch then runs as a job of the pseudo-terminal's shell, with that
  # terminal on its stdin, and the shell reports its exit code.
  if [ "$keys" = term ]; then
    cmd="$cmd </dev/tty & p=\$!; i=0; while [ ! -e $(printf '%q' "$TMP/masters/cloud1.invalid") ] && [ \$i -lt 100 ]; do sleep 0.1; i=\$((i + 1)); done; sleep 0.5; kill -TERM \$p; wait \$p"
    keys=""
  fi
  cmd="stty cols ${WATCH_COLS:-120} rows 40 && cd $(printf '%q' "$CO") && { $cmd; }"
  res="$(type_keys "$keys" | script -qec "$cmd" /dev/null 2>&1; printf 'rc=%s' "${PIPESTATUS[1]}")"
  rc="${res##*rc=}"
  out="$(printf '%s' "${res%rc=*}" | tr -d '\r')"
}
type_keys() {
  local i
  [ -n "$1" ] || return 0
  for ((i = 0; i < 100; i++)); do
    [ ! -e "$TMP/masters/cloud1.invalid" ] || break
    sleep 0.1
  done
  sleep 0.5
  case "$1" in q) printf q ;; int) printf '\003' ;; esac
}
# The visible text of every frame: no colour, no cursor movement.
plain() { printf '%s\n' "$1" | sed 's/\x1b\[[0-9;?]*[A-Za-z]//g'; }
count_in_log() { grep -c -- "$1" "$SSH_LOG"; }
# An alternation, not a bracket: a bracket of multibyte characters matches one
# byte under LC_ALL=C, and this file may run in any locale.
SPIN='(⠋|⠙|⠹|⠸|⠼|⠴|⠦|⠧|⠇|⠏)'

if script --version 2>/dev/null | grep -q util-linux && TERM=xterm tput smcup >/dev/null 2>&1; then
  SMCUP="$(TERM=xterm tput smcup)"; RMCUP="$(TERM=xterm tput rmcup)"
  CIVIS="$(TERM=xterm tput civis)"; CNORM="$(TERM=xterm tput cnorm)"
  restored() {  # $1 the case
    case "$out" in
      *"$SMCUP"*"$CIVIS"*"devbox status"*) _pass "$1: the alternate screen and the hidden cursor come before the first frame" ;;
      *) _fail "$1: the alternate screen and the hidden cursor come before the first frame" "$(printf '%q' "${out:0:80}")" ;;
    esac
    assert_fail "$1: no frame is drawn after the cursor comes back" contains "devbox status" "${out##*"$CNORM"}"
    assert_eq "" "$(printf '%s' "${out##*"$CNORM$RMCUP"}" | tr -d '\n')" \
      "$1: the EXIT trap shows the cursor and leaves the alternate screen, and that is the last output"
  }

  # R17: one frame, then the EXIT trap.
  watch_tty "" "DEVBOX_STATUS_FRAMES=1"
  assert_eq "0" "$rc" "one frame: exit 0"
  restored "one frame"
  assert_ok "the header names the interval and the key" \
    grep -qE '^devbox status  [0-9]{2}:[0-9]{2}:[0-9]{2}  every 3s  q quits' <<<"$(plain "$out")"
  assert_eq "0" "$(find "$TMP/masters" -maxdepth 1 -name '*.invalid' | wc -l | tr -d ' ')" \
    "every master the session opened is closed by the EXIT trap"

  # q and Ctrl-C leave with exit 0, long before the frame bound.
  SECONDS=0
  watch_tty q "DEVBOX_STATUS_FRAMES=400"
  assert_eq "0" "$rc" "q: exit 0"
  assert_ok "q: the watch ends at the key, not at the frame bound" test "$SECONDS" -lt 30
  restored "q"
  SECONDS=0
  watch_tty int "DEVBOX_STATUS_FRAMES=400"
  assert_eq "0" "$rc" "Ctrl-C: exit 0, the normal way out of a watch"
  assert_ok "Ctrl-C: the watch ends at the key, not at the frame bound" test "$SECONDS" -lt 30
  restored "Ctrl-C"
  SECONDS=0
  watch_tty term "DEVBOX_STATUS_FRAMES=400"
  assert_eq "143" "$rc" "SIGTERM: exit 143"
  assert_ok "SIGTERM: the watch ends at the signal, not at the frame bound" test "$SECONDS" -lt 30
  restored "SIGTERM"

  # R18: about 6 seconds at --interval 2 is three refreshes or more. lan1
  # answers once, then never finishes its second status.
  watch_tty "" "DEVBOX_STATUS_FRAMES=24 FAKE_STALL_SECOND=lan1.invalid DEVBOX_PROBE_ANSWER_SECONDS=60" --interval 2
  assert_eq "0" "$rc" "a watch with a stalled target: exit 0"
  n_cloud="$(count_in_log 'devbox-gate@cloud1.invalid status ')"
  assert_ok "cloud1 answers at every refresh: 3 status calls or more (got $n_cloud)" test "$n_cloud" -ge 3
  assert_eq "1" "$(count_in_log ' -f -N .*devbox-gate@cloud1.invalid')" \
    "cloud1: the gate password is sent once for the whole session"
  assert_eq "1" "$(count_in_log ' -f -N .*devbox-gate@lan1.invalid')" "lan1: the gate password is sent once"
  assert_eq "2" "$(count_in_log 'devbox-gate@lan1.invalid status ')" \
    "lan1: its first answer, then one call that never ends, and no second call stacked on it"
  # The line lan1 answered at the first refresh is older than two intervals by
  # the end, and says so.
  assert_ok "the old lan1 line ends with the time it is from" \
    grep -qE '^lan1      ok        tokens .* jobs 2/3 \(as of [0-9]{2}:[0-9]{2}:[0-9]{2}\)$' <<<"$(plain "$out")"
  assert_ok "and cloud1, which answers, has no such mark" \
    grep -qxF 'cloud1    ok        tokens ░░░░░░░░ 0/20     cpu █░░░░░░░ 0.3/8    mem █░░░░░░░ 2.0G/32G   jobs 0/3  no swap' <<<"$(plain "$out")"
  # The rows of the old answer stay in the table, under the line that dates them.
  assert_ok "lan1's gates stay in the table" grep -qE '^▶ running    fix-cache/feat-login  lan1 ' <<<"$(plain "$out")"
  # The spinner turns in the header alone, while a refresh is out. One beside
  # each row of this laptop made every row move on every frame.
  assert_ok "the header spinner turns while lan1's refresh is out" \
    grep -qE "q quits +$SPIN\$" <<<"$(plain "$out")"
  assert_fail "no row of the table carries a spinner" grep -qE "^ *$SPIN " <<<"$(plain "$out")"

  # R18: an unreachable target is tried once in 30 seconds, not at each refresh.
  watch_tty "" "DEVBOX_STATUS_FRAMES=24 FAKE_UNREACHABLE=lan1.invalid" --interval 2
  n_cloud="$(count_in_log 'devbox-gate@cloud1.invalid status ')"
  assert_ok "cloud1 answers at every refresh (got $n_cloud)" test "$n_cloud" -ge 3
  assert_eq "1" "$(count_in_log ' -f -N .*devbox-gate@lan1.invalid')" \
    "lan1, unreachable: one connection attempt in the first 30 seconds"
  assert_ok "and its line stays in the view" grep -q '^lan1      unreachable (no answer in 3s)' <<<"$(plain "$out")"
  # The 30 seconds may be shortened, as the probe's limits may be: at 3, lan1
  # is tried again, still less often than cloud1 is asked.
  watch_tty "" "DEVBOX_STATUS_FRAMES=24 FAKE_UNREACHABLE=lan1.invalid DEVBOX_STATUS_RETRY_SECONDS=3" --interval 2
  n_cloud="$(count_in_log 'devbox-gate@cloud1.invalid status ')"
  n_lan="$(count_in_log ' -f -N .*devbox-gate@lan1.invalid')"
  assert_ok "with a 3-second retry, lan1 is tried again ($n_lan attempts)" test "$n_lan" -ge 2
  assert_ok "and less often than cloud1 is asked ($n_lan against $n_cloud)" test "$n_lan" -lt "$n_cloud"

  # A refused password is not sent again in the session: the password cannot
  # change until the watch reads .devbox.env again, and the host's fail2ban
  # bans an address after 5 failures.
  watch_tty "" "DEVBOX_STATUS_FRAMES=24 FAKE_REFUSE=lan1.invalid" --interval 2
  assert_eq "1" "$(count_in_log ' -f -N .*devbox-gate@lan1.invalid')" "a refused password is sent once in the session"
  assert_ok "and the line says it was refused" grep -q '^lan1      the gate password was refused' <<<"$(plain "$out")"

  # Width: in watch mode a line is cut at the terminal width, never wrapped.
  # LC_ALL=C also turns the ASCII spinner, and keeps awk's length a count of
  # characters.
  WATCH_COLS=60 watch_tty "" "DEVBOX_STATUS_FRAMES=8 LC_ALL=C"
  long="$(plain "$out" | LC_ALL=C awk '{ if (length($0) > 60) print }')"
  assert_eq "" "$long" "on a 60-column terminal, no line of the view is longer than 60"
  host60="$(printf '%s' "$expected_view" | head -1 | cut -c1-60)"
  assert_ok "the lan1 server line is cut at column 60" grep -qxF "$host60" <<<"$(plain "$out")"
  assert_ok "with a charmap other than UTF-8, the spinner is |/-\\" \
    grep -qE 'q quits +[|/\\-]$' <<<"$(plain "$out")"
  assert_fail "and no braille frame is drawn" grep -qE "$SPIN" <<<"$out"
  assert_ok "and the bars are ASCII" grep -qF 'tokens #######.' <<<"$(plain "$out")"
else
  echo "  note: no util-linux script or no xterm terminfo on this machine, so the watch cases did not run"
fi

# ═══ R16 and the other usage errors: exit 2 ═════════════════════════════════
usage_case() {  # $1 the case, $2 the text the refusal must hold, then the arguments
  local desc="$1" text="$2"
  shift 2
  STATUS_ARGS=("$@")
  run_status
  STATUS_ARGS=()
  assert_eq "2" "$rc" "$desc: exit 2"
  assert_ok "$desc: the refusal says why" contains "$text" "$err"
  assert_eq "" "$out" "$desc: nothing on stdout"
  assert_eq "0" "$(grep -c 'devbox-gate@' "$SSH_LOG")" "$desc: no target is contacted"
}
usage_case "--watch without a terminal" "--watch needs a terminal" --watch
usage_case "--interval without --watch" "--interval needs --watch" --interval 5
usage_case "--interval below 2" "at least 2" --watch --interval 1
usage_case "--interval that is not a number" "at least 2" --watch --interval soon
usage_case "an unknown option" "unknown option: --json" --json
usage_case "a target the file does not list" "no target named lan9" --target lan9

printf 'DEVBOX_GATE_PASSWORD=fixture-gate-password\n' >"$CO/.devbox.env"
run_status
assert_eq "2" "$rc" "a .devbox.env with no target and no rental: exit 2"
assert_ok "and the refusal names the fix" \
  contains "no target to show: set DEVBOX_TARGETS or DEVBOX_RENT in .devbox.env" "$err"
rm -f "$CO/.devbox.env"
run_status
assert_eq "2" "$rc" "a checkout with no .devbox.env: exit 2"
assert_ok "with the same refusal" contains "no target to show" "$err"
printf '%s\n' "$ENV_BOTH" >"$CO/.devbox.env"

# A provider the file names is never left out in silence. With
# no key it is not asked, and its line says so. tests/test-devbox-status-rentals.sh
# covers a provider with a key, against a fake API.
printf 'DEVBOX_RENT=runpod\n' >>"$CO/.devbox.env"
run_status
assert_eq "0" "$rc" "a named provider with no key adds no failure: exit 0"
assert_eq "runpod    no key in .devbox.env, not checked" "$(printf '%s\n' "$out" | tail -1)" \
  "the provider has its own line after every target"
printf '%s\n' "$ENV_BOTH" >"$CO/.devbox.env"

printf '%d %d\n' "$TESTS_RUN" "$TESTS_FAILED"
