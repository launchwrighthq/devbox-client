#!/bin/bash
# The runtime of a rented Hetzner server, run in a directory instead of
# on a server. HZR_ROOT moves every path it touches, and curl, iptables, systemctl
# and chpasswd are functions that record what they were asked.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
# shellcheck source=tests/lib.sh
source ./lib.sh
command -v jq >/dev/null || { echo 'install jq to test the Hetzner runtime' >&2; exit 1; }
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
HZR_ROOT="$TMP/root"
export HZR_ROOT
# shellcheck source=server/bin/devbox-hetzner-runtime
source ../server/bin/devbox-hetzner-runtime
RENTED_STATE="$HZR_ROOT/var/lib/devbox-rented"
CONF="$HZR_ROOT/etc/devbox/hetzner"
TOKEN=fixtureHcloudToken0123456789
EVENTS="$TMP/events"

NOW=100
date() { printf '%s\n' "$NOW"; }
SCENARIO=normal
curl() {
  printf '%s\n' "$*" >> "$TMP/argv"
  local destination=/dev/stdout method=GET url=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --output) destination=$2; shift 2 ;;
      --request) method=$2; shift 2 ;;
      --header) [ "${2#@}" = "$2" ] || cat "${2#@}" >> "$TMP/headers"; shift 2 ;;
      --write-out|--connect-timeout|--max-time) shift 2 ;;
      -*) shift ;;
      *) url=$1; shift ;;
    esac
  done
  case "$url" in
    */metadata/instance-id) printf '4242'; return 0 ;;
  esac
  printf 'api %s %s\n' "$method" "${url#"$HZR_API"}" >> "$EVENTS"
  if [ "$method" = DELETE ]; then printf '{"action":{}}' > "$destination"; touch "$TMP/deleted"; printf 200; return 0; fi
  case "$SCENARIO" in
    api-error) printf '{"error":{"code":"unauthorized"}}' > "$destination"; printf 401; return 0 ;;
    wrong) printf '{"server":{"id":4242,"name":"someone-else","labels":{"devbox":"rented"}}}' > "$destination" ;;
    *) jq -nc --arg name "$(cat "$CONF/owner")" '{server: {id: 4242, name: $name, labels: {devbox: "rented"}}}' > "$destination" ;;
  esac
  printf 200
}
IPTABLES_FAIL=""
iptables() {
  printf 'iptables %s\n' "$*" >> "$EVENTS"
  [ -z "$IPTABLES_FAIL" ] || return 1
  case "$*" in
    *" -L DOCKER-USER"*) [ -e "$TMP/chain" ] ;;
    *" -N DOCKER-USER"*) touch "$TMP/chain" ;;
    *" -C DOCKER-USER"*) [ -e "$TMP/rule" ] ;;
    *" -I DOCKER-USER"*) touch "$TMP/rule" ;;
  esac
}
systemctl() { printf 'systemctl %s\n' "$*" >> "$EVENTS"; }
chpasswd() { printf 'chpasswd\n' >> "$EVENTS"; cat > "$TMP/chpasswd.in"; }

reset_server() {
  rm -rf "$HZR_ROOT" "$TMP/chain" "$TMP/rule" "$TMP/deleted" "$TMP/argv" "$TMP/headers"
  : > "$EVENTS"
  mkdir -p "$CONF" "$HZR_ROOT/etc/systemd/system" "$HZR_ROOT/run/cloud-init" \
    "$HZR_ROOT/var/lib/cloud/instances/i-1/sem" "$HZR_ROOT/var/lib/cloud/instances/i-1/scripts"
  ln -s instances/i-1 "$HZR_ROOT/var/lib/cloud/instance"
  printf '%s' "$TOKEN" > "$CONF/token"
  printf 'devbox-gate:fixture-rental-password\n' > "$CONF/gate-password"
  printf 'devbox-hz-laptop-0123456789-0123456789abcdef\n' > "$CONF/owner"
  printf '60\n' > "$CONF/idle-seconds"
  for f in user-data.txt user-data.txt.i cloud-config.txt obj.pkl; do
    printf 'content %s and fixture-rental-password\n' "$TOKEN" > "$HZR_ROOT/var/lib/cloud/instance/$f"
  done
  printf 'userdata %s\n' "$TOKEN" > "$HZR_ROOT/run/cloud-init/instance-data-sensitive.json"
  printf 'a stray copy of %s\n' "$TOKEN" > "$HZR_ROOT/var/lib/cloud/instances/i-1/sem/stray"
  printf 'only the password fixture-rental-password\n' > "$HZR_ROOT/var/lib/cloud/instances/i-1/sem/other"
  printf 'runcmd\n' > "$HZR_ROOT/var/lib/cloud/instances/i-1/scripts/runcmd"
  # The host key cloud-init wrote from ssh_keys, and a copy of it that cloud-init
  # kept as JSON, with its lines joined by a literal \n.
  mkdir -p "$HZR_ROOT/etc/ssh"
  printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\nfixtureHostKeyLineOne0123456789\nfixtureHostKeyLineTwo0123456789\n-----END OPENSSH PRIVATE KEY-----\n' \
    > "$HZR_ROOT/etc/ssh/ssh_host_ed25519_key"
  printf '{"ed25519_private": "-----BEGIN OPENSSH PRIVATE KEY-----\\nfixtureHostKeyLineOne0123456789\\nfixtureHostKeyLineTwo0123456789\\n"}\n' \
    > "$HZR_ROOT/var/lib/cloud/instances/i-1/sem/hostkey-copy"
  printf 'a note that names -----BEGIN OPENSSH PRIVATE KEY----- and no key\n' > "$HZR_ROOT/var/lib/cloud/instances/i-1/scripts/note"
}

