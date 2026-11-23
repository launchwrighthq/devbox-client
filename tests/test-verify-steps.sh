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
unset CI DEVBOX_RERUN DEVBOX_STRICT DEVBOX_STRICT_TREE

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
  # The seed verb of the prep-throughput spec. FAKE_SEED=old answers as a
  # devbox-gate older than the verb does, and FAKE_SEED=fault as a host fault.
  "seed "*)
    case "${FAKE_SEED-}" in
      old) echo "devbox-gate: unknown verb 'seed'. This account runs devbox gate verbs only: a client older than protocol 3 sends raw commands, so update the devbox client" >&2; exit 2 ;;
      fault) echo "devbox-runner seed: docker names no mountpoint for ws-laptop-app-main-a1b2c3-home" >&2; exit 1 ;;
      *) printf 'seed copied laptop-app-main-7c209c 1024 30\n' ;;
    esac ;;
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
# FAKE_FAILED_FILE: the step named FAKE_FAILED_FILE_STEP writes that test file
# failed into the gate's ledger, and still exits 0.
if [ -n "${FAKE_FAILED_FILE-}" ] && [ "$name" = "${FAKE_FAILED_FILE_STEP-}" ]; then
  printf 'file\tvitest\t%s\tfail\t1\n' "$FAKE_FAILED_FILE" >>"$DEVBOX_LEDGER"
fi
echo "step $name output"
exit "${!var:-0}"
STEP

# A checkout with only .devbox/ files and its sources: config.env and a
# three-step .devbox/steps. The lock file is a shared input.
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
# A red gate ends in two lines: the verdict, then the failures line.
verdict_line() { printf '%s\n' "$out" | grep '^devbox: ' | tail -n 1; }
failures_lines() { printf '%s\n' "$out" | grep -c '^verify: failures '; }
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
assert_eq "0" "$(failures_lines)" "failures line: a green gate prints none"
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
assert_eq "devbox: red (lint failed; typecheck failed)" "$(verdict_line)" "exit code: the red verdict names both"
# The line after the verdict names each failed step: no test file of these
# two failed, so neither is attributable.
assert_eq 'verify: failures {"lint": {"code": 2, "attributable": false, "failedFiles": []}, "typecheck": {"code": 5, "attributable": false, "failedFiles": []}}' \
  "$(last_line)" "failures line: the last line of a red gate names each failed step and its code"
assert_eq "1" "$(failures_lines)" "failures line: a red gate prints exactly one"
assert_ok "exit code: a failed step's log follows its header" grep -qx 'step lint output' <<<"$out"
RED="$(newest_record)"
assert_eq "fail 5 full" "$(step_line "$RED" typecheck)" "D10: the record keeps each step's own code"
assert_ok "D10: devbox result --log lint prints that step's section" \
  contains "step lint output" "$(result --log lint)"
assert_ok "D10: devbox result prints the red verdict" contains "devbox: red (lint failed; typecheck failed)" "$(result)"
# The one step a DEVBOX_VERIFY gate became, now written in .devbox/steps: its
# code is the run's, as it was before.
COMPAT="$TMP/compat"
new_checkout "$COMPAT"
printf 'verify -- bash %s verify\n' "$TMP/step.sh" >"$COMPAT/.devbox/steps"
cp "$CO/.devbox.env" "$COMPAT/.devbox.env"
IN="$COMPAT" FAKE_RC_verify=3 verify --target lan1
assert_eq "3" "$rc" "exit code: a one-step gate that exits 3 makes devbox verify exit 3"
assert_ok "exit code: its output streams as it did, one step alone" grep -qx 'step verify output' <<<"$out"
assert_eq "fail 3 full" "$(IN="$COMPAT"; step_line "$(newest_record)" verify)" "exit code: the record names the step verify"
rc=0
out="$(cd "$COMPAT" && env PATH="$TMP/bin:$PATH" HOME="$TMP/home" XDG_RUNTIME_DIR="$TMP/run" TMPDIR="$TMP/tmp" \
  DEVBOX_LOCK_WAIT=30 DEVBOX_STRICT=1 FAKE_RC_verify=3 bash "$REPO/client/libexec/devbox-verify" --target lan1 2>&1)" || rc=$?
