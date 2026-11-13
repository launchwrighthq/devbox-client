#!/bin/bash
# `devbox gc` is the command that destroys. It removes a container, its volume,
# its Postgres role and every database that role owns, from a keep-list this
# laptop computes and the server obeys. Nothing tested it until this file, and
# the property the whole command rests on was asserted only in a comment: the
# slug gc puts on the keep-list must be byte-identical to the slug `devbox
# verify` built for the same checkout. Any difference is a keep-list entry that
# matches no workspace, and the server then deletes the live one.
#
# Three review rounds found three separate ways those two derivations drifted
# apart: a symlinked path (logical against physical), a quoted or
# comment-trailed DEVBOX_PROJECT (an `awk -F=` reader against a sourced file),
# and a project name built from a value that only `.devbox.env` sets. Each is a
# fixture below.
#
# Both slugs are produced by RUNNING both programs. devbox_slug is never called
# here: a second copy of the derivation agrees with itself and proves nothing
# about the two programs that matter.
#
# Hermetic. A fake `ssh` first on PATH answers the handshake and RECORDS every
# argv it is handed, so no host, no docker and no network take part, and
# everything this file writes lives under one mktemp -d.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
# shellcheck source=tests/lib.sh
source ./lib.sh
REPO="$(cd .. && pwd)"
GC="$REPO/client/libexec/devbox-gc"
VERIFY="$REPO/client/libexec/devbox-verify"

# An operator who exported either of these into the shell that runs the suite
# would decide what half these cases assert, and the host cases would pass
# against a value this file never set. Each run states its own.
unset DEVBOX_GC_HOST

TMP="$(mktemp -d)" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

# Read as text, not sourced, so the handshake cases answer with the number the
# shipped library carries rather than with one this file chose.
proto="$(sed -n 's/^DEVBOX_PROTOCOL_VERSION=\(.*\)$/\1/p' "$REPO/lib/devbox-lib.sh")"
# The handshake's second field, computed the way devbox-runner computes it on a
# real host: the sha256 of the ONE shipped library, hex only, with no filename.
# The fixture answers what a current host answers, so the handshake report
# names one library and nothing in this file depends on the second field.
fp="$(sha256sum <"$REPO/lib/devbox-lib.sh" | cut -d' ' -f1)"

# ── the fake host ────────────────────────────────────────────────────────────
#
# It records the whole argv of every call BEFORE it answers, and that record is
# the evidence for the destructive-verb cases below: gc sends one gate verb with
# its words, so what reaches this file is exactly what would have reached a real
# devbox. The master open is the reachability probe and gets a silent exit 0, as
# does every call this file does not name, so a run that gets past the
# handshake stops at the next step instead of reaching rsync or docker.
mkdir -p "$TMP/bin" "$TMP/home" "$TMP/run"
{ gate_stub_head; cat <<'FAKE'
case "$GATE_CMD" in
  version) printf '%s\n' "${FAKE_SERVER_VERSION-}" ;;
  # The dry-run verb enumerates and prints one line per workspace, exactly as
  # the server's does, and deletes nothing. The client reads only whether any
  # line says `would remove`, which is what decides whether --yes is required,
  # so each case chooses that answer.
  "gc --dry-run "*) printf '%s\n' "${FAKE_PLAN-would keep ws-fixture}" ;;
  *) exit 0 ;;
esac
FAKE
} >"$TMP/bin/ssh"
chmod +x "$TMP/bin/ssh"
gate_stub_keyscan "$TMP/bin"

# ── running the two programs ─────────────────────────────────────────────────

out=""
rc=0
SERVER_VERSION="$proto"
SERVER_PLAN="would keep ws-fixture"
GC_HOST=""

