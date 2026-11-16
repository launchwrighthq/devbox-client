#!/bin/bash
# A resumed gate of a runner step, end to end through the real devbox-verify
# and the real step runner against a fake host
# (docs/specs/2026-11-15-gate-fixes-4-0-1-design.md, rows D1 and D4).
#
# MEASURED, D1: a stopped gate's vitest step failed two files. The plan of its
# resume narrowed the step to the failed files of another branch's newer
# record, every file on that list had passed in this gate, the step resumed
# as passed, and the gate printed `devbox: green`.
# MEASURED, D4: after a resume, the map held the pass run `-` for the files
# that passed before the stop, so the next plan named them `no trace` and ran
# them again.
#
# A fake ssh plays one target, lan1, with the lane lock, the held run, the gate
# and the `ledger` verb of tests/gate-stub-hold.sh. The gate is the hooks
# script with the real devbox-steps. vitest is a stub on PATH: it runs the
# files it is given, or every test file, writes each one's ledger lines and a
# trace line for it, and logs what it ran.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
# shellcheck source=tests/lib.sh
source ./lib.sh
unset CI DEVBOX_RERUN DEVBOX_STRICT
# shellcheck source=tests/gate-stub-hold.sh
source ./gate-stub-hold.sh

REPO="$(cd .. && pwd)"
TMP="$(mktemp -d)" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
mkdir -p "$TMP/bin" "$TMP/home" "$TMP/run" "$TMP/lanes" "$TMP/ws" "$TMP/tmp" "$TMP/plant"

contains() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }

PROTO="$(sed -n 's/^DEVBOX_PROTOCOL_VERSION=\(.*\)$/\1/p' "$REPO/lib/devbox-lib.sh")"
FP="$(sha256sum <"$REPO/lib/devbox-lib.sh" | cut -d' ' -f1)"
HOLD_LOG="$TMP/hold.log"
VITEST_LOG="$TMP/vitest.log"
export HOLD_LOG VITEST_LOG
export FAKE_VERSION="$PROTO $FP" FAKE_LANES="$TMP/lanes" FAKE_WS="$TMP/ws" FAKE_STOP_FILE="$TMP/stops"

# The fake host, at an RFC 5737 address.
A_LAN1=192.0.2.10

{ gate_stub_head; gate_stub_hold; cat <<'STUB'
case "$GATE_CMD" in
  version) printf '%s\n' "$FAKE_VERSION" ;;
  "queue-estimate "*) printf 'now 0 3 0/20 0/4 0\n' ;;
  "ensure-workspace "*) printf 'postgresql://fixture:fixture@fixture/fixture\n' ;;
  "sync-finish "*) ;;
  "setup "*) while IFS= read -r _; do :; done ;;
  "oom-count "*) printf '0\n' ;;
  "lock "*) _hold_lock ;;
  "run "*) _hold_run; _hold_gate ;;
  "ledger "*) _hold_ledger ;;
