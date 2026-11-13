#!/bin/bash
# The decision a client makes before it spends anything on the devbox, and the
# one thing its fallback may never do.
#
# A fake ssh stands in for the host. Everything this file asserts happens on
# the laptop side of that boundary, which is where the decision lives.
#
# A project's first remote run reported green after a set of its tests errored
# on an image that lacked a required system tool, and the skip count changed
# with no warning. The fallback this file drives is the
# same shape of hazard one level up: a busy queue, not a missing image, is what
# would send a run to this laptop, and a laptop missing DEVBOX_REQUIRES must
# never be the one that runs the gate.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
# shellcheck source=tests/lib.sh
source ./lib.sh
# shellcheck source=tests/gate-stub-hold.sh
source ./gate-stub-hold.sh

T="$(cd .. && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/proj/.devbox" "$TMP/home" "$TMP/run" "$TMP/lanes"
export FAKE_LANES="$TMP/lanes"

# A real checkout. devbox-verify starts with `git rev-parse --show-toplevel`,
# and no commit is needed: nothing under test reads history, and `.git` stays
# a DIRECTORY, which keeps this fixture out of the linked-worktree branch that
# would try to rsync a git common dir.
git -C "$TMP/proj" init -q
: >"$TMP/proj/.devbox/exclude"

# The profile is rewritten per case, because DEVBOX_REQUIRES is the one value
# the fallback cases below need to vary. A token that names no real program on
# any machine this suite runs on, so "unmet" never depends on what happens to
# be installed here.
ABSENT_TOKEN="devbox-test-tool-nobody-installs-hgq7"
# DEVBOX_NEEDS_POSTGRES is the second thing the fallback has to decide on, and
# it is varied through this variable rather than a second positional argument,
# so every existing call below keeps meaning exactly what it meant. The key is
# written ONLY when this is 1: a project that needs no database commits a
# profile that never mentions it, and a fixture that always wrote a 0 would
# test a file shape no project has.
PROFILE_PG=0
# The name of the variable the profile exports the DSN under. Emptied by one
# case below, which writes a profile that asks for a database and never says
# what to call it: half an edit, and a shape a person really commits.
PROFILE_DB_URL_VAR=DEMO_TEST_DATABASE_URL
write_profile() {
  {
    echo "DEVBOX_PROJECT=demo"
    echo "DEVBOX_WANT_TOKENS=10"
    echo "DEVBOX_MIN_TOKENS=6"
    # QUOTED. One case below sets DEVBOX_REQUIRES to whitespace alone, and
    # `DEVBOX_REQUIRES=   ` is an assignment of the empty string followed by
    # nothing at all, so an unquoted fixture could not write that case: the
    # branch it exercises would have read as covered while the profile under
    # it said something else.
    [ -n "${1:-}" ] && printf "DEVBOX_REQUIRES='%s'\n" "$1"
    if [ "$PROFILE_PG" = "1" ]; then
      echo 'DEVBOX_NEEDS_POSTGRES=1'
      [ -n "$PROFILE_DB_URL_VAR" ] && printf 'DEVBOX_DB_URL_VAR=%s\n' "$PROFILE_DB_URL_VAR"
    fi
    echo 'DEVBOX_SETUP=:'
    # The marker a local gate leaves, and the one line every "did NOT fall
    # back" assertion below checks is absent from the run's whole output.
    echo 'DEVBOX_VERIFY=echo "LOCAL GATE RAN"'
  } >"$TMP/proj/.devbox/config.env"
}
write_profile

# .devbox.env is rewritten per case for the same reason: DEVBOX_MAX_QUEUE_WAIT
# and DEVBOX_QUEUE_FULL_ACTION are what each case is actually about.
write_env() {
  { echo 'DEVBOX_TARGETS=fakehost'; echo 'DEVBOX_TARGET_FAKEHOST=fakehost'; echo "DEVBOX_TARGET_FAKEHOST_HOSTKEY=$GATE_STUB_PIN"; echo 'DEVBOX_GATE_PASSWORD=fixture-gate-password'; printf '%s\n' "$@"; } >"$TMP/proj/.devbox.env"
}
write_env

