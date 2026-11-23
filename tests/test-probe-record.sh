#!/bin/bash
# `devbox probe --record [--local] [--from <worktree>] [--wait <s>] <files...>`:
# the named failed files, run in the current checkout, with the failures line
# of a gate as the last stdout line when one fails.
#
# A landing script merges the base into a detached worktree and must learn
# which failed files of the branch's gate fail there too. The fixture is that
# case: the branch breaks one test file that passes at main, beside a file that
# fails at both. The probe runs with --local, and through a stub `devbox run`
# in a copy of the client, so no test reaches a host.
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

# The fixture project of test-probe.sh: a file holding FAIL fails, and every
# run fails with 3 when the setup did not run first. The checkout $TMP/<name>
# is on branch feature, and $TMP/<name>-base is a detached worktree at main.
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
  printf 'ok\n' >t/c.test
  printf '.setup-ran\n' >.gitignore
  git add -A && git commit -qm main
  git checkout -q -b feature
  printf 'FAIL\n' >t/a.test
  git add -A && git commit -qm feature
  git worktree add -q --detach "$dir-base" main
}

# Write one record: $1 run id, $2 branch, then step and file lines, fields
# separated by spaces.
write_record() {
  local run="$1" branch="$2" line
  shift 2
  {
    printf 'run\t%s\nat\t%s\nclient\t3.4.0\nbranch\t%s\ncommit\t%s\ntarget\tlocal\nscope\tfull\ncomplete\t1\n' \
      "$run" "${run##*.}" "$branch" 0123456789abcdef0123456789abcdef01234567
    for line in "$@"; do printf '%s\n' "${line// /$'\t'}"; done
  } >"$TMP/rec.txt"
  devbox_record_write "$run" "$TMP/rec.txt" ""
}

out=""; err=""; rc=0
run_probe() {
  out="$("$@" 2>"$TMP/err")"; rc=$?
  err="$(cat "$TMP/err")"
}

# No probe worktree was made and no lock is left: $1 the label, $2 the checkout
# that holds the git directory.
assert_clean() {
  assert_ok "$1: no probe worktree was made" test ! -e "$2/.git/devbox/probe"
  assert_ok "$1: and no lock is left" test ! -e "$2/.git/devbox/probe.lock"
  assert_eq 2 "$(git -C "$2" worktree list | grep -c .)" "$1: git lists the two worktrees of the fixture"
}

echo "-- in the checkout of the record"
new_repo own
write_record 0123456789abcdef.3001 feature "step lint k1 fail 1 1 full" "step test k2 fail 3 1 full" \
  "file test pytest t/a.test fail" "file test pytest t/b.test fail"
run_probe bash "$PROBE" --record --local t/b.test t/a.test
assert_eq 'probe test t/a.test fail
probe test t/b.test fail
verify: failures {"test": {"code": 1, "attributable": true, "failedFiles": ["t/a.test", "t/b.test"]}}' "$out" \
  "one line per file in record order, then the failures line as the last line"
assert_eq 1 "$rc" "a failed file exits 1"
assert_ok "the setup ran before the files" grep -qF "check: arg t/a.test" <<<"$err"
assert_ok "the test output went to stderr, never to stdout" test "$(grep -c 'check:' <<<"$out")" -eq 0
assert_clean "the own checkout" "$TMP/own"
assert_eq "feature" "$(git symbolic-ref --short HEAD)" "the checkout stays on its branch"

echo "-- in a detached worktree of the base, with --from"
cd "$TMP/own-base" || exit 1
run_probe bash "$PROBE" --record --local --from "$TMP/own" t/a.test t/b.test
assert_eq 'probe test t/a.test pass
probe test t/b.test fail
verify: failures {"test": {"code": 1, "attributable": true, "failedFiles": ["t/b.test"]}}' "$out" \
  "the files run at the base, and the failures line names the one that fails there"
assert_eq 1 "$rc" "and the probe exits 1"
assert_clean "a detached worktree" "$TMP/own"
run_probe bash "$PROBE" --record --local --from "$TMP/own" ./t/a.test
assert_eq "probe test t/a.test pass" "$out" "a file that passes prints its line and no failures line"
assert_eq 0 "$rc" "every file passed, so the probe exits 0"

