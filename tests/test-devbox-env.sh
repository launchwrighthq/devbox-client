#!/bin/bash
# .devbox.env is read as data, with the parser .devbox/config.env uses
# and a key list of its own. An older client sourced it, so a gate password that
# held `$`, a quote or a backtick broke the run or ran as code on the laptop.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
# shellcheck source=tests/lib.sh
source ./lib.sh
REPO="$(cd .. && pwd)"
# shellcheck source=client/libexec/devbox-config
source "$REPO/client/libexec/devbox-config"

TMP="$(mktemp -d)" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
contains() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }

# Each case loads in a subshell, so no value leaks into the next one. Prints the
# deployed targets, the rented ones and the password, joined by bars.
load() {  # $1 is the file content
  printf '%s\n' "$1" >"$TMP/.devbox.env"
  (
    devbox_env_load "$TMP/.devbox.env" || exit
    printf '%s|%s|%s' "${DEVBOX_DEPLOYED[*]}" "${DEVBOX_RENTED[*]}" "${DEVBOX_GATE_PASSWORD:-}"
  )
}
err=""; rc=0
load_err() { rc=0; err="$(load "$1" 2>&1 >/dev/null)" || rc=$?; }

# The pin line of lan1, appended to a file whose case is about another key.
PIN1=$'\nDEVBOX_TARGET_LAN1_HOSTKEY='"$GATE_STUB_PIN"
TWO='DEVBOX_TARGETS=lan1,cloud1
DEVBOX_TARGET_LAN1=lan1.invalid
DEVBOX_TARGET_CLOUD1=cloud1.invalid:2222
DEVBOX_GATE_PASSWORD=pw'"$PIN1"$'\nDEVBOX_TARGET_CLOUD1_HOSTKEY='"$GATE_STUB_OTHER_PIN"

# ── what a file says ─────────────────────────────────────────────────────────
assert_eq "lan1 cloud1||pw" "$(load "$TWO")" "two targets are read in DEVBOX_TARGETS order"
assert_eq "lan1 cloud1|runpod|pw" "$(load "$TWO"$'\nDEVBOX_RENT=runpod\nRUNPOD_KEY=k')" \
  "a rented target is read from DEVBOX_RENT"
assert_eq "||" "$(load '# nothing here')" "a file with neither DEVBOX_TARGETS nor DEVBOX_RENT names no target"
assert_eq "|runpod|" "$(load $'DEVBOX_RENT=runpod\nRUNPOD_KEY=k')" "a file may rent and deploy nothing"
assert_eq "lan1 cloud1||pw" "$(load "$TWO"$'\nDEVBOX_MAX_QUEUE_WAIT=600\nDEVBOX_QUEUE_FULL_ACTION=fail\nDEVBOX_RUNPOD_CPUS=8\nDEVBOX_RUNPOD_IDLE_SECONDS=600\nDEVBOX_RUNPOD_MAX_HOURLY=1\nDEVBOX_RUNPOD_REGIONS=XX-FIXTURE\nDEVBOX_RUNPOD_IMAGE=fixture/image:1\nHCLOUD_TOKEN=t')" \
  "every queue and rental key the client reads is accepted"

# The password is DATA. Each of these characters broke a sourced file or ran.
# shellcheck disable=SC2016  # the dollar and backquote are data under test
pw='a$HOME`id`"q'"'"'z;b'
assert_eq "lan1||$pw" "$(load $'DEVBOX_TARGETS=lan1\nDEVBOX_TARGET_LAN1=lan1.invalid'"$PIN1"$'\nDEVBOX_GATE_PASSWORD='"$pw")" \
  "a password with \$, a backquote, quotes and a semicolon is read verbatim"
assert_eq "lan1||p w" "$(load $'DEVBOX_TARGETS=lan1\nDEVBOX_TARGET_LAN1=lan1.invalid\nDEVBOX_GATE_PASSWORD="p w"'"$PIN1")" \
  "one pair of quotes is stripped, as in config.env"

