#!/bin/bash
# client/libexec/devbox-runpod-postgres, run against stubbed system tools: the URL it
# writes, the contract it creates, and a password that never becomes an argument.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
# shellcheck source=tests/lib.sh
source ./lib.sh
REPO="$(cd .. && pwd)"
SCRIPT="$REPO/client/libexec/devbox-runpod-postgres"

TMP="$(mktemp -d)" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
contains() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }

mkdir -p "$TMP/bin" "$TMP/state"
export ARGV_LOG="$TMP/argv" STDIN_LOG="$TMP/stdin" INSTALL_LOG="$TMP/install"
# Every stub records its argv. runuser also records its stdin, where the SQL travels, and
# install the files it writes from stdin.
for tool in apt-get curl pg_createcluster pg_ctlcluster pg_isready; do
  # The stub's own shell expands "$*" and $ARGV_LOG, not this one.
  # shellcheck disable=SC2016
  printf '#!/bin/sh\nprintf "%%s %%s\\n" %s "$*" >>"$ARGV_LOG"\n' "$tool" >"$TMP/bin/$tool"
done
cat >"$TMP/bin/runuser" <<'STUB'
#!/bin/sh
printf 'runuser %s\n' "$*" >>"$ARGV_LOG"
case "$*" in *" -c "*) ;; *) cat >>"$STDIN_LOG" ;; esac
STUB
cat >"$TMP/bin/install" <<'STUB'
#!/bin/sh
printf 'install %s\n' "$*" >>"$ARGV_LOG"
for last; do :; done
case "$*" in *" /dev/stdin "*) cat >>"$INSTALL_LOG" ;; *" -d "*|-d*) ;; *) : >"$last" ;; esac
STUB
chmod +x "$TMP/bin"/*

run() { PATH="$TMP/bin:$PATH" DEVBOX_POD_STATE="$TMP/state" DEVBOX_DSN_FILE="$TMP/dsn" bash "$SCRIPT"; }

rc=0
run >/dev/null 2>&1 || rc=$?
assert_eq 0 "$rc" "provisions with every system tool stubbed"
dsn="$(cat "$TMP/dsn" 2>/dev/null)"
pw="${dsn#postgresql+psycopg://devbox:}"
pw="${pw%@127.0.0.1:5435/devbox}"
assert_ok "writes a psycopg URL for role devbox on 127.0.0.1:5435" \
  test "$dsn" = "postgresql+psycopg://devbox:$pw@127.0.0.1:5435/devbox"
assert_ok "with a generated password" test "${#pw}" -ge 20
argv="$(cat "$ARGV_LOG")"
assert_fail "the password never becomes an argument" contains "$pw" "$argv"
assert_ok "it reaches psql on stdin" contains "PASSWORD '$pw'" "$(cat "$STDIN_LOG")"
sql="$(cat "$STDIN_LOG")"
assert_ok "the role can create a database per worker" contains "LOGIN CREATEDB" "$sql"
assert_ok "and the roles a suite's own tests create" contains "LOGIN CREATEDB CREATEROLE PASSWORD" "$sql"
assert_ok "and SET and INHERIT on the roles it creates" contains "ALTER ROLE devbox SET createrole_self_grant = 'set, inherit';" "$sql"
assert_ok "and owns its own database" contains "CREATE DATABASE devbox OWNER devbox" "$sql"
assert_ok "and may end a backend, as DROP DATABASE WITH (FORCE) needs" contains "GRANT pg_signal_backend TO devbox" "$sql"
assert_ok "the cluster is Postgres 16 on port 5435 with the server's connection cap" \
  contains "pg_createcluster 16 devbox --port 5435 -o max_connections=300" "$argv"
# pg_createcluster writes -o listen_addresses=127.0.0.1 bare, and Postgres refused that line
# with "syntax error near token .0". Quoted inside the -o, it came out as '''127.0.0.1'''.
assert_ok "pg_createcluster gets the connection cap and no listen address" \
  contains "pg_createcluster 16 devbox --port 5435 -o max_connections=300 -- --encoding=UTF8 --locale=C.UTF-8" "$argv"
assert_eq "listen_addresses = '127.0.0.1'" "$(grep listen_addresses "$INSTALL_LOG")" \
  "the listen address is a quoted string in the cluster's conf.d"
line_of() { grep -n -m1 -F -- "$1" "$ARGV_LOG" | cut -d: -f1; }
assert_ok "written there before the first start" \
  test "$(line_of conf.d/devbox.conf)" -lt "$(line_of 'pg_ctlcluster 16 devbox start')"
assert_ok "vector is in template1, so every worker database carries it" \
  contains "-d template1 -c CREATE EXTENSION IF NOT EXISTS vector" "$argv"
assert_ok "pgvector is installed beside Postgres" contains "postgresql-16-pgvector" "$argv"
assert_ok "the URL file is readable by dev only" contains "install -m 600 -o dev -g dev /dev/null $TMP/dsn" "$argv"

: >"$ARGV_LOG"
rc=0
run >/dev/null 2>&1 || rc=$?
assert_eq 0 "$rc" "a second run on the same pod succeeds"
assert_fail "and installs nothing again" contains "apt-get" "$(cat "$ARGV_LOG")"
assert_ok "but still proves the server answers" contains "pg_isready" "$(cat "$ARGV_LOG")"
assert_eq "$dsn" "$(cat "$TMP/dsn")" "and keeps the URL it wrote"

rc=0
err="$(PATH="$TMP/bin:$PATH" DEVBOX_POD_STATE="$TMP/other" bash "$SCRIPT" 2>&1)" || rc=$?
assert_fail "a run that names no URL file is refused" test "$rc" -eq 0
assert_ok "and says which variable to set" contains "DEVBOX_DSN_FILE" "$err"

printf '%d %d\n' "$TESTS_RUN" "$TESTS_FAILED"
