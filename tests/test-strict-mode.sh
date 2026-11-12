#!/bin/bash
# DEVBOX_STRICT=1: a caller that trusts the exit code and must never get a local gate.
#
# A caller that reads this code as "the remote gate ran" was misled in three
# cases. A missing
# .devbox.env, DEVBOX_ENABLED=0 or DEVBOX_QUEUE_FULL_ACTION=local ran the gate on
# THIS machine and exited with its code, so a laptop result came back as a remote
# one. The file's DEVBOX_HOST replaced the host the caller named. And devbox's own
# codes shared one space with the gate's: a gate that exits 7 and an OOM kill read
# the same. Strict mode closes all three, and every case here runs it both ways,
# because without DEVBOX_STRICT the plain behaviour must not move.
#
# Every case is a target: the fallbacks are a missing .devbox.env, a
# file that names no target, and rule 5 of the target choice. The environment
# wins for each DEVBOX_* key of .devbox.env, and DEVBOX_TARGET_<NAME> among them.
#
# Hermetic. A fake ssh, rsync and curl sit first on PATH and record every argv,
# because half of what this file asserts is that nothing ran.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
# shellcheck source=tests/lib.sh
source ./lib.sh
REPO="$(cd .. && pwd)"
VERIFY="$REPO/client/libexec/devbox-verify"

TMP="$(mktemp -d)" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/home" "$TMP/run"

contains() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }

# Computed from this checkout's library, so the handshake passes on the shipped
# values and a protocol bump for another reason does not fail this file.
FAKE_PROTO="$(sed -n 's/^DEVBOX_PROTOCOL_VERSION=\(.*\)$/\1/p' "$REPO/lib/devbox-lib.sh")"
FAKE_FP="$(sha256sum <"$REPO/lib/devbox-lib.sh" | cut -d' ' -f1)"
SSH_LOG="$TMP/ssh.log"
CURL_LOG="$TMP/curl.log"
PW_LOG="$TMP/pw.log"
OOM_N="$TMP/oom.n"
LOCAL_MARK="$TMP/local-gate-ran"
export FAKE_PROTO FAKE_FP SSH_LOG CURL_LOG PW_LOG OOM_N TMP

# ── the fake gate account ────────────────────────────────────────────────────
#
# It answers every verb of a full run, because the OOM comparison and the pool's
# 75 are read at the END of devbox-verify. The two oom-count reads come from a
# call counter, so one run can hand back a baseline and then a higher reading.
#
# The master open records the password that ssh's askpass hands over, so the
# case about which password wins can read it. It is a fixture value, and this
# file is the only reader of the log.
{
  printf '#!/bin/bash\n'
  cat <<'HEAD'
printf '%s\n' "$*" >>"$SSH_LOG"
case " $* " in *" -f -N "*) "$SSH_ASKPASS" >>"$PW_LOG" 2>/dev/null || true ;; esac
# The run verb's own connection (ControlPath=none) fails as ssh fails, with
# FAKE_RUN_SSH_ERR on stderr and exit 255, while every other call works.
case " $* " in *" ControlPath=none "*)
  if [ -n "${FAKE_RUN_SSH_ERR-}" ]; then printf '%s\n' "$FAKE_RUN_SSH_ERR" >&2; exit 255; fi ;;
esac
HEAD
  gate_stub_prelude
  cat <<'FAKE'
case "$GATE_CMD" in
  version) printf '%s %s\n' "$FAKE_PROTO" "$FAKE_FP"; exit 0 ;;
  "queue-estimate "*) printf '%s\n' "${FAKE_EST-now 0 3 4/32 1/3 0}"; exit 0 ;;
  "oom-count "*)
    n=$(( $(cat "$OOM_N") + 1 ))
    printf '%s' "$n" >"$OOM_N"
    if [ "$n" -eq 1 ]; then printf '%s\n' "${FAKE_OOM_BEFORE-0}"; else printf '%s\n' "${FAKE_OOM_AFTER-0}"; fi
    exit 0 ;;
  "setup "*) cat >/dev/null; exit "${FAKE_SETUP_RC:-0}" ;;
  # The fifth word of `run` is the max wait: a ceiling asks the pool with one,
  # and 0 is the gate with none. FAKE_WATCHDOG is a stop reason, printed as
  # devbox-pool prints it when the watchdog stopped the gate.
  "run "*)
    cat >/dev/null
    [ -z "${FAKE_WATCHDOG-}" ] || echo "devbox-pool: the watchdog stopped this gate: $FAKE_WATCHDOG" >&2
    [ -z "${FAKE_TICKET-}" ] || echo "devbox-pool: lost its queue ticket $FAKE_TICKET" >&2
    read -r _ _ _ _ _ _mw _ <<<"$GATE_CMD"
    case "$_mw" in
      0) exit "${FAKE_GATE_RC:-0}" ;;
      *) exit "${FAKE_ACQ:-0}" ;;
    esac ;;
  "ensure-workspace "*) printf '%s\n' "${FAKE_DSN-postgresql://fixture:fixture@fixture/fixture}"; exit 0 ;;
  "lock "*) printf 'LOCKED\n'; cat >/dev/null; exit 0 ;;
  *) exit 0 ;;
