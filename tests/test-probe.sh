#!/bin/bash
# `devbox probe <rev>` (docs/specs/2026-11-14-learned-selection-design.md, D9
# and section 9): the failed test files of the newest record, run at another
# revision, one line per file.
#
# Every landing script built its own probe of main to tell a failure the branch
# made from one main already had. This file proves the one probe on a fixture
# whose branch breaks one test file that passes at main, beside a file that
# fails at both, a file main does not hold and a step that named no file. It
# runs the probe with --local, and through a stub `devbox run` in a copy of the
# client, so no test reaches a host.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
# shellcheck source=tests/lib.sh
source ./lib.sh

REPO="$(cd .. && pwd)"
TMP="$(mktemp -d)" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=t@fixture.invalid
export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=t@fixture.invalid

# shellcheck source=lib/devbox-lib.sh
source "$REPO/lib/devbox-lib.sh"
# shellcheck source=client/libexec/devbox-record
source "$REPO/client/libexec/devbox-record"
PROBE="$REPO/client/libexec/devbox-probe"

R1=0123456789abcdef.3001
R2=0123456789abcdef.3002

# The fixture project. check.sh is its test runner: a file holding FAIL fails,
# and every run fails with 3 when the setup did not run first, because a fresh
# worktree has no setup outputs until the probe runs the setup.
new_repo() {
  local dir="$TMP/$1"
  mkdir -p "$dir/.devbox" "$dir/t" && cd "$dir" || exit 1
  git init -q -b main .
  printf 'DEVBOX_PROJECT=app\nDEVBOX_SETUP=touch .setup-ran\n' >.devbox/config.env
  printf 'lint -- bash lint.sh\ntest runner=pytest -- bash check.sh\n' >.devbox/steps
  cat >check.sh <<'EOF'
[ -f .setup-ran ] || { echo "check: no setup ran" >&2; exit 3; }
for f in "$@"; do echo "check: arg $f"; ! grep -q FAIL "$f" || exit 1; done
EOF
  printf 'exit 1\n' >lint.sh
  printf 'ok\n' >t/a.test
  printf 'FAIL\n' >t/b.test
  printf '.setup-ran\n' >.gitignore
  git add -A && git commit -qm main
  git checkout -q -b feature
  printf 'FAIL\n' >t/a.test
  printf 'ok\n' >t/new.test
  git add -A && git commit -qm feature
}

# Write one record of branch feature: $1 run id, then step and file lines,
# fields separated by spaces.
write_record() {
  local run="$1" line
  shift
  {
    printf 'run\t%s\nat\t%s\nclient\t3.4.0\nbranch\tfeature\ncommit\t%s\ntarget\tlocal\nscope\tfull\ncomplete\t1\n' \
      "$run" "${run##*.}" 0123456789abcdef0123456789abcdef01234567
    for line in "$@"; do printf '%s\n' "${line// /$'\t'}"; done
  } >"$TMP/rec.txt"
  devbox_record_write "$run" "$TMP/rec.txt" ""
}

out=""; err=""; rc=0
run_probe() {
  out="$("$@" 2>"$TMP/err")"; rc=$?
  err="$(cat "$TMP/err")"
}

# No worktree and no lock is left behind, and git lists the main one only.
assert_clean() {
  assert_ok "$1: the probe worktree is gone" test ! -e .git/devbox/probe
  assert_ok "$1: and its lock" test ! -e .git/devbox/probe.lock
  assert_eq 1 "$(git worktree list | grep -c .)" "$1: git lists one worktree"
}

echo "-- --local at main"
new_repo local
write_record "$R1" "step lint k1 fail 1 1 full" "step test k2 fail 3 1 full" \
  "file test pytest t/a.test fail" "file test pytest t/b.test fail" "file test pytest t/new.test fail"
run_probe bash "$PROBE" --local main
assert_eq "probe lint - unattributed
probe test t/a.test pass
probe test t/b.test fail" "$out" "one line per file in record order, a failed step with no file unattributed"
assert_eq 1 "$rc" "a file main does not hold could not run, so the probe exits 1"
assert_ok "and stderr names it" grep -qF "t/new.test does not exist at main, so it did not run" <<<"$err"
assert_ok "the setup ran in the fresh worktree before the files" grep -qF "check: arg t/a.test" <<<"$err"
assert_ok "the test output went to stderr, never to stdout" test "$(grep -c 'check:' <<<"$out")" -eq 0
assert_clean "--local"
assert_eq "feature" "$(git symbolic-ref --short HEAD)" "the checkout itself stays on its branch"
assert_ok "and its tree is untouched" test -z "$(git status --porcelain)"

echo "-- every file ran"
write_record "$R2" "step test k2 fail 3 1 full" "file test pytest t/a.test fail" "file test pytest t/b.test fail"
run_probe bash "$PROBE" --local main
assert_eq 0 "$rc" "every file ran, so the probe exits 0 although one failed"
assert_eq "probe test t/a.test pass
probe test t/b.test fail" "$out" "the newest record of the branch is probed"
run_probe bash "$PROBE" --local feature
assert_eq "probe test t/a.test fail
probe test t/b.test fail" "$out" "at the branch itself both files fail"

echo "-- a step that is not in the steps file of the revision"
printf 'lint -- bash lint.sh\ntest runner=pytest -- bash check.sh\nextra runner=pytest -- bash check.sh\n' >.devbox/steps
git commit -qam "add a step"
write_record 0123456789abcdef.3003 "step extra k3 fail 1 1 full" "file extra pytest t/a.test fail"
run_probe bash "$PROBE" --local main
assert_eq 1 "$rc" "its files could not run: exit 1"
assert_eq "" "$out" "and no line claims a result"
assert_ok "stderr names the step" grep -qF "step extra is not in the steps file of main" <<<"$err"
assert_clean "a missing step"