assert_eq "3" "$rc" "exit code: under DEVBOX_STRICT=1 the gate's own 3 passes unmapped"
IN="$COMPAT" verify --target lan1
assert_eq "0" "$rc" "exit code: the same step passing exits 0"

# ═══ R7: release 4.0 refuses the older keys on every path ════════════════════
#
# A refused line in .devbox/config.env stops verify, its plan, --local and
# devbox run with exit 2 before any target is asked. select= in .devbox/steps
# stops every path that reads the steps: verify, its plan, --local and devbox
# ci matrix. devbox run runs one command and reads no steps file. Each line
# names what replaces the key.
refused_everywhere() {  # $1 the description, $2 the text the refusal holds, then the argument lists
  local desc="$1" text="$2" args
  shift 2
  for args in "$@"; do
    # shellcheck disable=SC2086  # each entry is a list of words
    verify $args
    assert_eq "2" "$rc" "R7: $desc: verify $args exits 2"
    assert_ok "R7: $desc: verify $args names the replacement" contains "$text" "$out"
    assert_eq "" "$(cat "$SSH_LOG")" "R7: $desc: verify $args asks no target"
    assert_eq "" "$(ran)" "R7: $desc: verify $args runs no step"
  done
}
cp "$CO/.devbox/config.env" "$TMP/config.good"
for line in 'DEVBOX_VERIFY=npm run verify' 'DEVBOX_NEEDS_POSTGRES=1' 'DEVBOX_DB_URL_VAR=APP_DB'; do
  printf '%s\n' "$line" >>"$CO/.devbox/config.env"
  refused_everywhere "$line" "${line%%=*} is no longer read. " "--target lan1" "--plan" "--local" "--run -- true"
  cp "$TMP/config.good" "$CO/.devbox/config.env"
done
cp "$CO/.devbox/steps" "$TMP/steps.good"
printf 'more runner=vitest select=related -- npx vitest run\n' >>"$CO/.devbox/steps"
refused_everywhere "select=related" \
  "devbox verify: .devbox/steps line 5: select=related is no longer read, because every runner step selects its test files by what they read; remove it" \
  "--target lan1" "--plan" "--local"
rc=0
out="$(cd "$CO" && bash "$REPO/client/libexec/devbox-ci" matrix 2>&1)" || rc=$?
assert_eq "2" "$rc" "R7: select=related: devbox ci matrix exits 2"
assert_ok "R7: select=related: devbox ci matrix names the line" contains ".devbox/steps line 5: select=related is no longer read" "$out"
cp "$TMP/steps.good" "$CO/.devbox/steps"

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

# ═══ D1a (gate fixes 4.0.1): a red verdict never exits 0 ═════════════════════
# MEASURED: a resumed gate recorded its step pass beside two failed files of
# that step, and printed green. The verdict reads such a record red, and the
# code follows the verdict.
FAKE_FAILED_FILE=tests/a.test.ts FAKE_FAILED_FILE_STEP=lint verify --target lan1 --full --step lint
assert_eq "pass" "$(step_line "$(newest_record)" lint | cut -d' ' -f1)" "D1a: the record holds the step pass"
assert_eq "fail" "$(awk -F'\t' '$1 == "file" && $2 == "lint" { print $5 }' "$(newest_record)")" \
  "D1a: beside a failed test file of that step"
assert_eq "devbox: red (lint passed with 1 failed files)" "$(verdict_line)" "D1a: the verdict is red"
assert_eq 'verify: failures {"lint": {"code": 1, "attributable": true, "failedFiles": ["tests/a.test.ts"]}}' \
  "$(last_line)" "failures line: a --step run names the failed test file, relative to the repository root"
assert_eq "1" "$rc" "D1a: and the gate exits 1, the code of a failed gate, never 0"
FAKE_FAILED_FILE=tests/a.test.ts FAKE_FAILED_FILE_STEP=lint verify --local --full --step lint
assert_eq "devbox: red (lint passed with 1 failed files)" "$(verdict_line)" "D1a: a gate on this laptop reads red too"
assert_eq 'verify: failures {"lint": {"code": 1, "attributable": true, "failedFiles": ["tests/a.test.ts"]}}' \
  "$(last_line)" "failures line: --local prints the same line"
