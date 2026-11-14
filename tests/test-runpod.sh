#!/bin/bash
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
# shellcheck source=tests/lib.sh
source ./lib.sh
command -v jq >/dev/null || { echo 'install jq to test the RunPod provider' >&2; exit 1; }
REPO="$(cd .. && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# Functions without the entry call let the real ownership checks use a deterministic provider.
sed '$d' "$REPO/client/libexec/devbox-runpod" > "$TMP/provider.sh"
# The provider sources devbox-rented from its own directory.
cp "$REPO/client/libexec/devbox-rented" "$TMP/"
# shellcheck source=/dev/null
source "$TMP/provider.sh"
devbox_machine_label() { printf 'dev-laptop'; }
devbox_machine_id() {
  # The extracted provider calls this stub before the later failure stub replaces it.
  # shellcheck disable=SC2317
  printf '%s' "$MACHINE_ID"
}
MACHINE_ID=11111111111111111111111111111111
FIRST_NAME=$(runpod_name)
SECOND_NAME=$(runpod_name)
assert_ok 'rental name includes the shortened laptop label' test "${FIRST_NAME:0:20}" = devbox-cpu-dev-lapt-
assert_ok 'new rental names pass the cleanup ownership format' runpod_owner_name "$FIRST_NAME"
assert_ok 'repeat rentals preserve the laptop identifier' test "${FIRST_NAME%-*}" = "${SECOND_NAME%-*}"
assert_fail 'repeat rentals on one laptop have distinct names' test "$FIRST_NAME" = "$SECOND_NAME"
MACHINE_ID=22222222222222222222222222222222
OTHER_NAME=$(runpod_name)
assert_fail 'same hostname on another machine has a distinct identifier' test "${FIRST_NAME%-*}" = "${OTHER_NAME%-*}"
devbox_machine_id() { return 1; }
assert_fail 'missing machine identity refuses a new rental name' runpod_name
assert_fail 'cleanup rejects malformed laptop identifiers' runpod_owner_name devbox-cpu-dev-lapt-invalid-0123456789abcdef0123456789abcdef
RP_STATE="$TMP/state"
mkdir -p "$RP_STATE"
eval "$(declare -f runpod_api | sed '1s/runpod_api/runpod_http/')"
mkdir -p "$TMP/bin"
cat > "$TMP/bin/curl" <<'CURL'
#!/bin/bash
printf '%s\n' "$@" > "$RP_HTTP_ARGS"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output) destination=$2; shift 2 ;;
    --header) cat "${2#@}" > "$RP_HTTP_HEADERS"; shift 2 ;;
    *) shift ;;
  esac