esac
exit 0
STUB
} >"$TMP/bin/ssh"
# The sync's rsync to a host sends nothing. The manifest is a local rsync dry
# run, which must be the real rsync.
{
  printf '#!/bin/bash\n'
  printf '_real=%q\n' "$(command -v rsync)"
  cat <<'STUB'
case "${*: -1}" in devbox-gate@*) exit 0 ;; esac
exec "$_real" "$@"
STUB
} >"$TMP/bin/rsync"
printf '#!/bin/bash\nexec "$@"\n' >"$TMP/bin/npx"
# FAKE_FAIL names the files that fail. On the first run of a gate
# (DEVBOX_RESUME=0), FAKE_STOP_AT names the file a stop cuts short, and
# FAKE_PLANT names a directory whose files move into FAKE_PLANT_TO: another
# branch's record, written while this gate runs.
cat >"$TMP/bin/vitest" <<'STUB'
#!/bin/bash
files=()
for a in "$@"; do case "$a" in run | -*) ;; *) files+=("$a") ;; esac; done
[ "${#files[@]}" -gt 0 ] || files=(a.test.ts b.test.ts c.test.ts d.test.ts)
printf 'resume=%s %s\n' "${DEVBOX_RESUME-}" "${files[*]}" >>"$VITEST_LOG"
if [ "${DEVBOX_RESUME:-0}" = 0 ] && [ -n "${FAKE_PLANT-}" ]; then
  mkdir -p "$FAKE_PLANT_TO" && mv "$FAKE_PLANT"/* "$FAKE_PLANT_TO"/
fi
rc=0
for f in "${files[@]}"; do
  printf 'file\tvitest\t%s\tstart\n' "$f" >>"$DEVBOX_LEDGER"
  [ -z "${DEVBOX_TRACE_DIR-}" ] || printf 'read\t%s\tsrc/%s.ts\n' "$f" "${f%%.*}" >>"$DEVBOX_TRACE_DIR/vitest-$$.trace"
  [ "${DEVBOX_RESUME:-0}" = 1 ] || [ "$f" != "${FAKE_STOP_AT-}" ] || exit 143
  case " ${FAKE_FAIL-} " in
    *" $f "*) printf 'file\tvitest\t%s\tfail\t1\n' "$f" >>"$DEVBOX_LEDGER"; rc=1 ;;
    *) printf 'file\tvitest\t%s\tpass\t1\n' "$f" >>"$DEVBOX_LEDGER" ;;
  esac
done
exit "$rc"
STUB
chmod +x "$TMP/bin/ssh" "$TMP/bin/rsync" "$TMP/bin/npx" "$TMP/bin/vitest"
gate_stub_keyscan "$TMP/bin"

CO="$TMP/checkout"
mkdir -p "$CO/.devbox" "$CO/src"
git -C "$CO" init -q -b other
: >"$CO/.devbox/exclude"
for f in a b c d; do
  printf '%s v1\n' "$f" >"$CO/$f.test.ts"
  printf '%s v1\n' "$f" >"$CO/src/$f.ts"
done
printf 'DEVBOX_PROJECT=app\nDEVBOX_WANT_TOKENS=4\nDEVBOX_MIN_TOKENS=2\nDEVBOX_SETUP=:\n' >"$CO/.devbox/config.env"
printf 'test runner=vitest narrow=failed -- npx vitest run\n' >"$CO/.devbox/steps"
{
  echo 'DEVBOX_TARGETS=lan1'
  echo "DEVBOX_TARGET_LAN1=$A_LAN1"; echo "DEVBOX_TARGET_LAN1_HOSTKEY=$GATE_STUB_PIN"
  echo 'DEVBOX_GATE_PASSWORD=fixture-gate-password'
} >"$CO/.devbox.env"
DEVBOX_DIR="$CO/.git/devbox"

out="" rc=0
verify() {
  rc=0
  : >"$VITEST_LOG"
  out="$(cd "$CO" && env PATH="$TMP/bin:$PATH" HOME="$TMP/home" XDG_RUNTIME_DIR="$TMP/run" TMPDIR="$TMP/tmp" \
    DEVBOX_LOCK_WAIT=30 bash "$REPO/client/libexec/devbox-verify" "$@" 2>&1)" || rc=$?
}
verdict() { printf '%s\n' "$out" | tail -n 1; }

# ═══ D1: a resume reruns its own failed files, whatever another branch says ═
echo "-- D1"
FAKE_FAIL="c.test.ts d.test.ts" verify --target lan1
assert_eq 1 "$rc" "another branch's gate fails c and d"
assert_eq "devbox: red (test failed: 2 files)" "$(verdict)" "and its record names its two failed files"
# That record is written while this branch's gate runs, so this gate's own
# plan never reads it and only its resume could.
mv "$DEVBOX_DIR/records/"* "$TMP/plant/"
rm -rf "$DEVBOX_DIR/maps"
git -C "$CO" symbolic-ref HEAD refs/heads/feature
printf '1\n' >"$FAKE_STOP_FILE"
FAKE_FAIL="a.test.ts b.test.ts" FAKE_PLANT="$TMP/plant" FAKE_PLANT_TO="$DEVBOX_DIR/records" verify --target lan1
assert_ok "the gate was stopped" contains "the watchdog on lan1 stopped this gate" "$out"
assert_ok "and resumed" contains "devbox: resuming" "$out"
assert_eq "resume=0 a.test.ts b.test.ts c.test.ts d.test.ts" "$(sed -n 1p "$VITEST_LOG")" "the stopped run ran every file"
assert_eq "resume=1 a.test.ts b.test.ts" "$(sed -n 2p "$VITEST_LOG")" \
  "D1: the resume ran the two files this gate failed, and not the other branch's"
assert_fail "D1: the step did not resume as passed" contains "every file it runs passed in an earlier run" "$out"
assert_eq 1 "$rc" "D1: the resumed gate fails"
assert_eq "devbox: red (test failed: 2 files)" "$(verdict)" "D1: and its verdict is red over its own two files"

# ═══ D4: a file that passed before the stop keeps its reads and the run id ══
echo "-- D4"
rm -rf "$DEVBOX_DIR/records" "$DEVBOX_DIR/maps" "$TMP/run/devbox/ledgers" "${TMP:?}/ws/"*
verify --target lan1
assert_eq 0 "$rc" "a full gate passes and writes the map"
MAP="$(printf '%s\n' "$DEVBOX_DIR"/maps/test.*.map)"
assert_ok "one map of the step's context" test -f "$MAP"
assert_ok "the map holds a's read" grep -q $'^path\t[0-9]*\tsrc/a.ts$' "$MAP"
# The map's passes are under an older run. A config change once forced this
# run, but a config change now gives a runner step a map of its own
# (gate overload D8), so --full runs every file under the same context.
printf '1\n' >"$FAKE_STOP_FILE"
FAKE_STOP_AT=c.test.ts verify --target lan1 --full
assert_ok "the gate was stopped at c" contains "the watchdog on lan1 stopped this gate" "$out"
assert_eq "resume=1 c.test.ts d.test.ts" "$(sed -n 2p "$VITEST_LOG")" "the resume ran the open and the unstarted files"
assert_eq 0 "$rc" "the resumed gate passes"
pass_run() { awk -F'\t' -v f="$1" '$1 == "file" && $2 == f { print $3 }' "$MAP"; }
assert_eq "" "$(awk -F'\t' '$1 == "file" && $3 == "-"' "$MAP")" "D4: no file of the map has the pass run -"
resumed_run="$(pass_run c.test.ts)"
assert_ok "D4: c, which passed after the resume, names the resumed gate's record" \
  test -r "$DEVBOX_DIR/records/$resumed_run.record"
assert_eq "$resumed_run $resumed_run $resumed_run" "$(pass_run a.test.ts) $(pass_run b.test.ts) $(pass_run d.test.ts)" \
  "D4: a and b, which passed before the stop, have the same run as c and d"
printf 'more\n' >>"$CO/src/a.ts"
verify --target lan1 --plan
assert_ok "D4: a change to what a read selects a alone" grep -qx 'test  select 1 files  selected 1 of 4 test files' <<<"$out"
assert_ok "D4: by its kept read" grep -qx '  a.test.ts  read src/a.ts' <<<"$out"
assert_fail "D4: and no file is no trace" contains "no trace" "$out"

printf '%d %d\n' "$TESTS_RUN" "$TESTS_FAILED"