# ── the fake host ────────────────────────────────────────────────────────────
#
# FAKE_PROTO and FAKE_FP are COMPUTED from this checkout's own library, never
# hardcoded: devbox_handshake_verdict compares the server's answer against this
# client's DEVBOX_PROTOCOL_VERSION and a sha256 of lib/devbox-lib.sh, and a
# hardcoded pair would fail this whole file the day either one is bumped for a
# reason that has nothing to do with the queue.
FAKE_PROTO="$(grep -m1 '^DEVBOX_PROTOCOL_VERSION=' "$T/lib/devbox-lib.sh" | cut -d= -f2)"
FAKE_FP="$(sha256sum <"$T/lib/devbox-lib.sh" | cut -d' ' -f1)"

SSH_LOG="$TMP/ssh.log"
export TMP SSH_LOG FAKE_PROTO FAKE_FP

# Matched against GATE_CMD, the verb and its words after devbox-gate@<host>,
# and never the last argument alone. Several calls pass more than one word
# (`check-requires <token>...`, `run <slug> ...`), so a stub that only
# inspected the last word would see a token, match nothing, and silently fall
# through to the catch-all for calls this file means to answer specifically.
# The log keeps the WHOLE argv, so a case can still read every word that left.
{ gate_stub_head; gate_stub_hold; cat <<'STUB'
case "$GATE_CMD" in
  version) printf '%s %s\n' "$FAKE_PROTO" "$FAKE_FP"; exit 0 ;;
  "queue-estimate "*)
    printf '%s\n' "${FAKE_EST-}"
    # The real verb ALWAYS prints a seven-space detail line under its protocol
    # line: devbox-pool's own case has an arm for every verdict and no path
    # that prints one line alone. Every fixture here used to be ONE line, so
    # the client's rule that only the FIRST line is read was pinned by nothing:
    # changing that read to take the LAST line instead left every assertion
    # in this file green, while against a real host every verdict would have
    # been parsed out of this English text. The line is composed HERE, from the
    # verdict, rather than written into each fixture, so an answer added
    # tomorrow cannot quietly go back to being one line.
    #
    # The sentences are devbox-pool's own, and the numbers come out of the
    # answer's own fields, so a reader comparing the two files sees the same
    # shape. Nothing the client does may depend on any of it.
    read -r _verdict _secs _samples _tok _jobs _queued <<<"${FAKE_EST-}"
    case "$_verdict" in
      now)  printf '       %s tokens are free of %s and %s of %s job slots are taken, so this ask fits now\n' \
              "$(( ${_tok#*/} - ${_tok%%/*} ))" "${_tok#*/}" "${_jobs%%/*}" "${_jobs#*/}" ;;
      wait) printf '       %ss is a projection from %s recorded run(s) of each job ahead, not a reservation: the queue moves while a caller syncs and sets up\n' \
              "$_secs" "$_samples" ;;
      # DEVBOX_MIN_TOKENS is 6 in the profile every case here writes, so this
      # is the sentence the real pool would compose for that ask.
      never) printf '       a min of 6 can never be granted by a pool whose total is %s, from /etc/devbox/config\n' \
              "${_tok#*/}" ;;
      unknown) printf '       this pool has no recorded duration for at least one job it would have to wait behind, so it will not put a number on this\n' ;;
    esac
    # FAKE_EST_PAD reproduces the exact hazard `| head -1` used to carry: once
    # head has read one line and closed its end, a further write bigger than
    # the pipe buffer gets SIGPIPE. Real ssh servers print a short second line
    # here, never this much, but the size is what makes the race deterministic
    # rather than a coin flip on scheduling.
    if [ -n "${FAKE_EST_PAD-}" ]; then head -c 200000 /dev/zero; exit "$?"; fi
    exit 0 ;;
  # The `run` verb's fifth word is the max wait: 0 is the unbounded retry,
  # anything else is the ceiling the developer asked for. FAKE_ACQ is the pool's
  # exit under that ceiling BEFORE any grant (75: it gave up queuing), and
  # FAKE_ACQ2 is the gate's own exit after `go`.
  "run "*)
    read -r _ _ _ _ _ _mw _ <<<"$GATE_CMD"
    if [ "$_mw" != 0 ] && [ "${FAKE_ACQ:-0}" != 0 ]; then exit "$FAKE_ACQ"; fi
    _hold_run
    cat >/dev/null
    exit "${FAKE_ACQ2:-0}" ;;
  "ensure-workspace "*) printf 'postgresql://fixture:fixture@fixture/fixture\n'; exit 0 ;;
  # The lane lock. LOCKED <slug> first, then stdin held open exactly as the
  # gate verb `lock` holds it on the host: the client waits for that word and
  # releases by closing its end of the fifo.
  #
  # FAKE_LOCK_VIEW names a file this arm writes what it sees WHILE the client
  # waits on it: each path its stdin (the fifo) and its stdout (the answer
  # file) really are, matched by inode with -ef rather than by name, the mode
  # of the directory holding them, and every name in the temp directory.
  # FAKE_LOCK_FAIL makes the verb end without LOCKED, as a refused lock does.
  "lock "*)
    if [ -n "${FAKE_LOCK_VIEW-}" ]; then
      for _p in $(find "${TMPDIR:-/tmp}" -mindepth 1 2>/dev/null) /tmp/devbox-lock-fifo.*; do
        [ -e "$_p" ] || continue
        if [ /dev/stdin -ef "$_p" ]; then
          printf 'fifo %s\n' "$_p" >>"$FAKE_LOCK_VIEW"
          printf 'mode %s\n' "$(ls -ld "$(dirname "$_p")" | cut -c1-10)" >>"$FAKE_LOCK_VIEW"
        fi
        if [ /dev/stdout -ef "$_p" ]; then printf 'out %s\n' "$_p" >>"$FAKE_LOCK_VIEW"; fi
      done
      ls -A "${TMPDIR:-/tmp}" | sed 's/^/entry /' >>"$FAKE_LOCK_VIEW"
    fi
    _hold_lock ;;
  *) exit 0 ;;