done
echo 'private provider detail' > "$destination"
printf 403
CURL
chmod +x "$TMP/bin/curl"
# The extracted HTTP function reads the developer config's canonical key.
# shellcheck disable=SC2034
RUNPOD_KEY=fixture-only-key
export RP_HTTP_ARGS="$TMP/http-args" RP_HTTP_HEADERS="$TMP/http-headers"
rc=0
err=$(PATH="$TMP/bin:$PATH" runpod_http POST /pods 2>&1) || rc=$?
assert_eq 1 "$rc" 'provider HTTP errors fail the request'
assert_eq 'devbox runpod: POST /pods: HTTP 403' "$err" 'API errors omit response bodies and credentials'
assert_fail 'the API key never enters curl arguments' grep -q fixture-only-key "$RP_HTTP_ARGS"
assert_ok 'the API key reaches only the header stream' grep -q 'Bearer fixture-only-key' "$RP_HTTP_HEADERS"
OWNER=devbox-cpu-0123456789abcdef0123456789abcdef
SCENARIO=normal
runpod_api() {
  printf '%s %s\n' "$1" "$2" >> "$TMP/calls"
  if [ "$1" = DELETE ]; then touch "$TMP/deleted"; echo null; return; fi
  if [[ "$2" == *'?'* ]]; then
    if [ "$SCENARIO" = ambiguous ]; then
      jq -n --arg name "$OWNER" '[{id:"ours",name:$name},{id:"other",name:$name}]'
    elif [ "$SCENARIO" = uncertain ]; then echo '[]'
    else jq -n --arg name "$OWNER" '[{id:"ours",name:$name,cpuFlavorId:"cpu3g"}]'; fi
    return
  fi
  if [ -f "$TMP/deleted" ] && [ "$SCENARIO" != unconfirmed ]; then echo null; return; fi
  case "$SCENARIO" in
    wrong) jq -n '{id:"ours",name:"someone-else",cpuFlavorId:"cpu3g"}' ;;
    gpu) jq -n --arg name "$OWNER" '{id:"ours",name:$name,computeType:"GPU"}' ;;
    *) jq -n --arg name "$OWNER" '{id:"ours",name:$name,cpuFlavorId:"cpu3g"}' ;;
  esac
}
reset_rental() {
  rm -f "$TMP/calls" "$TMP/deleted"
  jq -n --arg name "$OWNER" '{name:$name,id:"ours",createdAt:4102444800}' > "$RP_STATE/pod.json"
  touch "$RP_STATE/key" "$RP_STATE/key.pub"
}
reset_rental
assert_ok 'deletes an owned CPU and confirms absence' runpod_down
assert_eq true "$(jq -r .terminated "$RP_STATE/pod.json")" 'records confirmed deletion'
assert_fail 'removes the private SSH key after confirmed deletion' test -e "$RP_STATE/key"
assert_eq 'GET /pods/ours
DELETE /pods/ours
GET /pods/ours' "$(cat "$TMP/calls")" 'delete is surrounded by ownership and absence reads'
OWNER="$FIRST_NAME"
reset_rental
assert_ok 'deletes a rental carrying the laptop identifier' runpod_down
assert_eq true "$(jq -r .terminated "$RP_STATE/pod.json")" 'records confirmed deletion for laptop-named rentals'
for SCENARIO in wrong gpu unconfirmed; do
  reset_rental
  assert_fail "refuses $SCENARIO cleanup" runpod_down
  assert_ok 'retains recovery material when cleanup is unconfirmed' test -f "$RP_STATE/key"
  assert_eq null "$(jq -r .terminated "$RP_STATE/pod.json")" 'does not claim termination'
done
for SCENARIO in normal ambiguous uncertain; do
  reset_rental
  runpod_save 'del(.id) | .createUncertain=true'
  if [ "$SCENARIO" = normal ]; then
    assert_ok 'recovers a lost create response by exact owner name' runpod_down
  else
    assert_fail "refuses $SCENARIO recovery" runpod_down
    assert_fail 'does not issue DELETE without one identified pod' grep -q DELETE "$TMP/calls"
  fi
done
printf 'broken JSON\n' > "$RP_STATE/pod.json"
assert_fail 'does not claim cleanup for an unreadable rental record' runpod_down
mkdir -p "$TMP/client/client/libexec" "$TMP/client/client/bin" "$TMP/client/lib" "$TMP/checkout/.devbox"
cp "$REPO/client/bin/devbox" "$TMP/client/client/bin/"
cp "$REPO/client/libexec/devbox-verify" "$REPO/client/libexec/devbox-run" "$REPO/client/libexec/devbox-config" \
  "$REPO/client/libexec/devbox-transport" "$REPO/client/libexec/devbox-targets" "$REPO/client/libexec/devbox-askpass" "$REPO/client/libexec/devbox-sync" \
  "$TMP/client/client/libexec/"