# ── boot ─────────────────────────────────────────────────────────────────────
reset_server
assert_ok 'boot completes' hzr_boot
assert_eq 4242 "$(cat "$RENTED_STATE/server-id")" 'the server id comes from the metadata service'
assert_eq 60 "$(cat "$RENTED_STATE/idle-seconds")" 'the idle time comes from the user data'
assert_eq "Authorization: Bearer $TOKEN" "$(cat "$RENTED_STATE/headers")" 'the token sits in a header file'
assert_eq 700 "$(stat -c %a "$RENTED_STATE")" 'which only root can read'
assert_ok 'the idle watcher runs as a supervised unit' grep -q 'Restart=always' "$HZR_ROOT/etc/systemd/system/devbox-hetzner-idle.service"
assert_ok 'and is enabled and started' grep -q 'systemctl enable --now devbox-hetzner-idle.service' "$EVENTS"
# A reboot removes the kernel rule, and dockerd restarts the workspaces during
# its own startup, before the watcher's first pass. The block unit runs first.
BLOCK_UNIT="$HZR_ROOT/etc/systemd/system/devbox-hetzner-block.service"
assert_ok 'a block unit runs before docker.service on every boot' grep -qx 'Before=docker.service' "$BLOCK_UNIT"
assert_ok 'and docker.service requires it, so dockerd never starts without the rule' grep -qx 'RequiredBy=docker.service' "$BLOCK_UNIT"
assert_ok 'it runs the runtime with block' grep -qx "ExecStart=/bin/bash $(readlink -f ../server/bin/devbox-hetzner-runtime) block" "$BLOCK_UNIT"
assert_ok 'and it is enabled' grep -qx 'systemctl enable devbox-hetzner-block.service' "$EVENTS"
order=$(grep -nE 'enable devbox-hetzner-block|enable --now' "$EVENTS" | cut -d: -f2 | cut -c1-22 | tr '\n' '|')
assert_eq 'systemctl enable devbo|systemctl enable --now|' "$order" 'the block unit is enabled before the watcher starts'
assert_ok 'workspaces cannot reach the metadata service' grep -q 'iptables -w -I DOCKER-USER 1 -d 169.254.169.254/32 -j DROP' "$EVENTS"
assert_eq 'devbox-gate:fixture-rental-password' "$(cat "$TMP/chpasswd.in")" 'chpasswd sets the gate password from the user data'
assert_fail 'and the password file is removed' test -e "$CONF/gate-password"
order=$(grep -nE 'enable --now|-I DOCKER-USER|^chpasswd' "$EVENTS" | cut -d: -f2 | cut -c1-12 | tr '\n' '|')
assert_eq 'systemctl en|iptables -w |chpasswd|' "$order" 'the watcher first, the metadata block next, the gate password last'
for f in user-data.txt user-data.txt.i cloud-config.txt obj.pkl; do
  assert_fail "cloud-init's $f is removed" test -e "$HZR_ROOT/var/lib/cloud/instance/$f"
done
assert_fail 'the sensitive instance data is removed' test -e "$HZR_ROOT/run/cloud-init/instance-data-sensitive.json"
assert_fail 'another file that holds the token is removed' test -e "$HZR_ROOT/var/lib/cloud/instances/i-1/sem/stray"
assert_fail 'and one that holds the gate password' test -e "$HZR_ROOT/var/lib/cloud/instances/i-1/sem/other"
assert_ok 'a file that holds neither is kept' test -e "$HZR_ROOT/var/lib/cloud/instances/i-1/scripts/runcmd"
assert_fail 'a copy of the private host key, the client pin for this server, is removed' \
  test -e "$HZR_ROOT/var/lib/cloud/instances/i-1/sem/hostkey-copy"
