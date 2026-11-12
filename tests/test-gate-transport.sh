#!/bin/bash
# client/libexec/devbox-transport and client/libexec/devbox-askpass.
#
# The gate password reaches ssh through SSH_ASKPASS and never through an argv.
# `ps aux` is readable by every user on a laptop, so an argument is a public
# string for as long as the process runs, and a secret never travels as one.
# These cases prove that with the process table itself, and with a
# recorder that would see any program the helper started.
#
# They also pin every ssh option the transport sets, because each one closes a
# hole: a key offered first would log in as someone else, a second password
# prompt doubles what fail2ban counts, and a missing known_hosts rule accepts a
# changed host key, which hands the password to whoever answered.
#
# And the host key pin. The first build recorded whatever key answered the
# first contact (accept-new), and the client probes every target on its own,
# often from an unattended agent, so a man in the middle on that contact got
# DEVBOX_GATE_PASSWORD. The pin cases prove, from the stub's own record, that
# a key that is not the pin never reaches an ssh that carries the password.
#
# Hermetic. ssh and rsync are stubs first on PATH that record their argv and
# the variables the transport sets; HOME and XDG_RUNTIME_DIR point under one
# mktemp -d.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
# shellcheck source=tests/lib.sh
source ./lib.sh
REPO="$(cd .. && pwd)"
TRANSPORT="$REPO/client/libexec/devbox-transport"
ASKPASS="$REPO/client/libexec/devbox-askpass"

TMP="$(mktemp -d)" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
contains() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }
PW='gate-Pw-0123456789abcdefghijKLMNOPQRST'

# ── the askpass helper ───────────────────────────────────────────────────────
#
# Run with an environment that holds the password and a PATH that holds only a
# recorder for every program the helper could start. A builtin never reaches
# PATH, so an empty record proves no process was started with the password.
mkdir -p "$TMP/rec"
for t in printf echo cat env tee; do
  printf '#!/bin/sh\necho "%s $*" >>"%s/rec.log"\n' "$t" "$TMP" >"$TMP/rec/$t"
  chmod +x "$TMP/rec/$t"
done
: >"$TMP/rec.log"
got="$(env -i PATH="$TMP/rec" DEVBOX_GATE_PASSWORD="$PW" "$(command -v bash)" "$ASKPASS" "devbox-gate@host's password: ")"
assert_eq "$PW" "$got" "askpass prints the password from its environment"
assert_eq "" "$(cat "$TMP/rec.log")" "and starts no program to do it, so no argv ever carries it"
rc=0
got="$(env -i PATH="$TMP/rec" "$(command -v bash)" "$ASKPASS" prompt)" || rc=$?
assert_eq "1" "$rc" "with no password it exits 1"
assert_eq "" "$got" "and prints nothing, so ssh sends no empty password to count against fail2ban"
assert_ok "askpass is executable in the checkout, because ssh exec()s it" test -x "$ASKPASS"

# ── the stubs ────────────────────────────────────────────────────────────────
mkdir -p "$TMP/bin" "$TMP/fakehome" "$TMP/run"
cat >"$TMP/bin/ssh" <<'STUB'
#!/bin/bash
{
  printf '[ssh]\n'; printf '%s\n' "$@"
  printf 'ENV SSH_ASKPASS=%s\n' "${SSH_ASKPASS-}"
  printf 'ENV SSH_ASKPASS_REQUIRE=%s\n' "${SSH_ASKPASS_REQUIRE-}"
  printf 'ENV PASSWORD_SET=%s\n' "${DEVBOX_GATE_PASSWORD:+yes}"
} >>"$LOG"
case " $* " in
  *" -O check "*) exit 1 ;;
  *" -f -N "*)
    # A real master that ControlPersist sends to the background keeps the
    # streams it was started with. The sleep stands in for it: if the transport
    # started the master on a pipe it reads, the caller waits out the sleep.
    ( sleep 8 ) &
    [ -z "${FAKE_OPEN_ERR-}" ] || printf '%s\n' "$FAKE_OPEN_ERR" >&2
    exit "${FAKE_OPEN_RC:-0}" ;;
