#!/bin/bash
# The client owns the gate (docs/specs/2026-11-14-client-owns-the-gate-design.md),
# end to end: the real devbox-verify plans the steps of a fixture's
# .devbox/steps, carries what did not change, runs the rest with the real
# devbox-steps through a fake gate account, writes the record, and prints the
# verdict. Rows D1, D5, D5a, D10, D10a, D11, R1, R2, R3 and the exit-code rule.
#
# MEASURED before it: every consumer put a wrapper of its own in front of the
# client, with its own plan, record and retry, and one-file changes reran every
# passed step. The fixture here has only .devbox/ files and its sources: no
# script of its own stands between it and the client.
#
# A fake ssh plays one target, lan1, with the lane lock, the held run, the gate
# and the `ledger` verb of tests/gate-stub-hold.sh. The gate runs the hooks as
# gate-root's verify entry does, so the step runner, the plan and the ledger
# tools cross in the hooks and run in the checkout directory. Each step is a
# line in STEP_LOG.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
# shellcheck source=tests/lib.sh
source ./lib.sh
# shellcheck source=tests/gate-stub-hold.sh
source ./gate-stub-hold.sh
# A CI job sets CI, and DEVBOX_LOCAL_GATE=ci reads it. Every case names its own.
unset CI DEVBOX_RERUN DEVBOX_STRICT

REPO="$(cd .. && pwd)"
TMP="$(mktemp -d)" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/home" "$TMP/run" "$TMP/lanes" "$TMP/ws" "$TMP/tmp"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

contains() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }

PROTO="$(sed -n 's/^DEVBOX_PROTOCOL_VERSION=\(.*\)$/\1/p' "$REPO/lib/devbox-lib.sh")"
FP="$(sha256sum <"$REPO/lib/devbox-lib.sh" | cut -d' ' -f1)"
HOLD_LOG="$TMP/hold.log"
SSH_LOG="$TMP/ssh.log"
STEP_LOG="$TMP/steps.log"
export HOLD_LOG SSH_LOG STEP_LOG
export FAKE_VERSION="$PROTO $FP" FAKE_LANES="$TMP/lanes" FAKE_WS="$TMP/ws"

# The fake host, at an RFC 5737 address.
A_LAN1=192.0.2.10

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
  "cancel "*) echo "gate-root: no running gate of this run belongs to this machine"; exit 1 ;;
esac
exit 0
STUB
} >"$TMP/bin/ssh"
# The sync's rsync to a host sends nothing. The plan lists the files with a
# local rsync dry run, which must be the real rsync.
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

# One step of the fixture's gate: it logs its name, prints one line, and exits
# with FAKE_RC_<name>, 0 when unset. FAKE_TOUCH names a synced file that the
# step named FAKE_TOUCH_STEP appends to while the gate runs.
cat >"$TMP/step.sh" <<'STEP'
#!/bin/bash
name="$1"
printf '%s\n' "$name" >>"$STEP_LOG"
var="FAKE_RC_${name//[^a-z0-9]/_}"
if [ -n "${FAKE_TOUCH-}" ] && [ "$name" = "${FAKE_TOUCH_STEP-}" ]; then printf 'changed\n' >>"$FAKE_TOUCH"; fi
echo "step $name output"
exit "${!var:-0}"
STEP