cp "$REPO/lib/devbox-lib.sh" "$TMP/client/lib/"
cat > "$TMP/client/client/libexec/devbox-runpod" <<'BACKEND'
printf 'target=%s action=%s mode=%s\n' "${FORCE_TARGET:-rent}" "$RUNPOD_ACTION" "$RUN_MODE"
if [ "$RUN_MODE" = 1 ]; then eval "$RUN_SCRIPT"; else exit 17; fi
BACKEND
git -C "$TMP/checkout" init -q
cat > "$TMP/checkout/.devbox/config.env" <<'PROFILE'
DEVBOX_PROJECT=example
DEVBOX_WANT_TOKENS=4
DEVBOX_MIN_TOKENS=2
DEVBOX_SETUP=:
DEVBOX_VERIFY=touch LOCAL_GATE_RAN
PROFILE
# A deployed target this file never reaches: --target runpod passes it by.
cat > "$TMP/checkout/.devbox.env" <<CONFIG
DEVBOX_TARGETS=fixture
DEVBOX_TARGET_FIXTURE=unused-fixture-host
DEVBOX_TARGET_FIXTURE_HOSTKEY=$GATE_STUB_PIN
DEVBOX_GATE_PASSWORD=fixture-gate-password
RUNPOD_KEY=fixture-from-config
CONFIG
rc=0
out=$(cd "$TMP/checkout" && bash "$TMP/client/client/bin/devbox" verify --target runpod 2>/dev/null) || rc=$?
assert_eq 17 "$rc" '--target runpod wins over the deployed targets'
assert_eq 'target=runpod action= mode=0' "$out" 'verify reaches the provider'
assert_fail 'verify never ran the local gate' test -e "$TMP/checkout/LOCAL_GATE_RAN"
# The dollar and semicolon are test data, expanded only by the test's expected printf.
# shellcheck disable=SC2016
out=$(cd "$TMP/checkout" && bash "$TMP/client/client/bin/devbox" run --target runpod -- printf '<%s>' 'two words' '$HOME; false' 2>/dev/null)
# The expected output keeps the command's literal dollar sign.
# shellcheck disable=SC2016
assert_eq 'target=runpod action= mode=1
<two words><$HOME; false>' "$out" 'run --target runpod preserves command arguments through the same dispatch'
rc=0
err=$(cd "$TMP/checkout" && bash "$TMP/client/client/bin/devbox" verify --runpod 2>&1) || rc=$?
assert_eq 2 "$rc" '--runpod is refused'
assert_ok 'and the refusal names --target runpod' test "${err#*devbox verify --target runpod}" != "$err"
rc=0
err=$(cd "$TMP/checkout" && bash "$TMP/client/client/bin/devbox" verify --target hetzner 2>&1) || rc=$?
assert_eq 2 "$rc" '--target hetzner with no HCLOUD_TOKEN is refused'
assert_fail '--target hetzner never ran the local gate' test -e "$TMP/checkout/LOCAL_GATE_RAN"
rc=0
err=$(cd "$TMP/checkout" && bash "$TMP/client/client/bin/devbox" verify --target nowhere 2>&1) || rc=$?
assert_eq 2 "$rc" 'a --target that .devbox.env does not list is refused'
assert_ok 'and the refusal names the listed targets' test "${err#*Its DEVBOX_TARGETS are: fixture}" != "$err"
# Rule 4 of target selection: with no deployed target, DEVBOX_RENT rents.
printf 'DEVBOX_RENT=runpod\nRUNPOD_KEY=fixture-from-config\n' > "$TMP/checkout/.devbox.env"
rc=0
out=$(cd "$TMP/checkout" && bash "$TMP/client/client/bin/devbox" verify 2>/dev/null) || rc=$?
assert_eq 17 "$rc" 'DEVBOX_RENT=runpod selects the rental without a separate enable flag'
assert_eq '==> devbox: renting runpod: no deployed target can take this gate
target=rent action= mode=0' "$out" 'the rental is named, then reached through the generic provider'
printf 'DEVBOX_BACKEND=runpod\nRUNPOD_KEY=fixture\n' > "$TMP/checkout/.devbox.env"
rc=0
err=$(cd "$TMP/checkout" && bash "$TMP/client/client/bin/devbox" verify 2>&1) || rc=$?
assert_eq 2 "$rc" 'an older DEVBOX_BACKEND fails instead of running locally'
assert_ok 'and the refusal names DEVBOX_RENT' test "${err#*DEVBOX_RENT=runpod}" != "$err"
assert_fail 'an older config never ran the local gate' test -e "$TMP/checkout/LOCAL_GATE_RAN"
printf 'DEVBOX_RENT=runpod\n' > "$TMP/checkout/.devbox.env"
rc=0
err=$(cd "$TMP/checkout" && RUNPOD_KEY=exported-but-not-configured bash "$TMP/client/client/bin/devbox" verify 2>&1) || rc=$?
assert_eq 2 "$rc" 'an exported key cannot replace RUNPOD_KEY in the developer config'
assert_ok 'missing-key error names the config key' test "${err#*RUNPOD_KEY is missing}" != "$err"
assert_fail 'the exported secret is absent from the error' test "${err#*exported-but-not-configured}" != "$err"
rm "$TMP/checkout/.devbox.env"
rc=0
err=$(cd "$TMP/checkout" && bash "$TMP/client/client/bin/devbox" verify --target runpod 2>&1) || rc=$?
assert_eq 2 "$rc" 'RunPod selection with no developer config fails before any gate'
assert_fail 'missing config never ran the local gate' test -e "$TMP/checkout/LOCAL_GATE_RAN"

