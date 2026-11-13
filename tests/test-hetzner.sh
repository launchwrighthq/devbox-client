#!/bin/bash
# The rented Hetzner target on the laptop: client/libexec/devbox-hetzner,
# reached through the real devbox-verify, against a Hetzner API and a server that
# do not exist.
#
# A fake curl plays the API from a state directory, and a fake ssh plays the
# server's gate account, so a whole run creates a server, waits for it, runs the
# gate there and deletes the server on `devbox hetzner down`. The test proves the
# properties a person cannot see: HCLOUD_TOKEN never reaches an argv, the gate
# password of the deployed targets never reaches the user data, a deletion is
# confirmed by a later not-found read, and every refusal keeps its strict code.
# The server addresses are in 203.0.113.0/24, the range RFC 5737 reserves for
# documentation.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
# shellcheck source=tests/lib.sh
source ./lib.sh
# shellcheck source=tests/gate-stub-hold.sh
source ./gate-stub-hold.sh
command -v jq >/dev/null || { echo 'install jq to test the Hetzner provider' >&2; exit 1; }
REPO="$(cd .. && pwd)"
LIB="$REPO/lib/devbox-lib.sh"
# shellcheck source=lib/devbox-lib.sh
source "$LIB"
TMP="$(mktemp -d)" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
contains() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }
PROTO="$DEVBOX_PROTOCOL_VERSION"
FP="$(sha256sum <"$LIB" | cut -d' ' -f1)"

TOKEN=fixtureHcloudToken0123456789
FLEET_PW=fixture-fleet-password-never-in-user-data
API="$TMP/api"
ARGV_LOG="$TMP/argv.log"
SSH_LOG="$TMP/ssh.log"
export API ARGV_LOG SSH_LOG
export FAKE_VERSION="$PROTO $FP"
mkdir -p "$TMP/bin" "$TMP/fakehome" "$TMP/run" "$TMP/lanes"
export FAKE_LANES="$TMP/lanes"

# ── the fake API ─────────────────────────────────────────────────────────────
cat >"$TMP/bin/curl" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >>"$ARGV_LOG"
method=GET; out=/dev/stdout; body=""; url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --request) method="$2"; shift 2 ;;
    --output) out="$2"; shift 2 ;;
    --header) cat "${2#@}" >>"$API/headers"; shift 2 ;;
    --data-binary) body="$(cat "${2#@}")"; shift 2 ;;
    --write-out|--connect-timeout|--max-time) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