# A checkout with only .devbox/ files and its sources: config.env with no
# DEVBOX_VERIFY, and a three-step .devbox/steps. The lock file is a shared input.
new_checkout() {
  local co="$1"
  mkdir -p "$co/.devbox" "$co/src" "$co/types" "$co/tests"
  git -C "$co" init -q
  : >"$co/.devbox/exclude"
  printf 'one\n' >"$co/src/a.ts"
  printf 'one\n' >"$co/types/t.d.ts"
  printf 'one\n' >"$co/tests/a.test.ts"
  printf 'one\n' >"$co/package-lock.json"
  printf 'DEVBOX_PROJECT=app\nDEVBOX_WANT_TOKENS=4\nDEVBOX_MIN_TOKENS=2\nDEVBOX_SETUP=:\nDEVBOX_SHARED_INPUTS=package-lock.json\n' \
    >"$co/.devbox/config.env"
  {
    echo '# the fixture gate'
    echo "lint       inputs=src/                     -- bash $TMP/step.sh lint"
    echo "typecheck  inputs=src/,types/              -- bash $TMP/step.sh typecheck"
    echo "test       after=lint inputs=src/,tests/   -- bash $TMP/step.sh test"
  } >"$co/.devbox/steps"
}
CO="$TMP/checkout"
new_checkout "$CO"
{
  echo 'DEVBOX_TARGETS=lan1'
  echo "DEVBOX_TARGET_LAN1=$A_LAN1"; echo "DEVBOX_TARGET_LAN1_HOSTKEY=$GATE_STUB_PIN"
  echo 'DEVBOX_GATE_PASSWORD=fixture-gate-password'
  echo 'DEVBOX_AFFINITY_GRACE=0'
} >"$CO/.devbox.env"
RECORDS="$CO/.git/devbox/records"