esac
FAKE
} >"$TMP/bin/ssh"
chmod +x "$TMP/bin/ssh"
gate_stub_keyscan "$TMP/bin"

cat >"$TMP/bin/rsync" <<'FAKE'
#!/bin/bash
exit "${FAKE_RSYNC_RC:-0}"
FAKE
chmod +x "$TMP/bin/rsync"

# The RunPod cases must refuse before any provider call. A curl that records its
# argv proves no rental was asked for.
cat >"$TMP/bin/curl" <<'FAKE'
#!/bin/bash
printf '%s\n' "$*" >>"$CURL_LOG"
exit 1
FAKE
chmod +x "$TMP/bin/curl"

# ── the fake checkout ────────────────────────────────────────────────────────
#
# A real repository with no commit: devbox-verify starts with `git rev-parse
# --show-toplevel`, and a `.git` DIRECTORY keeps it out of the linked-worktree
# branch that looks for the main checkout's .devbox.env.
CO="$TMP/checkout"
mkdir -p "$CO/.devbox"
git -C "$CO" init -q >/dev/null 2>&1
: >"$CO/.devbox/exclude"
# The local gate leaves a marker file. Every "nothing ran here" assertion checks
# that this file is absent, which no wording of a message can fake.
write_config() {
  {
    echo "DEVBOX_PROJECT=${1:-strictfix}"
    echo 'DEVBOX_WANT_TOKENS=4'
    echo 'DEVBOX_MIN_TOKENS=1'
    [ -z "${2:-}" ] || printf "DEVBOX_REQUIRES='%s'\n" "$2"
    echo 'DEVBOX_SETUP=:'
    echo "DEVBOX_VERIFY=touch $LOCAL_MARK && exit \${FAKE_LOCAL_RC:-0}"
  } >"$CO/.devbox/config.env"
}
write_config
write_env() { printf '%s\n' "$@" >"$CO/.devbox.env"; }
# The usual file: one deployed target, hostb, at the address hostb.invalid.
TARGET_B=('DEVBOX_TARGETS=hostb' 'DEVBOX_TARGET_HOSTB=hostb.invalid' "DEVBOX_TARGET_HOSTB_HOSTKEY=$GATE_STUB_PIN" 'DEVBOX_GATE_PASSWORD=file-password')

out=""; rc=0; ssh_log=""; curl_log=""; pw_log=""
# Every key a case varies is removed from the inherited environment first, so a
# developer's own shell cannot decide a case. Each case then names the
# environment it means with VAR=value arguments. The unreachable cache lives in
# $TMP/run/devbox and is removed per run: a case that makes a target unreachable
# must not decide the next one.
run_verify() {
  : >"$SSH_LOG"; : >"$CURL_LOG"; : >"$PW_LOG"; printf 0 >"$OOM_N"; rm -f "$LOCAL_MARK"
  rm -rf "$TMP/run/devbox"
  local args=()
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do args+=("$1"); shift; done
  [ "${1:-}" != -- ] || shift
  out="$(cd "$CO" && env -u DEVBOX_STRICT -u DEVBOX_TARGETS -u DEVBOX_TARGET_HOSTA -u DEVBOX_TARGET_HOSTB -u DEVBOX_TARGET_HOSTA_HOSTKEY -u DEVBOX_TARGET_HOSTB_HOSTKEY \
    -u DEVBOX_GATE_PASSWORD -u DEVBOX_RENT -u RUNPOD_KEY -u DEVBOX_MAX_QUEUE_WAIT -u DEVBOX_QUEUE_FULL_ACTION \
    PATH="$TMP/bin:$PATH" HOME="$TMP/home" XDG_RUNTIME_DIR="$TMP/run" DEVBOX_LOCK_WAIT=5 "${args[@]}" \
    bash "$VERIFY" "$@" 2>&1)"
  rc=$?
  ssh_log="$(cat "$SSH_LOG")"
  curl_log="$(cat "$CURL_LOG")"
  pw_log="$(cat "$PW_LOG")"
  return 0
}
local_ran() { [ -e "$LOCAL_MARK" ]; }

# ── 1. no local fallback ─────────────────────────────────────────────────────