# Read, never exported: the password reaches ssh through devbox-transport alone.
out="$(printf '%s\n' "$TWO" >"$TMP/.devbox.env"; devbox_env_load "$TMP/.devbox.env"; bash -c 'printf %s "${DEVBOX_GATE_PASSWORD-unset}"')"
assert_eq "unset" "$out" "the gate password is not exported to a child"

# A value an earlier shell exported does not stand in for a missing line.
out="$(export RUNPOD_KEY=from-a-shell DEVBOX_TARGET_OLD=old.invalid; printf '# none\n' >"$TMP/.devbox.env"; devbox_env_load "$TMP/.devbox.env"; printf '%s|%s' "${RUNPOD_KEY-unset}" "${DEVBOX_TARGET_OLD-unset}")"
assert_eq "unset|unset" "$out" "an exported RUNPOD_KEY or DEVBOX_TARGET_<NAME> is cleared before the file is read"

# ── removed keys, refused with their replacement ─────────────────────────────
load_err $'DEVBOX_HOST=cloud1.invalid\nDEVBOX_GATE_PASSWORD=x'
assert_eq "2" "$rc" "DEVBOX_HOST is refused"
assert_ok "and the refusal names DEVBOX_TARGETS and DEVBOX_TARGET_<NAME>" \
  contains "DEVBOX_HOST is no longer read. Name each host in DEVBOX_TARGETS, and give each its address in DEVBOX_TARGET_<NAME>" "$err"
load_err 'DEVBOX_ENABLED=1'
assert_eq "2" "$rc" "DEVBOX_ENABLED is refused"
assert_ok "and the refusal says what switches a file on" contains "A file that sets DEVBOX_TARGETS or DEVBOX_RENT is on" "$err"
load_err 'DEVBOX_BACKEND=runpod'
assert_eq "2" "$rc" "DEVBOX_BACKEND is refused"
assert_ok "and the refusal names DEVBOX_RENT and --target runpod" contains "DEVBOX_RENT=runpod" "$err"
assert_ok "and --target runpod" contains "--target runpod" "$err"
load_err 'DEVBOX_RUNPOD_SECONDS=60'
assert_eq "2" "$rc" "DEVBOX_RUNPOD_SECONDS is refused"
assert_ok "and the refusal names its replacement" contains "Write DEVBOX_RUNPOD_IDLE_SECONDS" "$err"
load_err 'DEVBOX_WHATEVER=1'
assert_ok "an unknown key is refused by name" contains ".devbox.env:1: unknown key DEVBOX_WHATEVER" "$err"
# shellcheck disable=SC2016  # the dollar is data under test
load_err 'export DEVBOX_TARGETS=$X'
assert_ok "a shell statement is refused" contains "is not KEY=value" "$err"

# ── targets and their addresses agree ────────────────────────────────────────
load_err $'DEVBOX_TARGETS=lan1,cloud1\nDEVBOX_TARGET_LAN1=lan1.invalid\nDEVBOX_GATE_PASSWORD=x'"$PIN1"
assert_eq "2" "$rc" "a listed target with no DEVBOX_TARGET_<NAME> is refused"
assert_ok "and the refusal names the missing key" contains "lists cloud1, and the file sets no DEVBOX_TARGET_CLOUD1" "$err"
load_err $'DEVBOX_TARGETS=lan1\nDEVBOX_TARGET_LAN1=lan1.invalid\nDEVBOX_TARGET_SPARE=spare.invalid\nDEVBOX_GATE_PASSWORD=x'"$PIN1"
assert_eq "2" "$rc" "a DEVBOX_TARGET_<NAME> that DEVBOX_TARGETS does not list is refused"
assert_ok "and the refusal names it" contains "sets DEVBOX_TARGET_SPARE, and DEVBOX_TARGETS does not list spare" "$err"
load_err $'DEVBOX_TARGET_LAN1=lan1.invalid'
assert_eq "2" "$rc" "a DEVBOX_TARGET_<NAME> with no DEVBOX_TARGETS at all is refused"
for bad in 'Lan1' 'lan-1' 'lan1, cloud1' 'lan1,,cloud1'; do
  load_err "DEVBOX_TARGETS=$bad"$'\nDEVBOX_TARGET_LAN1=lan1.invalid\nDEVBOX_GATE_PASSWORD=x'
  assert_eq "2" "$rc" "the target list '$bad' is refused"