esac
STUB
} >"$TMP/bin/ssh"
chmod +x "$TMP/bin/ssh"
gate_stub_keyscan "$TMP/bin"

# rsync is a real program on this laptop, and the real one cannot speak to a
# fake ssh transport: it would fail the sync and every case below with it.
# Stubbed so the sync neither opens a connection nor copies anything.
cat >"$TMP/bin/rsync" <<'STUB'
#!/bin/bash
exit 0
STUB
chmod +x "$TMP/bin/rsync"

out=""; rc=0; ssh_log=""
FAKE_EST=""; FAKE_ACQ=0; FAKE_ACQ2=0; FAKE_EST_PAD=""
run_verify() {
  : >"$SSH_LOG"
  out="$(cd "$TMP/proj" && env PATH="$TMP/bin:$PATH" HOME="$TMP/home" XDG_RUNTIME_DIR="$TMP/run" \
    FAKE_EST="$FAKE_EST" FAKE_ACQ="$FAKE_ACQ" FAKE_ACQ2="$FAKE_ACQ2" \
    FAKE_EST_PAD="$FAKE_EST_PAD" \
    DEVBOX_LOCK_WAIT=5 \
    bash "$T/client/libexec/devbox-verify" 2>&1)"
  rc=$?
  ssh_log="$(cat "$SSH_LOG")"
  return 0
}
contains() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }
count() { grep -c -- "$1" <<<"$2" || true; }

# ── the two keys are validated before the probe ──────────────────────────────
#
# Both are read from a gitignored file no reviewer sees, so a typo has to be
# refused loudly rather than treated as the feature quietly doing nothing.
write_env 'DEVBOX_MAX_QUEUE_WAIT=soon'
run_verify
assert_eq "2" "$rc" "a max queue wait that is not an integer is refused"
assert_ok "the refusal names the key, the bad value and its origin" \
  contains "refusing DEVBOX_MAX_QUEUE_WAIT 'soon' from $TMP/proj/.devbox.env: it must be a non-negative integer" "$out"
assert_fail "and the probe never ran: no probe reached the fake host" \
  contains " probe " "$ssh_log"

write_env 'DEVBOX_MAX_QUEUE_WAIT=60' 'DEVBOX_QUEUE_FULL_ACTION=maybe'
run_verify
assert_eq "2" "$rc" "an action outside local and fail is refused"
assert_ok "the refusal names the key, the bad value and the two it accepts" \
  contains "refusing DEVBOX_QUEUE_FULL_ACTION 'maybe' from $TMP/proj/.devbox.env: write local, or fail, which is the default" "$out"

# The rule applies EVEN WHEN THE FEATURE IS OFF: DEVBOX_MAX_QUEUE_WAIT absent
# must not make a bad DEVBOX_QUEUE_FULL_ACTION into a preference nobody reads.
write_env 'DEVBOX_QUEUE_FULL_ACTION=maybe'
run_verify
assert_eq "2" "$rc" "a bad action is refused even with no max queue wait set at all"