rm -f "$CO/.devbox.env"
run_verify DEVBOX_STRICT=1
assert_eq 64 "$rc" "strict, no .devbox.env: exit 64"
assert_ok "the refusal names the missing .devbox.env" contains "no .devbox.env in $CO" "$out"
assert_ok "and says strict mode refused the local run" contains "DEVBOX_STRICT=1" "$out"
assert_fail "the gate did not run on this machine" local_ran
assert_eq "" "$ssh_log" "and nothing reached a host"

run_verify
assert_eq 0 "$rc" "without strict, no .devbox.env still runs the gate locally"
assert_ok "the local gate ran" local_ran

# A file that names no target replaces the removed DEVBOX_ENABLED=0.
write_env 'DEVBOX_MAX_QUEUE_WAIT=60'
run_verify DEVBOX_STRICT=1
assert_eq 64 "$rc" "strict, a .devbox.env that names no target: exit 64"
assert_ok "the refusal names the two keys" contains "sets neither DEVBOX_TARGETS nor DEVBOX_RENT" "$out"
assert_fail "the gate did not run on this machine" local_ran
run_verify
assert_eq 0 "$rc" "without strict, a file that names no target runs the gate locally"
assert_ok "the local gate ran" local_ran

# The removed switch is refused by name in both modes, and it is a config refusal,
# never a fallback: nothing runs.
write_env 'DEVBOX_ENABLED=0' 'DEVBOX_HOST=hostb.invalid'
run_verify DEVBOX_STRICT=1
assert_eq 66 "$rc" "strict, an older DEVBOX_ENABLED line: exit 66, a refused config"
assert_ok "the refusal names the removed key" contains "DEVBOX_ENABLED is no longer read" "$out"
assert_fail "the gate did not run on this machine" local_ran
run_verify
assert_eq 2 "$rc" "without strict, the same refusal exits 2"
assert_fail "and the gate did not run here either" local_ran

# Rule 5 of the target choice, with nothing that refuses the fallback: no
# DEVBOX_REQUIRES and no DEVBOX_NEEDS_POSTGRES. Without strict the gate runs here.
write_env "${TARGET_B[@]}" 'DEVBOX_MAX_QUEUE_WAIT=60' 'DEVBOX_QUEUE_FULL_ACTION=local'
run_verify DEVBOX_STRICT=1 FAKE_EST='wait 900 3 4/4 1/2 2'
assert_eq 64 "$rc" "strict, every target over the ceiling with DEVBOX_QUEUE_FULL_ACTION=local: exit 64"
assert_ok "the refusal names the queue action" contains "DEVBOX_QUEUE_FULL_ACTION=local" "$out"
assert_fail "the gate did not run on this machine" local_ran
assert_fail "and no grant was asked for on the target" contains "devbox-gate@hostb.invalid run " "$ssh_log"
run_verify FAKE_EST='wait 900 3 4/4 1/2 2'
assert_eq 0 "$rc" "without strict, the same queue runs the gate locally"
assert_ok "the local gate ran" local_ran

# The same full queue, but this machine cannot run the gate, so the fallback is
# refused and the run keeps waiting on the target. Strict mode keeps that: no
# run_local call is reached, so there is nothing to refuse. The second,
# ceiling-free wait completes, and the queue event is named on stderr while the
# code stays the gate's.
write_config strictfix devbox-test-tool-nobody-installs-hgq7
run_verify DEVBOX_STRICT=1 FAKE_EST='wait 900 3 4/4 1/2 2' FAKE_ACQ=75 FAKE_GATE_RC=0
assert_eq 0 "$rc" "strict, a refused fallback waits on the target and keeps the gate's code"
assert_ok "stderr names the queue event" contains "::devbox-infra::queue" "$out"
assert_fail "the gate did not run on this machine" local_ran
run_verify FAKE_EST='wait 900 3 4/4 1/2 2' FAKE_ACQ=75 FAKE_GATE_RC=0
assert_eq 0 "$rc" "without strict, the same run exits 0"
assert_fail "and prints no infra line" contains "::devbox-infra::" "$out"
write_config

# --local is a person's choice, not a fallback, and its code is the gate's own.
write_env "${TARGET_B[@]}"
run_verify DEVBOX_STRICT=1 -- --local
assert_eq 0 "$rc" "strict --local runs the local gate"
assert_ok "the local gate ran" local_ran
assert_eq "" "$ssh_log" "and nothing reached a host"
run_verify DEVBOX_STRICT=1 FAKE_LOCAL_RC=3 -- --local
assert_eq 3 "$rc" "strict --local passes the local gate's own 3 through, unmapped"

# ── 2. the environment wins over .devbox.env ─────────────────────────────────