path="${url#https://api.hetzner.cloud/v1}"
printf '%s %s\n' "$method" "${path%%\?*}" >>"$API/calls"
answer() { printf '%s' "$1" >"$out"; }
if [ -e "$API/refuse-token" ]; then answer '{"error":{"code":"unauthorized","message":"secret detail"}}'; printf 401; exit 0; fi
# The three types of the default list, each with its disk in GB and a gross nbg1
# price of its own, so a test can tell which type a record's price came from.
type_disk() { case "$1" in cx43) echo 160 ;; ccx33) echo 240 ;; ccx43) echo 360 ;; esac; }
type_gross() { case "$1" in cx43) echo 0.0200000000 ;; ccx33) echo 0.0600000000 ;; *) echo 0.0988000000 ;; esac; }
server() {  # $1 the id
  local ip="203.0.113.$(( $1 - 700 ))" type
  type="$(cat "$API/type-$1" 2>/dev/null || echo ccx43)"
  jq -nc --argjson id "$1" --arg name "$(cat "$API/name-$1")" --arg ip "$ip" --arg status "${2:-running}" \
    --arg type "$type" --arg gross "$(type_gross "$type")" \
    '{server: {id: $id, name: $name, status: $status, labels: {devbox: "rented"}, public_net: {ipv4: {ip: $ip}},
      server_type: {name: $type, prices: [{location: "hel1", price_hourly: {net: "0.1000000000", gross: "0.1190000000"}},
        {location: "nbg1", price_hourly: {net: "0.0830000000", gross: $gross}}]}}}'
}
code=200
case "$method $path" in
  "GET /images?"*)
    answer "$(jq -nc --arg ids "$(cat "$API/images" 2>/dev/null)" --arg disk "$(cat "$API/disk" 2>/dev/null || echo 160)" \
      '{images: [$ids | split(" ")[] | select(. != "")
      | {id: tonumber, type: "snapshot", status: "available", created: ("2026-11-0" + . [-1:] + "T00:00:00+00:00"),
         disk_size: ($disk | tonumber), labels: {devbox: "workspace"}}]}')" ;;
  "GET /server_types?name="*)
    name="${path#*name=}"
    answer "$(jq -nc --arg name "$name" --arg disk "$(type_disk "$name")" \
      '{server_types: (if $disk == "" then [] else [{name: $name, disk: ($disk | tonumber)}] end)}')" ;;
  "POST /servers")
    # A type named in $API/unavailable answers as Hetzner does when it has no
    # capacity for that type in the location.
    type="$(jq -r .server_type <<<"$body")"
    printf '%s\n' "$type" >>"$API/tried"
    if grep -qx "$type" "$API/unavailable" 2>/dev/null; then
      answer '{"error":{"code":"resource_unavailable","message":"server type unavailable"}}'; printf 412; exit 0
    fi
    if [ -e "$API/refuse-create" ]; then answer '{"error":{"code":"invalid_input","message":"secret detail"}}'; printf 422; exit 0; fi
    id=$(( $(cat "$API/next" 2>/dev/null || echo 700) + 1 )); echo "$id" >"$API/next"
    printf '%s' "$body" >"$API/request-$id.json"
    jq -r .name <<<"$body" >"$API/name-$id"
    printf '%s' "$type" >"$API/type-$id"
    code=201; answer "$(server "$id" initializing)" ;;
  "GET /servers?name="*)
    name="${path#*name=}"; found='[]'
    for f in "$API"/name-*; do
      [ -e "$f" ] && [ "$(cat "$f")" = "$name" ] && [ ! -e "$API/deleted-${f##*-}" ] && found="[$(server "${f##*-}" | jq -c .server)]"
    done
    answer "{\"servers\":$found}" ;;
  "GET /servers/"*)
    id="${path#/servers/}"
    if [ -e "$API/deleted-$id" ] || [ ! -e "$API/name-$id" ]; then code=404; answer '{"error":{"code":"not_found"}}'
    else answer "$(server "$id")"; fi ;;
  "DELETE /servers/"*)
    id="${path#/servers/}"
    [ -e "$API/stuck" ] || touch "$API/deleted-$id"
    answer '{"action":{"id":1}}' ;;
  *) code=500; answer '{"error":{"code":"unexpected_call"}}' ;;
esac
printf '%s' "$code"
STUB

# ── the fake server: the gate account of a deployed devbox ───────────────────
#
# A probe that finds $API/selfdelete answers as gate-root does on a server whose
# runtime started its own deletion, and the server is then gone from the API.
{
  printf '#!/bin/bash\n'
  cat <<'PRE'
[ -z "${SSH_LOG-}" ] || printf '%s\n' "$*" >>"$SSH_LOG"
case " $* " in *" -f -N "*) printf '%s\n' "${DEVBOX_GATE_PASSWORD-}" >>"$API/passwords" ;; esac
if [ -e "$API/selfdelete" ] && [[ " $* " == *" probe "* ]]; then
  rm -f "$API/selfdelete"; touch "$API/deleted-$(cat "$API/next")"
  echo "devbox: this rented Hetzner server is being deleted; retry the command to rent another" >&2
  exit 75
fi
PRE
  gate_stub_prelude
  gate_stub_hold
  cat <<'STUB'
case "$GATE_CMD" in
  version) printf '%s\n' "$FAKE_VERSION" ;;
  "queue-estimate "*) printf 'now 0 3 0/20 0/4 0\n' ;;
  "ensure-workspace "*) printf 'postgresql://fixture:fixture@fixture/fixture\n' ;;
  "lock "*) _hold_lock ;;
  "run "*) _hold_run; cat >/dev/null; printf 'GATE RAN ON %s\n' "$GATE_HOST" ;;
esac
exit 0
STUB
} >"$TMP/bin/ssh"
printf '#!/bin/bash\nexit 0\n' >"$TMP/bin/rsync"
chmod +x "$TMP/bin/curl" "$TMP/bin/ssh" "$TMP/bin/rsync"
gate_stub_keyscan "$TMP/bin"

