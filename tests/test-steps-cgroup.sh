#!/bin/bash
# cgroup=nested in client/share/steps/devbox-steps: a step whose shell sits at
# cgroup depth 0 or 1 moves into devbox/<name> before its command starts, a
# step at depth 2 or more stays where it is, and a step that cannot be moved
# fails with a line that names the cause instead of running shallow.
#
# The risks: a test that asserts its cgroup depth fails on a reason the log
# never named, a test that skips on a shallow path passes having tested
# nothing, the moved pid is not the step's own shell, and a cgroup the step
# left busy fails a step that passed.
#
# The cgroup hierarchy is a folder under this file's mktemp -d, given to the
# runner as DEVBOX_CGROUP_ROOT, and /proc/self/cgroup is a file given as
# DEVBOX_PROC_CGROUP. `sudo` is a stub first on PATH that plays the kernel's
# part and refuses any path outside that folder, so no case here touches the
# real /sys/fs/cgroup or runs the real sudo.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
# shellcheck source=tests/lib.sh
source ./lib.sh
REPO="$(cd .. && pwd)"
STEPS="$REPO/client/share/steps/devbox-steps"

TMP="$(mktemp -d)" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
unset DEVBOX_STEPS_PLAN DEVBOX_STEPS_LOGS DEVBOX_LEDGER DEVBOX_RESUME DEVBOX_LEDGER_TOOLS \
  DEVBOX_TOKENS DEVBOX_WORKER_MEMORY DEVBOX_CGROUP_ROOT DEVBOX_PROC_CGROUP DEVBOX_WORKERS \
  DEVBOX_TRACE_DIR NODE_OPTIONS DEVBOX_STEP_MEMORY DEVBOX_MEMINFO

PROJ="$TMP/project"
BIN="$TMP/bin"
CG="$TMP/cgroup"
PROC="$TMP/proc-self-cgroup"
mkdir -p "$PROJ" "$BIN" "$CG"
printf '34359738368\n' >"$CG/memory.max"
KEY=0123456789abcdef  # a fixture machine id: gitleaks:allow

