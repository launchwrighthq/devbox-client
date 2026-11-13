#!/bin/bash
# `devbox status` and the rentals (R19 to R22), run as a real
# process against a fake RunPod API, a fake Hetzner API, fake pods and the fake
# gate account of a rented Hetzner server.
#
# A rental costs money while it exists, and the view is the one place that shows
# every pod and server of this laptop at once. The cases prove what a reader of
# the view cannot see: no DELETE is ever sent, a record is never changed, the
# API token never reaches an argv, and every cost says `about`.
#
# Hermetic: curl, ssh, ssh-keyscan and date are stubs first on PATH, HOME and
# XDG_RUNTIME_DIR point into one mktemp -d. The Hetzner server addresses are in
# 203.0.113.0/24, the range RFC 5737 reserves for documentation.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
# shellcheck source=tests/lib.sh
source ./lib.sh
command -v jq >/dev/null || { echo 'install jq to test the rental view' >&2; exit 1; }
REPO="$(cd .. && pwd)"
STATUS="$REPO/client/libexec/devbox-status"

TMP="$(mktemp -d)" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
contains() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }

PROTO="$(sed -n 's/^DEVBOX_PROTOCOL_VERSION=\(.*\)$/\1/p' "$REPO/lib/devbox-lib.sh")"
FP="$(sha256sum <"$REPO/lib/devbox-lib.sh" | cut -d' ' -f1)"

# The laptop's clock, fixed, so every `up` and every `so far` is exact. The
# pods' and servers' creation times below are relative to it.
NOW=1800000000
API="$TMP/api"
mkdir -p "$TMP/bin" "$TMP/fakehome" "$TMP/run" "$TMP/replies" "$API"
REAL_DATE="$(command -v date)"
# The stub's own text: its $# and $1 expand when the stub runs, not here.
# shellcheck disable=SC2016
printf '#!/bin/bash\nif [ "$#" = 1 ] && [ "$1" = +%%s ] && [ -n "${FAKE_NOW-}" ]; then echo "$FAKE_NOW"; exit 0; fi\nexec %q "$@"\n' \
  "$REAL_DATE" >"$TMP/bin/date"

# ── the fake APIs ────────────────────────────────────────────────────────────
#
# Every call is logged as `<method> <url>`, every argv as one line, so a test
# can prove that no DELETE was sent and that no key reached an argument.
# $API/runpod-refuse and $API/hetzner-refuse make that provider answer 401.
cat >"$TMP/bin/curl" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >>"$API/argv"
method=GET; out=/dev/stdout; url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --request) method="$2"; shift 2 ;;
    --output) out="$2"; shift 2 ;;
    --header) cat "${2#@}" >>"$API/headers"; shift 2 ;;
    --data-binary|--write-out|--connect-timeout|--max-time) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
printf '%s %s\n' "$method" "$url" >>"$API/calls"
case "$method $url" in
  "GET https://rest.runpod.io/v1/pods")
    if [ -e "$API/runpod-refuse" ]; then printf '{"error":"unauthorized"}' >"$out"; printf 401; exit 0; fi
    cat "$API/pods.json" >"$out"; printf 200 ;;
  "GET https://api.hetzner.cloud/v1/servers?label_selector=devbox%3Drented&per_page=50")
    if [ -e "$API/hetzner-refuse" ]; then printf '{"error":{"code":"unauthorized"}}' >"$out"; printf 401; exit 0; fi
    cat "$API/servers.json" >"$out"; printf 200 ;;
  *) printf '{"error":{"code":"unexpected_call"}}' >"$out"; printf 500 ;;
esac
STUB

# ── the fake pods and the fake gate account ─────────────────────────────────
#
# A pod is reached as `ssh -F <record dir>/ssh_config devbox-runpod <command>`,
# and the record dir says how it answers: fake-answer verbatim, fake-stall
# never, fake-deleting with exit 75, as the runtime answers while it deletes
# its pod. Every pod command is logged. Every other ssh is the gate account of
# the rented Hetzner server, which answers `status` with a reply file. A gate
# call may open with `-F /dev/null` too, so a pod is a -F that names a file.
{
  printf '#!/bin/bash\n'
  cat <<'PRE'
[ -z "${SSH_LOG-}" ] || printf '%s\n' "$*" >>"$SSH_LOG"
if [ "${1-}" = -F ] && [ "${2-}" != /dev/null ]; then
  _dir="$(dirname "$2")"
  printf '%s\n' "${*: -1}" >>"$API/pod-commands"
  [ ! -e "$_dir/fake-stall" ] || exec sleep 60
  [ ! -e "$_dir/fake-deleting" ] || exit 75
  cat "$_dir/fake-answer"
  exit 0
fi
PRE
  gate_stub_prelude
  cat <<'STUB'
case "$GATE_CMD" in
  "status "*) cat "$FAKE_STATUS_DIR/$GATE_HOST.status" 2>/dev/null; exit 0 ;;