esac
# The askpass helper ssh would run, run the way ssh runs it, so the password
# path is exercised end to end.
if [ -n "${FAKE_RUN_ASKPASS-}" ]; then "$SSH_ASKPASS" "password: " >"$TMP/askpass.out"; fi
[ -z "${FAKE_SLEEP-}" ] || sleep "$FAKE_SLEEP"
exit 0
STUB
cat >"$TMP/bin/rsync" <<'STUB'
#!/bin/bash
{ printf '[rsync]\n'; printf '%s\n' "$@"; printf 'ENV PASSWORD_SET=%s\n' "${DEVBOX_GATE_PASSWORD:+yes}"; } >>"$LOG"
exit 0
STUB
chmod +x "$TMP/bin/ssh" "$TMP/bin/rsync"
gate_stub_keyscan "$TMP/bin"
LOG="$TMP/calls.log"
KEYSCAN_LOG="$TMP/keyscan.log"
PIN="$GATE_STUB_PIN"
export LOG TMP KEYSCAN_LOG PIN

# Every case runs the transport in a fresh bash, with the password a plain
# shell variable, as devbox-verify holds it after `export -n`.
tr_run() {  # $1 the script to run after sourcing the transport
  : >"$LOG"; : >"$KEYSCAN_LOG"
  # shellcheck disable=SC2016  # the bash that sources the transport expands these, not this one
  out="$(env -u DEVBOX_GATE_PASSWORD PATH="$TMP/bin:$PATH" HOME="$TMP/fakehome" XDG_RUNTIME_DIR="$TMP/run" \
    bash -c 'source "$1"; pin_target() { devbox_gate_target "$1" "$2" "" "" "$PIN"; }; DEVBOX_GATE_PASSWORD="$2"; '"$1" _ "$TRANSPORT" "$PW" 2>&1 </dev/null)"
  rc=$?
  return 0
}
out=""; rc=0

# ── the target value ─────────────────────────────────────────────────────────
# shellcheck disable=SC2016  # the bash that sources the transport expands these, not this one
tr_run 'pin_target lan1.invalid cfg && echo "$GATE_DEST $GATE_PORT"'
assert_eq "devbox-gate@lan1.invalid 22" "$out" "an address reaches devbox-gate on port 22"
# shellcheck disable=SC2016  # the bash that sources the transport expands these, not this one
tr_run 'pin_target cloud1.invalid:2222 cfg && echo "$GATE_DEST $GATE_PORT $(devbox_gate_known_name)"'
assert_eq "devbox-gate@cloud1.invalid 2222 [cloud1.invalid]:2222" "$out" "address:port sets the port and the known_hosts name"
# shellcheck disable=SC2016  # the bash that sources the transport expands these, not this one
tr_run 'pin_target "[2001:db8::1]:2200" cfg && echo "$GATE_DEST $GATE_PORT"'
assert_eq "devbox-gate@2001:db8::1 2200" "$out" "a bracketed IPv6 address takes a port too"
for bad in root@lan1.invalid -oProxyCommand=id 'a b' 'h;id' 'h:0' 'h:99999' ''; do
  tr_run "pin_target '$bad' cfg"
  assert_eq "2" "$rc" "refuses the host value '$bad'"
done
tr_run 'pin_target root@lan1.invalid .devbox.env'
assert_ok "a value that names a user says the user is always devbox-gate" \
  contains "the user is always devbox-gate" "$out"

# ── the ssh options ──────────────────────────────────────────────────────────
tr_run 'pin_target lan1.invalid cfg && devbox_gate version'
call="$(awk '/^\[ssh\]/{n++} n==1' "$LOG")"
for opt in PreferredAuthentications=password PubkeyAuthentication=no NumberOfPasswordPrompts=1 \
           ControlMaster=auto ControlPersist=60 \
           "UserKnownHostsFile=$TMP/fakehome/.config/devbox/known_hosts" StrictHostKeyChecking=yes \
           HostKeyAlgorithms=ssh-ed25519 GlobalKnownHostsFile=/dev/null; do
  assert_ok "every gate call carries -o $opt" grep -qxF -- "$opt" <<<"$call"
done
assert_ok "and names the gate account" grep -qxF "devbox-gate@lan1.invalid" <<<"$call"
# ssh-keyscan reads no ssh config, so ssh must read none either. A ~/.ssh/config
# Host block named like the target, with another HostName, sent the pin check
# and the connection to two addresses, and every run failed as a changed key.
assert_ok "every gate call carries -F /dev/null, so no ssh config moves the address" \
  contains $'\n-F\n/dev/null\n' "$call"