# The stub of `sudo -n`. It logs its argv, refuses without -n, refuses a path
# outside $TMP, and refuses everything under STUB_SUDO_REFUSE=1, as sudo does
# for a user with no NOPASSWD rule. For the three calls cgroup=nested makes it
# plays the kernel: mkdir makes the folder, a write to cgroup.procs records
# the pid and points the fake /proc/self/cgroup at the new cgroup (unless
# STUB_KERNEL_IGNORES=1), and rmdir removes the folder, or fails as a busy
# cgroup fails under STUB_RMDIR_BUSY=1.
cat >"$BIN/sudo" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >>"$SUDO_LOG"
[ "${1-}" = -n ] || { echo "stub sudo: called without -n" >&2; exit 1; }
shift
for a in "$@"; do
  case "$a" in /*) [ "${a#"$STUB_TMP"/}" != "$a" ] || { echo "stub sudo: refusing $a, outside the test folder" >&2; exit 99; } ;; esac
done
[ "${STUB_SUDO_REFUSE-0}" != 1 ] || { echo "sudo: a password is required" >&2; exit 1; }
case "$1" in
  mkdir) exec "$@" ;;
  tee)
    cat >>"$2"
    [ "${STUB_KERNEL_IGNORES-0}" = 1 ] || printf '0::%s\n' "${2%/cgroup.procs}" | sed "s|^0::$STUB_CG_ROOT|0::|" >"$STUB_PROC"
    ;;
  rmdir)
    [ "${STUB_RMDIR_BUSY-0}" != 1 ] || { echo "rmdir: failed to remove '$2': Device or resource busy" >&2; exit 1; }
    cp "$2/cgroup.procs" "$STUB_MOVED" && rm -f "$2/cgroup.procs" && rmdir "$2"
    ;;
  *) echo "stub sudo: no case for $1" >&2; exit 98 ;;
esac
STUB
chmod +x "$BIN/sudo"
export SUDO_LOG="$TMP/sudo.log" STUB_TMP="$TMP" STUB_CG_ROOT="$CG" STUB_PROC="$PROC" STUB_MOVED="$TMP/moved"

# plan_step <name> <command>: one step line with no runner, run in full.
plan_step() {
  printf 'step\t%s\trun\t%s\t-\t-\t%s\t-\t0\n' "$1" "$KEY" "$(printf '%s' "$2" | base64 | tr -d '\n')"
}

# run_steps <case> <plan> <proc line> [VAR=value...]: the runner in the project
# folder, with the fake /proc/self/cgroup holding <proc line>. Sets OUT, ERR,
# RC and LOGS.
run_steps() {
  local case="$1" plan="$2"
  printf '%s\n' "$3" >"$PROC"
  shift 3
  LOGS="$TMP/logs-$case"
  RC=0
  : >"$SUDO_LOG"
  rm -f "$STUB_MOVED"
  OUT="$(cd "$PROJ" && env PATH="$BIN:$PATH" DEVBOX_TOKENS=2 DEVBOX_CGROUP_ROOT="$CG" \
    DEVBOX_PROC_CGROUP="$PROC" DEVBOX_STEPS_PLAN="$plan" DEVBOX_STEPS_LOGS="$LOGS" "$@" "$STEPS" 2>"$TMP/err")" || RC=$?
  ERR="$(cat "$TMP/err")"
}

# The command of the step under test: its own pid, then the cgroup it reads,
# as a test that checks its own cgroup does. MARK proves it ran.
MARK="$TMP/ran"
q_mark="$(printf '%q' "$MARK")"
CMD="echo pid=\$\$; echo cg=\$(cat \"\$DEVBOX_PROC_CGROUP\"); touch $q_mark"

# ── depth 1: the step moves to devbox/<name> ─────────────────────────────────

{ plan_step cgtest "$CMD"; printf 'cgroup\tcgtest\tnested\n'; } >"$TMP/one.plan"
rm -f "$MARK"
run_steps depth1 "$TMP/one.plan" "0::/init.scope"
assert_eq "0" "$RC" "a cgroup=nested step at depth 1 passes: $ERR"
assert_ok "its command reads a cgroup of depth 2, devbox/cgtest" grep -qxF "cg=0::/devbox/cgtest" <<<"$OUT"
assert_eq "$(sed -n 's/^pid=//p' <<<"$OUT")" "$(cat "$STUB_MOVED" 2>/dev/null)" \
  "the pid written to cgroup.procs is the step command's own, so every process it starts inherits the cgroup"
assert_eq "-n mkdir -p $CG/devbox/cgtest|-n tee $CG/devbox/cgtest/cgroup.procs|-n rmdir $CG/devbox/cgtest" \
  "$(paste -sd'|' "$SUDO_LOG")" "sudo -n creates the cgroup, moves the shell, then removes the cgroup after the step"
assert_fail "the cgroup is gone after the step" test -e "$CG/devbox/cgtest"
assert_ok "the log says where the step moved from and to" \
  grep -qxF "devbox-steps: cgtest runs in cgroup /init.scope, depth 1, so it moves to $CG/devbox/cgtest" "$LOGS/cgtest.log"

# ── depth 0, and a step without the attribute beside it ──────────────────────

{
  plan_step cgtest "$CMD"
  plan_step plain "true"
  printf 'cgroup\tcgtest\tnested\n'
} >"$TMP/two.plan"
run_steps depth0 "$TMP/two.plan" "0::/"
assert_eq "0" "$RC" "a cgroup=nested step at depth 0, beside a step without it, passes: $ERR"
assert_ok "and is moved" grep -qxF "cg=0::/devbox/cgtest" "$LOGS/cgtest.log"
assert_fail "the step without cgroup= makes no sudo call" grep -q plain "$SUDO_LOG"
assert_eq "3" "$(grep -c . "$SUDO_LOG")" "and the nested step makes its three"

# ── depth 2 or more: the step stays ──────────────────────────────────────────

rm -f "$MARK"
run_steps depth3 "$TMP/one.plan" "0::/user.slice/user-1000.slice/session-1.scope"
assert_eq "0" "$RC" "a cgroup=nested step at depth 3 passes: $ERR"
assert_ok "and ran" test -e "$MARK"
assert_eq "" "$(cat "$SUDO_LOG")" "with no sudo call at all"
assert_ok "in the cgroup it started in" grep -qxF "cg=0::/user.slice/user-1000.slice/session-1.scope" <<<"$OUT"
assert_ok "and the log says so" \
  grep -qxF "devbox-steps: cgtest runs in cgroup /user.slice/user-1000.slice/session-1.scope, depth 3, so cgroup=nested moves it nowhere" "$LOGS/cgtest.log"

# A cgroup v1 line ahead of the v2 line, as on a hybrid host: the 0:: line
# decides.
rm -f "$MARK"
run_steps hybrid "$TMP/one.plan" $'1:name=systemd:/\n0::/system.slice/runner.service'
assert_eq "0" "$RC" "a hybrid host's 0:: line of depth 2 is read past the v1 line: $ERR"
assert_eq "" "$(cat "$SUDO_LOG")" "and the step is not moved"

# ── a step that cannot be moved does not run ─────────────────────────────────

rm -f "$MARK"
run_steps refused "$TMP/one.plan" "0::/init.scope" STUB_SUDO_REFUSE=1
assert_eq "1" "$RC" "a step whose cgroup sudo cannot create fails the gate"
assert_ok "with code 2" grep -Eq '^devbox-steps: result cgtest fail [0-9]+ 2$' <<<"$OUT"
assert_fail "and its command never ran" test -e "$MARK"
assert_ok "and the log names the cause" \
  grep -qF "devbox-steps: cgtest has cgroup=nested and runs in cgroup /init.scope, depth 1, and sudo -n mkdir -p $CG/devbox/cgtest failed, so cgtest did not run" "$LOGS/cgtest.log"
assert_ok "with sudo's own message" grep -qxF "sudo: a password is required" "$LOGS/cgtest.log"

rm -f "$MARK"
run_steps v1 "$TMP/one.plan" "1:name=systemd:/"
assert_ok "a machine with no cgroup v2 line fails the step with code 2" \
  grep -Eq '^devbox-steps: result cgtest fail [0-9]+ 2$' <<<"$OUT"
assert_fail "and its command never ran" test -e "$MARK"
assert_ok "and the log names the missing line" \
  grep -qxF "devbox-steps: cgtest has cgroup=nested, and $PROC holds no cgroup v2 line (0::/...), so cgtest did not run" "$LOGS/cgtest.log"

# The write is taken and the path does not change: the step would run at depth
# 1 under a log that says it moved.
rm -f "$MARK"
run_steps ignored "$TMP/one.plan" "0::/init.scope" STUB_KERNEL_IGNORES=1
assert_ok "a move the path does not show fails the step with code 2" \
  grep -Eq '^devbox-steps: result cgtest fail [0-9]+ 2$' <<<"$OUT"
assert_fail "and its command never ran" test -e "$MARK"
assert_ok "and the log names the path it still read" \
  grep -qE "^devbox-steps: pid [0-9]+ was written to $CG/devbox/cgtest/cgroup.procs, and $PROC still names /init.scope, so cgtest did not run$" "$LOGS/cgtest.log"

# ── a cgroup that stays busy is reported, and the step keeps its pass ────────

run_steps busy "$TMP/one.plan" "0::/init.scope" STUB_RMDIR_BUSY=1
assert_eq "0" "$RC" "a step whose cgroup cannot be removed still passes: $ERR"
assert_ok "the run says the step left its cgroup" \
  grep -qxF "devbox-steps: cgtest left its cgroup $CG/devbox/cgtest" <<<"$OUT"
assert_ok "and the log says why" \
  grep -qxF "devbox-steps: could not remove the cgroup $CG/devbox/cgtest: a process the step started may still run in it" "$LOGS/cgtest.log"
# The next gate reuses the folder the busy one left: mkdir -p does not fail on it.
run_steps reuse "$TMP/one.plan" "0::/init.scope"
assert_eq "0" "$RC" "the next run reuses the cgroup the last one left: $ERR"
assert_fail "and removes it" test -e "$CG/devbox/cgtest"

# ── the plan's cgroup lines ──────────────────────────────────────────────────

{ plan_step cgtest true; printf 'cgroup\tcgtest\thost\n'; } >"$TMP/bad-value.plan"
run_steps bad-value "$TMP/bad-value.plan" "0::/init.scope"
assert_eq "2" "$RC" "a cgroup line whose value is not nested is refused with exit 2"
assert_ok "by its line" grep -qxF "devbox-steps: plan line 2: the cgroup of cgtest is host, not nested" <<<"$ERR"

{ plan_step cgtest true; printf 'cgroup\tother\tnested\n'; } >"$TMP/bad-step.plan"
run_steps bad-step "$TMP/bad-step.plan" "0::/init.scope"
assert_eq "2" "$RC" "a cgroup line that names no planned step is refused with exit 2"
assert_ok "by its line" grep -qxF "devbox-steps: plan line 2: a cgroup line names other, which no step line above it plans" <<<"$ERR"

{ plan_step cgtest true; printf 'cgroup\tcgtest\tnested\ncgroup\tcgtest\tnested\n'; } >"$TMP/twice.plan"
run_steps twice "$TMP/twice.plan" "0::/init.scope"
assert_eq "2" "$RC" "a step's cgroup given twice is refused with exit 2"
assert_eq "" "$(cat "$SUDO_LOG")" "and no refused plan made a sudo call"

printf '%d %d\n' "$TESTS_RUN" "$TESTS_FAILED"