esac
echo "fake gate: unexpected verb: $GATE_CMD" >&2
exit 9
STUB
} >"$TMP/bin/ssh"
chmod +x "$TMP/bin/curl" "$TMP/bin/ssh" "$TMP/bin/date"
gate_stub_keyscan "$TMP/bin"

# ── the checkout: a main checkout and two linked worktrees ──────────────────
CO="$TMP/fix-cache"
mkdir -p "$CO/.devbox"
git -C "$CO" init -q >/dev/null 2>&1
printf 'DEVBOX_PROJECT=rental-fixture\nDEVBOX_SETUP=:\nDEVBOX_VERIFY=:\n' >"$CO/.devbox/config.env"
git -C "$CO" add .devbox/config.env >/dev/null 2>&1
git -C "$CO" -c user.email=t@fixture.invalid -c user.name=fixture commit -q -m init >/dev/null 2>&1
git -C "$CO" worktree add -q -b feat "$TMP/feat-login" >/dev/null 2>&1
git -C "$CO" worktree add -q -b old "$TMP/old-run" >/dev/null 2>&1
GD_MAIN="$(git -C "$CO" rev-parse --path-format=absolute --git-dir)"
GD_FEAT="$(git -C "$TMP/feat-login" rev-parse --path-format=absolute --git-dir)"
GD_OLD="$(git -C "$TMP/old-run" rev-parse --path-format=absolute --git-dir)"

RUNPOD_KEY_VALUE=fixtureRunpodKey0123456789
HCLOUD_VALUE=fixtureHcloudToken0123456789
ENV_RENT="$(printf 'DEVBOX_RENT=runpod,hetzner\nRUNPOD_KEY=%s\nHCLOUD_TOKEN=%s\n' "$RUNPOD_KEY_VALUE" "$HCLOUD_VALUE")"
printf '%s\n' "$ENV_RENT" >"$CO/.devbox.env"

# Rental names in the forms runpod_owner_name and hetzner_owner_name accept.
hex() { printf "%0${2}d" 0 | tr 0 "$1"; }
POD_FEAT="devbox-cpu-lap1-0123456789-$(hex a 32)"
POD_GONE="devbox-cpu-lap1-0123456789-$(hex b 32)"
POD_FREE="devbox-cpu-lap2-abcdef0123-$(hex c 32)"
POD_OLD="devbox-cpu-lap1-0123456789-$(hex d 32)"
HZ_MAIN="devbox-hz-lap1-0123456789-$(hex a 16)"
HZ_FEAT="devbox-hz-lap1-0123456789-$(hex b 16)"
HZ_GONE="devbox-hz-lap1-0123456789-$(hex c 16)"
HZ_FREE="devbox-hz-lap2-abcdef0123-$(hex d 16)"