write_env "${TARGET_B[@]}"
run_verify DEVBOX_STRICT=1 DEVBOX_TARGET_HOSTB=hosta.invalid
assert_eq 0 "$rc" "strict, a full run on the environment's address for hostb exits 0"
assert_ok "the gate verbs went to the environment's address" contains "devbox-gate@hosta.invalid run " "$ssh_log"
assert_fail "and never to the file's address" contains "hostb.invalid" "$ssh_log"
run_verify DEVBOX_TARGET_HOSTB=hosta.invalid
assert_ok "without strict, the gate verbs went to the file's address" contains "devbox-gate@hostb.invalid run " "$ssh_log"
assert_fail "and not to the environment's" contains "hosta.invalid" "$ssh_log"

# A target list the environment names replaces the file's list. The file's
# address for a target the call does not use is not refused as unlisted.
run_verify DEVBOX_STRICT=1 DEVBOX_TARGETS=hosta DEVBOX_TARGET_HOSTA=hosta.invalid "DEVBOX_TARGET_HOSTA_HOSTKEY=$GATE_STUB_PIN"
assert_eq 0 "$rc" "strict, the environment's target list and address: exit 0"
assert_ok "the run chose the environment's target" contains "==> devbox: running on hosta" "$out"
assert_fail "and never asked the file's target" contains "hostb.invalid" "$ssh_log"

# A key that only the file sets still comes from the file.
run_verify DEVBOX_STRICT=1
assert_ok "strict, an address set only in the file comes from the file" contains "devbox-gate@hostb.invalid run " "$ssh_log"

# The gate password is a DEVBOX_* key too. It reaches ssh only through askpass.
run_verify DEVBOX_STRICT=1 DEVBOX_GATE_PASSWORD=env-password
assert_ok "strict, the environment's gate password reached ssh" contains "env-password" "$pw_log"
assert_fail "and the file's did not" contains "file-password" "$pw_log"
run_verify DEVBOX_GATE_PASSWORD=env-password
assert_ok "without strict, the file's gate password reached ssh" contains "file-password" "$pw_log"
assert_fail "and the environment's did not" contains "env-password" "$pw_log"
assert_fail "neither password value reaches the output" contains "-password" "$out"

# RUNPOD_KEY comes only from the file, in both modes, and is never restored.
write_env "${TARGET_B[@]}"
run_verify DEVBOX_STRICT=1 RUNPOD_KEY=fixture-env-key -- --target runpod
assert_eq 66 "$rc" "strict, RUNPOD_KEY only in the environment: exit 66"
assert_ok "the refusal names the missing key" contains "RUNPOD_KEY is missing" "$out"
assert_eq "" "$curl_log" "no provider call was made"
assert_eq "" "$ssh_log" "and nothing reached a host"
assert_fail "the gate did not run on this machine" local_ran
assert_fail "the key value never reaches the output" contains "fixture-env-key" "$out"
run_verify RUNPOD_KEY=fixture-env-key -- --target runpod
assert_eq 2 "$rc" "without strict, the same refusal exits 2"

# ── 3. devbox's own codes move to 64 to 79 ───────────────────────────────────

write_env "${TARGET_B[@]}"
run_verify DEVBOX_STRICT=1 FAKE_UNREACHABLE=hostb.invalid
assert_eq 67 "$rc" "strict, every target unreachable: exit 67"
run_verify FAKE_UNREACHABLE=hostb.invalid
assert_eq 3 "$rc" "without strict, every target unreachable: exit 3"

# A refused gate password is a repair for a person and not a wait, so strict
# mode gives it a code of its own. Without strict it shares 3 with the above.
run_verify DEVBOX_STRICT=1 FAKE_OPEN_RC=255 FAKE_OPEN_ERR='devbox-gate@hostb.invalid: Permission denied (password).'
assert_eq 75 "$rc" "strict, the gate password refused by every target: exit 75"
assert_ok "the refusal names the password" contains "the gate password was refused by hostb" "$out"
assert_fail "and nothing past the probe was asked" contains "ensure-workspace" "$ssh_log"
run_verify FAKE_OPEN_RC=255 FAKE_OPEN_ERR='devbox-gate@hostb.invalid: Permission denied (password).'
assert_eq 3 "$rc" "without strict, the refused password exits 3"

write_config '..'
run_verify DEVBOX_STRICT=1
assert_eq 66 "$rc" "strict, a refused DEVBOX_PROJECT: exit 66"
assert_fail "and it is not called a dead step" contains "a step before the gate stopped" "$out"
run_verify
assert_eq 2 "$rc" "without strict, the same refusal exits 2"
write_config