assert_ok "the control socket sits in the private dir, named by the caller's pid and %C" \
  grep -qxE "ControlPath=$TMP/run/devbox/[0-9]+-%C" <<<"$call"

# ── one master per run ───────────────────────────────────────────────────────
#
# %C alone hashes only the hosts, the port and the user, so every run on the
# laptop shared one master: about the sixth concurrent run hit sshd's
# MaxSessions 10, and a killed run's gate kept running while another run held
# the master. Two runs here are two processes, as two `devbox verify` are.
cpath() { grep -m1 '^ControlPath=' "$LOG"; }
tr_run 'pin_target lan1.invalid cfg && devbox_gate version'
first_cp="$(cpath)"
tr_run 'pin_target lan1.invalid cfg && devbox_gate version'
assert_ok "two runs against one target use two control sockets" test "$first_cp" != "$(cpath)"
# shellcheck disable=SC2016  # the bash that sources the transport expands these, not this one
tr_run 'pin_target lan1.invalid cfg && devbox_gate version && (devbox_gate version)'
assert_eq "1" "$(grep '^ControlPath=' "$LOG" | sort -u | wc -l | tr -d ' ')" \
  "and one run keeps one socket, a subshell of it included"

# The run verb takes its own connection, so the sshd session process gate-root
# watches ends exactly when this one ssh goes away, and devbox-pool stops the
# gate when it does.
tr_run 'pin_target lan1.invalid cfg && devbox_gate run s1 proj 8 8 0 3600 verify'
run_call="$(awk '/^\[ssh\]/{n++} n==1' "$LOG")"
assert_eq "ControlPath=none" "$(grep -m1 '^ControlPath=' <<<"$run_call")" \
  "run uses ControlPath=none, first, so ssh keeps it over the shared one"
assert_eq "ControlMaster=no" "$(grep -m1 '^ControlMaster=' <<<"$run_call")" "and ControlMaster=no"
assert_ok "and -F /dev/null" contains $'\n-F\n/dev/null\n' "$run_call"
tr_run 'pin_target lan1.invalid cfg && devbox_gate lock s1 60'
assert_eq "ControlMaster=auto" "$(grep -m1 '^ControlMaster=' "$LOG")" "every other verb reuses the run's master"

# The caller's EXIT trap closes the master, so it does not hold its connection
# for ControlPersist after the run.
tr_run 'pin_target lan1.invalid cfg && devbox_gate_close'
close_call="$(awk '/^\[ssh\]/{n++} n==1' "$LOG")"
assert_ok "devbox_gate_close sends -O exit" grep -qxF "exit" <<<"$close_call"
assert_ok "  to this run's own control socket" grep -qxE "ControlPath=$TMP/run/devbox/[0-9]+-%C" <<<"$close_call"
assert_ok "  with -F /dev/null" contains $'\n-F\n/dev/null\n' "$close_call"
tr_run 'devbox_gate_close; echo "rc=$?"'
assert_eq "rc=0" "$out" "and does nothing before a target is set"
assert_eq "" "$(cat "$LOG")" "  (no ssh starts)"
assert_eq "version" "$(tail -n4 <<<"$call" | head -n1)" "the verb is the last word, one argv word"
assert_ok "SSH_ASKPASS names the askpass helper" grep -qxF "ENV SSH_ASKPASS=$ASKPASS" <<<"$call"
assert_ok "SSH_ASKPASS_REQUIRE is force, so ssh asks the helper with no terminal" \
  grep -qxF "ENV SSH_ASKPASS_REQUIRE=force" <<<"$call"
assert_ok "the password is in ssh's environment" grep -qxF "ENV PASSWORD_SET=yes" <<<"$call"
assert_fail "and in none of its arguments" grep -qF "$PW" "$LOG"
assert_eq "700" "$(stat -c %a "$TMP/run/devbox")" "the control socket dir is mode 0700"

# The password crosses into the askpass helper the way ssh hands it over, and
# comes back out of it intact.
tr_run 'pin_target lan1.invalid cfg && FAKE_RUN_ASKPASS=1 devbox_gate version'
assert_eq "$PW" "$(cat "$TMP/askpass.out")" "the helper ssh runs reads the password ssh was given"

# The password is not exported to the caller's other children: a local gate,
# the workspace bash and every other program run without it.
tr_run 'pin_target lan1.invalid cfg && devbox_gate version && env'
assert_fail "a child of the caller does not inherit the password" contains "$PW" "$out"