CO="$TMP/checkout"
mkdir -p "$CO/.devbox"
git -C "$CO" init -q >/dev/null 2>&1
: >"$CO/.devbox/exclude"
printf 'DEVBOX_PROJECT=hetzner-fixture\nDEVBOX_WANT_TOKENS=2\nDEVBOX_MIN_TOKENS=1\nDEVBOX_SETUP=:\nDEVBOX_VERIFY=echo LOCAL GATE RAN\n' \
  >"$CO/.devbox/config.env"
STATE="$CO/.git/devbox-hetzner"
write_env() { printf '%s\n' "$@" >"$CO/.devbox.env"; }
reset_api() { rm -rf "$API" "$STATE"; mkdir -p "$API"; printf '41 42' >"$API/images"; : >"$ARGV_LOG"; : >"$SSH_LOG"; }
devbox() {
  rc=0
  out="$(cd "$CO" && env PATH="$TMP/bin:$PATH" HOME="$TMP/fakehome" XDG_RUNTIME_DIR="$TMP/run" DEVBOX_LOCK_WAIT=5 \
    DEVBOX_HETZNER_POLL_SECONDS=0 DEVBOX_HETZNER_READY_SECONDS="${READY:-30}" bash "$REPO/client/bin/devbox" "$@" 2>&1)" || rc=$?
}
calls() { cat "$API/calls" 2>/dev/null; }
record() { jq -r "$1" "$STATE/server.json" 2>/dev/null; }

# ── names ────────────────────────────────────────────────────────────────────
(
  # Not followed: the provider's own locals (rc among them) would read as this
  # file's variables changed in a subshell, and the subshell is here to keep them apart.
  # shellcheck source=/dev/null
  source "$REPO/client/libexec/devbox-hetzner"
  # shellcheck disable=SC2317  # called by rented_name in the sourced provider, which the linter does not follow here
  devbox_machine_label() { printf 'dev-laptop'; }
  # shellcheck disable=SC2317  # called by rented_name in the sourced provider, which the linter does not follow here
  devbox_machine_id() { printf '11111111111111111111111111111111'; }
  name="$(hetzner_name)"
  assert_ok "a server name carries the laptop label" test "${name:0:19}" = devbox-hz-dev-lapt-
  assert_ok "and passes the ownership check" hetzner_owner_name "$name"
  assert_ok "and fits a 63-character hostname label" test "${#name}" -le 63
  assert_fail "another provider's name is not owned" hetzner_owner_name devbox-cpu-dev-lapt-0123456789-0123456789abcdef
  printf '%d %d\n' "$TESTS_RUN" "$TESTS_FAILED" >"$TMP/sub.counts"
)
read -r sub_run sub_failed <"$TMP/sub.counts"
TESTS_RUN=$((TESTS_RUN + sub_run)); TESTS_FAILED=$((TESTS_FAILED + sub_failed))

# ── rule 4: DEVBOX_RENT=hetzner creates a server and runs the gate there ──────
reset_api
write_env DEVBOX_RENT=hetzner "HCLOUD_TOKEN=$TOKEN" "DEVBOX_GATE_PASSWORD=$FLEET_PW" DEVBOX_HETZNER_IDLE_SECONDS=900
devbox verify
assert_eq 0 "$rc" "DEVBOX_RENT=hetzner runs the gate on a new server"
assert_ok "the rental is named" contains "==> devbox: renting hetzner: no deployed target can take this gate" "$out"
assert_ok "the gate ran on the server's address" contains "GATE RAN ON 203.0.113.1" "$out"
assert_ok "through the gate transport, as devbox-gate" grep -q 'devbox-gate@203.0.113.1 run ' "$SSH_LOG"
assert_eq "GET /images
GET /server_types
POST /servers" "$(calls)" "the API is asked for the newest snapshot, the first type's disk, then for one server"
REQ="$API/request-701.json"
assert_eq "42 cx43 nbg1 rented" "$(jq -r '[.image, .server_type, .location, .labels.devbox] | join(" ")' "$REQ")" \
  "from the newest devbox=workspace snapshot, with the first type of the default list and the default location"
assert_eq "cx43" "$(record .serverType)" "the record names the type that was created"
assert_eq "0.02 EUR" "$(record '"\(.hourly) \(.currency)"')" \
  "the record keeps the gross hourly price of its own location from the create answer, in EUR"
