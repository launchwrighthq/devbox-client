#!/bin/bash
# The release version is written in three files, and the protocol version in
# one. This pins both.
#
# The release version has to agree across VERSION, package.json and
# pyproject.toml because a project pins the client in a lockfile: a wheel that
# calls itself 1.0.0 while VERSION says 1.1.0 makes `devbox version`, the tag
# and the lockfile three different answers to "which client is this", and the
# first place that shows up is a bug report nobody can reproduce.
#
# The protocol version is a DIFFERENT number, and the release MAJOR moves with
# it. A client refuses a host of another protocol and runs with any host of its
# own, so one major is one protocol: a minor or patch release of the server
# never forces a consumer to move its pin, and a major release always does.
#
# Every value is parsed with grep, sed and awk. jq and a TOML reader are not
# prerequisites of this repository, and a test that needs one is a test that
# silently stops running.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
# shellcheck source=tests/lib.sh
source ./lib.sh
REPO="$(cd .. && pwd)"

# ── the release version ──────────────────────────────────────────────────────
release=""
read -r release <"$REPO/VERSION" || true

# The dispatcher reads this file with one `read -r`, so anything past the first
# line is invisible to `devbox version` while still being visible to a human
# editing the file. Pin it to one line rather than let the two disagree.
assert_eq "1" "$(grep -c . "$REPO/VERSION")" \
  "VERSION holds exactly one non-empty line, which is all the CLI reads"

is_semver() { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; }
assert_ok "VERSION is a release version, not an empty or half-written file" \
  is_semver "$release"

# The first "version": "..." at the top level of the manifest. package.json has
# one, and taking the first match keeps this from reading a dependency's.
npm_version="$(sed -n 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
  "$REPO/package.json" | head -1)"
assert_eq "$release" "$npm_version" \
  "package.json's version equals VERSION"

# The `version = "..."` under [project]. It is the first such assignment in the
# file; hatchling's own tables carry no version key.
py_version="$(sed -n 's/^version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' \
  "$REPO/pyproject.toml" | head -1)"
assert_eq "$release" "$py_version" \
  "pyproject.toml's version equals VERSION"

# ── the protocol version ─────────────────────────────────────────────────────
#
# Read as TEXT, not by sourcing the library. Sourcing would accept
# DEVBOX_PROTOCOL_VERSION="1 " or a value computed at run time, and the client
# compares this number against a server's answer with a string comparison, so
# the literal is what matters.
proto="$(sed -n 's/^DEVBOX_PROTOCOL_VERSION=\(.*\)$/\1/p' "$REPO/lib/devbox-lib.sh")"

assert_ok "lib/devbox-lib.sh carries a DEVBOX_PROTOCOL_VERSION" \
  test -n "$proto"
# devbox-runner prints this verbatim and devbox-verify refuses anything that is
# not all digits, so a quoted, spaced or dotted value would make every server
# built from this library fail its own client's handshake.
is_bare_integer() { [[ "$1" =~ ^[0-9]+$ ]]; }
assert_ok "the protocol version is a bare non-negative integer" \
  is_bare_integer "$proto"

# One assignment, in the library both halves read. A second one anywhere in the
# payload is a second answer to "which protocol does this half speak", which is
# the drift the handshake exists to detect.
assign_count="$(grep -rc '^DEVBOX_PROTOCOL_VERSION=' \
  "$REPO/client" "$REPO/server" "$REPO/lib" | awk -F: '{n += $2} END {print n + 0}')"
assert_eq "1" "$assign_count" \
  "exactly one file in the payload assigns DEVBOX_PROTOCOL_VERSION"

# The protocol IS the release major. Releases 1.0.0 and 1.1.x spoke protocol 8,
# and a reader had to know an offset of 7 to tell a host's release from its
# version answer, so 2.0.0 renumbered it. A protocol bump without a major
# release would ship as a minor release that every older client of that major
# refuses, and a major release without a protocol bump would make consumers
# move their pin for nothing.
release_major="${release%%.*}"
assert_eq "$release_major" "$proto" \
  "the protocol equals the release major: one major is one protocol"

# The CLI's own answer, which no other test reads.
# `devbox version` resolves the library at run time and prints what it found, so
# a client that loaded a stale /usr/local/lib/devbox copy, or a second
# assignment further down the library, prints a number this file never saw. The
# verb is answered inside the dispatcher and opens no connection.
printed_proto="$("$REPO/client/bin/devbox" version 2>/dev/null \
  | sed -n 's/^protocol \(.*\)$/\1/p')"
assert_eq "$proto" "$printed_proto" \
  "devbox version prints the protocol version that lib/devbox-lib.sh assigns"

printf '%d %d\n' "$TESTS_RUN" "$TESTS_FAILED"