# Runs the real client with the fake host first on PATH, and truncates the
# record first so each case reads only its own calls.
run_gc() {
  local -a envv=(PATH="$TMP/bin:$PATH" HOME="$TMP/home" XDG_RUNTIME_DIR="$TMP/run" SSH_LOG="$TMP/ssh.log" \
    FAKE_SERVER_VERSION="$SERVER_VERSION" FAKE_PLAN="$SERVER_PLAN")
  # Passed only when the case sets it. An empty DEVBOX_GC_HOST reads as unset
  # today, and asserting the documented order through a value that happens to be
  # falsy would stop proving the order the moment that test changes.
  [ -n "$GC_HOST" ] && envv+=(DEVBOX_GC_HOST="$GC_HOST")
  : >"$TMP/ssh.log"
  out="$(env "${envv[@]}" bash "$GC" "$@" 2>&1)"
  rc=$?
  return 0
}

# The lane slugs `devbox verify` builds for the checkout at $1, lane 1 first,
# read off the `lock` verb it sends once the handshake passes: those are the
# workspaces it may run in, so they are the slugs gc must keep. verify is run
# from INSIDE the checkout, because that is how `make verify` reaches it and
# because the path it hashes is the toplevel git reports from there. The fake
# host answers the lock with no lane, so verify stops there, well before
# ensure-workspace and rsync. verify_slug is lane 1 alone.
verify_lanes() {
  local root="$1"
  : >"$TMP/ssh-verify.log"
  (cd "$root" && env PATH="$TMP/bin:$PATH" HOME="$TMP/home" XDG_RUNTIME_DIR="$TMP/run" SSH_LOG="$TMP/ssh-verify.log" \
    FAKE_SERVER_VERSION="$proto $fp" DEVBOX_LOCK_WAIT=1 bash "$VERIFY" >/dev/null 2>&1)
  sed -n 's/.*devbox-gate@[^ ]* lock [0-9]* //p' "$TMP/ssh-verify.log" | head -1
}
verify_slug() { local l; l="$(verify_lanes "$1")"; printf '%s' "${l%% *}"; }

# The slug `devbox gc` puts on the keep-list for the root at $1, read off the
# keep-list gc prints. Every fixture here passes exactly ONE root, so that line
# carries exactly one slug. A run that refuses prints no such line and returns
# the empty string, which the emptiness assertions below catch rather than
# comparing "" against "" and calling it agreement.
keep_slug() {
  local line
  line="$(printf '%s\n' "$out" | sed -n 's/^keeping: //p' | head -1)"
  printf '%s' "${line%% *}"
}
gc_slug() { run_gc --dry-run "$1"; keep_slug; }

contains()     { case "$2" in *"$1"*) return 0 ;; esac; return 1; }
not_contains() { case "$2" in *"$1"*) return 1 ;; esac; return 0; }

# The whole point of the file. Both halves are run, both slugs must be a real
# slug, and the two must match byte for byte. The emptiness assertions are not
# ceremony: a verify that dies before it prints, or an extraction that stops
# matching, returns "" from both halves and would otherwise report agreement
# where neither program ran.
assert_same_slug() {
  local desc="$1" vroot="$2" groot="$3" vs gs
  vs="$(verify_slug "$vroot")"
  gs="$(gc_slug "$groot")"
  assert_ok "$desc: verify produced a slug" test -n "$vs"
  assert_ok "$desc: gc produced a slug" test -n "$gs"
  assert_eq "$vs" "$gs" "$desc: verify and gc agree byte for byte"
}

# Writes one fixture checkout: a git repository, a .devbox/config.env carrying
# the DEVBOX_PROJECT line it is given, and a .devbox.env naming one target, at
# an address no resolver is ever asked about, because the fake ssh answers
# first.
#
# The token counts are here because devbox-verify refuses a profile without
# them, and this file is about the slug, not about that refusal.
make_checkout() {
  local dir="$1" project_line="$2" host="$3"
  mkdir -p "$dir/.devbox"
  git -C "$dir" init -q >/dev/null 2>&1
  printf '%s\nDEVBOX_WANT_TOKENS=1\nDEVBOX_MIN_TOKENS=1\nDEVBOX_SETUP=:\nDEVBOX_VERIFY=:\n' \
    "$project_line" >"$dir/.devbox/config.env"
  # Ignored here for the reason every real project ignores it: the file names
  # ONE developer's machine. The worktree fixture below depends on that, and a
  # fixture that commits the file would test a lookup no worktree ever needs.
  printf '.devbox.env\n' >"$dir/.gitignore"
  [ -n "$host" ] && printf 'DEVBOX_TARGETS=fixture\nDEVBOX_TARGET_FIXTURE=%s\nDEVBOX_TARGET_FIXTURE_HOSTKEY=%s\nDEVBOX_GATE_PASSWORD=fixture-gate-password\n' "$host" "$GATE_STUB_PIN" >"$dir/.devbox.env"
  return 0
}