UD="$(jq -r .user_data "$REQ")"
assert_ok "the user data is a cloud-config" test "${UD%%$'\n'*}" = "#cloud-config"
CONFIG_JSON="$(sed 1d <<<"$UD")"
assert_eq "/bin/bash /usr/local/libexec/devbox/devbox-hetzner-runtime boot" "$(jq -r '.runcmd[0] | join(" ")' <<<"$CONFIG_JSON")" \
  "cloud-init runs the runtime once"
assert_eq "0600 $TOKEN" "$(jq -r '.write_files[] | select(.path == "/etc/devbox/hetzner/token") | .permissions + " " + .content' <<<"$CONFIG_JSON")" \
  "the token lands in a root-only file"
pw_line="$(jq -r '.write_files[] | select(.path == "/etc/devbox/hetzner/gate-password") | .content' <<<"$CONFIG_JSON")"
assert_eq "devbox-gate:$(cat "$STATE/gate-password")" "${pw_line%$'\n'}" "chpasswd gets the server's own gate password"
assert_fail "the deployed targets' gate password is not in the user data" grep -qF "$FLEET_PW" "$REQ"
assert_eq "900" "$(jq -r '.write_files[] | select(.path == "/etc/devbox/hetzner/idle-seconds") | .content' <<<"$CONFIG_JSON" | tr -d '\n')" \
  "the idle time comes from DEVBOX_HETZNER_IDLE_SECONDS"
assert_eq "$(base64 -w0 <"$REPO/server/bin/devbox-hetzner-runtime")" \
  "$(jq -r '.write_files[] | select(.path == "/usr/local/libexec/devbox/devbox-hetzner-runtime") | .content' <<<"$CONFIG_JSON")" \
  "the runtime ships in the user data, from this client"
assert_eq "$(cut -d' ' -f1,2 "$STATE/hostkey.pub")" "$(jq -r '.ssh_keys.ed25519_public' <<<"$CONFIG_JSON" | cut -d' ' -f1,2)" \
  "the host key the client made is the server's"
assert_eq "203.0.113.1 $(cut -d' ' -f1,2 "$STATE/hostkey.pub")" "$(cat "$STATE/known_hosts")" "and the only key ssh accepts there"
assert_ok "ssh refuses any other key, even at the first contact" grep -q "StrictHostKeyChecking=yes" "$SSH_LOG"
assert_ok "with the rental's own known_hosts" grep -qF "UserKnownHostsFile=$STATE/known_hosts" "$SSH_LOG"
assert_fail "the private host key does not stay on the laptop" test -e "$STATE/hostkey"
# The pin of a rental is the fingerprint of the key the client made and sent,
# so the server is held to it like a deployed target to its HOSTKEY line, and
# no first contact over the network decides it.
(umask 077; jq -r '.ssh_keys.ed25519_private' <<<"$CONFIG_JSON" >"$TMP/ud-hostkey")
assert_eq "$(cut -d' ' -f1,2 "$STATE/hostkey.pub")" "$(ssh-keygen -y -f "$TMP/ud-hostkey" | cut -d' ' -f1,2)" \
  "the user data carries the private half of that key"
assert_eq "true []" "$(jq -c '[.ssh_deletekeys, .ssh_genkeytypes] | .[]' <<<"$CONFIG_JSON" | tr '\n' ' ' | sed 's/ $//')" \
  "and cloud-init deletes the image's keys and makes no other, so no other host key answers"
PIN_HZ="$(ssh-keygen -lf "$STATE/hostkey.pub" | cut -d' ' -f2)"
assert_eq "$PIN_HZ" "$(record '.hostKey')" "the record's pin is the fingerprint of that key"
assert_eq "$PIN_HZ" "$(ssh-keygen -lf "$TMP/ud-hostkey" | cut -d' ' -f2)" "  which is the key the server received"
UD_KEY_LINE="$(sed -n 2p "$TMP/ud-hostkey")"
rm -f "$TMP/ud-hostkey"
assert_fail "the private host key never reaches a curl argv" grep -qF "$UD_KEY_LINE" "$ARGV_LOG"
assert_fail "or an ssh argv" grep -qF "$UD_KEY_LINE" "$SSH_LOG"
assert_fail "neither does the request" test -e "$STATE/request.json"
assert_eq "$(cat "$STATE/gate-password")" "$(sort -u "$API/passwords")" "ssh logs in with the server's password, never the fleet's"
assert_fail "HCLOUD_TOKEN never reaches a curl argv" grep -qF "$TOKEN" "$ARGV_LOG"
assert_fail "or an ssh argv" grep -qF "$TOKEN" "$SSH_LOG"
assert_ok "it reaches curl in a header file" grep -qF "Bearer $TOKEN" "$API/headers"
assert_eq "600" "$(stat -c %a "$STATE/gate-password")" "the rental's password is mode 0600"
assert_fail "a rented target is never recorded for affinity" test -e "$CO/.git/devbox/last-target"
assert_eq "701 203.0.113.1 false" "$(record '[.id, .ip, .deleted // false] | map(tostring) | join(" ")')" "the record names the server"