# ── the records ──────────────────────────────────────────────────────────────
write_records() {
  mkdir -p "$GD_FEAT/devbox-runpod" "$GD_MAIN/devbox-runpod" "$GD_OLD/devbox-runpod" \
    "$GD_MAIN/devbox-hetzner" "$GD_FEAT/devbox-hetzner" "$GD_OLD/devbox-hetzner"
  # feat-login: a pod RunPod has, up 1h12m at $0.37/h.
  jq -n --arg name "$POD_FEAT" --argjson c $((NOW - 4320)) \
    '{name:$name,createdAt:$c,cpus:16,idleSeconds:7200,watchdog:"pod",createUncertain:false,id:"podaaa1",hourly:0.37}' \
    >"$GD_FEAT/devbox-runpod/pod.json"
  printf 'Host devbox-runpod\n  HostName pod1.invalid\n' >"$GD_FEAT/devbox-runpod/ssh_config"
  idle_answer $((NOW - 240))
  # fix-cache: a record whose pod RunPod no longer has.
  jq -n --arg name "$POD_GONE" --argjson c $((NOW - 9000)) \
    '{name:$name,createdAt:$c,cpus:16,id:"podgone",hourly:0.37,terminated:false}' >"$GD_MAIN/devbox-runpod/pod.json"
  # old-run: a pod deleted and confirmed, which shows nowhere.
  jq -n --arg name "$POD_OLD" '{name:$name,createdAt:1,cpus:16,id:"podold",hourly:0.37,terminated:true}' \
    >"$GD_OLD/devbox-runpod/pod.json"
  # fix-cache: the ready Hetzner server of the checkout status runs in. Its
  # record has no hourly price, as a record made before the client kept one.
  jq -n --arg name "$HZ_MAIN" --argjson c $((NOW - 600)) --arg pin "$GATE_STUB_PIN" \
    '{name:$name,createdAt:$c,serverType:"ccx43",location:"hel1",image:42,idleSeconds:7200,hostKey:$pin,createUncertain:false,id:701,ip:"203.0.113.1"}' \
    >"$GD_MAIN/devbox-hetzner/server.json"
  printf 'ssh-ed25519 %s devbox-hetzner\n' "$GATE_STUB_HOSTKEY" >"$GD_MAIN/devbox-hetzner/hostkey.pub"
  printf 'fixture-hetzner-gate-password' >"$GD_MAIN/devbox-hetzner/gate-password"
  # feat-login: a server whose record carries a four-decimal EUR price.
  jq -n --arg name "$HZ_FEAT" --argjson c $((NOW - 7200)) \
    '{name:$name,createdAt:$c,serverType:"ccx43",id:704,ip:"203.0.113.4",hourly:0.0988,currency:"EUR",createUncertain:false}' \
    >"$GD_FEAT/devbox-hetzner/server.json"
  # old-run: a record whose server Hetzner no longer has.
  jq -n --arg name "$HZ_GONE" '{name:$name,createdAt:1,serverType:"ccx43",id:799,ip:"203.0.113.99",createUncertain:false}' \
    >"$GD_OLD/devbox-hetzner/server.json"
}
idle_answer() {  # $1 the pod's idleSince
  jq -n --arg name "$POD_FEAT" --argjson since "$1" '{id:"podaaa1",name:$name,idleSeconds:7200,idleSince:$since,watchdog:true}' |
    { printf '%s\n' "$NOW"; cat; } >"$GD_FEAT/devbox-runpod/fake-answer"
}
remove_records() {
  rm -rf "$GD_MAIN/devbox-runpod" "$GD_FEAT/devbox-runpod" "$GD_OLD/devbox-runpod" \
    "$GD_MAIN/devbox-hetzner" "$GD_FEAT/devbox-hetzner" "$GD_OLD/devbox-hetzner"
}
record_sums() {
  find "$GD_MAIN" -path '*devbox-runpod/*' -o -path '*devbox-hetzner/*' 2>/dev/null | sort | while IFS= read -r f; do
    [ -f "$f" ] && printf '%s %s\n' "$f" "$(sha256sum <"$f" | cut -d' ' -f1)"
  done
}

# ── the accounts ─────────────────────────────────────────────────────────────
iso() { "$REAL_DATE" -u -d "@$1" "+%Y-%m-%dT%H:%M:%S+00:00"; }
# RunPod: the recorded pod, a devbox pod of another laptop that no record
# knows, up 3d2h, and a pod devbox did not create, which never shows. The
# unrecorded pod's creation time is in the form `2027-01-12 06:00:00.000 +0000
# UTC`, the other in ISO 8601: the view reads both.
write_accounts() {
  jq -n --arg feat "$POD_FEAT" --arg free "$POD_FREE" \
    --arg cfeat "$(iso $((NOW - 4320)))" \
    --arg cfree "$("$REAL_DATE" -u -d "@$((NOW - 266400))" '+%Y-%m-%d %H:%M:%S.000 +0000 UTC')" \
    '[{id:"podaaa1",name:$feat,vcpuCount:16,costPerHr:0.37,adjustedCostPerHr:0.37,desiredStatus:"RUNNING",createdAt:$cfeat},
      {id:"podx9y8",name:$free,vcpuCount:16,costPerHr:0.5,adjustedCostPerHr:0.37,desiredStatus:"RUNNING",createdAt:$cfree},
      {id:"stranger",name:"my-notebook-pod",vcpuCount:8,costPerHr:0.2,desiredStatus:"RUNNING",createdAt:$cfree}]' >"$API/pods.json"
  # Hetzner: the two recorded servers, one of another laptop, and one that
  # carries the label and no devbox rental name.
  jq -n --arg main "$HZ_MAIN" --arg feat "$HZ_FEAT" --arg free "$HZ_FREE" \
    --arg cmain "$(iso $((NOW - 600)))" --arg cfeat "$(iso $((NOW - 7200)))" --arg cfree "$(iso $((NOW - 3600)))" \
    '{servers: [
      {id:701,name:$main,status:"running",created:$cmain,server_type:{name:"ccx43"},labels:{devbox:"rented"}},
      {id:704,name:$feat,status:"running",created:$cfeat,server_type:{name:"ccx43"},labels:{devbox:"rented"}},
      {id:702,name:$free,status:"running",created:$cfree,server_type:{name:"cx22"},labels:{devbox:"rented"}},
      {id:703,name:"build-box",status:"running",created:$cfree,server_type:{name:"cx22"},labels:{devbox:"rented"}}]}' \
    >"$API/servers.json"
}