# ── 1. the slug is byte-identical on both sides ──────────────────────────────

# (a) A plain checkout. The base case: if this one ever disagrees, every case
# below is noise.
make_checkout "$TMP/plain" 'DEVBOX_PROJECT=plain-fixture' plain-fixture-host
assert_same_slug "plain checkout" "$TMP/plain" "$TMP/plain"

# (b) The same checkout reached through a symlink. verify hashes `git rev-parse
# --show-toplevel`, which is PHYSICAL. gc used to hash `cd "$root" && pwd`,
# which is LOGICAL, so one symlink above a checkout put a slug on the keep-list
# that no workspace has and gc deleted the live workspace, its volume, its
# Postgres role and every database that role owns. The link is named differently
# from its target on purpose: a logical read differs here in the basename as
# well as in the hash, so the failure is visible in the slug itself.
ln -s "$TMP/plain" "$TMP/link-to-plain"
assert_same_slug "checkout reached through a symlink" "$TMP/link-to-plain" "$TMP/link-to-plain"

# (c) A linked git worktree. Its .devbox.env cannot live beside it: the file
# names one developer's machine, so every project gitignores it, and a git
# worktree holds no gitignored file. Both halves have to find it beside the git
# common dir instead. The profile is committed, so the worktree carries it.
make_checkout "$TMP/wt-main" 'DEVBOX_PROJECT=worktree-fixture' wt-fixture-host
git -C "$TMP/wt-main" add -A >/dev/null 2>&1
git -C "$TMP/wt-main" -c user.email=t@fixture.invalid -c user.name=fixture \
  commit -q -m "fixture" >/dev/null 2>&1
git -C "$TMP/wt-main" worktree add -q -b fixture-branch "$TMP/wt-linked" >/dev/null 2>&1
assert_same_slug "linked worktree" "$TMP/wt-linked" "$TMP/wt-linked"

# (d) A quoted value. gc reads this file with the parser verify uses, and a
# reader that returns more than the value puts a different project name on the
# keep-list, which is a slug that matches no workspace.
#
# What this fixture cannot catch, and no fixture can: devbox_sanitize turns a
# leading or trailing quote into a dash and then trims it, so a reader that
# keeps the quotes and nothing else lands on the same slug anyway. It catches a
# reader that returns the whole line, or the name as well as the value.
make_checkout "$TMP/quoted" 'DEVBOX_PROJECT="quoted-fixture"' quoted-fixture-host
assert_same_slug "quoted DEVBOX_PROJECT" "$TMP/quoted" "$TMP/quoted"

# (e) and (f) are gone with the older .devbox/profile.sh. A trailing comment on the line,
# which an `awk -F=` reader returned as part of the value, and a DEVBOX_PROJECT
# built from a value only .devbox.env set, which gc read differently from
# verify and so deleted the live workspace, both needed a SOURCED profile.
# Now neither file is sourced and nothing in a value is expanded, so
# both programs read the same literal text through the same parser, and
# devbox-verify refuses a project name that holds a space, a `#` or a `$`.

# ── 2. every refusal, named ──────────────────────────────────────────────────
#
# Each of these used to be a `continue`. A root that is skipped is a slug
# missing from the keep-list, and the server deletes every workspace whose slug
# is not on that list, so a skip and a mistyped path destroy a live workspace in
# the same way. The whole run has to stop, and it has to say which condition the
# root failed, because a typo and a retired checkout arrive here as one event.

# The last guard between this command and every workspace on the machine. gc
# with no roots sends an empty keep-list, and an empty keep-list means "keep
# nothing".
GC_HOST=""
run_gc
assert_eq "2" "$rc" "no roots at all is refused"
assert_ok "the empty keep-list refusal says what an empty list would do" \
  contains "empty keep-list" "$out"