# The process table, read while ssh runs. This is the `ps aux` any user on the
# laptop can read.
: >"$LOG"
# shellcheck disable=SC2016  # the bash that sources the transport expands these, not this one
env -u DEVBOX_GATE_PASSWORD PATH="$TMP/bin:$PATH" HOME="$TMP/fakehome" XDG_RUNTIME_DIR="$TMP/run" FAKE_SLEEP=2 \
  bash -c 'source "$1"; pin_target() { devbox_gate_target "$1" "$2" "" "" "$PIN"; }; DEVBOX_GATE_PASSWORD="$2"; pin_target lan1.invalid cfg && devbox_gate version' \
  _ "$TRANSPORT" "$PW" </dev/null >/dev/null 2>&1 &
bg=$!
sleep 1
table="$(ps -eo args)"
wait "$bg"
assert_ok "the process table shows the ssh call while it runs" contains "devbox-gate@lan1.invalid version" "$table"
# The bash -c above names the password as its own $2 to stand in for a file
# read, so that one process is left out; the property is about ssh's argv.
assert_eq "0" "$(grep -F "$PW" <<<"$table" | grep -vc -- 'bash -c source' || true)" \
  "and no other process carries the password in its argv"

# Unset XDG_RUNTIME_DIR: the sockets go to a per-uid dir under TMPDIR, made 0700.
: >"$LOG"
# shellcheck disable=SC2016  # the bash that sources the transport expands these, not this one
out="$(env -u DEVBOX_GATE_PASSWORD -u XDG_RUNTIME_DIR TMPDIR="$TMP" PATH="$TMP/bin:$PATH" HOME="$TMP/fakehome" \
  bash -c 'source "$1"; pin_target() { devbox_gate_target "$1" "$2" "" "" "$PIN"; }; pin_target lan1.invalid cfg && devbox_gate version' _ "$TRANSPORT" 2>&1 </dev/null)"
assert_ok "with no XDG_RUNTIME_DIR the control path falls back under TMPDIR" \
  grep -qxE "ControlPath=$TMP/devbox-$(id -u)/[0-9]+-%C" "$LOG"
assert_eq "700" "$(stat -c %a "$TMP/devbox-$(id -u)")" "and that dir is mode 0700"
# A fallback dir that is a symlink is someone else's, and is refused.
rm -rf "$TMP/devbox-$(id -u)"
mkdir -p "$TMP/elsewhere"
ln -s "$TMP/elsewhere" "$TMP/devbox-$(id -u)"
# shellcheck disable=SC2016  # the bash that sources the transport expands these, not this one
out="$(env -u XDG_RUNTIME_DIR TMPDIR="$TMP" PATH="$TMP/bin:$PATH" HOME="$TMP/fakehome" \
  bash -c 'source "$1"; pin_target() { devbox_gate_target "$1" "$2" "" "" "$PIN"; }; pin_target lan1.invalid cfg' _ "$TRANSPORT" 2>&1 </dev/null)"; rc=$?
assert_ok "a control dir that is a symlink is refused" test "$rc" -ne 0
assert_ok "and the refusal names it" contains "is not a directory this user owns" "$out"

# A word that holds a space or a metacharacter is refused before ssh starts.
tr_run 'pin_target lan1.invalid cfg && devbox_gate check-requires "a b"'
assert_eq "2" "$rc" "a gate word with a space is refused"
assert_fail "and ssh never ran" grep -q 'check-requires' "$LOG"

# ── the master, opened once and on no pipe the caller reads ──────────────────
start=$SECONDS
# shellcheck disable=SC2016  # the bash that sources the transport expands these, not this one
tr_run 'pin_target lan1.invalid cfg && x="$(devbox_gate_open 2>&1; echo rc=$?)"; echo "$x"'
assert_ok "the master open succeeds" contains "rc=0" "$out"
assert_ok "and returns at once, though the master stays in the background" test "$((SECONDS - start))" -lt 6
open_call="$(awk '/^\[ssh\]/{n++} n==2' "$LOG")"
assert_ok "the open uses ControlMaster=yes" grep -qxF "ControlMaster=yes" <<<"$open_call"
assert_ok "with -f -N, so no verb runs as part of it" grep -qxF -- "-N" <<<"$open_call"
assert_ok "and -F /dev/null, so the master dials the address the pin check scanned" \
  contains $'\n-F\n/dev/null\n' "$open_call"