# ── reuse ────────────────────────────────────────────────────────────────────
# A record whose pin is not the fingerprint of its key is refused before any
# ssh: the known_hosts line is written from the key, and the pin is the check.
cp "$STATE/server.json" "$TMP/record.keep"
jq --arg pin "$GATE_STUB_OTHER_PIN" '.hostKey = $pin' "$TMP/record.keep" >"$STATE/server.json"
: >"$SSH_LOG"
devbox verify
assert_eq 2 "$rc" "a record whose pin is not its host key's fingerprint is refused"
assert_ok "and the refusal says to delete the rental" contains "is not the fingerprint of $STATE/hostkey.pub; run devbox hetzner down" "$out"
assert_fail "and no ssh reached the server" grep -q 'devbox-gate@' "$SSH_LOG"
cp "$TMP/record.keep" "$STATE/server.json"
: >"$API/calls"
devbox verify
assert_eq 0 "$rc" "the next run reuses the server"
assert_eq "GET /servers/701" "$(calls)" "with one read and no create"
assert_ok "and says so" contains "Hetzner server 701 at 203.0.113.1: reused" "$out"

# ── a server that deleted itself ─────────────────────────────────────────────
touch "$API/deleted-701"
: >"$API/calls"
devbox verify
assert_eq 0 "$rc" "a run after the idle deletion creates a new server"
assert_eq "GET /servers/701
GET /servers/701
GET /images
GET /server_types
POST /servers" "$(calls)" "after a not-found read confirms the old one is gone"
assert_ok "the gate ran on the new one" contains "GATE RAN ON 203.0.113.2" "$out"

# A server that answers that it is deleting itself is waited out, then replaced.
touch "$API/selfdelete"
: >"$API/calls"
devbox verify
assert_eq 0 "$rc" "a server that is deleting itself is replaced"
assert_ok "and the run says so" contains "is deleting itself after its idle time; creating another" "$out"
assert_ok "the gate ran on the next one" contains "GATE RAN ON 203.0.113.3" "$out"

# ── devbox hetzner status, down, up ──────────────────────────────────────────
devbox hetzner status
assert_eq 0 "$rc" "devbox hetzner status exits 0"
assert_ok "and names the server and its state" contains "Hetzner server 703 is running at 203.0.113.3" "$out"
: >"$API/calls"
devbox hetzner down
assert_eq 0 "$rc" "devbox hetzner down exits 0"
assert_eq "GET /servers/703
DELETE /servers/703
GET /servers/703" "$(calls)" "an ownership read, the delete, then a not-found read"
assert_eq true "$(record .deleted)" "the record says deleted only after that read"
assert_fail "and the server's gate password is gone from the laptop" test -e "$STATE/gate-password"
devbox hetzner down
assert_eq 0 "$rc" "a second down has nothing to do"

: >"$API/calls"; : >"$SSH_LOG"
devbox hetzner up
assert_eq 0 "$rc" "devbox hetzner up creates a server"
assert_ok "and runs no gate" contains "no gate ran" "$out"
assert_fail "no gate verb was sent" grep -q ' run ' "$SSH_LOG"

touch "$API/stuck"
: >"$API/calls"
devbox hetzner down
assert_eq 1 "$rc" "a delete that the API never confirms fails"
assert_ok "and says so" contains "deletion not yet confirmed" "$out"
assert_eq false "$(record '.deleted // false')" "and the record is not marked deleted"
rm -f "$API/stuck"
devbox hetzner down
assert_eq 0 "$rc" "a later down confirms it"