assert_ok "the empty keep-list refusal never reaches the host" \
  not_contains "host:" "$out"

run_gc "$TMP/does-not-exist"
assert_eq "2" "$rc" "a root that does not exist is refused"
assert_ok "the refusal names the missing directory" \
  contains "$TMP/does-not-exist is not a directory" "$out"

mkdir -p "$TMP/no-profile"
run_gc "$TMP/no-profile"
assert_eq "2" "$rc" "a root with no .devbox/config.env is refused"
assert_ok "the refusal names the file it could not read" \
  contains "no .devbox/config.env in $TMP/no-profile" "$out"
assert_ok "the refusal tells the operator to pass the checkout root" \
  contains "Pass the checkout root itself" "$out"

# A checkout that carries only the older profile is refused by name. The
# refusal above told a person to pass the checkout root, which such a root
# already is, so it named the wrong repair.
mkdir -p "$TMP/only-profile/.devbox"
git -C "$TMP/only-profile" init -q >/dev/null 2>&1
printf 'DEVBOX_PROJECT=old\n' >"$TMP/only-profile/.devbox/profile.sh"
run_gc "$TMP/only-profile"
assert_eq "2" "$rc" "a root with only .devbox/profile.sh is refused with exit 2"
assert_ok "naming the root" contains "devbox-gc: $TMP/only-profile cannot be collected:" "$out"
assert_ok "and the older file, with its repair" \
  contains ".devbox/profile.sh is an older format this client does not read. Convert it to .devbox/config.env" "$out"
assert_ok "never the subdirectory repair" not_contains "Pass the checkout root itself" "$out"
assert_eq "0" "$(grep -c . "$TMP/ssh.log" || true)" "and nothing reached a target"

# The profile is committed, so any contributor edits it, and an empty value
# sanitizes to nothing. devbox_slug refuses that rather than render a blank
# field, and gc has to report it against the root that carries it.
make_checkout "$TMP/empty-project" 'DEVBOX_PROJECT=""' empty-fixture-host
run_gc "$TMP/empty-project"
assert_eq "2" "$rc" "a root whose DEVBOX_PROJECT is empty is refused"
assert_ok "the refusal names DEVBOX_PROJECT and the profile it came from" \
  contains "no DEVBOX_PROJECT from $TMP/empty-project/.devbox" "$out"

# A subdirectory is resolved to its checkout root and never hashed as itself.
# The project came from the checkout's profile while the path came from the
# argument, so hashing the argument paired one checkout's project with another
# directory's path: a slug no workspace has, which is a live workspace the
# server deletes. The slug is compared against the one the toplevel produces,
# because that equality is the property, not the wording of the notice.
mkdir -p "$TMP/plain/src"
top_slug="$(gc_slug "$TMP/plain")"
run_gc --dry-run "$TMP/plain/src"
sub_slug="$(keep_slug)"
assert_ok "a subdirectory still produces a slug" test -n "$sub_slug"
assert_eq "$top_slug" "$sub_slug" \
  "a subdirectory hashes to its checkout root's slug, not to its own path"
assert_ok "and the operator is told which checkout was read instead" \
  contains "is inside the checkout at $TMP/plain" "$out"

# ── 3. which targets are about to lose workspaces ────────────────────────────
#
# No default may name anybody's machine. A guessed host is a gc run against
# somebody else's workspaces, and one root decides for the whole run, so the
# targets are printed before anything is contacted.

GC_HOST=""
run_gc --dry-run "$TMP/plain"
assert_eq "0" "$rc" "a root whose .devbox.env names a target makes a dry run succeed"
assert_ok "the targets come from the root's .devbox.env, each with its address" \
  contains "targets: fixture (plain-fixture-host) (from $TMP/plain/.devbox.env)" "$out"

# DEVBOX_GC_HOST named one host in an older client. A value still exported from an
# earlier shell is refused, not ignored: the operator meant one host, and gc now
# acts on every target.
GC_HOST="explicit-fixture-host"
run_gc --dry-run "$TMP/plain"
assert_eq "2" "$rc" "an exported DEVBOX_GC_HOST is refused"
assert_ok "and the refusal says gc acts on every target in DEVBOX_TARGETS" \
  contains "DEVBOX_GC_HOST is no longer read" "$out"
