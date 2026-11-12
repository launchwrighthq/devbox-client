#!/bin/bash
# The git common directory a worktree needs is synced INSIDE the checkout, and
# this is what stops git counting it as the developer's own untracked files.
#
# `.git-common/` holds thousands of files that exist under no laptop's checkout,
# so without an exclude the workspace's tree is one a project's tooling was
# never written against. MEASURED on a devbox host: thousands of untracked
# files against a handful on the laptop. A project tool that reads every
# untracked file grew past the workspace memory cap and was killed, twice, on an
# idle box, while locally it used a few MB.
#
# Read from the shipped library rather than driven, because the step runs
# inside a workspace. tests/test-sync.sh drives the same script against a real
# worktree. What these cases hold is each decision whose loss is silent.
#
# The step lived in client/libexec/devbox-sync as raw command strings for a
# remote root shell until protocol 6. It is devbox_sync_finish_script in
# lib/devbox-lib.sh now, which gate-root runs as dev in the workspace and
# devbox-runpod runs on a pod.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
# shellcheck source=tests/lib.sh
source ./lib.sh
LIB="$(cd .. && pwd)/lib/devbox-lib.sh"

contains() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }

# The script the function prints, so a case cannot pass on a line outside it.
# shellcheck source=lib/devbox-lib.sh
block="$(source "$LIB"; devbox_sync_finish_script)"
assert_ok "the sync finish script was found in the shipped library" test -n "$block"
# Comment lines dropped for every case below that is about what the script RUNS.
# Prose naming .gitignore must not satisfy, or fail, a case about the code.
code="$(printf '%s\n' "$block" | grep -v '^[[:space:]]*#')"
assert_ok "and it is the block that finishes the common dir" contains '.git-common/' "$block"

assert_ok "the exclude names the directory git must ignore" \
  contains "'.git-common/'" "$code"
assert_ok "it is written into the common dir's info/exclude" \
  contains '.git-common/info' "$code"

# info/exclude and never .gitignore. .gitignore is the PROJECT'S committed file,
# and this directory is the devbox's own artefact: a line written there is a
# local modification the developer did not make, on a file they do commit.
assert_fail "and never into the project's committed .gitignore" \
  contains '.gitignore' "$code"

# The rsync above refreshes info/exclude from the laptop's own copy every run, so
# an unguarded append adds one line per gate for the life of the workspace.
assert_ok "the append is guarded, so a second gate adds no second line" \
  contains 'grep -qxF' "$code"

# It must run after the gitdir pointers, because those are what make the common
# dir a git directory at all: an exclude written before them has nothing to sit in.
pointers="$(printf '%s\n' "$code" | grep -n 'gitdir:' | tail -1 | cut -d: -f1)"
exclude="$(printf '%s\n' "$code" | grep -n 'grep -qxF' | tail -1 | cut -d: -f1)"
assert_ok "the exclude is written after the gitdir pointers" \
  test -n "$pointers" -a -n "$exclude" -a "$exclude" -gt "$pointers"

printf '%d %d\n' "$TESTS_RUN" "$TESTS_FAILED"
