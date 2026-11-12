#!/bin/bash
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
# shellcheck source=tests/lib.sh
source ./lib.sh
# shellcheck source=server/bin/devbox-runpod-runtime
source ../server/bin/devbox-runpod-runtime
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
RPR_STATE="$TMP/state"
# The idle clock is devbox-rented-idle's, which the runtime sourced.
RENTED_STATE="$RPR_STATE"
mkdir -p "$RPR_STATE"
printf 'ours\n' > "$RPR_STATE/pod-id"
printf 'devbox-cpu-fixture\n' > "$RPR_STATE/owner"
printf 'Authorization: Bearer pod-scoped-fixture\n' > "$RPR_STATE/headers"
printf '60\n' > "$RPR_STATE/idle-seconds"
NOW=100
date() { printf '%s\n' "$NOW"; }
SCENARIO=normal
curl() {
  printf '%s\n' "$@" > "$TMP/args"
  local destination payload
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --output) destination=$2; shift 2 ;;
      --data-binary) payload=$(cat "${2#@}"); shift 2 ;;
      *) shift ;;
    esac
  done
  printf '%s\n' "$payload" >> "$TMP/calls"
  if [ "$SCENARIO" = api-error ]; then
    printf '{"errors":[{"message":"private provider detail"}]}' > "$destination"
  elif [[ "$payload" == *SelfTerminate* ]]; then
    printf '{"data":{"podTerminate":null}}' > "$destination"
    touch "$TMP/deleted"
  elif [ "$SCENARIO" = wrong ]; then
    printf '{"data":{"pod":{"id":"another-pod","name":"someone-else"}}}' > "$destination"
  else
    printf '{"data":{"pod":{"id":"ours","name":"devbox-cpu-fixture"}}}' > "$destination"
  fi
  printf 200
}

printf '50\n' > "$RPR_STATE/idle-since"
assert_ok 'keeps a pod below its idle timeout' rented_idle_check
assert_fail 'no API call is made before the timeout' test -e "$TMP/calls"
printf '0\n' > "$RPR_STATE/idle-since"
(
  exec 8>"$RPR_STATE/activity.lock"
  flock -s 8
  rented_idle_check
)
assert_fail 'an active test is never deleted even after the idle duration' test -e "$TMP/deleted"
assert_eq 100 "$(cat "$RPR_STATE/idle-since")" 'an active test refreshes the idle clock'
NOW=159
assert_ok 'the idle interval starts after activity, not creation' rented_idle_check
assert_fail 'the full idle interval is respected after activity' test -e "$TMP/deleted"
NOW=160
assert_ok 'an expired idle pod requests its own termination' rented_idle_check
assert_ok 'termination uses the GraphQL pod mutation' grep -q SelfTerminate "$TMP/calls"
assert_fail 'the scoped key never appears in curl argv' grep -q pod-scoped-fixture "$TMP/args"
assert_fail 'new work is refused once deletion started' rented_activity true

rm -f "$TMP/deleted" "$RPR_STATE/deleting" "$TMP/calls"
SCENARIO=wrong
assert_fail 'wrong pod identity refuses self-deletion' rented_idle_check
assert_fail 'wrong pod identity never issues a termination mutation' grep -q SelfTerminate "$TMP/calls"
SCENARIO=api-error
assert_fail 'provider errors leave cleanup unconfirmed' rented_idle_check
assert_fail 'provider errors never mark the pod deleted' test -e "$TMP/deleted"
SCENARIO=normal
assert_ok 'a later watcher tick retries cleanup after an API error' rented_idle_check
assert_ok 'the retry reaches self-termination' test -e "$TMP/deleted"

rm -f "$RPR_STATE/deleting"
NOW=200
assert_fail 'a failed command preserves its exit status' rented_activity bash -c 'exit 7'
assert_eq 200 "$(cat "$RPR_STATE/idle-since")" 'failed commands also reset the idle clock on exit'
NOW=250
assert_ok 'successful activity completes normally' rented_activity true
assert_eq 250 "$(cat "$RPR_STATE/idle-since")" 'successful commands reset the idle clock on exit'
printf '%d %d\n' "$TESTS_RUN" "$TESTS_FAILED"