# A newer record of another branch is the newest of any, which a detached
# worktree reads when it has no --from.
echo "-- the record --from picks"
(cd "$TMP/own" && write_record 0123456789abcdef.3002 other "step test k2 fail 3 1 full" "file test pytest t/c.test fail")
run_probe bash "$PROBE" --record --local t/a.test
assert_eq 2 "$rc" "without --from the newest record of any branch does not name the file: exit 2"
assert_eq "" "$out" "and no line claims a result"
assert_ok "stderr names the file" grep -qF "t/a.test is not a failed file of the newest record" <<<"$err"
run_probe bash "$PROBE" --record --local --from "$TMP/own" t/a.test
assert_eq 0 "$rc" "with --from the record of that checkout's branch names it"

echo "-- refusals"
run_probe bash "$PROBE" --record --local --from "$TMP/own" t/a.test t/nope.test
assert_eq 2 "$rc" "an unknown file exits 2"
assert_eq "" "$out" "and no file ran"
assert_ok "stderr names it" grep -qF "t/nope.test is not a failed file" <<<"$err"
run_probe bash "$PROBE" --record --local
assert_eq 2 "$rc" "no file exits 2"
assert_ok "with the usage of the record mode" grep -qF "devbox probe --record [--local] [--from <worktree>] [--wait <s>] <files...>" <<<"$err"
run_probe bash "$PROBE" --record --local --from "$TMP/no-such-dir" t/a.test
assert_eq 2 "$rc" "a --from outside a git checkout exits 2"
run_probe bash "$PROBE" --record --local --wait soon t/a.test
assert_eq 2 "$rc" "a --wait that is no number exits 2"
run_probe bash "$PROBE" --from "$TMP/own" main
assert_eq 2 "$rc" "--from without --record exits 2"
run_probe bash "$PROBE" --wait 1 main
assert_eq 2 "$rc" "--wait without --record exits 2"
git -C "$TMP/own" rm -q t/b.test && git -C "$TMP/own" commit -qm "drop b"
cd "$TMP/own" || exit 1
run_probe bash "$PROBE" --record --local t/a.test t/b.test
assert_eq 2 "$rc" "a file this checkout does not hold exits 2"
assert_eq "" "$out" "and no other file ran"
assert_ok "stderr names it" grep -qF "t/b.test does not exist at this checkout" <<<"$err"
assert_ok "and the lock of that refusal is released" test ! -e "$TMP/own/.git/devbox/probe.lock"
new_repo norecord
run_probe bash "$PROBE" --record --local t/a.test
assert_eq 2 "$rc" "no record exits 2"
assert_eq "" "$out" "and prints no line"
# A command that ends the probe by itself must not exit 1, which a caller reads
# as a failed file: a bare repository has no top level, and git exits 128.
git init -q --bare "$TMP/bare.git" && cd "$TMP/bare.git" || exit 1
run_probe bash "$PROBE" --record --local t/a.test
assert_eq 2 "$rc" "a probe that a failed command ends exits 2, never 1"
assert_eq "" "$out" "and prints no failures line"

echo "-- the lock"
new_repo lock
write_record 0123456789abcdef.3001 feature "step test k2 fail 3 1 full" "file test pytest t/b.test fail"
mkdir -p .git/devbox/probe.lock && printf '%s\n' "$$" >.git/devbox/probe.lock/pid
run_probe bash "$PROBE" --record --local t/b.test
assert_eq 2 "$rc" "a live probe's lock refuses the record mode with exit 2"
assert_ok "and names its pid" grep -qF "runs as pid $$" <<<"$err"
assert_eq "" "$out" "and prints no line"
assert_ok "and leaves that lock alone" test -e .git/devbox/probe.lock/pid
started=$SECONDS
run_probe bash "$PROBE" --record --local --wait 1 t/b.test
assert_eq 2 "$rc" "--wait 1 exits 2 when the lock stays held"
assert_ok "after it waited" test "$((SECONDS - started))" -ge 1
assert_eq "" "$out" "and no file ran"
(sleep 1; rm -rf .git/devbox/probe.lock) &
run_probe bash "$PROBE" --record --local --wait 30 t/b.test
wait
assert_eq 1 "$rc" "--wait takes a lock that is freed in time, and the file runs"
assert_eq 'probe test t/b.test fail
verify: failures {"test": {"code": 1, "attributable": true, "failedFiles": ["t/b.test"]}}' "$out" "with its lines"
assert_clean "a waited lock" "$TMP/lock"
dead="$(bash -c 'echo $$')"
mkdir -p .git/devbox/probe.lock && printf '%s\n' "$dead" >.git/devbox/probe.lock/pid
run_probe bash "$PROBE" --record --local t/b.test
assert_eq 1 "$rc" "a dead probe's lock is taken over, and the file runs"
assert_clean "a taken-over lock" "$TMP/lock"
printf 'DEVBOX_PROJECT=app\nDEVBOX_SETUP=exit 7\n' >.devbox/config.env
run_probe bash "$PROBE" --record --local t/b.test
assert_eq 2 "$rc" "a setup that fails under --local exits 2"
assert_eq "" "$out" "and prints no line and no failures line"
assert_clean "a failed setup" "$TMP/lock"