# devbox_config_load refuses an unknown key with `return 2`, which ends the run
# through set -e. That 2 is devbox's own config code, not a dead step.
echo 'DEVBOX_NOT_A_KEY=1' >>"$CO/.devbox/config.env"
run_verify DEVBOX_STRICT=1
assert_eq 66 "$rc" "strict, an unknown key in config.env: exit 66"
run_verify
assert_eq 2 "$rc" "without strict, the same refusal exits 2"
write_config

# A DEVBOX_FORWARD_ENV that names a .devbox.env key is refused by
# devbox_forward_name, which leaves through the library's guard exit.
echo 'DEVBOX_FORWARD_ENV=DEVBOX_GATE_PASSWORD' >>"$CO/.devbox/config.env"
run_verify DEVBOX_STRICT=1
assert_eq 66 "$rc" "strict, DEVBOX_FORWARD_ENV naming the gate password: exit 66"
assert_fail "and no gate ran" contains "devbox-gate@hostb.invalid run " "$ssh_log"
run_verify
assert_eq 2 "$rc" "without strict, the same refusal exits 2"
write_config

run_verify DEVBOX_STRICT=1 FAKE_DSN=garbage
assert_eq 65 "$rc" "strict, ensure-workspace returns no DSN: exit 65"
run_verify FAKE_DSN=garbage
assert_eq 1 "$rc" "without strict, the same failure exits 1"

# A step that dies under set -e with a code of its own (rsync's 23 here) is
# devbox's failure, not the gate's, so strict mode reports it as 65.
run_verify DEVBOX_STRICT=1 FAKE_RSYNC_RC=23
assert_eq 65 "$rc" "strict, a sync that fails with 23 before the gate: exit 65"
assert_fail "and no grant was asked for" contains "devbox-gate@hostb.invalid run " "$ssh_log"
run_verify FAKE_RSYNC_RC=23
assert_eq 23 "$rc" "without strict, the sync's own 23 passes through"

# The same rule for a step whose own code collides with a plain code. rsync
# exits 1 to 6 for its own reasons, and DEVBOX_SETUP exits with the project's
# code. A reviewer probe read rsync's 5 as 69 (handshake) and its 7
# as 71 with a false ::devbox-infra::oom. Only an exit devbox chose is mapped.
for step in "FAKE_RSYNC_RC=5:the sync" "FAKE_RSYNC_RC=7:the sync" "FAKE_SETUP_RC=7:DEVBOX_SETUP"; do
  setting="${step%%:*}"; name="${step#*:}"; code="${setting#*=}"
  run_verify DEVBOX_STRICT=1 "$setting"
  assert_eq 65 "$rc" "strict, $name exits $code before the gate: exit 65"
  assert_fail "and prints no infra line" contains "::devbox-infra::" "$out"
  assert_fail "and asks for no grant" contains "devbox-gate@hostb.invalid run " "$ssh_log"
  run_verify "$setting"
  assert_eq "$code" "$rc" "without strict, $name's own $code passes through"
done

# Exit 8 is "no target can take this gate". The queue line comes with it only
# when the queue is the cause.
write_env "${TARGET_B[@]}" 'DEVBOX_MAX_QUEUE_WAIT=60'
run_verify DEVBOX_STRICT=1 FAKE_EST='wait 900 3 4/4 1/2 2'
assert_eq 72 "$rc" "strict, every target over the ceiling with action fail: exit 72"
assert_ok "stderr names the queue event" contains "::devbox-infra::queue" "$out"
run_verify FAKE_EST='wait 900 3 4/4 1/2 2'
assert_eq 8 "$rc" "without strict, the same queue exits 8"

write_env "${TARGET_B[@]}"
run_verify DEVBOX_STRICT=1 FAKE_EST='never - 0 0/2 0/3 0'
assert_eq 72 "$rc" "strict, a pool that can never grant on every target: exit 72"
assert_ok "stderr names the queue event" contains "::devbox-infra::queue" "$out"

run_verify DEVBOX_STRICT=1 FAKE_HEALTH="$(date +%s) degraded disk 93%"
assert_eq 72 "$rc" "strict, every target degraded: exit 72"
assert_ok "the refusal names the target and its health" contains "hostb skipped: degraded (disk 93%)" "$out"
assert_fail "and it is not called a queue event" contains "::devbox-infra::queue" "$out"
run_verify FAKE_HEALTH="$(date +%s) degraded disk 93%"
assert_eq 8 "$rc" "without strict, every target degraded exits 8"