# The reply of the rented server to the `status` verb: an idle host.
GIB=1073741824
E=1700000000
{
  printf '%s %s %s\n' "$PROTO" "$FP" "$E"
  printf 'host ok 5 0 20 0 3 0 0.31 8 %s %s 0 %s\n' "$((30 * GIB))" "$((32 * GIB))" "$((16 * GIB))"
  printf 'end\n'
} >"$TMP/replies/203.0.113.1.status"

# ── running the real program ─────────────────────────────────────────────────
out=""; err=""; rc=0
SSH_LOG="$TMP/ssh.log"
run_status() {
  : >"$SSH_LOG"
  out="$(cd "$CO" && env LC_ALL=C PATH="$TMP/bin:$PATH" HOME="$TMP/fakehome" XDG_RUNTIME_DIR="$TMP/run" \
    SSH_LOG="$SSH_LOG" API="$API" FAKE_NOW="$NOW" FAKE_STATUS_DIR="$TMP/replies" \
    "$@" bash "$STATUS" ${STATUS_ARGS[@]+"${STATUS_ARGS[@]}"} 2>"$TMP/err")"
  rc=$?
  err="$(cat "$TMP/err")"
  return 0
}
STATUS_ARGS=()

# ═══ no rental ═══════════════════════════════════════════════════════════════
printf '[]\n' >"$API/pods.json"
printf '{"servers":[]}\n' >"$API/servers.json"
run_status
assert_eq "0" "$rc" "two providers with nothing rented: exit 0"
assert_eq "$(printf 'runpod    no rental\n\nhetzner   no rental')" "$out" "each provider says it has no rental"
assert_eq "" "$err" "and nothing on stderr"

# ═══ R19, R22: the three row kinds and the sum row ═══════════════════════════
write_records
write_accounts
before="$(record_sums)"
# The rented Hetzner server is a target: its line comes with the servers, its
# gates go in the table, and its provider block holds what it costs.
expected_view="$(cat <<EOF
hetzner   ok        tokens ........ 0/20     load #....... 0.3/8    mem #....... 2.0G/32G   jobs 0/3

no gate runs or waits

runpod    fix-cache      record says pod podgone, RunPod has no such pod: devbox runpod down in that worktree clears the record
          feat-login     pod podaaa1  16 vCPU  \$0.37/h  up 1h12m  about \$0.44 so far
                         idle 4m, deletes itself in 1h56m
          not recorded   pod podx9y8  $POD_FREE  16 vCPU  \$0.37/h  up 3d2h  about \$27.38 so far
          2 pods  \$0.74/h  about \$27.82 so far

hetzner   fix-cache      server 701  ccx43  price not recorded  up 10m00s
          feat-login     server 704  ccx43  EUR 0.0988/h  up 2h00m  about EUR 0.20 so far
          old-run        record says server 799, Hetzner has no such server: devbox hetzner down in that worktree clears the record
          not recorded   server 702  $HZ_FREE  cx22  price not recorded  up 1h00m
          3 servers  EUR 0.0988/h  about EUR 0.20 so far for 1  price not recorded for 2
EOF
)"
: >"$API/calls"
run_status
assert_eq "0" "$rc" "both providers answer: exit 0"
assert_eq "$expected_view" "$out" "the Hetzner server line, the RunPod rows and the Hetzner rows"
assert_eq "" "$err" "and nothing on stderr"
assert_fail "a pod devbox did not create never shows" contains "stranger" "$out"
assert_fail "a labelled server with no rental name never shows" contains "703" "$out"
assert_eq "1" "$(grep -c '^GET https://rest.runpod.io/v1/pods$' "$API/calls")" "one GET /pods"
assert_eq "1" "$(grep -c '^GET https://api.hetzner.cloud/v1/servers?' "$API/calls")" "one GET /servers, filtered to the devbox label"
assert_eq "date +%s && bash /opt/devbox/runpod-runtime status" "$(sort -u "$API/pod-commands")" \
  "the pod is asked its runtime status and nothing else"
