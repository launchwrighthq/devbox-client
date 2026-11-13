#!/bin/bash
# The lane lock and the held run of protocol 3, as a fake gate account plays
# them. Sourced by the tests that drive a whole `devbox verify` against a fake
# ssh, after tests/lib.sh.
#
# Since protocol 3 a client joins the queue of every eligible target: `lock
# <wait> <slug>...` takes the first free lane, and `run` (nine words) waits in
# the pool's queue, prints `devbox-pool: held <granted> <want>` at the grant and
# reads one line. `go` is followed by the env header and the gate's stdin;
# `abort`, or the end of stdin, ends the run with nothing run. Eleven stubs that
# each carried this exchange would drift from the host the way three version
# parses once drifted, so gate_stub_hold prints it once, as two functions a
# stub's own `case "$GATE_CMD"` calls:
#
#   _hold_lock   the whole `lock` verb. A lane is a real flock on
#                $FAKE_LANES/<host>/<slug>.lock, so concurrent runs of one
#                checkout and a test that holds a lane by hand meet as they do
#                on a host. A host named in FAKE_LANES_BUSY has every lane busy.
#                FAKE_LOCK_FAIL refuses at once. The wait is the verb's first
#                word, as on the host.
#   _hold_run    the queue and the hold of `run`, up to `go`, with the env
#                header read; it returns with the gate's stdin still unread,
#                and the stub's own arm plays the gate. Before that it exits:
#                0 on `abort` or the end of stdin, 80 with the pool's line when
#                no `go` comes within FAKE_PREP seconds, and FAKE_PRE_RC (with
#                FAKE_PRE_ERR on stderr) when the run ends before any grant.
#                FAKE_GRANT is "<host>:<seconds> ...": the queue wait of that
#                host, or `never`. A host it does not name grants at once.
#                FAKE_GRANTED is the token count of the held line, the ask when
#                unset.
#
# Every step is a line in $HOLD_LOG when the stub's environment names one:
# `<time> <host> <event> <word>`, the time from EPOCHREALTIME. A queued run
# keeps a ticket file in $FAKE_TICKETS (when set) from its start to its end,
# so a test can read which queues still hold a run.
#
# A queued run reads NO stdin, as the real pool reads none before its grant.
# This stub once read stdin while queued, so an `abort` ended its wait, and
# every client test passed while a real queued pool ignored that line and kept
# its ticket until its own grant. The client leaves a queue by killing that
# join's ssh, and the host notices the session is gone: here a watcher removes
# the ticket once this stub's process is gone, and logs `left session`. Each
# wait after the grant is the `read` builtin on stdin, and each child process
# has every stream on /dev/null: a run the client drops is killed, and a child
# that held the pipe of its stderr would outlive it.

gate_stub_hold() {
  cat <<'HOLD'
_hold_log() {
  local _t="${EPOCHREALTIME:-$(date +%s)}"
  # EPOCHREALTIME takes the locale's decimal mark, and awk reads a comma as
  # the end of the number.
  [ -z "${HOLD_LOG-}" ] || printf '%s %s %s %s\n' "${_t/,/.}" "$GATE_HOST" "$1" "${2-}" >>"$HOLD_LOG"
}
_hold_lock() {
  local _w _slugs _s _end
  read -r _ _w _slugs <<<"$GATE_CMD"
  if [ -n "${FAKE_LOCK_FAIL-}" ]; then
    echo "gate-root: refusing the lock: $FAKE_LOCK_FAIL" >&2
    exit 1
  fi
  mkdir -p "${FAKE_LANES:?}/$GATE_HOST"
  _end=$((SECONDS + _w))
  while :; do
    case " ${FAKE_LANES_BUSY-} " in *" $GATE_HOST "*) ;; *)
      for _s in $_slugs; do
        exec 9>"$FAKE_LANES/$GATE_HOST/$_s.lock"
        if flock -n 9; then
          _hold_log lock "$_s"
          printf 'LOCKED %s\n' "$_s"
          while IFS= read -r _; do :; done
          exit 0
        fi
        exec 9>&-
      done ;;
    esac
    if [ "$SECONDS" -ge "$_end" ]; then
      read -r _s _ <<<"$_slugs"
      echo "gate-root: no lane of $_s was free within ${_w}s" >&2
      exit 1
    fi
    # A child is safe here: the lock's stdout and stderr are files, so a
    # sleep that outlives a killed lock holds no pipe of the client's.
    sleep 1
  done
}
_hold_run() {
  local _slug _want _wait="" _e _cmd _n _i _l _rc _ticket="" _q _me _end
  read -r _ _slug _ _want _ _ _ _ _ _ <<<"$GATE_CMD"
  _hold_log run "$_slug"
  if [ -n "${FAKE_PRE_RC-}" ]; then
    [ -z "${FAKE_PRE_ERR-}" ] || printf '%s\n' "$FAKE_PRE_ERR" >&2
    exit "$FAKE_PRE_RC"
  fi
  for _e in ${FAKE_GRANT-}; do
    [ "${_e%%:*}" != "$GATE_HOST" ] || _wait="${_e#*:}"
  done
  if [ -n "$_wait" ] && [ "$_wait" != 0 ]; then
    _q="$FAKE_TICKETS"
    [ -n "$_q" ] || _q="$(mktemp -d)"
    _ticket="$_q/$GATE_HOST.$$"
    : >"$_ticket"
    _me=$$
    (
      while kill -0 "$_me" 2>/dev/null; do sleep 0.1; done
      if [ -e "$_ticket" ]; then rm -f "$_ticket"; _hold_log left session; fi
      [ -n "${FAKE_TICKETS-}" ] || rm -rf "$_q"
    ) </dev/null >/dev/null 2>&1 &
    if [ "$_wait" = never ]; then
      while :; do sleep 0.1 </dev/null >/dev/null 2>&1; done
    fi
    _end=$(( ${EPOCHREALTIME/[.,]/} + _wait * 1000000 ))
    while [ "${EPOCHREALTIME/[.,]/}" -lt "$_end" ]; do sleep 0.1 </dev/null >/dev/null 2>&1; done
    rm -f "$_ticket"
  fi
  echo "==> granted ${FAKE_GRANTED:-$_want} tokens after ${_wait:-0}s" >&2
  printf 'devbox-pool: held %s %s\n' "${FAKE_GRANTED:-$_want}" "$_want" >&2
  _hold_log held "${FAKE_GRANTED:-$_want}"
  if IFS= read -r -t "${FAKE_PREP:-60}" _cmd; then _rc=0; else _rc=$?; fi
  if [ "$_rc" -gt 128 ]; then
    echo "devbox-pool: released the grant: no go within ${FAKE_PREP:-60}s" >&2
    _hold_log released prep
    exit 80
  fi
  if [ "$_cmd" != go ]; then
    _hold_log abort "${_cmd:-eof}"
    exit 0
  fi
  _hold_log go
  IFS= read -r _n || exit 0
  for ((_i = 0; _i < _n; _i++)); do
    IFS= read -r _l || exit 0
    [ -z "${FAKE_HEADER_FILE-}" ] || printf '%s\n' "$_l" >>"$FAKE_HEADER_FILE"
  done
}
HOLD
}