# ── DEVBOX_MAX_QUEUE_WAIT unset or 0 is no ceiling ───────────────────────────
#
# Since protocol 6 the queue estimate is part of the one probe every run sends,
# so it costs no round trip of its own, with or without a ceiling.
write_env
FAKE_ACQ=0; FAKE_ACQ2=0
run_verify
assert_eq "0" "$rc" "with no max queue wait, the run still completes"
assert_eq "1" "$(count " probe " "$ssh_log")" \
  "and the target was asked exactly one probe"
assert_eq "0" "$(count "queue-estimate" "$ssh_log")" \
  "and no separate queue-estimate"
assert_ok "the run names the target it joins" contains "==> devbox: queuing on fakehost: " "$out"

# ── a gate's OWN 75 is not reinterpreted when the feature is off ────────────
#
# devbox-pool exits 75 in answer to its own --max-wait, and also on its
# unconditional DEVBOX_POOL_DEADLINE, which fires with no ceiling at all. So a
# 75 can reach this client even with the feature off, and FAKE_ACQ2 here
# stands for either source: this client cannot tell them apart, and does not
# need to. With the feature off there is no ceiling to name, so a 75 must
# pass straight through under EITHER action: "0 or unset keeps today's
# behaviour exactly".
write_env
FAKE_ACQ2=75
run_verify
assert_eq "75" "$rc" "a gate exiting 75 with no ceiling ever asked for is passed through, default action"
assert_fail "and is not reported as a ceiling giving up: the gate DID run" \
  contains "gave up waiting for tokens" "$out"

write_env 'DEVBOX_QUEUE_FULL_ACTION=local'
run_verify
assert_eq "75" "$rc" "the same 75 with the local action is passed through too, not fallen back from"
assert_fail "the remote gate's own answer is not thrown away for a local run" \
  contains "LOCAL GATE RAN" "$out"
FAKE_ACQ2=0

# ── the decision table ────────────────────────────────────────────────────────

# now: remote, no matter what the ceiling is.
write_env 'DEVBOX_MAX_QUEUE_WAIT=60'
FAKE_EST="now 0 3 4/32 1/3 0"
run_verify
assert_eq "0" "$rc" "a 'now' verdict runs remotely and completes"
assert_ok "the client says the ask fits now" contains "this ask fits now" "$out"
assert_ok "the run really reached the acquire" contains "devbox-gate@fakehost run " "$ssh_log"
assert_fail "and never ran the gate here" contains "LOCAL GATE RAN" "$out"
slug="$(printf '%s\n' "$out" | sed -n 's/^==> workspace \([^ ]*\) on fakehost$/\1/p')"
assert_ok "the acquire carries this workspace's own slug, which gate-root passes as the pool's label" \
  contains "devbox-gate@fakehost run $slug demo " "$ssh_log"

# wait, under the max: remote.
FAKE_EST="wait 30 5 10/32 3/3 2"
run_verify
assert_eq "0" "$rc" "a wait under the ceiling runs remotely and completes"
assert_ok "the projection is printed" \
  contains "10/32 tokens, 3/3 jobs, 2 waiting: about 30s of queuing" "$out"
assert_ok "the run really reached the acquire" contains "devbox-gate@fakehost run " "$ssh_log"
assert_fail "and never ran the gate here" contains "LOCAL GATE RAN" "$out"

# wait, EQUAL to the max: the decision table says <= is remote, so a projection
# that exactly meets the ceiling must not be read as exceeding it.
FAKE_EST="wait 60 5 10/32 3/3 2"
run_verify
assert_eq "0" "$rc" "a wait exactly equal to the ceiling still runs remotely and completes"
assert_ok "the run really reached the acquire" contains "devbox-gate@fakehost run " "$ssh_log"

# wait, with a MALFORMED seconds field (only a drifted or older server sends
# this): degrades to "no usable queue estimate" instead of crashing the
# ceiling comparison with a raw shell error the developer never asked for.
FAKE_EST="wait x 5 10/32 3/3 2"
run_verify
assert_eq "0" "$rc" "an unparseable seconds field still runs remotely and completes"
assert_ok "it degrades to the same message an unusable answer gets" \
  contains "no usable queue estimate, so this run waits on it under a 60s ceiling" "$out"
assert_fail "and no raw shell error reaches the developer's terminal" \
  contains "integer expression expected" "$out"
