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

# ── the four keys of the client-owned gate (spec section 4.1) ────────────────
#
# Each prints RERUN_CONFIG|RERUN|SETUP_INPUTS|SHARED_INPUTS|LOCAL_GATE, where
# RERUN is DEVBOX_RERUN as this shell sees it, a slash, then as a child bash
# sees it, each <unset> when it is not there. A refusal prints RERUN on stderr.
# ENV_* stand in for what an earlier shell exported.
newkeys() {  # $1 the file content
  printf '%s\n' "$1" >"$TMP/config.env"
  (
    unset DEVBOX_RERUN DEVBOX_RERUN_CONFIG DEVBOX_SETUP_INPUTS DEVBOX_SHARED_INPUTS DEVBOX_LOCAL_GATE
    [ -z "${ENV_RERUN+x}" ] || export DEVBOX_RERUN="$ENV_RERUN"
    [ -z "${ENV_RERUN_CONFIG+x}" ] || export DEVBOX_RERUN_CONFIG="$ENV_RERUN_CONFIG"
    [ -z "${ENV_INPUTS+x}" ] || export DEVBOX_SETUP_INPUTS="$ENV_INPUTS" DEVBOX_SHARED_INPUTS="$ENV_INPUTS"
    [ -z "${ENV_LOCAL_GATE+x}" ] || export DEVBOX_LOCAL_GATE="$ENV_LOCAL_GATE"
    rc=0
    devbox_config_parse "$TMP/config.env" || rc=$?
    # The child expands it, never this shell.
    # shellcheck disable=SC2016
    rerun="${DEVBOX_RERUN-<unset>}/$(bash -c 'printf %s "${DEVBOX_RERUN-<unset>}"')"
    [ "$rc" = 0 ] || { echo "rerun after the refusal: $rerun" >&2; exit "$rc"; }
    printf '%s|%s|%s|%s|%s' "$DEVBOX_RERUN_CONFIG" "$rerun" \
      "$DEVBOX_SETUP_INPUTS" "$DEVBOX_SHARED_INPUTS" "$DEVBOX_LOCAL_GATE"
  )
}
assert_eq "|<unset>/<unset>|||always" "$(newkeys "$BASE")" \
  "with none of the four keys: no config rerun, no inputs, local gate always"
assert_eq "|<unset>/<unset>|||always" \
  "$(ENV_RERUN_CONFIG=full ENV_INPUTS=package-lock.json ENV_LOCAL_GATE=never newkeys "$BASE")" \
  "and no exported value stands in for a key the file does not set"
assert_eq "full|<unset>/<unset>|||always" "$(newkeys "$BASE"$'\nDEVBOX_RERUN=full')" \
  "DEVBOX_RERUN=full lands in DEVBOX_RERUN_CONFIG, and DEVBOX_RERUN stays unset"
assert_eq "changed|<unset>/<unset>|||always" "$(newkeys "$BASE"$'\nDEVBOX_RERUN=changed')" \
  "DEVBOX_RERUN=changed is read"
assert_eq "full|changed/changed|||always" "$(ENV_RERUN=changed newkeys "$BASE"$'\nDEVBOX_RERUN=full')" \
  "the file's DEVBOX_RERUN never replaces the exported value, which stays exported"
assert_eq "|full/full|||always" "$(ENV_RERUN=full newkeys "$BASE")" \
  "and an exported DEVBOX_RERUN is never read as the config's value"
for bad in "" Full all "changed full"; do
  rc=0
  err="$(ENV_RERUN=changed newkeys "$BASE"$'\n'"DEVBOX_RERUN=$bad" 2>&1)" || rc=$?
  assert_eq "2" "$rc" "DEVBOX_RERUN='$bad' is refused"
  assert_ok "naming the key and the file" \
    contains "$TMP/config.env: refusing DEVBOX_RERUN '$bad': write changed or full" "$err"
  assert_ok "and the exported value stays in place" contains "rerun after the refusal: changed/changed" "$err"
done
rc=0
err="$(ENV_RERUN=changed newkeys "$BASE"$'\nDEVBOX_RERUN=full\nDEVBOX_NOPE=1' 2>&1)" || rc=$?
assert_eq "2" "$rc" "a config refused after its DEVBOX_RERUN line exits 2"
assert_ok "and the exported value stays in place" contains "rerun after the refusal: changed/changed" "$err"