# ── --target hetzner beside deployed targets ─────────────────────────────────
write_env DEVBOX_TARGETS=lan1 DEVBOX_TARGET_LAN1=lan1.invalid "DEVBOX_TARGET_LAN1_HOSTKEY=$GATE_STUB_PIN" "DEVBOX_GATE_PASSWORD=$FLEET_PW" "HCLOUD_TOKEN=$TOKEN"
: >"$SSH_LOG"
devbox verify --target hetzner
assert_eq 0 "$rc" "--target hetzner runs on a rented server"
assert_fail "and never opens a connection to the deployed target" grep -qE -- "-f -N .*devbox-gate@lan1.invalid|devbox-gate@lan1.invalid (probe|run) " "$SSH_LOG"
assert_ok "and names why" contains "the rented Hetzner server of this checkout" "$out"
devbox hetzner down

# ── refusals, plain and strict ───────────────────────────────────────────────
write_env DEVBOX_RENT=hetzner "HCLOUD_TOKEN=$TOKEN"
reset_api
: >"$API/images"
devbox verify
assert_eq 2 "$rc" "a project with no devbox=workspace snapshot is refused"
assert_ok "and the refusal names the snapshot builder" contains "The operator of the server half builds one." "$out"
assert_eq "GET /images" "$(calls)" "before any server is created"
DEVBOX_STRICT=1 devbox verify
assert_eq 66 "$rc" "strict mode: a missing snapshot is a refused configuration (66)"

reset_api
touch "$API/refuse-token"
devbox verify
assert_eq 1 "$rc" "a token the API refuses fails the run"
assert_ok "and names the HTTP status and the error code" contains "devbox hetzner: GET /images: HTTP 401 (unauthorized)" "$out"
assert_fail "and never the response body" contains "secret detail" "$out"
DEVBOX_STRICT=1 devbox verify
assert_eq 65 "$rc" "strict mode: an API failure is devbox's own failure (65)"

reset_api
: >"$API/passwords"
printf '#!/bin/bash\ncase " $* " in *" -f -N "*) echo "devbox-gate@x: Permission denied (password)." >&2; exit 255 ;; esac\nexec %q "$@"\n' \
  "$TMP/bin/ssh" >"$TMP/ssh-refused"
mkdir -p "$TMP/refused"; cp "$TMP/ssh-refused" "$TMP/refused/ssh"; chmod +x "$TMP/refused/ssh"
rc=0
out="$(cd "$CO" && env PATH="$TMP/refused:$TMP/bin:$PATH" HOME="$TMP/fakehome" XDG_RUNTIME_DIR="$TMP/run" \
  DEVBOX_HETZNER_POLL_SECONDS=0 DEVBOX_HETZNER_READY_SECONDS=0 bash "$REPO/client/bin/devbox" verify 2>&1)" || rc=$?
assert_eq 3 "$rc" "a server that never takes its gate password fails the run with 3"
assert_ok "and names the wait" contains "did not become ready in 0s" "$out"
assert_ok "the server this run created is deleted" grep -q 'DELETE /servers/701' "$API/calls"
assert_eq true "$(record .deleted)" "and that delete is confirmed"
rc=0
out="$(cd "$CO" && env PATH="$TMP/refused:$TMP/bin:$PATH" HOME="$TMP/fakehome" XDG_RUNTIME_DIR="$TMP/run" DEVBOX_STRICT=1 \
  DEVBOX_HETZNER_POLL_SECONDS=0 DEVBOX_HETZNER_READY_SECONDS=0 bash "$REPO/client/bin/devbox" verify 2>&1)" || rc=$?
assert_eq 67 "$rc" "strict mode: a server that never answers is an unreachable target (67)"

# A server whose sshd takes the password and whose gate then stalls is not
# ready. The wait set its probe limit in front of the function call, so the
# test of timeout's own status read the global empty limit, a killed probe was
# taken as an answer, and the server was announced ready.
reset_api
write_env DEVBOX_RENT=hetzner "HCLOUD_TOKEN=$TOKEN"
rc=0
out="$(cd "$CO" && env PATH="$TMP/bin:$PATH" HOME="$TMP/fakehome" XDG_RUNTIME_DIR="$TMP/run" \
  FAKE_STALL=203.0.113.1 FAKE_STALL_VERB=probe DEVBOX_PROBE_ANSWER_SECONDS=1 \
  DEVBOX_HETZNER_POLL_SECONDS=0 DEVBOX_HETZNER_READY_SECONDS=2 bash "$REPO/client/bin/devbox" verify 2>&1)" || rc=$?