assert_ok "the run really reached the acquire" contains "devbox-gate@fakehost run " "$ssh_log"

# wait, over the max: the target is still joined. The estimate is an upper
# bound, so its queue may grant first, and only the ceiling ends the wait. A
# client that skipped it exited 8 at once while the queue could still free up.
FAKE_EST="wait 120 5 10/32 3/3 2"
run_verify
assert_eq "0" "$rc" "a wait over the ceiling is joined, and a grant within the ceiling runs the gate"
assert_ok "the join names the estimate" \
  contains "10/32 tokens, 3/3 jobs, 2 waiting: about 120s of queuing" "$out"
assert_fail "and the target is not skipped" contains "fakehost skipped" "$out"
assert_ok "the run really reached the acquire" contains "devbox-gate@fakehost run " "$ssh_log"

# wait, over the max, no grant within the ceiling, action fail: exit 8, gate
# runs nowhere. FAKE_ACQ=75 is the pool giving up on the ceiling it was sent.
FAKE_ACQ=75
run_verify
assert_eq "8" "$rc" "a wait over the ceiling that is not granted within it exits 8 with the default action"
assert_ok "the message names the queue and the ceiling" \
  contains "gave up waiting for tokens on fakehost after 60s. The gate did not run, here or there." "$out"
assert_ok "and the file to fix" contains "raise DEVBOX_MAX_QUEUE_WAIT in $TMP/proj/.devbox.env" "$out"
assert_eq "1" "$(count "devbox-gate@fakehost run " "$ssh_log")" \
  "and the acquire was asked for once"
assert_fail "no workspace was ever asked for on the host" \
  contains "devbox-gate@fakehost ensure-workspace" "$ssh_log"

# wait, over the max, no grant within the ceiling, action local,
# DEVBOX_REQUIRES unset: falls back, and nothing was created on the host.
write_env 'DEVBOX_MAX_QUEUE_WAIT=60' 'DEVBOX_QUEUE_FULL_ACTION=local'
write_profile
run_verify
assert_eq "0" "$rc" "the same wait with the local action and no requirements completes"
assert_ok "the local gate really ran" contains "LOCAL GATE RAN" "$out"
assert_ok "the banner names this machine and the reason" \
  contains "running demo's gate on THIS machine instead of fakehost." "$out"
assert_ok "and the reason is the ceiling" \
  contains "the queue on fakehost did not free up within your DEVBOX_MAX_QUEUE_WAIT of 60s" "$out"
assert_fail "no workspace was ever asked for on the host" \
  contains "devbox-gate@fakehost ensure-workspace" "$ssh_log"

# The same fallback with a DEVBOX_REQUIRES that is set and genuinely SATISFIED
# here, not merely absent from the profile. `bash` is on PATH on any machine
# this suite itself runs under, so this exercises the real pass through
# devbox-requires-local rather than the short-circuit an empty DEVBOX_REQUIRES
# takes before that program is ever invoked.
write_profile "bash"
run_verify
assert_eq "0" "$rc" "a met, non-empty DEVBOX_REQUIRES also falls back"
assert_ok "the local gate really ran" contains "LOCAL GATE RAN" "$out"
# The banner is the sentence a developer reads to decide whether to trust the
# result, so what it CLAIMS is asserted and not only that it appeared. It used
# to say this gate "covers the same code as the remote one", an equivalence no
# list of DEVBOX_REQUIRES tokens can establish, and the case below is a project
# for which it is false.
assert_ok "the banner names the tokens that were actually checked" \
  contains "every DEVBOX_REQUIRES token is satisfied here: bash." "$out"
assert_fail "and claims no equivalence with the remote gate" \
  contains "covers the same code as the remote one" "$out"
write_profile

# ── DEVBOX_NEEDS_POSTGRES refuses the fallback ───────────────────────────────
#
# DEVBOX_REQUIRES has three token forms, a path, a name on PATH and a version
# pin, and none of them can say "a provisioned Postgres role with its DSN
# exported". Only the remote path provisions that, so a gate that falls back
# here runs with the URL unset, and the cost is measured: a project skipped
# its database tests that way and still exited 0. A busy queue would then have produced a green gate over less code than the developer believes
# was tested, which is the failure this whole project exists to prevent.
#
# The requirement is `bash`, genuinely satisfied on any machine that can run
# this suite, so the refusal cannot be the requirement check standing in for
# the key.
PROFILE_PG=1
write_profile "bash"
run_verify
assert_eq "0" "$rc" "a project that needs Postgres keeps the run on the devbox, which still completes"
assert_fail "the local gate must NOT have run: this laptop provisions no database" \
  contains "LOCAL GATE RAN" "$out"