export FAKE_OPEN_RC=255 FAKE_OPEN_ERR="devbox-gate@lan1.invalid: Permission denied (password)."
tr_run 'pin_target lan1.invalid cfg; devbox_gate_open; echo "rc=$?"'
assert_ok "a refused password returns 3" contains "rc=3" "$out"
export FAKE_OPEN_ERR="@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @
Host key verification failed."
# shellcheck disable=SC2016  # the bash that sources the transport expands these, not this one
tr_run 'pin_target lan1.invalid cfg; devbox_gate_open; echo "rc=$? $GATE_OPEN_ERROR"'
assert_ok "a changed host key returns 4" contains "rc=4" "$out"
assert_ok "and names the known_hosts file it differs from" contains "$TMP/fakehome/.config/devbox/known_hosts" "$out"
export FAKE_OPEN_ERR="ssh: connect to host lan1.invalid port 22: Connection timed out"
# shellcheck disable=SC2016  # the bash that sources the transport expands these, not this one
tr_run 'pin_target lan1.invalid cfg; devbox_gate_open; echo "rc=$? $GATE_OPEN_ERROR"'
assert_ok "an unreachable host returns 1, with ssh's line" contains "rc=1 ssh: connect to host" "$out"
unset FAKE_OPEN_RC FAKE_OPEN_ERR

# ── the host key pin ─────────────────────────────────────────────────────────
KH="$TMP/fakehome/.config/devbox/known_hosts"
for pair in "$GATE_STUB_HOSTKEY $GATE_STUB_PIN" "$GATE_STUB_OTHER_HOSTKEY $GATE_STUB_OTHER_PIN"; do
  printf 'h ssh-ed25519 %s\n' "${pair%% *}" >"$TMP/fixture.pub"
  assert_eq "${pair#* }" "$(ssh-keygen -lf "$TMP/fixture.pub" | cut -d' ' -f2)" \
    "the fixture pin ${pair#* } is ssh-keygen's fingerprint of its key"
done

# A target with no pin, or a value that is not one, is refused before ssh starts.
for bad in '' 'SHA256:short' "${GATE_STUB_PIN#SHA256:}" "MD5:${GATE_STUB_PIN#SHA256:}"; do
  tr_run "devbox_gate_target lan1.invalid cfg '' '' '$bad' && devbox_gate version"
  assert_eq "2" "$rc" "the transport refuses the pin '$bad'"
  assert_eq "" "$(cat "$LOG" "$KEYSCAN_LOG")" "  and no ssh or ssh-keyscan started"
done
assert_ok "and the refusal names the line to copy" contains "Copy the DEVBOX_TARGET_<NAME>_HOSTKEY line the operator's deploy prints" "$out"

# First contact, and ssh-keyscan returns the pinned key: the entry is written
# under the name ssh looks up, and the master opens.
rm -f "$KH"
# shellcheck disable=SC2016  # the bash that sources the transport expands these, not this one
tr_run 'devbox_gate_target lan1.invalid cfg "" "" "$PIN" && devbox_gate_open; echo "rc=$? new=$GATE_NEW_HOSTKEY"'
assert_ok "a first contact whose scanned key is the pin opens the master" contains "rc=0 new=$GATE_STUB_PIN" "$out"
assert_eq "lan1.invalid ssh-ed25519 $GATE_STUB_HOSTKEY" "$(cat "$KH")" "and records exactly that key, once"
assert_ok "ssh-keyscan asked for the ed25519 key on the target's port" grep -qxE -- "-t ed25519 -T [0-9]+ -p 22 lan1.invalid" "$KEYSCAN_LOG"
# shellcheck disable=SC2016  # the bash that sources the transport expands these, not this one
tr_run 'devbox_gate_target lan1.invalid cfg "" "" "$PIN" && devbox_gate_open; echo "rc=$?"'
assert_ok "the next contact checks the entry against the pin and opens" contains "rc=0" "$out"
assert_eq "" "$(cat "$KEYSCAN_LOG")" "  without scanning again"
assert_eq "1" "$(wc -l <"$KH" | tr -d ' ')" "  and without a second line"
# shellcheck disable=SC2016  # the bash that sources the transport expands these, not this one
tr_run 'devbox_gate_target cloud1.invalid:2222 cfg "" "" "$PIN" && devbox_gate_open; echo "rc=$?"'
assert_ok "a target on another port is recorded under [address]:port" grep -qxF "[cloud1.invalid]:2222 ssh-ed25519 $GATE_STUB_HOSTKEY" "$KH"