assert_ok "and nothing was contacted" test ! -s "$TMP/ssh.log"
GC_HOST=""

# The same lookup verify does, and for the same reason: a worktree holds no
# gitignored file, so without this fallback `devbox gc` over a set of worktrees
# refused a run that should have reaped them.
run_gc --dry-run "$TMP/wt-linked"
assert_ok "a linked worktree resolves the targets through the git common dir" \
  contains "targets: fixture (wt-fixture-host) (from $TMP/wt-main/.devbox.env)" "$out"

# No .devbox.env anywhere, so there is nothing to read the targets from.
make_checkout "$TMP/no-host" 'DEVBOX_PROJECT=no-host-fixture' ""
run_gc --dry-run "$TMP/no-host"
assert_ok "a run with no .devbox.env anywhere is refused" test "$rc" -ne 0
assert_ok "the refusal names .devbox.env and DEVBOX_TARGETS" \
  contains "no .devbox.env in any root passed, or beside its main checkout. gc acts on the targets that file lists in DEVBOX_TARGETS" "$out"
assert_ok "nothing was contacted before the refusal" \
  test ! -s "$TMP/ssh.log"

# A .devbox.env that rents and deploys nothing holds no workspace to collect.
make_checkout "$TMP/rent-only" 'DEVBOX_PROJECT=rent-only-fixture' ""
printf 'DEVBOX_RENT=runpod\nRUNPOD_KEY=fixture\n' >"$TMP/rent-only/.devbox.env"
run_gc --dry-run "$TMP/rent-only"
assert_eq "2" "$rc" "a .devbox.env with no DEVBOX_TARGETS is refused"
assert_ok "and the refusal says why" contains "lists no DEVBOX_TARGETS" "$out"

# ── 4. what actually crosses to the host ─────────────────────────────────────
#
# The record the fake ssh keeps is the only place a destructive verb can appear,
# because gc sends one gate verb. A `gc` without `--dry-run` is the verb
# that removes containers, volumes, roles and databases, so these cases assert
# on its absence rather than on the exit code: a run can exit 0 having sent it.

# A `gc` verb line in the record that does not carry --dry-run is the verb that
# removes. Written as "none without it" rather than "one with it",
# because what is guarded here is an extra destructive call, not a missing safe
# one.
sent_destructive_gc() {
  grep -E 'devbox-gate@[^ ]+ gc ' "$TMP/ssh.log" | grep -qv -- '--dry-run'
}
sent_no_destructive_gc() { ! sent_destructive_gc; }
sent_dry_run_gc() { grep -qE 'devbox-gate@[^ ]+ gc --dry-run ' "$TMP/ssh.log"; }

SERVER_PLAN="would keep ws-fixture"
run_gc --dry-run "$TMP/plain"
assert_eq "0" "$rc" "--dry-run exits 0"
assert_ok "--dry-run asks the server what gc would do" sent_dry_run_gc
assert_ok "--dry-run sends no destructive gc verb" sent_no_destructive_gc
assert_ok "--dry-run says it deleted nothing" contains "nothing was deleted" "$out"
assert_ok "--dry-run shows which checkout produced which slug" \
  contains "$TMP/plain -> " "$out"

# A run that is not a dry run, on a plan that WOULD remove a workspace, with no
# --yes. The keep-list is computed and the host is named, and the verb that
# deletes must not leave this laptop until an operator has read that plan and
# said so. Exit 3 rather than 0, so a wrapper that ignores the output cannot
# read a printed plan as a gc that ran.
SERVER_PLAN="would remove ws-retired-fixture"
run_gc "$TMP/plain"
assert_eq "3" "$rc" "a run that would remove something, without --yes, refuses"
assert_ok "a run without --yes sends no destructive gc verb" sent_no_destructive_gc
assert_ok "the refusal names the flag that would proceed" contains "--yes" "$out"
assert_ok "the refusal says nothing was deleted" contains "Nothing was deleted" "$out"