# The remote path, through a copy of the client whose devbox-run is a stub: it
# logs where it was started, then runs the command here.
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
write_record 0123456789abcdef.3001 feature "step test k2 fail 3 1 full" "file test pytest t/a.test fail" "file test pytest t/b.test fail"
export RUN_LOG="$TMP/run.log"
cd "$TMP/remote-base" || exit 1
run_probe bash "$TMP/client/libexec/devbox-probe" --record --from "$TMP/remote" t/a.test t/b.test
assert_eq 1 "$rc" "the record mode through devbox run exits 1 for a failed file"
assert_eq 'probe test t/a.test pass
probe test t/b.test fail
verify: failures {"test": {"code": 1, "attributable": true, "failedFiles": ["t/b.test"]}}' "$out" "and prints the same lines as --local"
assert_eq "$TMP/remote-base" "$(cat "$RUN_LOG")" "devbox run was started in the current checkout"
assert_ok "a marker line without the nonce reaches stderr, never a result" grep -qF "devbox-probe-forged" <<<"$err"
STUB_RC=3 run_probe bash "$TMP/client/libexec/devbox-probe" --record --from "$TMP/remote" t/a.test t/b.test
assert_eq 2 "$rc" "a devbox run that ran nothing exits 2"
assert_eq "" "$out" "and prints no line and no failures line"
assert_ok "stderr names each file that did not run" grep -qF "t/b.test of step test did not run (the run ended with 3 before it)" <<<"$err"
assert_clean "a failed devbox run" "$TMP/remote"

# dir= runs the command in that folder. This copy wraps the parser to set
# STEP_DIR, as tests/test-probe.sh does. Two steps name one file here, so the
# file runs once under each, and the failures line holds one entry per step.
echo "-- a step with dir=, and a file of two steps"
cat >>"$TMP/client/libexec/devbox-steps-file" <<'EOF'
eval "$(declare -f devbox_steps_load | sed '1s/^devbox_steps_load/_fixture_steps_load/')"
devbox_steps_load() { _fixture_steps_load "$@" || return; [ -z "${STEP_CMD[svc]+x}" ] || STEP_DIR[svc]=service/; }
EOF
new_repo dir
mkdir -p service/tests && cp check.sh service/
printf 'FAIL\n' >service/tests/x.test && printf 'ok\n' >service/tests/y.test
printf 'svc runner=pytest -- bash check.sh\nall runner=pytest -- bash check.sh\n' >.devbox/steps
printf 'DEVBOX_PROJECT=app\nDEVBOX_SETUP=touch .setup-ran service/.setup-ran\n' >.devbox/config.env
printf '.setup-ran\nservice/.setup-ran\n' >.gitignore
git add -A && git commit -qm service
write_record 0123456789abcdef.3001 feature "step svc k fail 1 1 full" "step all k fail 1 1 full" \
  "file svc pytest service/tests/x.test fail" "file svc pytest service/tests/y.test fail" \
  "file all pytest service/tests/x.test fail"
run_probe bash "$TMP/client/libexec/devbox-probe" --record --local service/tests/y.test service/tests/x.test
assert_eq 1 "$rc" "a dir= step's failed file exits 1"
assert_eq 'probe svc service/tests/x.test fail
probe svc service/tests/y.test pass
probe all service/tests/x.test fail
verify: failures {"svc": {"code": 1, "attributable": true, "failedFiles": ["service/tests/x.test"]}, "all": {"code": 1, "attributable": true, "failedFiles": ["service/tests/x.test"]}}' "$out" \
  "each line names the path from the repository root, and a file of two steps runs under each"
assert_ok "the dir= runner got the path from its folder" grep -qxF "check: arg tests/x.test" <<<"$err"
assert_ok "the step without dir= got the path from the root" grep -qxF "check: arg service/tests/x.test" <<<"$err"
assert_clean "a dir= step" "$TMP/dir"

printf '%d %d\n' "$TESTS_RUN" "$TESTS_FAILED"