assert_ok 'a file that holds only the BEGIN line every key shares is kept' \
  test -e "$HZR_ROOT/var/lib/cloud/instances/i-1/scripts/note"
assert_ok 'the host key sshd uses is kept' test -s "$HZR_ROOT/etc/ssh/ssh_host_ed25519_key"
assert_ok 'the runtime keeps its own copy of the token' test -s "$CONF/token"
assert_fail 'the token never reached a curl argv' grep -qF "$TOKEN" "$TMP/argv"

# A restart of boot keeps the clock of a server that sat idle.
printf '7\n' > "$RENTED_STATE/idle-since"
assert_ok 'boot again completes' hzr_boot
assert_eq 7 "$(cat "$RENTED_STATE/idle-since")" 'and keeps the idle clock'
assert_eq 1 "$(grep -c -- '-I DOCKER-USER' "$EVENTS")" 'and inserts the metadata rule once'

reset_server
printf 'not-a-rental\n' > "$CONF/owner"
assert_fail 'boot refuses an owner name the client does not make' hzr_boot
assert_fail 'and sets no gate password' grep -q chpasswd "$EVENTS"

# ── the watch pass ───────────────────────────────────────────────────────────
reset_server
hzr_boot >/dev/null 2>&1
rm -f "$TMP/rule"
assert_ok 'a pass puts back a metadata rule that a firewall reload removed' rented_pass
assert_ok 'with the same insert' test -e "$TMP/rule"

# ── block, the unit's action after a reboot ──────────────────────────────────
reset_server
assert_ok 'block inserts the rule on a fresh kernel' hzr_main block
assert_ok 'and makes the chain dockerd has not made yet' grep -q 'iptables -w -N DOCKER-USER' "$EVENTS"
assert_ok 'with the DROP for the metadata service' grep -q 'iptables -w -I DOCKER-USER 1 -d 169.254.169.254/32 -j DROP' "$EVENTS"
assert_fail 'and touches no other part of the server' grep -qE '^(api|systemctl|chpasswd)' "$EVENTS"
: > "$EVENTS"
assert_ok 'a second block finds the rule' hzr_main block
assert_fail 'and inserts no copy' grep -q -- '-I DOCKER-USER' "$EVENTS"
rm -f "$TMP/chain" "$TMP/rule"
IPTABLES_FAIL=1
assert_fail 'a block that fails fails the unit, so docker.service does not start' hzr_main block
IPTABLES_FAIL=""

# ── idle deletion ────────────────────────────────────────────────────────────
reset_server
hzr_boot >/dev/null 2>&1
: > "$EVENTS"
printf '50\n' > "$RENTED_STATE/idle-since"
assert_ok 'keeps a server below its idle time' rented_idle_check
assert_fail 'and makes no API call' grep -q '^api' "$EVENTS"
printf '0\n' > "$RENTED_STATE/idle-since"
(
  exec 8>"$RENTED_STATE/activity.lock"
  flock -s 8
  rented_idle_check
)
assert_fail 'a gate that holds the activity lock is never deleted' test -e "$TMP/deleted"
assert_eq 100 "$(cat "$RENTED_STATE/idle-since")" 'and it starts the idle clock again'
NOW=160
assert_ok 'an idle server asks for its own deletion' rented_idle_check
assert_eq 'api GET /servers/4242
api DELETE /servers/4242' "$(cat "$EVENTS")" 'after the API confirms its name and label'
assert_ok 'and refuses new gates from then on' test -e "$RENTED_STATE/deleting"
assert_fail 'the token never reached a curl argv' grep -qF "$TOKEN" "$TMP/argv"

reset_server
hzr_boot >/dev/null 2>&1
: > "$EVENTS"
printf '0\n' > "$RENTED_STATE/idle-since"
SCENARIO=wrong
assert_fail 'a server the API names otherwise is not deleted' rented_idle_check
assert_fail 'and no DELETE is sent' grep -q DELETE "$EVENTS"
SCENARIO=api-error
assert_fail 'an API error leaves the deletion for the next pass' rented_idle_check
assert_fail 'and sends no DELETE' grep -q DELETE "$EVENTS"
SCENARIO=normal
assert_ok 'the next pass deletes the server' rented_idle_check
assert_ok 'with one DELETE' grep -q 'DELETE /servers/4242' "$EVENTS"
printf '%d %d\n' "$TESTS_RUN" "$TESTS_FAILED"