assert_eq "1" "$(wc -l <"$API/pod-commands" | tr -d ' ')" "and only the pod a record and RunPod agree on"
assert_eq "$before" "$(record_sums)" "no record changed: a gone pod's record is reported, not cleared"
assert_ok "the gate verb went to the server of this checkout's record" grep -q 'devbox-gate@203.0.113.1 status ' "$SSH_LOG"
assert_fail "and no record's known_hosts was written" test -e "$GD_MAIN/devbox-hetzner/known_hosts"

# R20: every cost says `about`.
bad=0
while IFS= read -r line; do
  case "$line" in *"so far"*) { contains "about \$" "$line" || contains "about EUR " "$line"; } || bad=$((bad + 1)) ;; esac
done <<<"$out"
assert_eq "0" "$bad" "every amount so far carries the word about"

# A pod that is working, one that does not answer, one that deletes itself.
idle_answer $((NOW - 10))
run_status
assert_ok "a pod whose idle clock moved in the last minute: busy, or idle under 1m" \
  contains "                         busy, or idle under 1m, deletes itself after 2h00m idle" "$out"
idle_answer $((NOW - 240))
touch "$GD_FEAT/devbox-runpod/fake-stall"
run_status DEVBOX_STATUS_POD_SECONDS=1
assert_ok "a pod that does not answer: idle state unknown" contains "idle state unknown (no answer in 1s)" "$out"
assert_eq "0" "$rc" "and that is no failure of the view: exit 0"
rm -f "$GD_FEAT/devbox-runpod/fake-stall"
touch "$GD_FEAT/devbox-runpod/fake-deleting"
run_status
assert_ok "a pod that is deleting itself says so" contains "deleting itself now" "$out"
rm -f "$GD_FEAT/devbox-runpod/fake-deleting"

# --target names one provider.
STATUS_ARGS=(--target runpod)
run_status
assert_eq "0" "$rc" "--target runpod: exit 0"
assert_ok "and shows the RunPod block" contains "runpod    fix-cache" "$out"
assert_fail "and not the Hetzner one" contains "hetzner" "$out"
STATUS_ARGS=(--target hetzner)
run_status
assert_ok "--target hetzner shows the Hetzner block" contains "hetzner   ok" "$out"
assert_fail "and not the RunPod one" contains "runpod  " "$out"
STATUS_ARGS=()

# A server that is not running is no target: its row says its state.
jq '.servers[0].status = "off"' "$API/servers.json" >"$API/s.tmp" && mv "$API/s.tmp" "$API/servers.json"
run_status
assert_ok "a stopped server is a row with its state" \
  contains "hetzner   fix-cache      server 701  ccx43  off  price not recorded  up 10m00s" "$out"
assert_fail "and no gate verb is sent to it" grep -q 'devbox-gate@203.0.113.1 status ' "$SSH_LOG"
write_accounts

# ═══ exit code 1: an API call failed ═════════════════════════════════════════
touch "$API/runpod-refuse"
run_status
assert_eq "1" "$rc" "the RunPod API refuses the key: exit 1"
assert_ok "and the block names the failed call" contains "runpod    the RunPod API call failed: GET /pods: HTTP 401" "$out"
assert_ok "a record is still listed, as not checked" contains "feat-login     record says pod podaaa1, not checked" "$out"
assert_ok "the Hetzner block is still there" contains "hetzner   ok" "$out"
rm -f "$API/runpod-refuse"
touch "$API/hetzner-refuse"
run_status
assert_eq "1" "$rc" "the Hetzner API refuses the token: exit 1"
assert_ok "and the block names the call and the error code" \
  contains "hetzner   the Hetzner API call failed: GET /servers: HTTP 401 (unauthorized)" "$out"
rm -f "$API/hetzner-refuse"

# The first non-zero code in target order, then providers: a deployed target
# that does not answer comes first.
printf '%s\nDEVBOX_TARGETS=lan1\nDEVBOX_TARGET_LAN1=lan1.invalid\nDEVBOX_TARGET_LAN1_HOSTKEY=%s\nDEVBOX_GATE_PASSWORD=fixture-gate-password\n' \
  "$ENV_RENT" "$GATE_STUB_PIN" >"$CO/.devbox.env"
