#!/bin/bash
# The client refuses to sync a tree whose Git LFS paths hold pointer files,
# proven with no host, no network and no git-lfs.
#
# rsync ships the working tree, so a checkout that never ran `git lfs pull`
# would put 130-byte pointer texts on the host where the gate reads the file. The
# refusal has to come before the first round trip, so a fake `ssh` RECORDS every
# argv it is handed and the pointer cases assert that it was handed none.
#
# The fixture's files are staged with `git hash-object --no-filters` and
# `update-index --cacheinfo`, never `git add`: a laptop whose global config
# carries the lfs filter would otherwise turn the fixture's own content into
# pointers, and one without git-lfs would refuse the add.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
# shellcheck source=tests/lib.sh
source ./lib.sh
REPO="$(cd .. && pwd)"
VERIFY="$REPO/client/libexec/devbox-verify"

TMP="$(mktemp -d)" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

proto="$(sed -n 's/^DEVBOX_PROTOCOL_VERSION=\(.*\)$/\1/p' "$REPO/lib/devbox-lib.sh")"
fp="$(sha256sum <"$REPO/lib/devbox-lib.sh" | cut -d' ' -f1)"

# Answers the handshake and nothing else, so a run that passes the LFS check
# stops at the first verb it cannot satisfy. Reaching the log at all is the
# evidence that the check let the run through.
mkdir -p "$TMP/bin" "$TMP/home" "$TMP/run"
{ gate_stub_head; cat <<'FAKE'
case "$GATE_CMD" in
  version) printf '%s\n' "${FAKE_SERVER_VERSION-}" ;;
  *) exit 1 ;;
esac
FAKE
} >"$TMP/bin/ssh"
chmod +x "$TMP/bin/ssh"
gate_stub_keyscan "$TMP/bin"

POINTER='version https://git-lfs.github.com/spec/v1
oid sha256:2a21bbbe2cea938f6e3b9eb6df300d2872fd97571f5540d79da2647a1c052287
size 12345'

CO=""
new_checkout() {
  CO="$TMP/checkout-$1"
  mkdir -p "$CO/.devbox"
  git -C "$CO" init -q >/dev/null 2>&1
  printf 'DEVBOX_TARGETS=undertest\nDEVBOX_TARGET_UNDERTEST=devbox-under-test\nDEVBOX_TARGET_UNDERTEST_HOSTKEY=%s\nDEVBOX_GATE_PASSWORD=fixture-gate-password\n' "$GATE_STUB_PIN" >"$CO/.devbox.env"
  printf 'DEVBOX_PROJECT=lfs-fixture\nDEVBOX_WANT_TOKENS=1\nDEVBOX_MIN_TOKENS=1\nDEVBOX_SETUP=:\nDEVBOX_VERIFY=:\n' \
    >"$CO/.devbox/config.env"
  return 0
}
# Writes one file with the given content and stages it with no filter.
track() {
  local path="$1" content="$2" sha
  mkdir -p "$(dirname "$CO/$path")"
  printf '%s\n' "$content" >"$CO/$path"
  sha="$(git -C "$CO" hash-object -w --no-filters -- "$path")"
  git -C "$CO" update-index --add --cacheinfo "100644,$sha,$path"
}

out=""; rc=0
run_verify() {
  : >"$TMP/ssh.log"
  out="$(cd "$CO" && env PATH="$TMP/bin:$PATH" HOME="$TMP/home" XDG_RUNTIME_DIR="$TMP/run" SSH_LOG="$TMP/ssh.log" \
    FAKE_SERVER_VERSION="$proto $fp" bash "$VERIFY" 2>&1)"
  rc=$?
  return 0
}
contains()     { case "$2" in *"$1"*) return 0 ;; esac; return 1; }
not_contains() { case "$2" in *"$1"*) return 1 ;; esac; return 0; }
ssh_untouched() { [ ! -s "$TMP/ssh.log" ]; }
ssh_reached()   { [ -s "$TMP/ssh.log" ]; }

# ── a pointer under an LFS path ──────────────────────────────────────────────
new_checkout pointer
track .gitattributes 'assets/**/*.bin filter=lfs diff=lfs merge=lfs -text'
track assets/data/sample.bin "$POINTER"
track assets/data/meta.json '{"name": "sample"}'
run_verify
assert_eq "9" "$rc" "a pointer under an LFS path exits 9"
assert_ok "the refusal names the pointer file" \
  contains "assets/data/sample.bin" "$out"
assert_ok "the refusal names the fix" contains "git lfs pull" "$out"
assert_ok "the refusal names the install command" contains "apt install git-lfs" "$out"
assert_ok "the refusal does not name a plain-git file" not_contains "meta.json" "$out"
assert_ok "no round trip happened before the refusal" ssh_untouched

# ── the content itself under an LFS path ─────────────────────────────────────
new_checkout content
track .gitattributes 'assets/**/*.bin filter=lfs diff=lfs merge=lfs -text'
track assets/data/sample.bin 'binary content stand-in'
run_verify
assert_ok "real content under an LFS path is not refused" not_contains "Git LFS pointers" "$out"
assert_ok "and the run goes on to the host" ssh_reached

# ── a real binary, with NUL bytes, under an LFS path ─────────────────────────
# Each such file printed "warning: command substitution: ignored null byte in
# input" on every verify, run and status.
new_checkout binary
track .gitattributes 'assets/**/*.bin filter=lfs diff=lfs merge=lfs -text'
mkdir -p "$CO/assets/data"
printf '\000\001\002binary\000\000\000stand-in\n' >"$CO/assets/data/blob.bin"
sha="$(git -C "$CO" hash-object -w --no-filters -- assets/data/blob.bin)"
git -C "$CO" update-index --add --cacheinfo "100644,$sha,assets/data/blob.bin"
run_verify
assert_ok "a binary with NUL bytes under an LFS path is not refused" not_contains "Git LFS pointers" "$out"
assert_ok "and bash prints no null-byte warning for it" not_contains "null byte" "$out"
assert_ok "and the run goes on to the host" ssh_reached

# ── pointer text outside every LFS path ──────────────────────────────────────
#
# A document that quotes a pointer, and a tree with no LFS rule at all, are
# ordinary content: refusing them would block a project that never used LFS.
new_checkout outside
track .gitattributes '*.sh text eol=lf'
track docs/lfs-pointer-example.txt "$POINTER"
run_verify
assert_ok "pointer text in a tree with no LFS rule is not refused" not_contains "Git LFS pointers" "$out"
assert_ok "and the run goes on to the host" ssh_reached

new_checkout elsewhere
track .gitattributes 'assets/**/*.bin filter=lfs diff=lfs merge=lfs -text'
track docs/lfs-pointer-example.txt "$POINTER"
run_verify
assert_ok "pointer text outside the LFS paths is not refused" not_contains "Git LFS pointers" "$out"

printf '%d %d\n' "$TESTS_RUN" "$TESTS_FAILED"
