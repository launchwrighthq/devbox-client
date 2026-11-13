#!/bin/bash
# Tests for the pure half of the devbox runner: naming and token arithmetic.
# These functions decide the name of a container, a volume, a Postgres role and
# a Postgres database. A change here orphans real resources, which is why they
# are pinned before anything touches a host.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
# shellcheck source=tests/lib.sh
source ./lib.sh
# shellcheck source=lib/devbox-lib.sh
source ../lib/devbox-lib.sh

assert_eq "my-app" "$(devbox_sanitize my-app)" \
  "an already-clean label is unchanged"
assert_eq "my-branch" "$(devbox_sanitize My_Branch)" \
  "uppercase folds and an underscore becomes a dash, so it is a DNS label"
assert_eq "a-b" "$(devbox_sanitize -- "--a///b--")" \
  "runs of separators collapse and the ends are trimmed"
assert_fail "an empty label is rejected" devbox_sanitize ""

# devbox_slug takes the machine label and machine id as explicit arguments
# rather than reading them itself, so the naming stays a pure function.
machine="laptop"
mid_laptop_a="11111111111111111111111111111111"
mid_laptop_b="22222222222222222222222222222222"

# The hash is over the machine id and the absolute path, so two worktrees
# sharing a basename differ.
slug_main="$(devbox_slug "$machine" "$mid_laptop_a" my-app /work/my-app)"
slug_wt="$(devbox_slug "$machine" "$mid_laptop_a" my-app /work/my-app/worktrees/main)"
assert_eq "laptop-my-app-my-app" "${slug_main%-*}" \
  "the slug is machine, project, basename, then a hash suffix"
assert_fail "two paths with the same basename must not collide" \
  test "$slug_main" = "$slug_wt"
assert_eq "$slug_main" "$(devbox_slug "$machine" "$mid_laptop_a" my-app /work/my-app)" \
  "the slug is stable, so a second run finds the same workspace"
assert_eq "6" "$(devbox_slug "$machine" "$mid_laptop_a" my-app /work/my-app | awk -F- '{print length($NF)}')" \
  "the hash suffix is 6 hex characters"

# The actual bug this signature change fixes: two laptops can hold the same
# project at the same absolute path and can even share a hostname, so the
# machine id, not the path or the hostname, has to be what tells them apart.
slug_laptop_b="$(devbox_slug "$machine" "$mid_laptop_b" my-app /work/my-app)"
assert_fail "two machine ids with the same project and path must not collide" \
  test "$slug_main" = "$slug_laptop_b"

# Every component must fail loudly on an empty sanitize, not just the
# worktree basename. project comes from a project's committed
# .devbox/config.env, so a misconfigured or empty DEVBOX_PROJECT has to be an
# actionable error rather than a malformed-looking slug that still succeeds.
assert_fail "a project that sanitizes to empty is rejected, not rendered as a blank field" \
  devbox_slug "$machine" "$mid_laptop_a" "---" /work/foo
assert_fail "a machine that sanitizes to empty is rejected, not rendered as a leading dash" \
  devbox_slug "---" "$mid_laptop_a" my-app /work/foo

assert_eq "ws_my_app_main_a1b2c3" "$(devbox_pg_ident my-app-main-a1b2c3)" \
  "a Postgres identifier is the slug with dashes as underscores, prefixed ws_"
long="$(devbox_pg_ident "$(printf 'x%.0s' {1..200})")"
assert_eq "63" "${#long}" \
  "an over-long slug truncates to Postgres's 63-byte identifier limit"

# devbox_pg_ident's own defense still holds under the new, longer slug shape.
# devbox_slug now caps every component (machine to 8, project to 18, worktree
# to 18) so a real slug can never reach 63 bytes on its own, but
# devbox_pg_ident is a general-purpose truncation and must still keep the
# discriminating tail, not the head, for any input that does exceed the limit.
long_a="$(printf 'x%.0s' {1..60})aaaaaa"
long_b="$(printf 'x%.0s' {1..60})bbbbbb"
id_one="$(devbox_pg_ident "$long_a")"
id_two="$(devbox_pg_ident "$long_b")"
assert_fail "two long identifiers differing only in their hash-like suffix must not collide" \
  test "$id_one" = "$id_two"