# The same run, confirmed. This is what proves the three assertions above can
# fail: the record does hold a destructive verb when one is sent, and it carries
# the machine id and the keep-list this run printed, not some other scope.
run_gc --yes "$TMP/plain"
mid="$(printf '%s\n' "$out" | sed -n 's/^machine: //p' | head -1)"
keeplist="$(printf '%s\n' "$out" | sed -n 's/^keeping: //p' | head -1)"
assert_ok "--yes sends the destructive gc verb" sent_destructive_gc
assert_ok "the destructive verb carries the machine id and keep-list gc printed" \
  grep -qF "devbox-gate@plain-fixture-host gc $mid $keeplist" "$TMP/ssh.log"

# ── 5. the handshake, which gc runs for a stronger reason than verify ────────
#
# verify only builds; gc destroys. A server that computes devbox_pg_ident
# differently maps this keep-list onto another worktree's Postgres role and gc
# drops that one instead, so a mismatch is refused rather than reported.

SERVER_VERSION=99
run_gc --yes "$TMP/plain"
assert_eq "5" "$rc" "a server on a different protocol version exits 5"
assert_ok "the refusal names both versions" \
  contains "client speaks $proto, the server speaks 99" "$out"
assert_ok "and names both repairs, because the integer does not say which half is older" \
  contains "move this project's devbox-client pin" "$out"
assert_ok "a refused handshake sends no destructive gc verb" sent_no_destructive_gc

# An empty answer is what an unreachable host and a server with no version verb
# both give back. gc runs no separate reachability probe, so one message covers
# both and names each repair.
SERVER_VERSION=""
run_gc --yes "$TMP/plain"
assert_eq "5" "$rc" "a server that answers nothing exits 5"
assert_ok "the empty answer is reported as unreachable, missing or older" \
  contains "did not report a protocol version" "$out"
assert_ok "an unanswered handshake sends no destructive gc verb" sent_no_destructive_gc

# ── 6. the gate password ─────────────────────────────────────────────────────
#
# gc reaches the host as the gate account. A refused password is exit 3 with
# the sentence a client is promised after a rotation, never a silent skip
# and never the handshake's exit 5, which would send the operator to reinstall
# a server that is fine.
SERVER_VERSION="$proto $fp"
export FAKE_OPEN_RC=255 FAKE_OPEN_ERR="devbox-gate@plain-fixture-host: Permission denied (password)."
run_gc --yes "$TMP/plain"
unset FAKE_OPEN_RC FAKE_OPEN_ERR
assert_eq "3" "$rc" "a refused gate password exits 3"
assert_ok "and says the gate password was refused" contains "the gate password was refused" "$out"
assert_ok "a refused password sends no destructive gc verb" sent_no_destructive_gc
assert_fail "and asks the host nothing" grep -qE 'devbox-gate@[^ ]+ version' "$TMP/ssh.log"

# A .devbox.env with no password is refused before anything is contacted.
make_checkout "$TMP/no-password" 'DEVBOX_PROJECT=no-password-fixture' no-password-host
sed -i '/^DEVBOX_GATE_PASSWORD=/d' "$TMP/no-password/.devbox.env"
GC_HOST=""
run_gc --dry-run "$TMP/no-password"
assert_eq "2" "$rc" "a .devbox.env with no gate password is refused"
assert_ok "the refusal names the key" contains "no DEVBOX_GATE_PASSWORD" "$out"
assert_ok "and nothing was contacted" test ! -s "$TMP/ssh.log"
# An exported value does not stand in for the missing line.
export DEVBOX_GATE_PASSWORD=from-an-old-shell
run_gc --dry-run "$TMP/no-password"
unset DEVBOX_GATE_PASSWORD
assert_eq "2" "$rc" "an exported gate password does not stand in for the file"

