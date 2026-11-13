#!/bin/bash
# .devbox/config.env is read as data, and the hooks built from it run in a fresh bash.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
# shellcheck source=tests/lib.sh
source ./lib.sh
REPO="$(cd .. && pwd)"
# The parser checks DEVBOX_LANES with the library's require_lanes, the rule the
# host's `lock` verb applies too, so the library is loaded first, as every
# client program loads it.
# shellcheck source=lib/devbox-lib.sh
source "$REPO/lib/devbox-lib.sh"
# shellcheck source=client/libexec/devbox-config
source "$REPO/client/libexec/devbox-config"

TMP="$(mktemp -d)" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
contains() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }

# Each case parses in a subshell, so no value leaks into the next one.
parse() {  # $1 is the file content; prints DEVBOX_PROJECT|SETUP|VERIFY|REQUIRES|RUNPOD_IMAGE
  printf '%s\n' "$1" >"$TMP/config.env"
  (
    unset DEVBOX_PROJECT DEVBOX_SETUP DEVBOX_VERIFY DEVBOX_REQUIRES
    devbox_config_parse "$TMP/config.env" || exit
    printf '%s|%s|%s|%s|%s' "$DEVBOX_PROJECT" "$DEVBOX_SETUP" "$DEVBOX_VERIFY" \
      "${DEVBOX_REQUIRES:-}" "${DEVBOX_RUNPOD_IMAGE:-}"
  )
}
BASE='DEVBOX_PROJECT=p
DEVBOX_SETUP=npm ci
DEVBOX_VERIFY=npm run verify'

assert_eq "p|npm ci|npm run verify||" "$(parse "$BASE")" "plain values are read verbatim"
assert_eq 'p|npm ci|npm run verify|jq=1.7 shellcheck|' \
  "$(parse "$BASE"$'\nDEVBOX_REQUIRES="jq=1.7 shellcheck"')" "one pair of double quotes is stripped"
assert_eq 'p|npm ci|echo "a b"||' \
  "$(parse 'DEVBOX_PROJECT=p
DEVBOX_SETUP=npm ci
DEVBOX_VERIFY='"'"'echo "a b"'"'"'')" "single quotes keep inner double quotes"
# The dollar and backquote are data under test, never expanded.
# shellcheck disable=SC2016
assert_eq 'p|npm ci|echo $HOME `id`||' \
  "$(parse 'DEVBOX_PROJECT=p
DEVBOX_SETUP=npm ci
DEVBOX_VERIFY=echo $HOME `id`')" "nothing in a value is expanded"
assert_eq "p|npm ci|npm run verify||" \
  "$(parse "  # comment"$'\n\n'"$BASE"$'\n  ')" "comments, blank lines and outer spaces are skipped"

err="$(parse "$BASE"$'\nDEVBOX_TOKENS=4' 2>&1)"; rc=$?
assert_eq "2" "$rc" "an unknown key is refused"
assert_ok "and the refusal names the line and the key" contains "config.env:4: unknown key DEVBOX_TOKENS" "$err"
err="$(parse "$BASE"$'\nDEVBOX_PROJECT=q' 2>&1)"; rc=$?
assert_eq "2" "$rc" "a key set twice is refused"
assert_ok "and the refusal says so" contains "DEVBOX_PROJECT is set twice" "$err"
err="$(parse "$BASE"$'\nDEVBOX_REQUIRES="jq' 2>&1)"; rc=$?
assert_eq "2" "$rc" "an unclosed quote is refused"
assert_ok "and the refusal says so" contains "opens a quote it does not close" "$err"
err="$(parse "$BASE"$'\nexport DEVBOX_REQUIRES=x' 2>&1)"; rc=$?
assert_eq "2" "$rc" "a shell statement is refused"
assert_ok "and the refusal names the line" contains "config.env:4 is not KEY=value" "$err"
err="$(parse $'DEVBOX_PROJECT=p\nDEVBOX_SETUP=:' 2>&1)"; rc=$?
assert_eq "2" "$rc" "a config with no DEVBOX_VERIFY is refused"
assert_ok "and the refusal names the key" contains "sets no DEVBOX_VERIFY" "$err"
err="$(DEVBOX_VERIFY=inherited parse $'DEVBOX_PROJECT=p\nDEVBOX_SETUP=:' 2>&1)"; rc=$?
assert_eq "2" "$rc" "an inherited environment value does not stand in for a missing key"

assert_eq "p|npm ci|npm run verify||fixture/image:1" \
  "$(parse "$BASE"$'\nDEVBOX_RUNPOD_IMAGE=fixture/image:1')" "the config sets a RunPod image"
assert_eq "p|npm ci|npm run verify||mine" \
  "$(DEVBOX_RUNPOD_IMAGE=mine parse "$BASE"$'\nDEVBOX_RUNPOD_IMAGE=fixture/image:1')" \
  "a developer's RunPod image wins over the config's default"