assert_eq "63" "${#id_one}" "the truncated identifier still fits Postgres's limit"

# One mktemp -d for the whole file, removed by a trap. The three inline
# `rm -rf` lines this replaces were reached only on the path that runs to the
# end, so a Ctrl-C or run-tests.sh's timeout(1) left a directory in /tmp. The
# fixtures below are subdirectories of it, and stay separate directories: the
# summed pool and the corrupt pool each have to be alone with their own grant
# files.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# devbox_machine_id accepts an explicit candidate list (rather than always
# reading /etc/machine-id and /var/lib/dbus/machine-id) so this test can point
# it at fixtures instead of the real filesystem.
mid_dir="$TMP/machine-id"
mkdir -p "$mid_dir"
echo "abc123" >"$mid_dir/etc-machine-id"
assert_eq "abc123" "$(devbox_machine_id "$mid_dir/etc-machine-id" "$mid_dir/dbus-machine-id")" \
  "the first candidate is read when it exists"
assert_eq "abc123" "$(devbox_machine_id "$mid_dir/missing" "$mid_dir/etc-machine-id")" \
  "a missing first candidate falls through to the second"
assert_fail "no readable machine-id anywhere is refused, not silently defaulted to the hostname" \
  devbox_machine_id "$mid_dir/missing-one" "$mid_dir/missing-two"

# Token arithmetic. A grants dir holds one file per job, named by PID.
grants="$TMP/grants-sum"
mkdir -p "$grants"
assert_eq "0" "$(pool_held "$grants")" "an empty pool holds nothing"
echo 12 >"$grants/1001"
echo 4 >"$grants/1002"
assert_eq "16" "$(pool_held "$grants")" "held tokens are the sum of the grant files"

# A truncated or corrupt grant file must not be silently read as 0: that would
# under-count held tokens and let pool_may_grant approve a grant that pushes
# real usage over budget, the one thing the pool exists to prevent.
grants="$TMP/grants-corrupt"
mkdir -p "$grants"
echo 12 >"$grants/1001"
echo bogus >"$grants/1002"
assert_fail "a non-numeric grant file is rejected, not coerced to zero" \
  pool_held "$grants"

assert_ok   "12 of 16 fits when nothing is held and no job runs" \
  pool_may_grant 16 0 0 2 12
assert_ok   "4 more fits beside a held 12" \
  pool_may_grant 16 12 1 2 4
assert_fail "a second 12 does not fit beside a held 12" \
  pool_may_grant 16 12 1 2 12
assert_fail "a third job is refused even when tokens are free, because memory is not" \
  pool_may_grant 16 0 2 2 4

# The handshake verdict quotes the host's answer in its refusal, and every
# client prints that refusal on a terminal. A host that answers with ESC or BEL
# bytes would otherwise drive the developer's terminal.
ctl=$'\033]0;owned\a\033[2J'
v="$(devbox_handshake_verdict "7${ctl}x" ../lib/devbox-lib.sh)"; vrc=$?
assert_eq "5" "$vrc" "an answer with control bytes in its protocol field is not a protocol version"
assert_eq "the server answered '7]0;owned[2Jx', which is not a protocol version" "$v" \
  "  and the refusal quotes it with every control byte removed"
v="$(devbox_handshake_verdict "$DEVBOX_PROTOCOL_VERSION ${ctl}abc" ../lib/devbox-lib.sh)"; vrc=$?
assert_eq "0" "$vrc" "an answer with control bytes in its fingerprint still speaks this protocol"
assert_ok "  and the report quotes that fingerprint with every control byte removed" \
  grep -qF "the server's ]0;owned[2Ja)" <<<"$v"
assert_fail "  and carries no ESC or BEL" grep -q $'[\033\a]' <<<"$v"