# First contact, and ssh-keyscan returns another key: a man in the middle, or a
# reinstalled host. Nothing is recorded, and no ssh that could carry the
# password starts: the stub records the environment of every ssh it runs.
rm -f "$KH"
# shellcheck disable=SC2016  # the bash that sources the transport expands these, not this one
tr_run 'devbox_gate_target lan1.invalid cfg "" "" "$PIN"; FAKE_KEYSCAN_OTHER=lan1.invalid FAKE_RUN_ASKPASS=1 devbox_gate_open; echo "rc=$? $GATE_OPEN_ERROR"'
rm -f "$TMP/askpass.out"
assert_ok "a first contact whose scanned key is not the pin returns 4, the host key class" contains "rc=4 " "$out"
assert_ok "and names both fingerprints" contains "is $GATE_STUB_OTHER_PIN, and the pin of lan1.invalid pins $GATE_STUB_PIN" "$out"
assert_ok "and says it may be an attack or a reinstalled host" contains "It may be an attack on this network, or a reinstalled host" "$out"
assert_fail "nothing is recorded" test -s "$KH"
assert_fail "no master was opened" grep -qxF -- "-N" "$LOG"
assert_eq "0" "$(grep -c 'ENV PASSWORD_SET=yes' "$LOG")" "and no ssh ran with the password in its environment"
# shellcheck disable=SC2016  # the bash that sources the transport expands these, not this one
tr_run 'devbox_gate_target lan1.invalid cfg "" "" "$PIN"; FAKE_KEYSCAN_OTHER=lan1.invalid devbox_gate run s1 proj 8 8 0 3600 verify; echo "rc=$?"'
assert_ok "the run verb, on its own connection, is refused the same way, as ssh's own 255" contains "rc=255" "$out"
assert_ok "  with the line verify reads as a host key refusal" contains "Host key verification failed: the host key of lan1.invalid is $GATE_STUB_OTHER_PIN" "$out"
assert_eq "" "$(cat "$LOG")" "  and no ssh started at all"
# shellcheck disable=SC2016  # the bash that sources the transport expands these, not this one
tr_run 'devbox_gate_target lan1.invalid cfg "" "" "$PIN"; FAKE_KEYSCAN_OTHER=lan1.invalid devbox_gate_rsync -a /src/ sync/s1/proj/; echo "rc=$?"'
assert_ok "so is the sync" contains "rc=255" "$out"
assert_eq "" "$(cat "$LOG")" "  and no rsync started"

# A recorded entry that is not the pin: from before the pin changed, or written
# by something else. It must not win, so it is refused before any scan or ssh.
printf 'lan1.invalid ssh-ed25519 %s\n' "$GATE_STUB_OTHER_HOSTKEY" >"$KH"
# shellcheck disable=SC2016  # the bash that sources the transport expands these, not this one
tr_run 'devbox_gate_target lan1.invalid cfg "" "" "$PIN"; devbox_gate_open; echo "rc=$? $GATE_OPEN_ERROR"'
assert_ok "a stale recorded entry returns 4" contains "rc=4 " "$out"
assert_ok "and names the file and both fingerprints" contains "the host key recorded for lan1.invalid in $KH is $GATE_STUB_OTHER_PIN, and the pin of lan1.invalid pins $GATE_STUB_PIN" "$out"
assert_ok "and the command that removes it" contains "ssh-keygen -R 'lan1.invalid' -f $KH" "$out"
assert_eq "" "$(cat "$KEYSCAN_LOG")" "  no scan replaced it in silence"
assert_fail "  and no master was opened" grep -qxF -- "-N" "$LOG"
assert_eq "0" "$(grep -c 'ENV PASSWORD_SET=yes' "$LOG")" "  and no ssh ran with the password in its environment"
printf 'lan1.invalid ssh-ed25519 %s\nlan1.invalid ssh-ed25519 %s\n' "$GATE_STUB_HOSTKEY" "$GATE_STUB_OTHER_HOSTKEY" >"$KH"
# shellcheck disable=SC2016  # the bash that sources the transport expands these, not this one
tr_run 'devbox_gate_target lan1.invalid cfg "" "" "$PIN"; devbox_gate_open; echo "rc=$?"'
assert_ok "a pinned entry beside a stale one is refused too, because ssh accepts either" contains "rc=4" "$out"