assert_ok "the refusal says which machine and why" \
  contains "NOT running demo's gate on this machine." "$out"
assert_ok "and names the key that caused it, in the file that holds it" \
  contains "DEVBOX_NEEDS_POSTGRES=1 in $TMP/proj/.devbox/config.env" "$out"
assert_ok "and names the variable a gate here would have run without" \
  contains "\$DEMO_TEST_DATABASE_URL unset" "$out"
assert_ok "and says the run keeps waiting on the devbox" \
  contains "so this run keeps waiting on fakehost instead." "$out"
assert_fail "the satisfied token list is never reported as if it settled the question" \
  contains "every DEVBOX_REQUIRES token is satisfied here" "$out"
assert_ok "which it does: the acquire really ran" contains "devbox-gate@fakehost run " "$ssh_log"

# The same key with DEVBOX_DB_URL_VAR missing. The refusal reads that name to
# tell the developer which variable a local gate would run without, and a bare
# read of it under `set -u` ends the whole run with "unbound variable" halfway
# through the sentence, taking with it the one line that names the file to fix.
PROFILE_DB_URL_VAR=""
write_profile "bash"
run_verify
assert_ok "a profile that names no URL variable still gets the whole refusal" \
  contains "DEVBOX_NEEDS_POSTGRES=1 in $TMP/proj/.devbox/config.env" "$out"
assert_fail "and the local gate is still not what runs" \
  contains "LOCAL GATE RAN" "$out"
PROFILE_DB_URL_VAR=DEMO_TEST_DATABASE_URL
PROFILE_PG=0
write_profile

# ── a DEVBOX_REQUIRES that is set and holds only whitespace ──────────────────
#
# `[ -n "$DEVBOX_REQUIRES" ]` is true of "   ", `read -r -a` then yields zero
# tokens, and devbox-requires-local is never called at all. The banner used to
# announce that every token was satisfied over a check that never ran. Falling
# back here is correct; telling the developer their machine was checked when
# nothing was is the same silent green as a suite reporting pass over
# skipped database tests.
write_profile "   "
run_verify
assert_eq "0" "$rc" "a whitespace-only DEVBOX_REQUIRES still falls back and completes"
assert_ok "the local gate ran" contains "LOCAL GATE RAN" "$out"
assert_fail "but nothing claims a token was satisfied, because none was checked" \
  contains "every DEVBOX_REQUIRES token is satisfied here" "$out"
assert_ok "the banner says plainly that nothing about this machine was checked" \
  contains "DEVBOX_REQUIRES names nothing to check here" "$out"
write_profile

# wait, over the max, action local, DEVBOX_REQUIRES UNMET: refuses the
# fallback and keeps waiting on the devbox instead.
write_profile "$ABSENT_TOKEN"
run_verify
assert_eq "0" "$rc" "an unmet requirement keeps the run on the devbox, which still completes"
assert_fail "the local gate must NOT have run" contains "LOCAL GATE RAN" "$out"
assert_ok "the refusal says which machine and why" \
  contains "NOT running demo's gate on this machine." "$out"
assert_ok "and names the unmet token" \
  contains "FAIL $ABSENT_TOKEN: not on PATH on this machine" "$out"
assert_ok "and says the run keeps waiting on the devbox" \
  contains "so this run keeps waiting on fakehost instead." "$out"
assert_ok "which it does: the acquire really ran" contains "devbox-gate@fakehost run " "$ssh_log"

# never: exit 8 whatever the action says, naming DEVBOX_MIN_TOKENS and the
# host config, and never as a comparison against a fraction.
write_profile "$ABSENT_TOKEN"
FAKE_EST="never - 0 0/32 0/3 0"
run_verify
assert_eq "8" "$rc" "a 'never' verdict exits 8 even though the action is local"
assert_ok "the project's own file and value are named" \
  contains "DEVBOX_MIN_TOKENS is 6 in $TMP/proj/.devbox/config.env" "$out"
assert_ok "and the host's total, read out of the held/total field, is named as a number" \
  contains "fakehost skipped: its pool holds 32 token(s) in all, and can never grant DEVBOX_MIN_TOKENS=6" "$out"