# Use the real provider for config failures; the fake curl records any accidental API call.
cp "$REPO/client/libexec/devbox-runpod" "$REPO/client/libexec/devbox-rented" "$TMP/client/client/libexec/"
mkdir -p "$TMP/client/server/bin"
cp "$REPO/server/bin/devbox-runpod-runtime" "$REPO/server/bin/devbox-rented-idle" "$TMP/client/server/bin/"
printf 'DEVBOX_RUNPOD_IMAGE=fixture/image:1\n' >> "$TMP/checkout/.devbox/config.env"
for bad in DEVBOX_RUNPOD_IDLE_SECONDS=0 DEVBOX_RUNPOD_CPUS=3 DEVBOX_RUNPOD_SECONDS=7200; do
  printf 'DEVBOX_RENT=runpod\nRUNPOD_KEY=fixture\n%s\n' "$bad" > "$TMP/checkout/.devbox.env"
  rm -f "$RP_HTTP_ARGS"
  rc=0
  (cd "$TMP/checkout" && PATH="$TMP/bin:$PATH" bash "$TMP/client/client/bin/devbox" verify) >/dev/null 2>&1 || rc=$?
  assert_eq 2 "$rc" "invalid $bad fails before allocation"
  assert_fail 'invalid configuration reaches no API call' test -e "$RP_HTTP_ARGS"
done

# A pod has no pool, so a project that needs Postgres must name the variable its URL goes in.
printf 'DEVBOX_RENT=runpod\nRUNPOD_KEY=fixture\n' > "$TMP/checkout/.devbox.env"
printf 'DEVBOX_NEEDS_POSTGRES=1\n' >> "$TMP/checkout/.devbox/config.env"
rm -f "$RP_HTTP_ARGS"
rc=0
err=$(cd "$TMP/checkout" && PATH="$TMP/bin:$PATH" bash "$TMP/client/client/bin/devbox" verify 2>&1) || rc=$?
assert_eq 2 "$rc" 'DEVBOX_NEEDS_POSTGRES=1 with no DEVBOX_DB_URL_VAR fails before allocation'
assert_ok 'and names the missing key' test "${err#*needs DEVBOX_DB_URL_VAR}" != "$err"
assert_fail 'and reaches no API call' test -e "$RP_HTTP_ARGS"

# The run script exports the pod's URL the way the SSH backend's --env-file does.
src=$(cat "$REPO/client/libexec/devbox-runpod")
# Both are source text to find, not expansions.
# shellcheck disable=SC2016
assert_ok 'provision runs the pod Postgres script when the project needs one' \
  test "${src#*DEVBOX_DSN_FILE=\$dsn_file bash /opt/devbox/client/libexec/devbox-runpod-postgres}" != "$src"
# shellcheck disable=SC2016
assert_ok 'and the gate reads the URL into DEVBOX_DB_URL_VAR before exporting it' \
  test "${src#*printf \'%s=\"\$(cat %s)\"\\nexport %s\\n\'}" != "$src"

# DEVBOX_REQUIRES on the pod. A pod never got the list, so an image without a required tool
# ran the gate, where a deployed target exits 6. runpod_execute runs here with every remote
# step stubbed: ssh logs each pod command, and runs the requirement check on this machine
# with the real devbox-requires-local, after one level of the pod shell's quoting.
mkdir -p "$TMP/podbin" "$TMP/podclient" "$TMP/podstate"
printf 'devbox_sync() { :; }\n' > "$TMP/podclient/devbox-sync"
printf '#!/bin/sh\nexit 0\n' > "$TMP/podbin/rsync"
cat > "$TMP/podbin/ssh" <<'SSH'
#!/bin/bash
cmd="${4#bash /opt/devbox/runpod-runtime activity }"
eval "set -- $cmd"
inner="$3"
printf '%s\n' "$inner" >> "$POD_LOG"
case "$inner" in
  *devbox-requires-local*)
    [ "${POD_SSH_FAILS:-0}" != 1 ] || exit 255
    inner="${inner#runuser -u dev -- }"
    exec bash -c "${inner//\/opt\/devbox\/client\/libexec/$POD_LIBEXEC}" ;;
  *) [ -t 0 ] || cat >/dev/null ;;