done
load_err $'DEVBOX_TARGETS=lan1,lan1\nDEVBOX_TARGET_LAN1=lan1.invalid\nDEVBOX_GATE_PASSWORD=x'"$PIN1"
assert_ok "a target listed twice is refused" contains "names lan1 twice" "$err"
for reserved in runpod hetzner local; do
  load_err "DEVBOX_TARGETS=$reserved"$'\nDEVBOX_TARGET_'"${reserved^^}"$'=lan1.invalid\nDEVBOX_GATE_PASSWORD=x'
  assert_eq "2" "$rc" "a deployed target named $reserved is refused, because --target $reserved means another place"
done
load_err $'DEVBOX_TARGETS=lan1\nDEVBOX_TARGET_LAN1=lan1.invalid'"$PIN1"
assert_eq "2" "$rc" "deployed targets with no DEVBOX_GATE_PASSWORD are refused"
assert_ok "and the refusal names the key" contains "sets no DEVBOX_GATE_PASSWORD" "$err"
out="$(export DEVBOX_GATE_PASSWORD=from-a-shell; load $'DEVBOX_TARGETS=lan1\nDEVBOX_TARGET_LAN1=lan1.invalid'"$PIN1" 2>/dev/null)"; rc=$?
assert_eq "2" "$rc" "an exported gate password does not stand in for the file's"

# ── the host key pin of each target ──────────────────────────────────────────
#
# The client probes every target on its own, often from an unattended agent. The
# first build recorded whatever key answered first, so a man in the middle on
# that one contact received the gate password, which opens every target. Each
# listed target now names its key, and a file that does not is refused before
# anything is sent.
load_err $'DEVBOX_TARGETS=lan1\nDEVBOX_TARGET_LAN1=lan1.invalid\nDEVBOX_GATE_PASSWORD=x'
assert_eq "2" "$rc" "a listed target with no DEVBOX_TARGET_<NAME>_HOSTKEY is refused"
assert_ok "and the refusal names the key" contains "lists lan1, and the file sets no DEVBOX_TARGET_LAN1_HOSTKEY" "$err"
assert_ok "and says to copy the line the deploy prints" contains "Copy the DEVBOX_TARGET_LAN1_HOSTKEY line that the operator's deploy prints for lan1" "$err"
for bad in "${GATE_STUB_PIN#SHA256:}" 'SHA256:short' "MD5:${GATE_STUB_PIN#SHA256:}" "${GATE_STUB_PIN}=" \
           "256 $GATE_STUB_PIN lan1 (ED25519)" "${GATE_STUB_PIN:0:20}-${GATE_STUB_PIN:21}" ''; do
  load_err $'DEVBOX_TARGETS=lan1\nDEVBOX_TARGET_LAN1=lan1.invalid\nDEVBOX_GATE_PASSWORD=x\nDEVBOX_TARGET_LAN1_HOSTKEY='"$bad"
  assert_eq "2" "$rc" "the pin '$bad' is refused"
done
assert_ok "and the refusal says what a pin looks like and where it comes from" \
  contains "DEVBOX_TARGET_LAN1_HOSTKEY is '', and a pin is SHA256:<43 characters>, as ssh-keygen -lf prints it. Copy the DEVBOX_TARGET_LAN1_HOSTKEY line that the operator's deploy prints for lan1." "$err"
assert_eq "lan1||x" "$(load $'DEVBOX_TARGETS=lan1\nDEVBOX_TARGET_LAN1=lan1.invalid\nDEVBOX_GATE_PASSWORD=x\nDEVBOX_TARGET_LAN1_HOSTKEY="'"$GATE_STUB_PIN"'"')" \
  "a quoted pin is read like any quoted value"