assert_fail "never as an unlabelled fraction compared to a plain count" \
  contains "is smaller: 0/32" "$out"
assert_ok "and the host config key that fixes it is named" \
  contains "raise DEVBOX_TOTAL_TOKENS in the deployment config of each target" "$out"
assert_fail "the local gate must NOT have run: never is refused, not routed around" \
  contains "LOCAL GATE RAN" "$out"

# The SAME verdict, but with a SATISFIABLE DEVBOX_REQUIRES ("bash"), so this
# property cannot be proven by the requirement check standing in for it.
# Without this case, a mutant that routes the never arm through
# queue_fallback under the local action is invisible: an UNMET requirement
# would refuse it anyway and land on the same exit 8, for the wrong reason.
write_profile "bash"
run_verify
assert_eq "8" "$rc" "'never' exits 8 with the local action even when the requirement is genuinely met"
assert_fail "refused as policy, not because devbox-requires-local said no" \
  contains "LOCAL GATE RAN" "$out"
write_profile

# The answer is read as ONE full capture, not piped into `head -1`, so a
# large second line cannot make ssh's own exit status swallow the first.
# FAKE_EST_PAD writes 200KB after the real line: under the old `| head -1`
# shape this reliably triggers a SIGPIPE once head has read its one line and
# closed the pipe, which turned this exact 'never' into "unknown" and cost
# the hour this verdict exists to save.
FAKE_EST="never - 0 0/32 0/3 0"
FAKE_EST_PAD=1
run_verify
assert_eq "8" "$rc" "a 'never' verdict is still read correctly behind a large second line"
assert_ok "the refusal still names the real numbers" \
  contains "DEVBOX_MIN_TOKENS is 6 in $TMP/proj/.devbox/config.env" "$out"
FAKE_EST_PAD=""

# unknown: remote, same as an empty or unparseable answer.
FAKE_EST="unknown - 0 4/32 1/3 1"
run_verify
assert_eq "0" "$rc" "an unknown verdict runs remotely and completes"
assert_ok "the client says so and names the ceiling that still applies" \
  contains "no usable queue estimate, so this run waits on it under a 60s ceiling" "$out"
assert_ok "the run really reached the acquire" contains "devbox-gate@fakehost run " "$ssh_log"

# ── the acquire's own ceiling expiry (exit 75) ───────────────────────────────

# fail: exit 8, and only one acquire was ever tried. The action is reset here
# on purpose: the previous case left DEVBOX_QUEUE_FULL_ACTION=local in place,
# and reusing that by accident would test the fallback again instead of this.
write_env 'DEVBOX_MAX_QUEUE_WAIT=60'
FAKE_EST="now 0 3 4/32 1/3 0"
FAKE_ACQ=75
run_verify
assert_eq "8" "$rc" "a ceiling that expires at the acquire, with the default action, exits 8"
assert_ok "the message names the ceiling and says the gate ran nowhere" \
  contains "gave up waiting for tokens on fakehost after 60s. The gate did not run, here or there." "$out"
assert_eq "1" "$(count "devbox-gate@fakehost run " "$ssh_log")" \
  "and it was asked for exactly once: a ceiling that expired is not retried under the fail action"

# local, DEVBOX_REQUIRES met: the acquire is not retried either, because the
# fallback took the run before a second attempt was ever considered.
write_env 'DEVBOX_MAX_QUEUE_WAIT=60' 'DEVBOX_QUEUE_FULL_ACTION=local'
FAKE_EST="now 0 3 4/32 1/3 0"
FAKE_ACQ=75; FAKE_ACQ2=0
run_verify
assert_eq "0" "$rc" "a ceiling that expires with the local action and a met requirement completes"
assert_ok "the local gate ran" contains "LOCAL GATE RAN" "$out"
assert_ok "the banner's reason is the acquire, not the probe" \
  contains "the queue on fakehost did not free up within your DEVBOX_MAX_QUEUE_WAIT of 60s" "$out"
assert_eq "1" "$(count "devbox-gate@fakehost run " "$ssh_log")" \
  "and the acquire was tried exactly once: the fallback took the run before any retry"