assert_eq "1" "$(failures_lines)" "failures line: and exactly one"
assert_eq "1" "$rc" "D1a: and exits 1"

# ═══ D10a: a file changed while the gate ran: complete 0, nothing carries ════
printf 'four\n' >"$CO/src/a.ts"
FAKE_TOUCH="$CO/src/a.ts" FAKE_TOUCH_STEP=lint verify --target lan1
assert_eq "0" "$rc" "D10a: the steps passed, so the code is 0"
assert_ok "D10a: one line says the result does not carry" \
  contains "devbox verify: files changed while the gate ran, so this result does not carry" "$out"
assert_eq "0" "$(field "$(newest_record)" complete)" "D10a: the record is complete 0"
# Every step of this gate ended. Its verdict once read `did not end every step`.
assert_eq "files changed while it ran" "$(field "$(newest_record)" reason)" "D10a: the record names why it does not carry"
assert_ok "D10a: and the verdict names that reason" \
  grep -qE '^devbox: incomplete \(run [^ ]+ does not carry: files changed while it ran\)$' <<<"$(last_line)"
printf 'four\n' >"$CO/src/a.ts"
verify --plan
assert_ok "D10a: with the planned tree back, lint does not carry from that record" grep -qE '^lint  run  ' <<<"$out"

# ═══ DEVBOX_STRICT_TREE=1: such a gate exits 13, and nothing else changes ═════
TREE_VERDICT='^devbox: incomplete \(run [^ ]+ does not carry: files changed while it ran\)$'
printf 'four-a\n' >"$CO/src/a.ts"
DEVBOX_STRICT_TREE=1 FAKE_TOUCH="$CO/src/a.ts" FAKE_TOUCH_STEP=lint verify --target lan1
assert_eq "13" "$rc" "strict tree: every step passed and a file changed, so the gate exits 13"
assert_ok "strict tree: the last line is the same incomplete verdict" grep -qE "$TREE_VERDICT" <<<"$(last_line)"
assert_ok "strict tree: one line names the key and the code" \
  contains "devbox verify: DEVBOX_STRICT_TREE=1, so this gate exits 13: every step passed, and the files are not the ones the gate ran on" "$out"
assert_eq "0" "$(field "$(newest_record)" complete)" "strict tree: the record is complete 0, as without the key"
printf 'four-b\n' >"$CO/src/a.ts"
DEVBOX_STRICT_TREE=1 FAKE_TOUCH="$CO/src/a.ts" FAKE_TOUCH_STEP=lint verify --local
assert_eq "13" "$rc" "strict tree: a gate on this machine exits 13 too"
assert_ok "strict tree: with the same last line" grep -qE "$TREE_VERDICT" <<<"$(last_line)"
printf 'four-c\n' >"$CO/src/a.ts"
DEVBOX_STRICT_TREE=0 FAKE_TOUCH="$CO/src/a.ts" FAKE_TOUCH_STEP=lint verify --target lan1
assert_eq "0" "$rc" "strict tree: DEVBOX_STRICT_TREE=0 is the default, exit 0"
printf 'four-d\n' >"$CO/src/a.ts"
DEVBOX_STRICT_TREE=1 FAKE_RC_lint=3 FAKE_TOUCH="$CO/src/a.ts" FAKE_TOUCH_STEP=lint verify --target lan1
assert_eq "3" "$rc" "strict tree: a failed step keeps its own code"
printf 'four-s\n' >"$CO/src/a.ts"
DEVBOX_STRICT=1 DEVBOX_STRICT_TREE=1 FAKE_TOUCH="$CO/src/a.ts" FAKE_TOUCH_STEP=lint verify --target lan1
assert_eq "13" "$rc" "strict tree: DEVBOX_STRICT=1 does not move the 13"
assert_ok "strict tree: and the last line is the same incomplete verdict" grep -qE "$TREE_VERDICT" <<<"$(last_line)"
printf 'four-e\n' >"$CO/src/a.ts"
DEVBOX_STRICT_TREE=1 verify --target lan1
assert_eq "0" "$rc" "strict tree: a gate whose files did not change exits 0"
assert_ok "strict tree: and reads green" contains "devbox: green" "$(last_line)"

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
sed -i 's/^DEVBOX_LOCAL_GATE=never$/DEVBOX_LOCAL_GATE=always/' "$SOLO/.devbox/config.env"
IN="$SOLO" verify --full
assert_eq "0" "$rc" "D11: DEVBOX_LOCAL_GATE=always runs the gate here as release 3 did"
sed -i '/^DEVBOX_LOCAL_GATE=/d' "$SOLO/.devbox/config.env"
IN="$SOLO" verify --full
assert_eq "2" "$rc" "D11: the default since release 4.0, ci, refuses a gate here with no CI and no --local"
assert_ok "D11: and its line names the key and the way out" contains "DEVBOX_LOCAL_GATE=ci refuses a gate on this machine" "$out"
IN="$SOLO" CI=true verify --full
assert_eq "0" "$rc" "D11: the default runs the gate here when CI is set"