# ── 7. every target, one unreachable ────────────────────────────────────────
#
# gc acts on every target in DEVBOX_TARGETS. A target that does not answer is
# printed as "not collected" and makes the exit non-zero, never skipped in
# silence: the next gc depends on knowing which hosts were cleaned. The target
# that does answer is still collected.
make_checkout "$TMP/two" 'DEVBOX_PROJECT=two-fixture' ""
printf 'DEVBOX_TARGETS=lan1,cloud1\nDEVBOX_TARGET_LAN1=lan1-fixture-host\nDEVBOX_TARGET_LAN1_HOSTKEY=%s\nDEVBOX_TARGET_CLOUD1=cloud1-fixture-host\nDEVBOX_TARGET_CLOUD1_HOSTKEY=%s\nDEVBOX_GATE_PASSWORD=fixture-gate-password\n' "$GATE_STUB_PIN" "$GATE_STUB_PIN" \
  >"$TMP/two/.devbox.env"
SERVER_VERSION="$proto $fp"
SERVER_PLAN="would remove ws-retired-fixture"
export FAKE_UNREACHABLE=lan1-fixture-host
run_gc --yes "$TMP/two"
unset FAKE_UNREACHABLE
assert_ok "an unreachable target makes the exit non-zero" test "$rc" -ne 0
assert_eq "3" "$rc" "with the code a target that does not answer gives"
assert_ok "the targets line names both" \
  contains "targets: lan1 (lan1-fixture-host), cloud1 (cloud1-fixture-host)" "$out"
assert_ok "the unreachable one is printed as not collected" \
  contains "devbox-gc: lan1: not collected: unreachable" "$out"
assert_ok "and named again in the closing line" contains "devbox-gc: not collected: lan1." "$out"
assert_ok "the reachable one is still asked for its plan" \
  grep -qF "devbox-gate@cloud1-fixture-host gc --dry-run" "$TMP/ssh.log"
assert_ok "and collected" grep -qE 'devbox-gate@cloud1-fixture-host gc [^-]' "$TMP/ssh.log"
assert_fail "the unreachable one is sent no gc verb" grep -qE 'devbox-gate@lan1-fixture-host gc' "$TMP/ssh.log"

# Both reachable: both collected, in list order, exit 0.
run_gc --yes "$TMP/two"
assert_eq "0" "$rc" "two reachable targets are both collected"
assert_ok "the first" grep -qE 'devbox-gate@lan1-fixture-host gc [^-]' "$TMP/ssh.log"
assert_ok "and the second" grep -qE 'devbox-gate@cloud1-fixture-host gc [^-]' "$TMP/ssh.log"
assert_ok "and each has a header line" contains "== cloud1 (cloud1-fixture-host)" "$out"

# A dry run over both prints both plans and deletes nothing anywhere.
run_gc --dry-run "$TMP/two"
assert_eq "0" "$rc" "a dry run over two targets exits 0"
assert_fail "and sends no destructive gc verb to either" sent_destructive_gc
assert_eq "2" "$(grep -c 'gc --dry-run' "$TMP/ssh.log")" "and asks each target for its plan once"

# ── 8. lanes (R14) ───────────────────────────────────────────────────────────
#
# A worktree holds up to DEVBOX_LANES workspaces on each target, each with its
# own slug, and the server deletes every slug the keep-list does not name. So
# the keep-list carries every lane from 1 to DEVBOX_LANES, and a lane above a
# lowered count is left off for the server to collect. The lane slugs are read
# off what gc prints, never computed here, for the reason the header gives.
keep_words() { printf '%s\n' "$out" | sed -n 's/^keeping: //p' | head -1; }
SERVER_VERSION="$proto $fp"
SERVER_PLAN="would keep ws-fixture"