assert_eq 3 "$rc" "a server whose probe stalls after the login fails the run with 3"
assert_ok "and names the wait and the probe" contains "did not become ready in 2s: its probe gave no answer" "$out"
assert_fail "it is never announced ready" contains ": ready" "$out"
assert_ok "and the server this run created is deleted" grep -q 'DELETE /servers/701' "$API/calls"

reset_api
write_env DEVBOX_TARGETS=lan1 DEVBOX_TARGET_LAN1=lan1.invalid "DEVBOX_TARGET_LAN1_HOSTKEY=$GATE_STUB_PIN" "DEVBOX_GATE_PASSWORD=$FLEET_PW"
devbox verify --target hetzner
assert_eq 2 "$rc" "--target hetzner with no HCLOUD_TOKEN is refused"
assert_ok "and the refusal names the key" contains "HCLOUD_TOKEN is missing" "$out"
assert_eq "" "$(calls)" "with no API call"
write_env DEVBOX_RENT=hetzner "HCLOUD_TOKEN=$TOKEN" DEVBOX_HETZNER_IDLE_SECONDS=28801
devbox verify
assert_eq 2 "$rc" "an idle time over 8 hours is refused"
DEVBOX_STRICT=1 devbox verify
assert_eq 66 "$rc" "strict mode: 66"
write_env DEVBOX_RENT=hetzner "HCLOUD_TOKEN=$TOKEN" "DEVBOX_HETZNER_SERVER_TYPE=ccx43;id"
devbox verify
assert_eq 2 "$rc" "a server type that is not a name is refused"
assert_eq "" "$(calls)" "and reaches no API call"
write_env DEVBOX_RENT=hetzner "HCLOUD_TOKEN=$TOKEN" "DEVBOX_HETZNER_SERVER_TYPE=cx43,,ccx43"
devbox verify
assert_eq 2 "$rc" "a list with an empty element is refused"
write_env DEVBOX_RENT=hetzner "HCLOUD_TOKEN=$TOKEN" "DEVBOX_HETZNER_SERVER_TYPE=cx43,ccx43;id"
devbox verify
assert_eq 2 "$rc" "every element of the list is checked, the last one too"
assert_ok "and the refusal names the list form" contains "is not a comma-separated list of Hetzner server types" "$out"
assert_eq "" "$(calls)" "and reaches no API call"

# ── the server type list ─────────────────────────────────────────────────────
# Hetzner answers a create with HTTP 412 resource_unavailable when a type has no
# capacity in the location. The client then tries the next type of the list.
reset_api
write_env DEVBOX_RENT=hetzner "HCLOUD_TOKEN=$TOKEN"
printf 'cx43\n' >"$API/unavailable"
devbox verify
assert_eq 0 "$rc" "a type with no capacity passes the rental to the next type"
assert_eq "cx43
ccx33" "$(cat "$API/tried")" "the default list is tried in its order"
assert_ok "the move is said in one line" \
  contains "==> Hetzner server type cx43 has no capacity in nbg1 (HTTP 412 resource_unavailable); trying ccx33" "$out"
assert_fail "with no error line from the API call" contains "HTTP 412 (resource_unavailable)" "$out"
assert_eq "ccx33 ccx33 0.06" "$(jq -r .server_type "$API/request-701.json") $(record '"\(.serverType) \(.hourly)"')" \
  "the server, the record and its price are the type that was created"
assert_ok "the run names that type" contains "==> Hetzner server 701: ccx33 in nbg1" "$out"
assert_ok "the gate ran on it" contains "GATE RAN ON 203.0.113.1" "$out"
devbox hetzner down

# A type whose disk is smaller than the snapshot's cannot boot it, so it is
# skipped before any create is sent for it.
reset_api
printf '200' >"$API/disk"
devbox verify
assert_eq 0 "$rc" "a type whose disk is smaller than the snapshot is skipped"
assert_eq "ccx33" "$(cat "$API/tried")" "and no create is sent for it"
assert_ok "the skip is said in one line" \
  contains "==> Hetzner server type cx43 skipped: its 160 GB disk is smaller than the 200 GB of snapshot 42" "$out"