# ═══ D2 end to end: a broken .devbox/steps is refused before any host ════════
cp "$CO/.devbox/steps" "$TMP/steps.good"
printf 'broken inputs=src/ no-separator\n' >>"$CO/.devbox/steps"
verify --target lan1
assert_eq "2" "$rc" "D2: a broken line exits 2"
assert_ok "D2: by its line number" contains "devbox verify: .devbox/steps line 5: " "$out"
assert_eq "" "$(cat "$SSH_LOG")" "D2: before any target is asked"
cp "$TMP/steps.good" "$CO/.devbox/steps"

# ═══ requires=: the tokens of the steps that run join DEVBOX_REQUIRES ════════
# (learned-selection spec, section 4.2)
sed -i 's|^test       after=lint |test       after=lint requires=cmd:fixture-tool |' "$CO/.devbox/steps"
verify --target lan1 --full
assert_ok "requires: a running step's token is asked of the target" grep -q 'check-requires cmd:fixture-tool' "$SSH_LOG"
assert_ok "requires: and named with the image requirements" contains "==> image requirements: cmd:fixture-tool" "$out"
printf 'six\n' >"$CO/types/t.d.ts"
verify --target lan1
assert_eq "typecheck" "$(ran)" "requires: with test carried, typecheck alone runs"
assert_fail "requires: and the carried step's token is not asked" grep -q 'check-requires' "$SSH_LOG"
cp "$TMP/steps.good" "$CO/.devbox/steps"

# ═══ D4 of the prep-throughput spec: a seed never stops a gate ═══════════════
# The verb's place: after ensure-workspace, before the sync's finish.
verb_line() { grep -n " devbox-gate@$A_LAN1 $1 " "$SSH_LOG" | sed -n '1s/:.*//p'; }
verify --target lan1 --full
assert_eq "0" "$rc" "D4: a host that seeds runs the gate"
assert_ok "D4: the answer is one ==> seed: line" grep -qx '==> seed: copied laptop-app-main-7c209c 1024 30' <<<"$out"
assert_ok "D4: the seed carries the slug, the machine id and the project" \
  grep -qE " seed [a-z0-9-]+ [0-9a-f]+ app$" "$SSH_LOG"
assert_ok "D4: it follows ensure-workspace and precedes the sync's finish" \
  test "$(verb_line ensure-workspace)" -lt "$(verb_line seed)" -a "$(verb_line seed)" -lt "$(verb_line sync-finish)"
FAKE_SEED=old verify --target lan1 --full
assert_eq "0" "$rc" "D4: a host without the verb still runs the gate"
assert_ok "D4: with one skipped line naming the target" grep -qx '==> seed: skipped, lan1 predates seed' <<<"$out"
assert_eq "lint test typecheck" "$(sort "$STEP_LOG" | tr '\n' ' ' | sed 's/ $//')" "D4: and every step ran"
assert_fail "D4: the refusal itself stays off the terminal" contains "unknown verb" "$out"
FAKE_SEED=fault verify --target lan1 --full
assert_eq "0" "$rc" "D4: a seed that exits 1 still runs the gate"
assert_ok "D4: read as cold" grep -qx '==> seed: cold, lan1 gave no seed answer (exit 1)' <<<"$out"
assert_ok "D4: with the host's own stderr" contains "devbox verify: seed: devbox-runner seed: docker names no mountpoint" "$out"
assert_eq "lint test typecheck" "$(sort "$STEP_LOG" | tr '\n' ' ' | sed 's/ $//')" "D4: and every step ran"

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