# The ceiling a run asked for runs out at the acquire, after the probe said it fits.
write_env "${TARGET_B[@]}" 'DEVBOX_MAX_QUEUE_WAIT=60'
run_verify DEVBOX_STRICT=1 FAKE_ACQ=75
assert_eq 72 "$rc" "strict, the acquire's ceiling runs out with action fail: exit 72"
assert_ok "stderr names the queue event" contains "::devbox-infra::queue" "$out"
run_verify FAKE_ACQ=75
assert_eq 8 "$rc" "without strict, the same ceiling exits 8"

write_env "${TARGET_B[@]}"
run_verify DEVBOX_STRICT=1 FAKE_GATE_RC=75
assert_eq 74 "$rc" "strict, the pool gives up with 75 and no ceiling: exit 74"
assert_ok "stderr names the pool deadline" contains "::devbox-infra::pool-deadline" "$out"
run_verify FAKE_GATE_RC=75
assert_eq 75 "$rc" "without strict, the pool's 75 passes through"

# The watchdog's stop is exit 10, and 76 in strict mode. The gate did not run to
# its end, so the code is devbox's report, as an OOM kill's is.
run_verify DEVBOX_STRICT=1 FAKE_GATE_RC=79 FAKE_WATCHDOG='past DEVBOX_GATE_MAX_SECONDS of 3600s'
assert_eq 76 "$rc" "strict, the watchdog stopped the gate: exit 76"
assert_ok "stderr names the watchdog event" contains "::devbox-infra::watchdog" "$out"
assert_ok "and the reason" contains "past DEVBOX_GATE_MAX_SECONDS of 3600s" "$out"
run_verify FAKE_GATE_RC=79 FAKE_WATCHDOG='past DEVBOX_GATE_MAX_SECONDS of 3600s'
assert_eq 10 "$rc" "without strict, the watchdog's stop exits 10"
assert_fail "and prints no infra line" contains "::devbox-infra::" "$out"
# A gate that exits 79 of its own prints no watchdog line, and keeps its code.
run_verify DEVBOX_STRICT=1 FAKE_GATE_RC=79
assert_eq 79 "$rc" "strict, a gate's own 79 with no watchdog line: exit 79, the gate's own"
assert_fail "and prints no infra line" contains "::devbox-infra::" "$out"

# The pool lost the gate's queue ticket and could not restore it: exit 11, and
# 77 in strict mode. The gate never ran.
LOST='1000.4242 after 30s of waiting for 4 tokens (min 1) and cannot restore it in /run/devbox-pool/queue'
run_verify DEVBOX_STRICT=1 FAKE_GATE_RC=78 FAKE_TICKET="$LOST"
assert_eq 77 "$rc" "strict, the pool lost the queue ticket: exit 77"
assert_ok "stderr names the pool-ticket event" contains "::devbox-infra::pool-ticket" "$out"
assert_ok "and the client names the event and says the gate did not run" \
  contains "lost this gate's queue ticket and could not restore it, so the gate did not run" "$out"
run_verify FAKE_GATE_RC=78 FAKE_TICKET="$LOST"
assert_eq 11 "$rc" "without strict, the lost ticket exits 11"
assert_fail "and prints no infra line" contains "::devbox-infra::" "$out"
run_verify FAKE_GATE_RC=78
assert_eq 78 "$rc" "without strict, a gate's own 78 with no ticket line keeps its code"
assert_fail "and is never called a lost ticket" contains "lost this gate's queue ticket" "$out"
run_verify DEVBOX_STRICT=1 FAKE_GATE_RC=78
assert_eq 78 "$rc" "strict, a gate's own 78 with no ticket line: exit 78, the gate's own"

# The run verb opens its own connection with a fresh password login, after the
# probe, the lock, the sync and the setup. A refusal there is ssh's 255, and it
# passed through as the gate's own status: 255 unmapped under strict mode,
# where a refused gate password is 75.
run_verify DEVBOX_STRICT=1 FAKE_RUN_SSH_ERR='devbox-gate@hostb.invalid: Permission denied (password).'
assert_eq 75 "$rc" "strict, the gate password refused at the run step: exit 75"
assert_ok "and the run says the gate did not run" contains "refused by hostb at the run step; the gate did not run" "$out"
assert_fail "and prints no infra line" contains "::devbox-infra::" "$out"
run_verify FAKE_RUN_SSH_ERR='devbox-gate@hostb.invalid: Permission denied (password).'
assert_eq 3 "$rc" "without strict, the same refusal exits 3"
run_verify DEVBOX_STRICT=1 FAKE_RUN_SSH_ERR='ssh: connect to host hostb.invalid port 22: Connection refused'
assert_eq 67 "$rc" "strict, the run step cannot connect: exit 67, a target that did not answer"
assert_fail "and prints no infra line" contains "::devbox-infra::" "$out"
run_verify FAKE_RUN_SSH_ERR='ssh: connect to host hostb.invalid port 22: Connection refused'
assert_eq 3 "$rc" "without strict, exit 3"
# A gate that exits 255 of its own prints no ssh line, and keeps its code.
run_verify DEVBOX_STRICT=1 FAKE_GATE_RC=255
assert_eq 255 "$rc" "strict, a gate's own 255 with no ssh line: exit 255, the gate's own"