# The default, with no DEVBOX_LANES in the config, is two lanes. Lane 1 is
# today's slug, the one verify builds (section 1 compares it byte for byte).
make_checkout "$TMP/lanes" 'DEVBOX_PROJECT=lanes-fixture' lanes-fixture-host
run_gc --dry-run "$TMP/lanes"
assert_eq "0" "$rc" "a checkout that sets no DEVBOX_LANES: the dry run exits 0"
read -r -a two_lanes <<<"$(keep_words)"
assert_eq "2" "${#two_lanes[@]}" "with no DEVBOX_LANES, the keep-list holds two lanes of the worktree"
lane1="${two_lanes[0]:-}"
lane2="${two_lanes[1]:-}"
assert_ok "lane 1 is a slug" test -n "$lane1"
assert_ok "and lane 2 is another one" test -n "$lane2"
assert_ok "lane 2's slug differs from lane 1's" test "$lane1" != "$lane2"
assert_eq "${lane1%-*}" "${lane2%-*}" "the two lanes share every part of the slug but the hash"
assert_ok "and the plan pairs the checkout with both lanes" contains "$TMP/lanes -> $lane1 $lane2" "$out"
# The lanes verify asks the host to lock are the lanes gc keeps, byte for byte:
# a lane verify may run in and gc does not keep is a live workspace deleted.
assert_eq "$lane1 $lane2" "$(verify_lanes "$TMP/lanes")" "verify locks exactly the lanes gc keeps"
assert_ok "the dry run asks the server about both lanes" \
  grep -qF "gc --dry-run $(printf '%s\n' "$out" | sed -n 's/^machine: //p' | head -1) $lane1 $lane2" "$TMP/ssh.log"

# An exported DEVBOX_LANES from an earlier shell does not narrow the keep-list:
# a lane count from anywhere but the committed config deletes a live lane.
DEVBOX_LANES=1 run_gc --dry-run "$TMP/lanes"
assert_eq "$lane1 $lane2" "$(keep_words)" "an exported DEVBOX_LANES=1 is not read: both lanes are kept"

# DEVBOX_LANES=1: lane 2 is above the count, so it leaves the keep-list and the
# server collects its container, both volumes and its role. Lane 1 stays.
printf 'DEVBOX_LANES=1\n' >>"$TMP/lanes/.devbox/config.env"
run_gc --dry-run "$TMP/lanes"
assert_eq "0" "$rc" "DEVBOX_LANES=1: the dry run exits 0"
assert_eq "$lane1" "$(keep_words)" "DEVBOX_LANES=1 keeps lane 1 alone"
assert_fail "and lane 2 is not on the keep-list the server is sent" grep -qF "$lane2" "$TMP/ssh.log"
SERVER_PLAN="would remove ws-$lane2"
run_gc --yes "$TMP/lanes"
assert_ok "with --yes, the destructive verb keeps lane 1" \
  grep -qE "devbox-gate@lanes-fixture-host gc [0-9a-f]+ $lane1\$" "$TMP/ssh.log"
assert_fail "and names no lane 2" grep -qF "$lane2" "$TMP/ssh.log"
SERVER_PLAN="would keep ws-fixture"

# DEVBOX_LANES=4: four distinct slugs, lane 1 first.
sed -i 's/^DEVBOX_LANES=1$/DEVBOX_LANES=4/' "$TMP/lanes/.devbox/config.env"
run_gc --dry-run "$TMP/lanes"
read -r -a four_lanes <<<"$(keep_words)"
assert_eq "4" "${#four_lanes[@]}" "DEVBOX_LANES=4 keeps four lanes"
assert_eq "$lane1" "${four_lanes[0]:-}" "lane 1 first"
assert_eq "$lane2" "${four_lanes[1]:-}" "then lane 2, the same slug the default kept"
assert_eq "4" "$(printf '%s\n' "${four_lanes[@]}" | sort -u | grep -c .)" "and the four slugs are distinct"
assert_eq "${four_lanes[*]}" "$(verify_lanes "$TMP/lanes")" "and verify locks the same four"

# A count outside 1 to 4 refuses the whole run before any target is contacted.
# A guessed count is a keep-list that drops a live lane.
for bad_lanes in 0 5 two; do
  sed -i "s/^DEVBOX_LANES=.*/DEVBOX_LANES=$bad_lanes/" "$TMP/lanes/.devbox/config.env"
  run_gc --dry-run "$TMP/lanes"
  assert_eq "2" "$rc" "DEVBOX_LANES=$bad_lanes is refused with exit 2"
  assert_ok "and the refusal names DEVBOX_LANES" contains "DEVBOX_LANES '$bad_lanes'" "$out"
  assert_ok "and nothing was contacted" test ! -s "$TMP/ssh.log"
done

printf '%d %d\n' "$TESTS_RUN" "$TESTS_FAILED"