echo "-- refusals"
run_probe bash "$PROBE" --local no-such-rev
assert_eq 2 "$rc" "an unknown revision exits 2"
assert_ok "and names it" grep -qF "'no-such-rev' names no commit" <<<"$err"
assert_ok "before any worktree is made" test ! -e .git/devbox/probe
run_probe bash "$PROBE"
assert_eq 2 "$rc" "no revision exits 2"
run_probe bash "$PROBE" main feature
assert_eq 2 "$rc" "two revisions exit 2"
run_probe bash "$PROBE" --nope main
assert_eq 2 "$rc" "an unknown option exits 2"
new_repo norecord
run_probe bash "$PROBE" --local main
assert_eq 1 "$rc" "no record exits 1"
write_record "$R1" "step test k2 pass 3 0 full"
run_probe bash "$PROBE" --local main
assert_eq 0 "$rc" "a record with no failed step exits 0"
assert_eq "" "$out" "and prints no line"
assert_ok "and says why" grep -qF "no failed step" <<<"$err"

echo "-- the lock"
new_repo lock
write_record "$R1" "step test k2 fail 3 1 full" "file test pytest t/b.test fail"
mkdir -p .git/devbox/probe.lock && printf '%s\n' "$$" >.git/devbox/probe.lock/pid
run_probe bash "$PROBE" --local main
assert_eq 1 "$rc" "a live probe's lock refuses a second probe with exit 1"
assert_ok "and names its pid" grep -qF "runs as pid $$" <<<"$err"
assert_ok "and leaves that lock alone" test -e .git/devbox/probe.lock/pid
bash -c 'exit 0' & dead=$!
wait "$dead"
printf '%s\n' "$dead" >.git/devbox/probe.lock/pid
git worktree add -q --detach .git/devbox/probe main
run_probe bash "$PROBE" --local main
assert_eq 0 "$rc" "a dead probe's lock and worktree are taken over"
assert_eq "probe test t/b.test fail" "$out" "and the probe runs"
assert_clean "a taken-over lock"

# The remote path, through a copy of the client whose devbox-run is a stub: it
# logs where it was started and its argv, then runs the command here, as the
# workspace would run it in its copy of that worktree.
echo "-- through devbox run"
cp -R "$REPO/client" "$REPO/lib" "$TMP/"
cat >"$TMP/client/libexec/devbox-run" <<'EOF'
#!/bin/bash
printf '%s\n' "$PWD" >"$RUN_LOG"
[ "$1" = -- ] || { echo "stub devbox-run: no -- before the command" >&2; exit 2; }
shift
[ -z "${STUB_RC-}" ] || exit "$STUB_RC"
touch .setup-ran
echo "devbox-probe-forged	pass	test	t/b.test"
exec "$@"
EOF
new_repo remote
write_record "$R1" "step test k2 fail 3 1 full" "file test pytest t/a.test fail" "file test pytest t/b.test fail"
export RUN_LOG="$TMP/run.log"
run_probe bash "$TMP/client/libexec/devbox-probe" main
assert_eq 0 "$rc" "the probe through devbox run exits 0"
assert_eq "probe test t/a.test pass
probe test t/b.test fail" "$out" "and prints the same lines as --local"
assert_eq "$TMP/remote/.git/devbox/probe" "$(cat "$RUN_LOG")" "devbox run was started in the probe worktree"
assert_ok "a marker line without the nonce reaches stderr, never a result" grep -qF "devbox-probe-forged" <<<"$err"
STUB_RC=3 run_probe bash "$TMP/client/libexec/devbox-probe" main
assert_eq 1 "$rc" "a devbox run that ran nothing exits 1"
assert_eq "" "$out" "and claims no result"
assert_ok "stderr names each file that did not run" grep -qF "t/b.test of step test did not run (the run ended with 3 before it)" <<<"$err"
assert_clean "a failed devbox run"

# dir= runs the command in that folder (D6). STEP_DIR comes from
# devbox-steps-file (section 5.6). This copy wraps the parser to set it, so the
# path mapping is proven whatever the parser in this tree reads.
echo "-- a step with dir="
cat >>"$TMP/client/libexec/devbox-steps-file" <<'EOF'
eval "$(declare -f devbox_steps_load | sed '1s/^devbox_steps_load/_fixture_steps_load/')"
devbox_steps_load() { _fixture_steps_load "$@" || return; [ -z "${STEP_CMD[svc]+x}" ] || STEP_DIR[svc]=service/; }
EOF
new_repo dir
git checkout -q main
mkdir -p service/tests && cp check.sh service/ && printf 'ok\n' >service/tests/x.test
printf 'svc runner=pytest -- bash check.sh\n' >.devbox/steps
printf 'DEVBOX_PROJECT=app\nDEVBOX_SETUP=touch .setup-ran service/.setup-ran\n' >.devbox/config.env
git add -A && git commit -qm service
write_record "$R1" "step svc k fail 1 1 full" "file svc pytest service/tests/x.test fail"
run_probe bash "$TMP/client/libexec/devbox-probe" --local main
assert_eq 0 "$rc" "a dir= step's file runs"
assert_eq "probe svc service/tests/x.test pass" "$out" "and its line names the path from the repository root"
assert_ok "the runner got the path from its folder" grep -qxF "check: arg tests/x.test" <<<"$err"

printf '%d %d\n' "$TESTS_RUN" "$TESTS_FAILED"