touch "$API/runpod-refuse"
run_status FAKE_UNREACHABLE=lan1.invalid
assert_eq "3" "$rc" "lan1 unreachable, then a refused RunPod key: exit 3, the target's code"
assert_ok "lan1 comes first" test "$(printf '%s\n' "$out" | head -1 | cut -c1-4)" = lan1
rm -f "$API/runpod-refuse"
printf '%s\n' "$ENV_RENT" >"$CO/.devbox.env"

# ═══ R21: a provider with no key ═════════════════════════════════════════════
: >"$API/calls"
printf 'DEVBOX_RENT=runpod,hetzner\n' >"$CO/.devbox.env"
run_status
assert_eq "0" "$rc" "DEVBOX_RENT names both, and no key is set: exit 0"
assert_eq "$(printf 'runpod    no key in .devbox.env, not checked\n\nhetzner   no key in .devbox.env, not checked')" "$out" \
  "each provider says that it has no key"
assert_eq "" "$(cat "$API/calls")" "and no API is called"
printf '%s\n' "$ENV_RENT" >"$CO/.devbox.env"

# A provider the file names only by its key is shown too.
printf 'RUNPOD_KEY=%s\n' "$RUNPOD_KEY_VALUE" >"$CO/.devbox.env"
run_status
assert_ok "RUNPOD_KEY alone shows the RunPod block" contains "runpod    fix-cache" "$out"
printf '%s\n' "$ENV_RENT" >"$CO/.devbox.env"

# ═══ the keys and the deletes ════════════════════════════════════════════════
assert_fail "the RunPod key never reaches an argv" grep -q "$RUNPOD_KEY_VALUE" "$API/argv"
assert_fail "the Hetzner token never reaches an argv" grep -q "$HCLOUD_VALUE" "$API/argv"
assert_ok "both reach only the header stream" grep -q "Bearer $RUNPOD_KEY_VALUE" "$API/headers"
assert_fail "no DELETE was sent in any case of this file" grep -q '^DELETE ' "$API/calls"
assert_eq "$before" "$(record_sums)" "and after every case, no record changed"

# ═══ watch mode: the APIs and the pods at most every 30 seconds ══════════════
#
# Four refreshes at --interval 2 ask the rented server's gate at each refresh,
# and the two APIs and the pod once: the price does not change during a rental,
# and both APIs have a rate limit.
if script --version 2>/dev/null | grep -q util-linux; then
  : >"$API/calls"; : >"$API/pod-commands"; : >"$SSH_LOG"
  cmd="stty cols 200 rows 40 && cd $(printf '%q' "$CO") && env PATH=$(printf '%q' "$TMP/bin:$PATH") HOME=$(printf '%q' "$TMP/fakehome") XDG_RUNTIME_DIR=$(printf '%q' "$TMP/run") SSH_LOG=$(printf '%q' "$SSH_LOG") API=$(printf '%q' "$API") FAKE_NOW=$NOW FAKE_STATUS_DIR=$(printf '%q' "$TMP/replies") TERM=xterm LC_ALL=C.UTF-8 DEVBOX_STATUS_FRAMES=28 bash $(printf '%q' "$STATUS") --watch --interval 2"
  wrc=0
  wout="$(script -qec "$cmd" /dev/null </dev/null 2>&1 | tr -d '\r' | sed 's/\x1b\[[0-9;?]*[A-Za-z]//g')" || wrc=$?
  assert_eq "0" "$wrc" "a watch of seven seconds exits 0"
  assert_ok "and draws the RunPod block" contains "runpod    fix-cache" "$wout"
  assert_ok "and the Hetzner target block" contains "hetzner   ok" "$wout"
  assert_eq "1" "$(grep -c 'rest.runpod.io' "$API/calls")" "one RunPod API call in four refreshes"
  assert_eq "1" "$(grep -c 'api.hetzner.cloud' "$API/calls")" "one Hetzner API call in four refreshes"
  assert_eq "1" "$(wc -l <"$API/pod-commands" | tr -d ' ')" "one pod call in four refreshes"
  hz_calls="$(grep -c 'devbox-gate@203.0.113.1 status ' "$SSH_LOG")"
  assert_ok "the rented server's gate is asked at each refresh ($hz_calls calls)" test "$hz_calls" -ge 3
else
  echo "  note: no util-linux script on this machine, so the watch case did not run"
fi

remove_records
printf '%d %d\n' "$TESTS_RUN" "$TESTS_FAILED"