# local, DEVBOX_REQUIRES UNMET: the fallback is refused, so this laptop asks
# again with NO ceiling instead, using the SAME command string as the first
# attempt.
write_profile "$ABSENT_TOKEN"
run_verify
assert_eq "0" "$rc" "a ceiling that expires, refused locally, is retried with no ceiling and completes"
assert_fail "the local gate must NOT have run" contains "LOCAL GATE RAN" "$out"
assert_ok "the retry is announced" \
  contains "waiting on fakehost without a ceiling, because this machine cannot run this gate." "$out"
assert_eq "2" "$(count "devbox-gate@fakehost run " "$ssh_log")" \
  "the acquire was asked for exactly twice: the bounded try and the unbounded retry"
first_try="$(grep -m1 "devbox-gate@fakehost run " <<<"$ssh_log")"
second_try="$(grep "devbox-gate@fakehost run " <<<"$ssh_log" | tail -n1)"
assert_ok "the first attempt carried the developer's ceiling" \
  contains " 10 6 60 3600 verify" "$first_try"
assert_ok "and the retry carried none: it is bounded only by the pool's own deadline" \
  contains " 10 6 0 3600 verify" "$second_try"
write_profile

# ── the lock's fifo lives in a private directory ─────────────────────────────
#
# Since protocol 3 the fifos of every join live under the probe's own private
# directory, one directory per target, so the fifo sits some levels under
# TMPDIR rather than directly in it.
#
# The client used to make the fifo at a random name in the shared /tmp and open
# that name plus a fixed `.out` with `>`. The name was public from the moment
# mkfifo made it, so another local user could plant a symlink at the `.out`
# name and have the client truncate the file it pointed at. TMPDIR is a fresh
# directory per run here, so "nothing is left behind" is an exact count.
run_verify_tmpdir() {
  LOCK_TMP="$TMP/locktmp.$1"; LOCK_VIEW="$TMP/lockview.$1"
  mkdir -m 700 "$LOCK_TMP"; : >"$LOCK_VIEW"
  out="$(cd "$TMP/proj" && env PATH="$TMP/bin:$PATH" HOME="$TMP/home" XDG_RUNTIME_DIR="$TMP/run" \
    TMPDIR="$LOCK_TMP" FAKE_LOCK_VIEW="$LOCK_VIEW" FAKE_LOCK_FAIL="${2:-}" \
    DEVBOX_LOCK_WAIT=5 \
    bash "$T/client/libexec/devbox-verify" 2>&1)"
  rc=$?
  view="$(cat "$LOCK_VIEW")"
  left="$(find "$LOCK_TMP" -mindepth 1 | wc -l | tr -d ' ')"
  return 0
}
gone() { [ -n "$1" ] && [ ! -e "$1" ]; }

write_env
FAKE_EST=""; FAKE_ACQ=0; FAKE_ACQ2=0
run_verify_tmpdir held
assert_eq "0" "$rc" "a run that takes the lock with TMPDIR set completes"
lock_fifo="$(sed -n 's/^fifo //p' <<<"$view")"
lock_dir="$(dirname "${lock_fifo:-/nonexistent/x}")"
under() { case "$1" in "$2"/*) return 0 ;; esac; return 1; }
assert_ok "the lock's stdin was a fifo inside a directory under TMPDIR" under "$lock_dir" "$LOCK_TMP"
assert_ok "and its stdout was a file in that same directory" \
  contains "out $lock_dir/" "$view"
assert_ok "that directory was private to this user while the lock waited" \
  contains "mode drwx------" "$view"
assert_fail "the fifo was not in the shared /tmp" contains "fifo /tmp/devbox-lock-fifo." "$view"
assert_fail "no devbox-lock-fifo name existed in the temp directory during the run" \
  contains "entry devbox-lock-fifo" "$view"
assert_ok "the private lock directory is gone after exit" gone "$lock_dir"
assert_eq "0" "$left" "and the temp directory is empty after exit"

run_verify_tmpdir refused 1
assert_eq "4" "$rc" "a lock the host refuses exits 4"
assert_ok "and says it could not take the lock" contains "could not take the lock" "$out"
lock_fifo="$(sed -n 's/^fifo //p' <<<"$view")"
assert_ok "the refused lock also waited on a fifo under TMPDIR" under "${lock_fifo:-/nonexistent/x}" "$LOCK_TMP"
assert_ok "the refused lock's private directory is gone after exit" \
  gone "$(dirname "${lock_fifo:-/nonexistent/x}")"
assert_eq "0" "$left" "and the temp directory is empty after a refused lock"

printf '%d %d\n' "$TESTS_RUN" "$TESTS_FAILED"