# ── what one protocol promises ───────────────────────────────────────────────
#
# A client and a host of one protocol may load different library bytes, so the
# handshake no longer sees a change to what this file computes. These values
# are that promise. Two halves that compute another slug or another Postgres
# name for one worktree put two checkouts on one Postgres role, which has
# happened once. A change that moves any value here is a protocol bump and a
# major release: change DEVBOX_PROTOCOL_VERSION, the major in VERSION, and the
# protocol and the values below, in one commit.
pinned_protocol=2
assert_eq "$pinned_protocol" "$DEVBOX_PROTOCOL_VERSION" \
  "the values below are the ones protocol $pinned_protocol promises; a bump re-reads them"
assert_eq "laptop-my-app-my-app-9bde2c" \
  "$(devbox_slug laptop 0123456789abcdef my-app /work/my-app)" \
  "protocol $pinned_protocol: the slug of a short worktree"
assert_eq "ws_laptop_my_app_my_app_9bde2c" \
  "$(devbox_pg_ident laptop-my-app-my-app-9bde2c)" \
  "protocol $pinned_protocol: the Postgres name of that slug"
assert_eq "laptop-w-a-project-with-a-v-a-worktree-with-a-e72ea1" \
  "$(devbox_slug laptop-with-a-long-name 0123456789abcdef a-project-with-a-very-long-name /work/a-worktree-with-a-very-long-name)" \
  "protocol $pinned_protocol: the slug of long names, each component cut to its width"
assert_eq "ws_laptop_w_a_project_with_a_v_a_worktree_with_a_e72ea1" \
  "$(devbox_pg_ident laptop-w-a-project-with-a-v-a-worktree-with-a-e72ea1)" \
  "protocol $pinned_protocol: the Postgres name of that slug"

# One protocol is one release major. A host on another minor release loads other
# bytes of the same protocol, and the verdict once refused it, so every release
# that touched this file forced every consumer to move its pin. The fingerprint
# is a report now, and only the integer refuses.
same_fp="$(devbox_lib_fingerprint ../lib/devbox-lib.sh)"
v="$(devbox_handshake_verdict "$DEVBOX_PROTOCOL_VERSION $same_fp" ../lib/devbox-lib.sh)"; vrc=$?
assert_eq "0" "$vrc" "one protocol and one library agree"
assert_ok "  and the report says the libraries are the same file" \
  grep -qF "load the same devbox-lib.sh (${same_fp:0:12})" <<<"$v"
other_fp="$(printf 'another minor release' | sha256sum | cut -d' ' -f1)"
v="$(devbox_handshake_verdict "$DEVBOX_PROTOCOL_VERSION $other_fp" ../lib/devbox-lib.sh)"; vrc=$?
assert_eq "0" "$vrc" "one protocol with another library is compatible"
assert_ok "  and the report names both fingerprints" \
  grep -qF "this client's ${same_fp:0:12}, the server's ${other_fp:0:12}" <<<"$v"
v="$(devbox_handshake_verdict "$DEVBOX_PROTOCOL_VERSION" ../lib/devbox-lib.sh)"; vrc=$?
assert_eq "0" "$vrc" "one protocol with no fingerprint is compatible"
assert_ok "  and the report says the server named none" grep -qF "names no library fingerprint" <<<"$v"
v="$(devbox_handshake_verdict "$((DEVBOX_PROTOCOL_VERSION + 1)) $same_fp" ../lib/devbox-lib.sh)"; vrc=$?
assert_eq "6" "$vrc" "the next protocol is refused even with the same library bytes"
v="$(devbox_handshake_verdict "$DEVBOX_PROTOCOL_VERSION $same_fp" /nonexistent/devbox-lib.sh)"; vrc=$?
assert_eq "0" "$vrc" "a library this client cannot fingerprint does not refuse the protocol"
assert_ok "  and the report says the libraries were not compared, never that they match" \
  grep -qF "were not compared" <<<"$v"

printf '%d %d\n' "$TESTS_RUN" "$TESTS_FAILED"