load_err $'DEVBOX_TARGETS=lan1\nDEVBOX_TARGET_LAN1=lan1.invalid\nDEVBOX_GATE_PASSWORD=x'"$PIN1"$'\nDEVBOX_TARGET_SPARE_HOSTKEY='"$GATE_STUB_PIN"
assert_eq "2" "$rc" "a pin for a target DEVBOX_TARGETS does not list is refused, like its address"
assert_ok "and the refusal names it" contains "sets DEVBOX_TARGET_SPARE_HOSTKEY, and DEVBOX_TARGETS does not list spare" "$err"
load_err $'DEVBOX_TARGET_LAN1_HOSTKEY='"$GATE_STUB_PIN"
assert_eq "2" "$rc" "a pin with no DEVBOX_TARGETS at all is refused"
load_err $'DEVBOX_TARGETS=lan1\nDEVBOX_TARGET_LAN1=lan1.invalid\nDEVBOX_GATE_PASSWORD=x'"$PIN1$PIN1"
assert_ok "a pin set twice is refused" contains "DEVBOX_TARGET_LAN1_HOSTKEY is set twice" "$err"
out="$(export DEVBOX_TARGET_LAN1_HOSTKEY="$GATE_STUB_PIN"; load $'DEVBOX_TARGETS=lan1\nDEVBOX_TARGET_LAN1=lan1.invalid\nDEVBOX_GATE_PASSWORD=x' 2>/dev/null)"; rc=$?
assert_eq "2" "$rc" "an exported pin does not stand in for the file's"

# ── rented targets ───────────────────────────────────────────────────────────
load_err 'DEVBOX_RENT=runpod'
assert_eq "2" "$rc" "DEVBOX_RENT=runpod with no RUNPOD_KEY is refused"
assert_ok "and the refusal names the key" contains "RUNPOD_KEY is missing" "$err"
load_err 'DEVBOX_RENT=hetzner'
assert_eq "2" "$rc" "DEVBOX_RENT=hetzner with no HCLOUD_TOKEN is refused"
assert_ok "and the refusal names the key" contains "HCLOUD_TOKEN is missing" "$err"
load_err $'DEVBOX_RENT=hetzner,runpod\nHCLOUD_TOKEN=t\nRUNPOD_KEY=k\nDEVBOX_HETZNER_SERVER_TYPE=ccx33\nDEVBOX_HETZNER_LOCATION=nbg1\nDEVBOX_HETZNER_IDLE_SECONDS=600'
assert_eq "0" "$rc" "DEVBOX_RENT=hetzner,runpod with both keys and the three Hetzner settings loads"
load_err $'DEVBOX_RENT=aws\nRUNPOD_KEY=k'
assert_eq "2" "$rc" "an unknown rented target is refused"
load_err $'DEVBOX_RENT=runpod,runpod\nRUNPOD_KEY=k'
assert_ok "a rented target named twice is refused" contains "names runpod twice" "$err"

# ── where the file is found ──────────────────────────────────────────────────
#
# A linked worktree holds no gitignored file, so it borrows the main
# checkout's: worktrees that each ran their gate locally put more test workers
# on one laptop than it had cores.
git -C "$TMP" init -q main >/dev/null 2>&1
printf '.devbox.env\n' >"$TMP/main/.gitignore"
git -C "$TMP/main" add -A >/dev/null 2>&1
git -C "$TMP/main" -c user.email=t@fixture.invalid -c user.name=fixture commit -q -m init >/dev/null 2>&1
git -C "$TMP/main" worktree add -q -b wt "$TMP/wt" >/dev/null 2>&1
printf '%s\n' "$TWO" >"$TMP/main/.devbox.env"
assert_eq "$TMP/main/.devbox.env" "$(devbox_env_find "$TMP/main")" "the main checkout reads its own file"
assert_eq "$TMP/main/.devbox.env" "$(devbox_env_find "$TMP/wt")" "a linked worktree borrows the main checkout's file"
printf 'DEVBOX_RENT=\n' >"$TMP/wt/.devbox.env"
assert_eq "$TMP/wt/.devbox.env" "$(devbox_env_find "$TMP/wt")" "a worktree's own file wins"
assert_fail "a directory with no file anywhere finds none" devbox_env_find "$TMP/nowhere"

printf '%d %d\n' "$TESTS_RUN" "$TESTS_FAILED"
