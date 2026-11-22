#!/bin/bash
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
# shellcheck source=tests/lib.sh
source ./lib.sh
REPO="$(cd .. && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# shellcheck source=client/libexec/devbox-sync
source "$REPO/client/libexec/devbox-sync"
# shellcheck source=lib/devbox-lib.sh
source "$REPO/lib/devbox-lib.sh"
git -C "$TMP" init -q source
mkdir -p "$TMP/source/.devbox" "$TMP/target"
touch "$TMP/source/.devbox/exclude"
DEVBOX_EXCLUDE=.devbox/exclude
echo one > "$TMP/source/tracked"
echo template > "$TMP/source/.env.staging.example"
git -C "$TMP/source" add .devbox tracked .env.staging.example
git -C "$TMP/source" -c user.name=Test -c user.email=test@example.invalid commit -qm fixture
git -C "$TMP/source" worktree add -qb fixture "$TMP/worktree"
git -C "$TMP/source" worktree add -qb peer "$TMP/peer"
ROOT="$TMP/worktree"
SYNC_DEST="$TMP/target"
# The two remote steps devbox-sync asks its caller for, with only the transport
# removed: real rsync into the target, and the real finish script from
# lib/devbox-lib.sh run by a local bash, the way gate-root runs it in the
# workspace. Source deletion, cache protection and the gitdir pointers execute.
devbox_sync_push() {
  local sub="$1"; shift
  command rsync "$@" "$SYNC_DEST/${sub:+$sub/}"
}
devbox_sync_finish() {
  devbox_sync_finish_script | bash -s -- "$SYNC_DEST" "$1"
}
cd "$ROOT" || exit
echo private > .env.staging
echo private > .devbox.env
echo private > signing.pem
mkdir -p "$(git rev-parse --git-dir)/devbox-runpod" "$SYNC_DEST/node_modules"
mkdir -p "$SYNC_DEST/.git-common/worktrees/peer"
echo stale > "$SYNC_DEST/.git-common/worktrees/peer/index"
echo private > "$(git rev-parse --git-dir)/devbox-runpod/key"
# The Hetzner rental's record holds its server's gate password.
mkdir -p "$(git rev-parse --git-dir)/devbox-hetzner"
echo private > "$(git rev-parse --git-dir)/devbox-hetzner/gate-password"
echo cached > "$SYNC_DEST/node_modules/cache"
# devbox's own records and maps sit in the common dir, and a workspace from an
# older client already holds a copy of them.
mkdir -p "$(git rev-parse --path-format=absolute --git-common-dir)/devbox/records" \
  "$SYNC_DEST/.git-common/devbox/records"
echo log > "$(git rev-parse --path-format=absolute --git-common-dir)/devbox/records/run.log"
echo stale > "$SYNC_DEST/.git-common/devbox/records/old.log"
echo untracked > new-source
mkdir -p .idea .playwright-mcp playwright-report test-results .claude/logs .claude/state .claude/worktrees/peer
for f in .idea/workspace.xml .aider.chat.history.md .playwright-mcp/page.png playwright-report/index.html \
  test-results/run.json .claude/settings.local.json .claude/logs/session.log .claude/state/goal.json .claude/worktrees/peer/file; do
  echo scratch > "$f"
done
echo shared > .claude/settings.json
mkdir -p vendor/pkg/1.0.0 vendor/devbox/client
echo wheel > vendor/pkg/1.0.0/pkg-1.0.0-py3-none-any.whl
echo clone > vendor/devbox/client/marker
assert_ok 'syncs a linked checkout using the shared helper' devbox_sync
assert_eq wheel "$(cat "$SYNC_DEST/vendor/pkg/1.0.0/pkg-1.0.0-py3-none-any.whl")" 'sends a vendored package under vendor/'
assert_fail 'does not send the vendored client clone' test -e "$SYNC_DEST/vendor/devbox"
assert_eq fixture "$(git -C "$SYNC_DEST" branch --show-current)" 'retains the real branch, not a synthetic clone'
assert_eq "$(git rev-parse HEAD)" "$(git -C "$SYNC_DEST" rev-parse HEAD)" 'retains the checkout commit and its shared objects'
assert_fail 'removes a prior copy of an unrelated worktree' test -e "$SYNC_DEST/.git-common/worktrees/peer"
assert_fail 'does not send the records and maps in the common dir' test -e "$SYNC_DEST/.git-common/devbox/records/run.log"
assert_fail 'removes the copy of them an older client sent' test -e "$SYNC_DEST/.git-common/devbox"
assert_eq one "$(cat "$SYNC_DEST/tracked")" 'copies tracked source'
assert_eq untracked "$(cat "$SYNC_DEST/new-source")" 'copies new source'
assert_eq template "$(cat "$SYNC_DEST/.env.staging.example")" 'keeps credential templates'
for file in .env.staging .devbox.env signing.pem .git-common/worktrees/worktree/devbox-runpod/key \
  .git-common/worktrees/worktree/devbox-hetzner/gate-password \
  .idea .aider.chat.history.md .playwright-mcp playwright-report test-results \
  .claude/settings.local.json .claude/logs .claude/state .claude/worktrees; do
  assert_fail "does not transfer $file" test -e "$SYNC_DEST/$file"
