#!/bin/bash
# The client schedules nothing (docs/specs/2026-11-14-learned-selection-design.md,
# D11): no timer, no age rule and no forced full run. A full run happens when a
# person asks for one, with --full or --fresh, or a config says DEVBOX_RERUN=full.
#
# A rule that ran every step after some number of hours or gates would hide a
# read the trace missed behind a clock, and make two gates of one tree plan two
# different things. This file reads the client's source, so a scheduler, a
# clock read in the files that make the plan, or a new path to a full run fails
# here before it ships.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
# shellcheck source=tests/lib.sh
source ./lib.sh
REPO="$(cd .. && pwd)"

# Print each `<file>:<line>:<text>` of the files after $1 that matches the
# extended regex $1, comment lines left out. A comment may name a timer to
# say why there is none.
code_grep() {
  local re="$1"
  shift
  grep -nHE -- "$re" "$@" | grep -vE '^[^:]+:[0-9]+:[[:space:]]*(#|//)'
}

echo "-- no scheduler anywhere in the client"
mapfile -t client_files < <(find "$REPO/client" -type f ! -name '*.md' | LC_ALL=C sort)
assert_ok "the client holds files to read" test "${#client_files[@]}" -ge 10
hits="$(code_grep 'crontab|systemd-run|launchctl|\.timer\b|\bat now\b|setInterval' "${client_files[@]}")"
assert_eq "" "$hits" "no cron entry, systemd timer, launchd job or interval timer"

echo "-- the files that make the plan read no clock"
plan_files=()
for f in "$REPO"/client/libexec/devbox-plan "$REPO"/client/libexec/devbox-steps-file \
  "$REPO"/client/libexec/devbox-record "$REPO"/client/libexec/devbox-map*; do
  [ -e "$f" ] && plan_files+=("$f")
done
assert_ok "devbox-plan, devbox-steps-file and devbox-record are there to read" test "${#plan_files[@]}" -ge 3
hits="$(code_grep '(^|[^_a-z])date( +|$)|EPOCHSECONDS|EPOCHREALTIME|systime\(|\bSECONDS\b|-mtime|-mmin|-newer|stat -c ?%[YZ]|stat -f ?%m|Date\.now|time\.time' "${plan_files[@]}")"
assert_eq "" "$hits" "no date, clock variable, file age or epoch read, so no age rule can plan a run"

echo "-- a full run comes from a person or a config"
verify="$REPO/client/libexec/devbox-verify"
assert_eq "2" "$(code_grep 'rerun_flag full' "$verify" | grep -c .)" "verify sets the full flag in two places"
assert_eq "2" "$(code_grep 'rerun_flag full' "$verify" | grep -cE ':[0-9]+:[[:space:]]*--(full|fresh)\) ')" \
  "and both are the --full and --fresh arms of the arguments"
assert_eq "1" "$(code_grep '\brerun=full\b' "$verify" | grep -c .)" "verify forces full in one other place"
line="$(code_grep '\brerun=full\b' "$verify" | cut -d: -f2)"
assert_ok "and that place is the manifest that could not be read, where nothing can carry" \
  test "$(sed -n "$((line - 1))p" "$verify" | tr -d '[:space:]')" = STEPS_NO_MANIFEST=1
hits="$(code_grep '(^|[[:space:];])(RERUN_FLAG|DEVBOX_RERUN[A-Z_]*)=["'"'"']?full' "${client_files[@]}")"
assert_eq "" "$hits" "no code assigns full to the rerun setting"
# The one reader of the setting takes the flag, the environment and the
# config, then the default `changed`, and nothing else.
body="$(awk '/^devbox_rerun_setting\(\)/ { on = 1 } on { print } on && /^}/ { exit }' "$REPO/client/libexec/devbox-plan")"
assert_ok "devbox_rerun_setting starts from changed" grep -qF 'local value=changed' <<<"$body"
assert_eq "RERUN_FLAG DEVBOX_RERUN_ENV DEVBOX_RERUN_CONFIG" \
  "$(grep -oE '\$\{(RERUN_FLAG|DEVBOX_[A-Z_]+):-\}' <<<"$body" | sed 's/^\${//; s/:-}$//' | tr '\n' ' ' | sed 's/ $//')" \
  "and reads the flag, the environment and the config, in that order, and no other source"

printf '%d %d\n' "$TESTS_RUN" "$TESTS_FAILED"