# The wall-clock limit is refused by the library's guard, which marks its exit.
echo 'DEVBOX_GATE_MAX_SECONDS=99999' >>"$CO/.devbox/config.env"
run_verify DEVBOX_STRICT=1
assert_eq 66 "$rc" "strict, a DEVBOX_GATE_MAX_SECONDS over the ceiling: exit 66"
run_verify
assert_eq 2 "$rc" "without strict, the same refusal exits 2"
write_config

# ── 4. the gate's code is never replaced while the gate runs to its end ──────

run_verify DEVBOX_STRICT=1 FAKE_GATE_RC=1
assert_eq 1 "$rc" "strict, a gate that exits 1: devbox exits 1"
assert_fail "and prints no infra line" contains "::devbox-infra::" "$out"

run_verify DEVBOX_STRICT=1 FAKE_GATE_RC=7
assert_eq 7 "$rc" "strict, a gate that exits 7 with no OOM kill: devbox exits 7"

run_verify DEVBOX_STRICT=1 FAKE_GATE_RC=66
assert_eq 66 "$rc" "strict, a gate that exits 66: devbox exits 66, the gate's own"

run_verify DEVBOX_STRICT=1 FAKE_GATE_RC=0 FAKE_OOM_BEFORE=2 FAKE_OOM_AFTER=3
assert_eq 0 "$rc" "strict, a gate that exits 0 while the OOM count rose: exit 0"
assert_ok "stderr has ::devbox-infra::oom" contains "::devbox-infra::oom" "$out"
run_verify FAKE_GATE_RC=0 FAKE_OOM_BEFORE=2 FAKE_OOM_AFTER=3
assert_eq 0 "$rc" "without strict, the same run exits 0"
assert_fail "and reads no OOM counter after a green gate" contains "::devbox-infra::" "$out"

run_verify DEVBOX_STRICT=1 FAKE_GATE_RC=1 FAKE_OOM_BEFORE=2 FAKE_OOM_AFTER=3
assert_eq 1 "$rc" "strict, a gate that ran to its end with 1 while the OOM count rose: exit 1"
assert_ok "stderr has ::devbox-infra::oom" contains "::devbox-infra::oom" "$out"
run_verify FAKE_GATE_RC=1 FAKE_OOM_BEFORE=2 FAKE_OOM_AFTER=3
assert_eq 7 "$rc" "without strict, the same run exits 7"

# 137 is 128 + SIGKILL: the gate was killed and did not run to its end, so
# there is no gate code to keep and the kill is devbox's report.
run_verify DEVBOX_STRICT=1 FAKE_GATE_RC=137 FAKE_OOM_BEFORE=2 FAKE_OOM_AFTER=3
assert_eq 71 "$rc" "strict, a gate killed with 137 while the OOM count rose: exit 71"
assert_ok "stderr has ::devbox-infra::oom" contains "::devbox-infra::oom" "$out"

# ── the RunPod target's refusals, end to end ─────────────────────────────────
#
# runpod_main is the last line of a sourced file, so a refusal's `return N`
# ends devbox-verify through set -e, inside the source. devbox-verify's
# devbox_die after the source never runs, so each refusal must mark itself.
# A review probe found DEVBOX_RUNPOD_CPUS=3 giving 65, not 66.
# These run the real client up to the refusal; the fake curl proves no rental.
for tool in jq ssh-keygen flock; do
  assert_ok "$tool is installed for the RunPod refusal cases" command -v "$tool"
done
RP_LOCK_DIR="$CO/.git/devbox-runpod"
write_env 'RUNPOD_KEY=fixture-file-key' 'DEVBOX_RUNPOD_IMAGE=fixture/image:1' 'DEVBOX_RUNPOD_CPUS=3'
run_verify DEVBOX_STRICT=1 -- --target runpod
assert_eq 66 "$rc" "strict, --target runpod with DEVBOX_RUNPOD_CPUS=3: exit 66"
assert_ok "the refusal names the CPU counts" contains "use 4, 8, 16 or 32 CPUs" "$out"
assert_fail "and it is not called a dead step" contains "a step before the gate stopped" "$out"
assert_eq "" "$curl_log" "and no provider call was made"
run_verify -- --target runpod
assert_eq 2 "$rc" "without strict, the same refusal exits 2"