# ── DEVBOX_LANES: the workspaces one worktree may hold on each target ───────
#
# verify takes this many lane locks and gc keeps this many lanes, so both read
# it here, and an exported value never stands in for the file.
lanes() {  # $1 the file content; prints DEVBOX_LANES
  printf '%s\n' "$1" >"$TMP/config.env"
  ( unset DEVBOX_LANES; DEVBOX_LANES="${ENV_LANES-}"; devbox_config_parse "$TMP/config.env" || exit; printf '%s' "$DEVBOX_LANES" )
}
assert_eq "2" "$(lanes "$BASE")" "a config with no DEVBOX_LANES has two lanes"
assert_eq "2" "$(ENV_LANES=4 lanes "$BASE")" "and an inherited value does not stand in for the file"
for n in 1 2 3 4; do
  assert_eq "$n" "$(lanes "$BASE"$'\n'"DEVBOX_LANES=$n")" "DEVBOX_LANES=$n is read"
done
for bad in 0 5 two 2x "" -1; do
  rc=0
  err="$(lanes "$BASE"$'\n'"DEVBOX_LANES=$bad" 2>&1)" || rc=$?
  assert_eq "2" "$rc" "DEVBOX_LANES='$bad' is refused"
  assert_ok "by the library's rule, naming the key and the file" \
    contains "refusing DEVBOX_LANES '$bad' from $TMP/config.env: write a whole number of lanes from 1 to 4" "$err"
done

# ── DEVBOX_AFFINITY_GRACE is a .devbox.env key ───────────────────────────────
printf 'DEVBOX_AFFINITY_GRACE=30\n' >"$TMP/dev.env"
assert_eq "30" "$(devbox_env_load "$TMP/dev.env" && printf '%s' "$DEVBOX_AFFINITY_GRACE")" \
  "DEVBOX_AFFINITY_GRACE is read from .devbox.env"
rc=0
(printf 'DEVBOX_AFFINITY_GRACE=30\n' >"$TMP/c.env"; devbox_config_parse "$TMP/c.env") >/dev/null 2>&1 || rc=$?
assert_eq "2" "$rc" "and is no key of the project's config"

# The hooks run in a fresh bash, the way the workspace runs them.
mkdir -p "$TMP/co/.devbox"
cat >"$TMP/co/.devbox/config.env" <<'CONFIG'
DEVBOX_PROJECT=co
DEVBOX_ENVIRONMENT=export GREETING=hello
DEVBOX_SETUP=echo "setup $GREETING"
DEVBOX_VERIFY=echo verify; exit 3
CONFIG
out="$(cd "$TMP/co" && devbox_config_load && bash -c "$(devbox_hooks_script)"$'\n''devbox_environment && devbox_setup')"
assert_eq "setup hello" "$out" "setup runs after the environment hook"
rc=0
out="$(cd "$TMP/co" && devbox_config_load && bash -c "$(devbox_hooks_script)"$'\n''devbox_environment && devbox_verify')" || rc=$?
assert_eq "verify" "$out" "verify runs its command"
assert_eq "3" "$rc" "and its exit status is the gate's"
assert_eq "$TMP/co/.devbox/config.env" "$(cd "$TMP/co" && devbox_config_load && echo "$DEVBOX_CONFIG")" \
  "DEVBOX_CONFIG names the file for messages"
assert_eq ".devbox/exclude" "$(cd "$TMP/co" && devbox_config_load && echo "$DEVBOX_EXCLUDE")" \
  "the exclude list is .devbox/exclude"
assert_fail "no provision hook exists unless the config sets one" \
  bash -c "$(cd "$TMP/co" && devbox_config_load && devbox_hooks_script)"$'\n''declare -F devbox_provision'

# An older client sourced .devbox/profile.sh, with a notice on every run. This
# client refuses it by name, and never sources it: a sourced profile made every value
# code.
mkdir -p "$TMP/old/.devbox"
printf 'DEVBOX_PROJECT=old\ndevbox_setup() { echo old-setup; }\ndevbox_verify() { :; }\n' >"$TMP/old/.devbox/profile.sh"
rc=0
err="$(cd "$TMP/old" && devbox_config_load 2>&1 >/dev/null)" || rc=$?
assert_eq "2" "$rc" "an older .devbox/profile.sh is refused"
assert_ok "and the refusal says how to convert it" contains "Convert it to .devbox/config.env" "$err"
# The setup function prints a word if the profile ever runs as code.
out="$(cd "$TMP/old" && devbox_config_load 2>/dev/null; declare -F devbox_setup || true)"
assert_eq "" "$out" "and the profile is never sourced"
mkdir -p "$TMP/none"
rc=0
(cd "$TMP/none" && devbox_config_load) >/dev/null 2>&1 || rc=$?
assert_eq "2" "$rc" "a checkout with neither file is refused"

printf '%d %d\n' "$TESTS_RUN" "$TESTS_FAILED"