# A host that does not answer ssh-keyscan is unreachable, never a key mismatch.
rm -f "$KH"
# shellcheck disable=SC2016  # the bash that sources the transport expands these, not this one
tr_run 'devbox_gate_target lan1.invalid cfg "" "" "$PIN"; FAKE_KEYSCAN_NONE=lan1.invalid devbox_gate_open; echo "rc=$?"'
assert_ok "no key from ssh-keyscan returns 1, a host that did not answer" contains "rc=1" "$out"
assert_fail "  and no master was opened" grep -qxF -- "-N" "$LOG"
rm -f "$KH"

# ── rsync through the same ssh ───────────────────────────────────────────────
tr_run 'pin_target lan1.invalid cfg && devbox_gate_rsync -a --delete /src/ sync/s1/proj/'
rcall="$(awk '/^\[rsync\]/{n++} n==1' "$LOG")"
assert_eq "devbox-gate@lan1.invalid:sync/s1/proj/" "$(grep -v '^ENV ' <<<"$rcall" | tail -n1)" \
  "rsync writes to the gate's sync/ path"
e="$(grep -A1 -xF -- '-e' <<<"$rcall" | tail -n1)"
for opt in "'ssh'" "'PreferredAuthentications=password'" "'NumberOfPasswordPrompts=1'" "'ControlMaster=auto'" \
           "'StrictHostKeyChecking=yes'" "'HostKeyAlgorithms=ssh-ed25519'"; do
  assert_ok "the rsync -e command carries $opt, quoted for rsync's own splitter" contains "$opt" "$e"
done
assert_ok "the rsync -e command carries '-F' '/dev/null', so the sync dials the pinned address" \
  contains "'-F' '/dev/null'" "$e"
assert_ok "rsync's ssh gets the password through the environment" grep -qxF "ENV PASSWORD_SET=yes" <<<"$rcall"
assert_fail "and never through an argument" grep -qF "$PW" "$LOG"

# rsync splits a host spec at its FIRST colon. Unbracketed, an IPv6 target
# named the host `2001`, so every ssh verb worked and the sync failed.
for v6 in "2001:db8::1" "[2001:db8::1]:2200"; do
  tr_run "pin_target '$v6' cfg && devbox_gate_rsync -a /src/ sync/s1/proj/"
  rcall="$(awk '/^\[rsync\]/{n++} n==1' "$LOG")"
  assert_eq "devbox-gate@[2001:db8::1]:sync/s1/proj/" "$(grep -v '^ENV ' <<<"$rcall" | tail -n1)" \
    "an IPv6 target ($v6) reaches rsync in brackets"
done

# ── the OpenSSH floor ────────────────────────────────────────────────────────
ver_ok() {  # $1 what ssh -V prints
  printf '#!/bin/bash\necho "%s" >&2\n' "$1" >"$TMP/bin/ssh-v/ssh"
  # shellcheck disable=SC2016  # the bash that sources the transport expands these, not this one
  env PATH="$TMP/bin/ssh-v:$PATH" bash -c 'source "$1"; pin_target() { devbox_gate_target "$1" "$2" "" "" "$PIN"; }; devbox_ssh_version_ok' _ "$TRANSPORT"
}
mkdir -p "$TMP/bin/ssh-v"
chmod +x "$TMP/bin/ssh-v" 2>/dev/null
printf '' >"$TMP/bin/ssh-v/ssh"; chmod +x "$TMP/bin/ssh-v/ssh"
assert_ok "OpenSSH 8.4 meets the floor" ver_ok "OpenSSH_8.4p1 fixture, OpenSSL 1.1.1"
assert_ok "OpenSSH 9.2 meets the floor" ver_ok "OpenSSH_9.2p1 fixture, OpenSSL 3.0.0"
assert_fail "OpenSSH 8.2 does not" ver_ok "OpenSSH_8.2p1 fixture, OpenSSL 1.1.1"
assert_fail "OpenSSH 7.9 does not" ver_ok "OpenSSH_7.9p1, LibreSSL 2.7.3"
assert_fail "and an answer with no version does not" ver_ok "ssh: unknown"

printf '%d %d\n' "$TESTS_RUN" "$TESTS_FAILED"