# Rule 4 rents after the probe, so the probe's EXIT trap is swapped for the
# strict map alone before devbox-runpod arms its own. The same refusal must
# still read 66 on that path.
write_env "${TARGET_B[@]}" 'DEVBOX_RENT=runpod' 'RUNPOD_KEY=fixture-file-key' \
  'DEVBOX_RUNPOD_IMAGE=fixture/image:1' 'DEVBOX_RUNPOD_CPUS=3'
run_verify DEVBOX_STRICT=1 FAKE_UNREACHABLE=hostb.invalid
assert_eq 66 "$rc" "strict, a rented target refused after the probe: exit 66"
assert_ok "the run went to the rented target" contains "renting runpod" "$out"
assert_eq "" "$curl_log" "and no provider call was made"
run_verify FAKE_UNREACHABLE=hostb.invalid
assert_eq 2 "$rc" "without strict, the same refusal exits 2"

write_env 'RUNPOD_KEY=fixture-file-key' 'DEVBOX_RUNPOD_IMAGE=fixture/image:1'
mkdir -p "$RP_LOCK_DIR"
exec 7>"$RP_LOCK_DIR/run.lock"
assert_ok "the test holds this checkout's RunPod run lock" flock -n 7
run_verify DEVBOX_STRICT=1 -- --target runpod
assert_eq 68 "$rc" "strict, --target runpod with the run lock held: exit 68"
assert_ok "the refusal names the other run" contains "another run owns this checkout" "$out"
assert_fail "and it is not called a dead step" contains "a step before the gate stopped" "$out"
assert_eq "" "$curl_log" "and no provider call was made"
run_verify -- --target runpod
assert_eq 4 "$rc" "without strict, the same refusal exits 4"
exec 7>&-
assert_fail "the RunPod key value never reaches the output" contains "fixture-file-key" "$out"

# runpod_finish replaces devbox-verify's EXIT trap, so it applies the map
# itself. A dead step and a gate's code cannot be reached end to end without a
# provider, so runpod_finish is extracted and RUN with the shipped map. Nothing
# here marks an exit as devbox's own: OWN_EXIT stays 0.
sed '$d' "$REPO/client/libexec/devbox-runpod" >"$TMP/provider.sh"
awk '/^devbox_exit_code\(\) \{/,/^\}/' "$VERIFY" >"$TMP/exit-map.sh"
assert_ok "devbox_exit_code was found in the shipped client" test -s "$TMP/exit-map.sh"
# Arguments: STRICT, GATE_OWNS_EXIT, then the status the trap sees.
finish_rc() {
  local rc=0
  bash -c 'source "$1"; source "$2"; mkdir -p "$3"; RP_STATE="$3"; RP_CLEANUP=0
    STRICT="$4"; GATE_OWNS_EXIT="$5"; OWN_EXIT=0; EXIT_KIND=""; (exit "$6"); runpod_finish' \
    _ "$TMP/provider.sh" "$TMP/exit-map.sh" "$TMP/rp" "$@" 2>/dev/null || rc=$?
  printf '%s' "$rc"
}
assert_eq 65 "$(finish_rc 1 0 5)" "strict, a RunPod step that dies with 5 before the gate: exit 65"
assert_eq 2 "$(finish_rc 1 1 2)" "strict, a RunPod gate that exits 2: exit 2"
assert_eq 5 "$(finish_rc 0 0 5)" "without strict, a RunPod step's own 5 passes through"

# ── a checkout that carries only an older profile ────────────────────────────
#
# An older client sourced a legacy .devbox/profile.sh, which was PROJECT code, and
# strict mode had to clear its mark around it so a profile that died with 7 did
# not read as an OOM kill. This client reads no profile: the checkout is refused by name
# as a config, and the profile never runs.
write_env "${TARGET_B[@]}"
mv "$CO/.devbox/config.env" "$CO/.devbox/config.env.away"
printf '%s\n' "touch $TMP/profile-ran" '(exit 7)' >"$CO/.devbox/profile.sh"
run_verify DEVBOX_STRICT=1
assert_eq 66 "$rc" "strict, a checkout with only an older profile: exit 66"
assert_ok "the refusal names the profile" contains ".devbox/profile.sh is an older format" "$out"
assert_fail "and prints no infra line" contains "::devbox-infra::" "$out"
assert_fail "and the profile never ran" test -e "$TMP/profile-ran"
run_verify
assert_eq 2 "$rc" "without strict, the same refusal exits 2"
rm -f "$CO/.devbox/profile.sh"
mv "$CO/.devbox/config.env.away" "$CO/.devbox/config.env"

printf '%d %d\n' "$TESTS_RUN" "$TESTS_FAILED"