done
assert_eq shared "$(cat "$SYNC_DEST/.claude/settings.json")" 'still transfers the rest of .claude/'
rm tracked new-source
echo two > changed
assert_ok 'repeats sync after local edits' devbox_sync
assert_fail 'removes deleted tracked source' test -e "$SYNC_DEST/tracked"
assert_fail 'removes deleted untracked source' test -e "$SYNC_DEST/new-source"
assert_eq cached "$(cat "$SYNC_DEST/node_modules/cache")" 'retains installed dependency cache'
assert_eq two "$(cat "$SYNC_DEST/changed")" 'copies edited source'
assert_fail 'does not upload an unrelated worktree on repeat sync' test -e "$SYNC_DEST/.git-common/worktrees/peer"
assert_eq 1 "$(grep -cxF .git-common/ "$SYNC_DEST/.git-common/info/exclude")" 'excludes internal history exactly once'
# A `.venv` symlink already in the workspace is protected from `--delete` by the
# exclude rule, so the finish script is the only step that removes it.
ln -s /nonexistent/laptop/venv "$SYNC_DEST/.venv"
assert_ok 'a third sync runs with a stale .venv symlink in the workspace' devbox_sync
assert_fail 'and the finish step removed that symlink' test -L "$SYNC_DEST/.venv"
assert_eq "gitdir: $SYNC_DEST/.git-common/worktrees/worktree" "$(cat "$SYNC_DEST/.git")" \
  'the workspace .git points at the synced common dir, not at the laptop'

# A folder the laptop no longer has leaves the workspace whole. Its protected and
# excluded entries once kept it there: a seeded workspace held two module folders
# of a sibling branch with only ts/node_modules in them, and rsync exited 0.
printf '# a comment\n- dist/\ncoverage/\n' > .devbox/exclude
for d in gone/ts/node_modules/pkg gone/.venv/bin gone/.pytest_cache gone/dist gone/coverage gone/ts/.idea; do
  mkdir -p "$SYNC_DEST/$d"
  echo stale > "$SYNC_DEST/$d/file"
done
mkdir -p live dist coverage "$SYNC_DEST/live/node_modules/pkg"
echo source > live/file
echo built > dist/out
echo report > coverage/index
echo cached > "$SYNC_DEST/live/node_modules/pkg/file"
out="$(devbox_sync 2>&1)"; rc=$?
assert_eq 0 "$rc" 'a sync runs with a folder in the workspace that the laptop no longer has'
case "$out" in *"cannot delete"*) _fail 'and rsync deleted every folder it was asked to' "got: $out" ;;
  *) _pass 'and rsync deleted every folder it was asked to' ;; esac
assert_fail 'that folder is gone with its node_modules, venv, caches and excluded files' test -e "$SYNC_DEST/gone"
assert_eq cached "$(cat "$SYNC_DEST/live/node_modules/pkg/file")" 'a live folder keeps its node_modules'
assert_eq cached "$(cat "$SYNC_DEST/node_modules/cache")" 'the root node_modules stays'
assert_fail 'a "- " line of the exclude file still excludes' test -e "$SYNC_DEST/dist"
assert_fail 'a bare line of the exclude file still excludes' test -e "$SYNC_DEST/coverage"
assert_fail 'a comment line of the exclude file is no pattern' test -e "$SYNC_DEST/# a comment"
mv .devbox/exclude .devbox/exclude.moved
assert_ok 'a checkout with no exclude file syncs with the built-in rules' devbox_sync
assert_eq report "$(cat "$SYNC_DEST/coverage/index")" 'and nothing it would name is excluded'
mv .devbox/exclude.moved .devbox/exclude

# A caller that defines no remote step gets a refusal, never a sync that ran
# half its steps against nothing.
out="$(unset -f devbox_sync_finish; devbox_sync 2>&1)"; rc=$?
assert_eq 1 "$rc" 'a caller without devbox_sync_finish is refused'
case "$out" in *"defines no devbox_sync_finish"*) _pass 'and the refusal names the missing step' ;;
  *) _fail 'and the refusal names the missing step' "got: $out" ;; esac
printf '%d %d\n' "$TESTS_RUN" "$TESTS_FAILED"