assert_eq "|<unset>/<unset>|package-lock.json uv.lock|tsconfig.base.json apps/web/package.json|always" \
  "$(newkeys "$BASE"$'\nDEVBOX_SETUP_INPUTS="package-lock.json uv.lock"\nDEVBOX_SHARED_INPUTS="tsconfig.base.json apps/web/package.json"')" \
  "both input lists are read as space-separated relative paths"
assert_eq "|<unset>/<unset>|||always" "$(newkeys "$BASE"$'\nDEVBOX_SETUP_INPUTS=\nDEVBOX_SHARED_INPUTS=')" \
  "an empty input list is allowed"
assert_eq "|<unset>/<unset>|./a/.b/c@1+2_x-y||always" "$(newkeys "$BASE"$'\nDEVBOX_SETUP_INPUTS=./a/.b/c@1+2_x-y')" \
  "a path may hold letters, digits and . _ + @ / -"
for key in DEVBOX_SETUP_INPUTS DEVBOX_SHARED_INPUTS; do
  for bad in /etc/passwd ../up a/../b a/.. .. -rf 'a*b' "a'b" "a\$b" 'a~b'; do
    rc=0
    err="$(newkeys "$BASE"$'\n'"$key=\"ok.json $bad\"" 2>&1)" || rc=$?
    assert_eq "2" "$rc" "$key holding '$bad' is refused"
    assert_ok "naming the key, the path and the rule" \
      contains "$TMP/config.env: refusing $key '$bad': write paths relative to the checkout root" "$err"
  done
done

for v in always ci never; do
  assert_eq "|<unset>/<unset>|||$v" "$(newkeys "$BASE"$'\n'"DEVBOX_LOCAL_GATE=$v")" "DEVBOX_LOCAL_GATE=$v is read"
done
assert_eq "|<unset>/<unset>|||ci" "$(ENV_LOCAL_GATE=always newkeys "$BASE"$'\nDEVBOX_LOCAL_GATE=ci')" \
  "and an exported DEVBOX_LOCAL_GATE does not replace the file's"
for bad in "" CI sometimes; do
  rc=0
  err="$(newkeys "$BASE"$'\n'"DEVBOX_LOCAL_GATE=$bad" 2>&1)" || rc=$?
  assert_eq "2" "$rc" "DEVBOX_LOCAL_GATE='$bad' is refused"
  assert_ok "naming the key and the file" \
    contains "$TMP/config.env: refusing DEVBOX_LOCAL_GATE '$bad': write always, ci or never" "$err"
done

# ── devbox_local_gate_allowed: a checkout with no .devbox.env (spec D11) ────
#
# Prints "run" or "refused", then the refusal text after a bar.
local_gate() {  # $1 the DEVBOX_LOCAL_GATE value, $2 CI or "", $3 the --local flag
  local err rc=0
  err="$(DEVBOX_LOCAL_GATE="$1" CI="$2" devbox_local_gate_allowed "$3" 2>&1)" || rc=$?
  if [ "$rc" = 0 ]; then printf 'run|%s' "$err"; else printf 'refused|%s' "$err"; fi
}
CI_REFUSAL="devbox verify: no .devbox.env, and DEVBOX_LOCAL_GATE=ci refuses a gate on this machine; pass --local, or set CI in a CI job"
NEVER_REFUSAL="devbox verify: no .devbox.env, and DEVBOX_LOCAL_GATE=never refuses a gate on this machine; write a .devbox.env that names a target"
for ci in "" true; do
  for flag in 0 1; do
    assert_eq "run|" "$(local_gate always "$ci" "$flag")" "always runs here (CI='$ci', --local=$flag)"
    assert_eq "refused|$NEVER_REFUSAL" "$(local_gate never "$ci" "$flag")" \
      "never refuses with its own line (CI='$ci', --local=$flag)"
  done
done
assert_eq "refused|$CI_REFUSAL" "$(local_gate ci "" 0)" "ci refuses with no CI and no --local, and says how to proceed"
assert_eq "run|" "$(local_gate ci "" 1)" "ci runs here with --local"
assert_eq "run|" "$(local_gate ci true 0)" "ci runs here when CI is set"
assert_eq "run|" "$(local_gate ci true 1)" "ci runs here when CI is set and --local is given"
assert_eq "run|" "$(unset DEVBOX_LOCAL_GATE; CI="" devbox_local_gate_allowed 0 2>&1 && printf 'run|')" \
  "an unloaded DEVBOX_LOCAL_GATE runs here, the release 1 default"

printf '%d %d\n' "$TESTS_RUN" "$TESTS_FAILED"