esac
SSH
chmod +x "$TMP/podbin/rsync" "$TMP/podbin/ssh"
jq -n '{cpus:4}' > "$TMP/podstate/pod.json"
cat > "$TMP/execute.sh" <<'DRIVER'
set -euo pipefail
source "$TMP/provider.sh"
source "$REPO/client/libexec/devbox-config"
devbox_runfile_phase() { :; }
git() { :; }
RP_STATE="$TMP/podstate" RP_CLIENT="$TMP/podclient" ROOT="$TMP/podroot"
DEVBOX_LIB="$REPO/lib/devbox-lib.sh" DEVBOX_CONFIG="$TMP/checkout/.devbox/config.env"
DEVBOX_PROJECT=example DEVBOX_WANT_TOKENS=2 DEVBOX_MIN_TOKENS=1
DEVBOX_SETUP=: DEVBOX_VERIFY=: RUN_MODE=0 STRICT=0 OWN_EXIT=0
read -r -a REQUIRES <<<"$POD_REQUIRES"
trap 'printf "%s\n" "$OWN_EXIT" > "$TMP/own-exit"' EXIT
runpod_execute
DRIVER
# The driver reads TMP and REPO from its environment.
export TMP REPO
pod_run() {
  rm -f "$TMP/pod.log" "$TMP/own-exit"
  POD_REQUIRES="$1" POD_SSH_FAILS="${2:-0}" POD_LOG="$TMP/pod.log" POD_LIBEXEC="$REPO/client/libexec" \
    PATH="$TMP/podbin:$PATH" bash "$TMP/execute.sh" >"$TMP/pod.out" 2>"$TMP/pod.err"
}
gate_line() { grep -n -m1 -x 'runuser -u dev -- bash -se' "$TMP/pod.log" | cut -d: -f1; }
check_line() { grep -n -m1 devbox-requires-local "$TMP/pod.log" | cut -d: -f1; }

pod_run 'bash devbox-fixture-absent-tool'
assert_eq 6 "$?" 'a token the pod lacks refuses the gate with exit 6, as on a deployed target'
assert_eq 1 "$(cat "$TMP/own-exit")" 'and marks the 6 as devbox own, so strict mode maps it to 70'
assert_fail 'and the gate never ran' grep -q -x 'runuser -u dev -- bash -se' "$TMP/pod.log"
assert_ok 'the check ran as dev with every token' \
  grep -q -x 'runuser -u dev -- bash /opt/devbox/client/libexec/devbox-requires-local bash devbox-fixture-absent-tool' "$TMP/pod.log"
assert_ok 'the refusal names the unmet token' grep -q 'FAIL devbox-fixture-absent-tool' "$TMP/pod.err"
assert_ok 'and the project whose gate it refused' grep -q "refusing to run example's gate on runpod" "$TMP/pod.err"

pod_run 'bash /bin'
assert_eq 0 "$?" 'tokens the pod carries pass, and the gate runs'
assert_ok 'the check ran' test -n "$(check_line)"
assert_ok 'after the provision and before the gate' test "$(check_line)" -lt "$(gate_line)"

pod_run 'devbox-fixture-absent-tool' 1
assert_eq 255 "$?" 'an ssh that fails during the check keeps its own status'
assert_eq 0 "$(cat "$TMP/own-exit")" 'and is not marked as a refusal'

pod_run ''
assert_eq 0 "$?" 'a project with no DEVBOX_REQUIRES runs its gate'
assert_fail 'and pays no check' grep -q devbox-requires-local "$TMP/pod.log"
printf '%d %d\n' "$TESTS_RUN" "$TESTS_FAILED"