assert_eq "ccx33" "$(record .serverType)" "the next type that holds the snapshot is created"
devbox hetzner down

# Every type refused: no server exists, the record says so, and the message
# names each type and its reason.
reset_api
printf '300' >"$API/disk"
printf 'ccx43\n' >"$API/unavailable"
devbox verify
assert_eq 1 "$rc" "a list whose every type is refused fails the run"
assert_ok "and names each type and its reason" \
  contains "devbox hetzner: no server type of DEVBOX_HETZNER_SERVER_TYPE could be created in nbg1: cx43: a 160 GB disk, smaller than the snapshot's 300 GB; ccx33: a 240 GB disk, smaller than the snapshot's 300 GB; ccx43: no capacity in nbg1" "$out"
assert_fail "the last type's line promises no next type" contains "nbg1 (HTTP 412 resource_unavailable); trying" "$out"
assert_eq "ccx43" "$(cat "$API/tried")" "one create was sent, for the one type that holds the snapshot"
assert_eq "true false" "$(record '"\(.deleted) \(.createUncertain)"')" "the record says no server exists"
assert_fail "and the unused gate password is gone" test -e "$STATE/gate-password"
assert_fail "no delete is sent for a server that was never created" grep -q '^DELETE' "$API/calls"
DEVBOX_STRICT=1 devbox verify
assert_eq 65 "$rc" "strict mode: no capacity on every type is the API's answer (65)"
: >"$API/unavailable"
devbox verify
assert_eq 0 "$rc" "the next run is not held by the refused one, and creates a server"
devbox hetzner down

reset_api
printf '400' >"$API/disk"
devbox verify
assert_eq 2 "$rc" "a list with no type that holds the snapshot is a setting, refused with 2"
assert_eq "" "$(cat "$API/tried" 2>/dev/null)" "and no create is sent"

reset_api
write_env DEVBOX_RENT=hetzner "HCLOUD_TOKEN=$TOKEN" "DEVBOX_HETZNER_SERVER_TYPE=cx99,ccx43"
devbox verify
assert_eq 0 "$rc" "a type Hetzner does not list is skipped"
assert_ok "with a line that names it" contains "==> Hetzner server type cx99 skipped: Hetzner lists no such server type" "$out"
assert_eq "ccx43" "$(record .serverType)" "and the next type is created"
devbox hetzner down

# Any other refusal of a create stops the rental, as with one type.
reset_api
write_env DEVBOX_RENT=hetzner "HCLOUD_TOKEN=$TOKEN"
printf 'cx43\n' >"$API/unavailable"
touch "$API/refuse-create"
devbox verify
assert_eq 1 "$rc" "a create refused for another reason stops the rental"
assert_ok "and names the API's answer" contains "devbox hetzner: POST /servers: HTTP 422 (invalid_input)" "$out"
assert_eq "cx43
ccx33" "$(cat "$API/tried")" "and tries no type after it"

# Two runs of one checkout must not both create a server: the second waits on
# up.lock, and gives up after DEVBOX_HETZNER_LOCK_SECONDS (900 by default).
reset_api
write_env DEVBOX_RENT=hetzner "HCLOUD_TOKEN=$TOKEN"
mkdir -p "$STATE"
exec 9>"$STATE/up.lock"
flock -x 9
DEVBOX_HETZNER_LOCK_SECONDS=1 devbox verify
assert_eq 4 "$rc" "a creation that another run of this checkout holds fails the run with 4"
assert_ok "and names the wait" contains "another run of this checkout held the creation for 1s; nothing ran" "$out"
assert_eq "" "$(calls)" "and makes no API call, so no second server is created"
DEVBOX_STRICT=1 DEVBOX_HETZNER_LOCK_SECONDS=0 devbox verify
assert_eq 68 "$rc" "strict mode: a held creation is devbox's own lock (68)"
exec 9>&-
DEVBOX_HETZNER_LOCK_SECONDS=1 devbox verify
assert_eq 0 "$rc" "once the other run lets go, the run creates the server"
assert_ok "with one create" test "$(grep -c 'POST /servers' "$API/calls")" = 1
devbox hetzner down
printf '%d %d\n' "$TESTS_RUN" "$TESTS_FAILED"