out=""; rc=0
reset() { : >"$HOLD_LOG"; : >"$SSH_LOG"; : >"$STEP_LOG"; }
# verify [args]: run devbox-verify in the checkout $IN (default $CO).
verify() {
  reset
  rc=0
  out="$(cd "${IN:-$CO}" && env PATH="$TMP/bin:$PATH" HOME="$TMP/home" XDG_RUNTIME_DIR="$TMP/run" TMPDIR="$TMP/tmp" \
    DEVBOX_LOCK_WAIT=30 bash "$REPO/client/libexec/devbox-verify" "$@" 2>&1)" || rc=$?
}
result() { (cd "${IN:-$CO}" && bash "$REPO/client/libexec/devbox-result" "$@" 2>&1); }
ran() { tr '\n' ' ' <"$STEP_LOG" | sed 's/ $//'; }
last_line() { printf '%s\n' "$out" | tail -n 1; }
# The newest record of the checkout $IN, by its `at` and then its file name.
newest_record() {
  local dir="${IN:-$CO}/.git/devbox/records"
  awk -F'\t' '$1 == "at" { print $2 "\t" FILENAME }' "$dir"/*.record 2>/dev/null | sort -k1,1n -k2,2 | tail -n 1 | cut -f2
}
field() { awk -F'\t' -v k="$2" '$1 == k { print $2; exit }' "$1"; }
step_line() { awk -F'\t' -v s="$2" '$1 == "step" && $2 == s { print $4, $6, $7 }' "$1"; }

# ═══ D1: a fixture with only .devbox/ files passes its whole gate ════════════
verify --target lan1
assert_eq "0" "$rc" "D1: a three-step .devbox/steps passes devbox verify through the fake host"
assert_ok "D1: every step ran on the host" test "$(sort "$STEP_LOG" | tr '\n' ' ')" = "lint test typecheck "
assert_ok "D1: test ran after lint, as after=lint says" \
  test "$(grep -n '^lint$' "$STEP_LOG" | cut -d: -f1)" -lt "$(grep -n '^test$' "$STEP_LOG" | cut -d: -f1)"
assert_eq "devbox: green (3 steps: 3 ran, 0 carried)" "$(last_line)" "D1: the last line is the green verdict"
assert_fail "D1: the runner's result lines stay out of the terminal" contains "devbox-steps: result" "$out"
assert_ok "D1: the runner and the plan crossed in the hooks into the workspace" \
  test -f "$TMP/ws/$A_LAN1/$(ls "$TMP/ws/$A_LAN1")/steps/devbox-steps"
REC1="$(newest_record)"
assert_ok "D10: the gate wrote one record" test -f "$REC1"
assert_eq "1" "$(field "$REC1" complete)" "D10: complete 1"
assert_eq "full" "$(field "$REC1" scope)" "D10: scope full"
assert_eq "lan1" "$(field "$REC1" target)" "D10: target lan1"
assert_eq "pass 0 full" "$(step_line "$REC1" lint)" "D10: lint passed with code 0, run in full"
assert_ok "D10: each step line carries its sha256 key" \
  test "$(awk -F'\t' '$1 == "step" && $3 ~ /^[0-9a-f]{64}$/' "$REC1" | wc -l | tr -d ' ')" = 3
assert_ok "D10: the manifest lies beside the record" test -s "${REC1%.record}.files"
assert_ok "D10: the gate's output lies beside it, result lines included" grep -q '^devbox-steps: result lint pass ' "${REC1%.record}.log"
assert_ok "D10: devbox result prints the green verdict" contains "devbox: green (3 steps: 3 ran, 0 carried)" "$(result)"

# ═══ D5: a second run carries every step and asks no host ════════════════════
verify --target lan1
assert_eq "0" "$rc" "D5: an unchanged tree exits 0"
assert_eq "" "$(cat "$SSH_LOG")" "D5: with no ssh call at all"
assert_eq "" "$(ran)" "D5: and no step ran"
assert_eq "devbox: green (3 steps: 0 ran, 3 carried)" "$(last_line)" "D5: the verdict counts three carried steps"
REC2="$(newest_record)"
assert_eq "carried 0 full" "$(step_line "$REC2" test)" "D5: the record says carried"
assert_eq "1" "$(field "$REC2" complete)" "D5: and is complete, so it carries in turn"

# ═══ R1: --plan prints each step's plan and reason, and runs nothing ═════════
printf 'two\n' >"$CO/types/t.d.ts"
verify --plan
assert_eq "0" "$rc" "R1: --plan exits 0"
assert_eq "" "$(cat "$SSH_LOG")" "R1: with no ssh call"
assert_eq "" "$(ran)" "R1: and no step ran"
assert_ok "R1: typecheck runs, with the changed input as its reason" grep -qx 'typecheck  run  inputs changed: 1 files' <<<"$out"
assert_ok "R1: lint carries, naming the run it carries from" grep -qE '^lint  carry  carried from run [0-9a-f]+\.[0-9]+$' <<<"$out"
assert_eq "" "$(find "$RECORDS" -newer "$REC2" -name '*.record')" "R1: and no record was written"

# ═══ D5a: a change to one input runs only the steps that read it ═════════════
verify --target lan1
assert_eq "0" "$rc" "D5a: the run with one changed input passes"
assert_eq "typecheck" "$(ran)" "D5a: types/t.d.ts changed, so typecheck alone ran on the host"
assert_eq "devbox: green (3 steps: 1 ran, 2 carried)" "$(last_line)" "D5a: two steps carried"
printf 'two\n' >"$CO/package-lock.json"
verify --target lan1
assert_eq "lint test typecheck" "$(sort "$STEP_LOG" | tr '\n' ' ' | sed 's/ $//')" "D5a: a shared input changed, so every step ran"

# ═══ the exit code: the first failed step in plan order ══════════════════════
FAKE_RC_lint=2 FAKE_RC_typecheck=5 verify --target lan1 --full
assert_eq "2" "$rc" "exit code: lint fails with 2 and typecheck with 5, so devbox verify exits 2"
assert_eq "devbox: red (lint failed; typecheck failed)" "$(last_line)" "exit code: the red verdict names both"
assert_ok "exit code: a failed step's log follows its header" grep -qx 'step lint output' <<<"$out"
RED="$(newest_record)"
assert_eq "fail 5 full" "$(step_line "$RED" typecheck)" "D10: the record keeps each step's own code"
assert_ok "D10: devbox result --log lint prints that step's section" \
  contains "step lint output" "$(result --log lint)"
assert_ok "D10: devbox result prints the red verdict" contains "devbox: red (lint failed; typecheck failed)" "$(result)"
# A project that has not moved to .devbox/steps: DEVBOX_VERIFY is one step, and
# its code is the run's, as it was before.
COMPAT="$TMP/compat"
new_checkout "$COMPAT"
rm "$COMPAT/.devbox/steps"
printf 'DEVBOX_VERIFY=bash %s verify\n' "$TMP/step.sh" >>"$COMPAT/.devbox/config.env"
cp "$CO/.devbox.env" "$COMPAT/.devbox.env"
IN="$COMPAT" FAKE_RC_verify=3 verify --target lan1
assert_eq "3" "$rc" "exit code: a DEVBOX_VERIFY that exits 3 makes devbox verify exit 3"
assert_ok "exit code: its output streams as it did, one step alone" grep -qx 'step verify output' <<<"$out"
assert_eq "fail 3 full" "$(IN="$COMPAT"; step_line "$(newest_record)" verify)" "exit code: the record names the step verify"
rc=0
out="$(cd "$COMPAT" && env PATH="$TMP/bin:$PATH" HOME="$TMP/home" XDG_RUNTIME_DIR="$TMP/run" TMPDIR="$TMP/tmp" \
  DEVBOX_LOCK_WAIT=30 DEVBOX_STRICT=1 FAKE_RC_verify=3 bash "$REPO/client/libexec/devbox-verify" --target lan1 2>&1)" || rc=$?
assert_eq "3" "$rc" "exit code: under DEVBOX_STRICT=1 the gate's own 3 passes unmapped"
IN="$COMPAT" verify --target lan1
assert_eq "0" "$rc" "exit code: the same DEVBOX_VERIFY passing exits 0"
printf 'DEVBOX_VERIFY=bash %s verify\n' "$TMP/step.sh" >>"$CO/.devbox/config.env"
verify --target lan1 --plan
assert_eq "1" "$(grep -c 'DEVBOX_VERIFY in .* does not run' <<<"$out")" "both set: one line says .devbox/steps is the gate"
assert_ok "both set: the plan holds the three steps of the file" test "$(grep -cE '^(lint|typecheck|test)  ' <<<"$out")" = 3
sed -i '/^DEVBOX_VERIFY=/d' "$CO/.devbox/config.env"

# ═══ R2: --step writes a partial record and never prints green ═══════════════
printf 'three\n' >"$CO/src/a.ts"
verify --target lan1 --step lint
assert_eq "0" "$rc" "R2: --step lint passes"
assert_eq "lint" "$(ran)" "R2: and runs lint alone"
PART="$(newest_record)"
assert_eq "partial" "$(field "$PART" scope)" "R2: the record is partial"
assert_fail "R2: the run never prints devbox: green" contains "devbox: green" "$out"
assert_ok "R2: its last line is a partial pass" contains "devbox: partial pass" "$(last_line)"
verify --plan
assert_ok "R2: the passed step carries later, because a key is a key" grep -qE '^lint  carry  ' <<<"$out"
verify --target lan1 --step nope
assert_eq "2" "$rc" "R2: a step the gate does not hold is refused with exit 2"
assert_eq "" "$(cat "$SSH_LOG")" "R2: before any target is asked"

# ═══ D10a: a file changed while the gate ran: complete 0, nothing carries ════
printf 'four\n' >"$CO/src/a.ts"
FAKE_TOUCH="$CO/src/a.ts" FAKE_TOUCH_STEP=lint verify --target lan1
assert_eq "0" "$rc" "D10a: the steps passed, so the code is 0"
assert_ok "D10a: one line says the result does not carry" \
  contains "devbox verify: files changed while the gate ran, so this result does not carry" "$out"
assert_eq "0" "$(field "$(newest_record)" complete)" "D10a: the record is complete 0"
printf 'four\n' >"$CO/src/a.ts"
verify --plan
assert_ok "D10a: with the planned tree back, lint does not carry from that record" grep -qE '^lint  run  ' <<<"$out"

# ═══ R3: --local runs the same steps with the same runner and record ═════════
printf 'five\n' >"$CO/src/a.ts"
verify --target lan1 --full
REMOTE_REC="$(newest_record)"
verify --local --full
assert_eq "0" "$rc" "R3: --local passes"
assert_eq "lint test typecheck" "$(sort "$STEP_LOG" | tr '\n' ' ' | sed 's/ $//')" "R3: and runs the same three steps here"
assert_eq "" "$(cat "$SSH_LOG")" "R3: with no ssh call"
LOCAL_REC="$(newest_record)"
assert_eq "local" "$(field "$LOCAL_REC" target)" "R3: the local record names target local"
norm() { awk -F'\t' -v OFS='\t' '$1 == "run" || $1 == "at" || $1 == "target" { next } $1 == "step" { $5 = "-" } { print }' "$1"; }
assert_eq "$(norm "$REMOTE_REC")" "$(norm "$LOCAL_REC")" "R3: the two records are equal but for the run, the time, the target and the seconds"
assert_ok "R3: the local logs sit in the private dir" test -n "$(find "$TMP/run/devbox/steps" -name lint.log)"

# ═══ D11: no .devbox.env and DEVBOX_LOCAL_GATE ═══════════════════════════════
SOLO="$TMP/solo"
new_checkout "$SOLO"
printf 'DEVBOX_LOCAL_GATE=ci\n' >>"$SOLO/.devbox/config.env"
IN="$SOLO" verify
assert_eq "2" "$rc" "D11: no .devbox.env, DEVBOX_LOCAL_GATE=ci and no CI: exit 2"
assert_ok "D11: naming the key and the way out" contains "DEVBOX_LOCAL_GATE=ci refuses a gate on this machine; pass --local, or set CI in a CI job" "$out"
assert_eq "" "$(ran)" "D11: and nothing ran"
IN="$SOLO" CI=true verify
assert_eq "0" "$rc" "D11: with CI set, the gate runs here"
assert_eq "local" "$(IN="$SOLO"; field "$(newest_record)" target)" "D11: and its record names target local"
IN="$SOLO" verify --local --full
assert_eq "0" "$rc" "D11: with --local, the gate runs here"
assert_ok "D11: all three steps" test "$(wc -l <"$STEP_LOG" | tr -d ' ')" = 3
sed -i 's/^DEVBOX_LOCAL_GATE=ci$/DEVBOX_LOCAL_GATE=never/' "$SOLO/.devbox/config.env"
IN="$SOLO" verify --local
assert_eq "2" "$rc" "D11: DEVBOX_LOCAL_GATE=never refuses --local too"
sed -i '/^DEVBOX_LOCAL_GATE=/d' "$SOLO/.devbox/config.env"
IN="$SOLO" verify --full
assert_eq "0" "$rc" "D11: the default, always, runs the gate here as release 1 did"

# ═══ D2 end to end: a broken .devbox/steps is refused before any host ════════
cp "$CO/.devbox/steps" "$TMP/steps.good"
printf 'broken inputs=src/ no-separator\n' >>"$CO/.devbox/steps"
verify --target lan1
assert_eq "2" "$rc" "D2: a broken line exits 2"
assert_ok "D2: by its line number" contains "devbox verify: .devbox/steps line 5: " "$out"
assert_eq "" "$(cat "$SSH_LOG")" "D2: before any target is asked"
cp "$TMP/steps.good" "$CO/.devbox/steps"

# The display shows each step line as it arrives. Through mawk, a real gate's
# step lines reached the terminal only when the gate ended.
eval "$(sed -n '/^steps_display() {/,/^}/p' "$REPO/client/libexec/devbox-verify")"
{ printf '[0 s] lint started\n'; sleep 3; printf 'devbox-steps: result lint pass 3 0\n'; } \
  | steps_display "$TMP/display.raw" > "$TMP/display.out" &
display_pid=$!
n=0
while ! grep -q 'lint started' "$TMP/display.out" 2>/dev/null && [ "$n" -lt 20 ]; do sleep 0.1; n=$((n + 1)); done
assert_ok "the display shows a step line while the gate still runs" grep -q 'lint started' "$TMP/display.out"
wait "$display_pid"
assert_eq 0 "$?" "a display whose last line is a result line still ends 0"
assert_fail "and it hides the result line" grep -q 'devbox-steps: result' "$TMP/display.out"
assert_ok "which the raw copy keeps for the record" grep -q 'devbox-steps: result lint pass 3 0' "$TMP/display.raw"

printf '%d %d\n' "$TESTS_RUN" "$TESTS_FAILED"
