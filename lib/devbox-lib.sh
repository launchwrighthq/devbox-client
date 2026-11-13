#!/bin/bash
# Pure functions for the devbox remote-verify runner. Nothing here touches a
# host, a socket or a file outside a directory it is handed, so the whole file
# is covered by tests/test-devbox-lib.sh.
#
# One slug names four resources: the container, the volume, the Postgres role
# and the Postgres database. Keeping that derivation in one tested place is why
# the runner needs no registry of what it has created.

# Lowercase, collapse anything that is not alphanumeric into a single dash, and
# trim the ends. The result is a DNS label, which is what Docker accepts for a
# container name and what a hostname has to be.
devbox_sanitize() {
  [ "${1-}" = "--" ] && shift
  local s="${1-}"
  s="$(printf '%s' "$s" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-')"
  s="$(printf '%s' "$s" | tr -s '-')"
  s="${s#-}"
  s="${s%-}"
  [ -n "$s" ] || return 1
  printf '%s' "$s"
}

# The handshake between a client and a server. The two halves must agree on
# devbox_slug and devbox_pg_ident, and each reads this version from its OWN
# copy of this file, so two halves that compute them differently show up as a
# version mismatch. It changes only for a change that makes the two halves
# disagree: an output of this file that the other half reads or recomputes, or
# a verb the client reaches over ssh, devbox-runner's and devbox-pool's alike.
# A comment or a new function keeps it. It is not the release version, which
# lives in VERSION at the repo root, but the release major equals it, so one
# major is one protocol (tests/test-version-agreement.sh).
# devbox_pg_ident's comment below records the collision this prevents. Two
# checkouts silently shared one Postgres role.
#
# Version 2 is that integer plus a FINGERPRINT. `devbox-runner version` prints
# the sha256 of the library file it resolved beside this number, because the
# number alone cannot see two copies of this file that drifted while both still
# claim the same protocol. Two copies of the library can drift while both
# claim one protocol, for example after a partial upgrade, which leaves a
# laptop and a host on one protocol integer and two different libraries. That
# is a divergent devbox_pg_ident and therefore the collision below all over
# again.
#
# Version 3 answers in the same two fields, and the bump is the rule for this
# file: this library changed, so every host that carries the old bytes must be
# reinstalled before it is trusted. devbox_version_match_text landed at the
# bottom of this file, which puts the one comparison rule for a version pin in
# the requires-token format where BOTH halves reach it, and a host still
# running the previous copy compares that pin by a rule this laptop no longer uses.
#
# 4 adds the pool's queue verbs. A client that asks an older host for
# queue-estimate gets a usage line and exit 2, so a developer would set
# DEVBOX_MAX_QUEUE_WAIT, get no probe, and never be told why. The handshake is
# what refuses that instead.
#
# 5 changes no verb. The library text changed, so its fingerprint changed, and
# the bump makes the handshake say so with the integer. A host that still loads
# the version 4 copy is refused as a protocol mismatch, which names the fix,
# rather than as a bare fingerprint difference.
#
# 6 adds the gate account, many targets and the watchdog. A client no longer
# sends a command string to a root shell: it logs in as devbox-gate and sends
# one verb with checked words, which devbox-gate and gate-root accept from a
# fixed list. A client on 5 sends `devbox-runner
# version` as a raw string, and the dispatcher refuses it as an unknown verb.
# The five argument guards moved into this file at the same time, so both
# halves apply one copy of each rule. A client probes every deployed target
# with one `probe` verb, whose one-line answer devbox_probe_line builds on the
# host and devbox_probe_parse reads on the laptop. A host on 5 has no
# devbox-gate account, so the login fails and the client names a refused gate
# password (exit 3). It never reaches the probe there. An empty probe answer is
# a handshake failure: a devbox-gate that predates the probe verb, or a missing
# devbox-runner. The client names the repair, rather than skip that host for a
# reason nobody can act on.
#
# 6 also marks every guard's refusal as devbox's own. devbox-verify's strict
# mode (DEVBOX_STRICT=1) maps only an exit that devbox chose, and it reads
# OWN_EXIT to know one. The guards first exited 2 with no mark, so strict mode
# read a refused DEVBOX_PROJECT as a step that died (65) instead of a refused
# config (66).
#
# 6 also carries the watchdog. The `run` verb carries the gate's wall-clock
# limit, and require_gate_max_seconds below is the one rule the client,
# devbox-gate and gate-root apply to it. A host whose `run` takes six words
# refuses the seven-word `run` with exit 2 AFTER the sync and the setup have
# run; the handshake refuses it at the probe, before anything is spent, and
# names the repair.
#
# 7 adds the `status` verb: `devbox-pool snapshot`,
# `devbox-runner status <machine-id>`, the gate verb in devbox-gate and
# gate-root, and the reply format, which devbox_status_line builds on the host
# and devbox_status_parse reads on the laptop. A host on 6 refuses `status` as
# an unknown verb and answers nothing, and the client reads that empty answer as
# a handshake failure, as it does for the probe. The bump also stops `devbox
# verify` on a host that still runs 6, so every target is deployed before any
# consumer moves its pin.
#
# 8 removes every character that is not printable from a host's version answer
# in devbox_handshake_verdict and from its probe answer in devbox_probe_parse,
# before either is read or printed. Both come from a host, and a refusal prints
# them on the developer's terminal, so a host that sent ESC bytes could rewrite
# that terminal. The library text changed, so the integer moves by this file's
# rule.
#
# 2 is protocol 8 renumbered, and from here the integer IS the release major:
# release 2.x speaks 2, and tests/test-version-agreement.sh holds the two equal.
# Releases 1.0.0 and 1.1.x spoke 8, so a reader had to know an offset of 7 to
# tell which release a host runs from its version answer. Nothing either half
# computes changed. The new number alone makes a 1.x client refuse a 2.x host,
# so 2.0.0 is a major release. The earlier protocol 2 predates every host a
# client of today reaches.
#
# This assignment sits BELOW devbox_sanitize, and only for the directive under
# this line. A shellcheck directive placed before the first command of a file
# applies to the whole file and to every line added to it later, so a genuinely
# unused variable written here tomorrow would be silenced by a reason that is
# true of this one variable alone. That is a blanket disable, which this
# repository forbids, and it turns the gate into decoration. After a command, a directive
# binds to the next command only. The position costs nothing at run time: this
# file is SOURCED, so every line here runs before the sourcing script
# continues, and the variable is set long before any consumer reads it.
# shellcheck disable=SC2034  # read by whatever sources this file, never here
DEVBOX_PROTOCOL_VERSION=2

# The handshake's second field: the sha256 of a library file, hex only, with no
# filename beside it. It is handed the path rather than reading its own, so it
# stays pure in this file's sense and tests/test-devbox-lib.sh can drive it
# against a fixture, and so devbox-runner can fingerprint the copy its resolver
# actually selected rather than the copy the host is assumed to carry.
#
# Every failure returns non-zero and prints nothing on stdout, and that is the
# whole safety of the feature: an empty string compares equal to another empty
# string, so a fingerprint this function silently failed to compute would report
# two drifted libraries as agreeing. A missing file, an unreadable one and an
# absent sha256sum are therefore refusals, not blanks.
#
# The file is read on STDIN rather than named as an argument, because GNU
# sha256sum escapes a filename that holds a backslash or a newline by prefixing
# its whole output line with a backslash, which would put that backslash into
# the first field and make a perfectly good file's fingerprint compare unequal
# to itself.
devbox_lib_fingerprint() {
  local f="${1-}" sum
  if [ -z "$f" ] || [ ! -f "$f" ] || [ ! -r "$f" ]; then
    echo "devbox_lib_fingerprint: no readable library file at '$f'" >&2
    return 1
  fi
  if ! command -v sha256sum >/dev/null 2>&1; then
    echo "devbox_lib_fingerprint: sha256sum is not here, so this library cannot be fingerprinted" >&2
    return 1
  fi
  sum="$(sha256sum <"$f" | cut -d' ' -f1)" || return 1
  # The shape is checked rather than trusted, for the reason above: a truncated
  # or empty digest that reached a caller would be compared as though it were a
  # real one.
  if ! [[ "$sum" =~ ^[0-9a-f]{64}$ ]]; then
    echo "devbox_lib_fingerprint: sha256sum returned no hex digest for '$f'" >&2
    return 1
  fi
  printf '%s' "$sum"
}

# The verdict on one `devbox-runner version` answer, and the ONE implementation
# of that comparison.
#
# devbox-verify, devbox-gc and devbox-doctor each carried their own parse and
# their own comparison of this answer. devbox-gc's was never updated when the
# answer gained its second field, so it matched a correct "<integer> <sha256>"
# against `*[!0-9]*` and reported every server this repository installs as
# unreachable, missing or predating the handshake. Every gc run exited 5 with a
# wrong diagnosis, on the one client command that DESTROYS a container, a
# volume, a Postgres role and every database that role owns. Three copies of one
# protocol rule is the drift this repository exists to prevent, applied to the
# very mechanism that detects drift, so there is one copy now and it is here.
#
# Pure in this file's sense: it is handed the server's answer and the path of
# the library to fingerprint, and touches nothing else, so
# tests/test-devbox-lib.sh can drive every case below with no host, no ssh and
# no docker.
#
# The protocol integer is the ONE compatibility number, and it equals the
# release major (tests/test-version-agreement.sh). A client and a server of one
# major work together whatever their minor and patch. This function once refused
# every server whose library differed by one byte, comments included, so every
# release that touched the library forced every consumer to move its pin before
# its next gate could run. A change that makes two halves of one protocol
# disagree, such as another slug or another reply format, is a protocol bump and
# a major release. tests/test-devbox-lib.sh pins the outputs that would show one.
#
# It prints ONE line and returns a distinct status per case. The line is the
# diagnosis on failure, and on success it says whether the two libraries are the
# same file. It names no host and no program: the caller knows its own name and
# its own repair, and a library that wrote "devbox verify:" into a line
# devbox-gc prints would send the reader to the wrong command.
#
#   0  both halves speak one protocol
#   1  this client's library carries no DEVBOX_PROTOCOL_VERSION
#   3  the server answered nothing
#   5  the server's answer is not a protocol version at all
#   6  the two protocol integers differ
#
# The fingerprint is a report, never a refusal. A library that differs is the
# normal state of a laptop on 2.2.0 beside a host on 2.4.1. The success line
# still names the case, because `devbox doctor` prints it. A fingerprint this
# client failed to compute is named as that, never compared as the empty
# string, which would report two different libraries as the same file.
devbox_handshake_verdict() {
  local answer="${1-}" lib="${2-}" line proto fp local_fp
  if [ -z "${DEVBOX_PROTOCOL_VERSION:-}" ]; then
    printf '%s\n' "this client's copy of devbox-lib.sh carries no DEVBOX_PROTOCOL_VERSION, so this client predates the handshake"
    return 1
  fi
  # The first line only. A server that answered several lines would otherwise
  # put a newline inside a refusal that every caller prints as one line.
  line="${answer%%$'\n'*}"
  line="${line//[^[:print:]]/}"
  read -r proto fp <<<"$line" || true
  case "$proto" in
    "")
      printf '%s\n' "the server did not report a protocol version"
      return 3 ;;
    *[!0-9]*)
      printf '%s\n' "the server answered '$line', which is not a protocol version"
      return 5 ;;
  esac
  if [ "$proto" != "$DEVBOX_PROTOCOL_VERSION" ]; then
    printf '%s\n' "the protocol integers differ: this client speaks $DEVBOX_PROTOCOL_VERSION, the server speaks $proto"
    return 6
  fi
  # Twelve characters is enough to tell two sha256 digests apart by eye and
  # short enough to read in a terminal beside the rest of the line.
  if ! local_fp="$(devbox_lib_fingerprint "$lib" 2>/dev/null)"; then
    printf '%s\n' "both halves speak protocol $proto; this client could not fingerprint $lib, so the two libraries were not compared"
  elif [ -z "$fp" ]; then
    printf '%s\n' "both halves speak protocol $proto; the server names no library fingerprint"
  elif [ "$fp" = "$local_fp" ]; then
    printf '%s\n' "both halves speak protocol $proto and load the same devbox-lib.sh (${local_fp:0:12})"
  else
    printf '%s\n' "both halves speak protocol $proto; their copies of devbox-lib.sh differ (this client's ${local_fp:0:12}, the server's ${fp:0:12}), which one protocol allows"
  fi
}

# <machine>-<project>-<worktree basename>-<6 hex of the machine id and path>.
#
# Component widths (8, 18, 18) are chosen so `ws_` plus the slug is 56 bytes,
# comfortably inside Postgres's 63-byte identifier limit.
devbox_slug() {
  local machine="$1" machine_id="$2" project="$3" path="$4" mach proj base hash
  # Every component is sanitized, truncated and dash-trimmed the same way. An
  # earlier version returned exit 0 for a project or machine that sanitized to
  # empty (project comes from a project's committed .devbox/profile.sh, so a
  # misconfigured or empty DEVBOX_PROJECT must fail loudly, not render as a
  # blank field or a stray double dash).
  mach="$(devbox_sanitize "$machine")" || return 1
  mach="${mach:0:8}"
  mach="${mach%-}"
  proj="$(devbox_sanitize "$project")" || return 1
  proj="${proj:0:18}"
  proj="${proj%-}"
  base="$(devbox_sanitize "$(basename "$path")")" || return 1
  base="${base:0:18}"
  base="${base%-}"
  # The hash covers the MACHINE ID as well as the path, because two laptops
  # routinely hold the same project at the same absolute path. Hashing the path
  # alone gave both of them one slug, so they shared a container, a volume, a
  # Postgres role and a database, and their two gates clobbered each other's
  # tables.
  #
  # The machine id rather than the hostname, because two laptops can both
  # carry the same vendor default hostname. The hostname is the readable
  # component only.
  hash="$(printf '%s\0%s' "$machine_id" "$path" | sha256sum | cut -c1-6)"
  printf '%s-%s-%s-%s' "$mach" "$proj" "$base" "$hash"
}

# The two impure readers. Kept out of devbox_slug so that stays a pure function
# with unit tests; these touch the machine and are thin enough to read at a
# glance.
devbox_machine_label() { devbox_sanitize "$(hostname)"; }

# Reads /etc/machine-id, falling back to /var/lib/dbus/machine-id. Accepts an
# explicit candidate list so tests/test-devbox-lib.sh can point this at a
# directory with neither file, without touching the real filesystem paths.
#
# This function cannot see a CLONED machine id, and no check here can. Two VMs
# imaged from one template carry the same /etc/machine-id, so devbox_slug gives
# them one slug space and gc gives them one scope: a gc on the first VM removes
# the second VM's containers, volumes, Postgres roles and databases, because
# their devbox.machine-id label matches the filter. Minting a per-install id
# would fix it, and would also change every slug that every existing workspace
# already carries, so this round records the limitation rather than renaming
# live resources. devbox doctor cannot detect it either.
devbox_machine_id() {
  local -a candidates=("$@")
  [ "${#candidates[@]}" -eq 0 ] && candidates=(/etc/machine-id /var/lib/dbus/machine-id)
  local f id
  for f in "${candidates[@]}"; do
    [ -r "$f" ] || continue
    read -r id <"$f" || continue
    [ -n "$id" ] || continue
    # Checked here, at the one place the value is read, so every caller gets the
    # same rule. This string is interpolated into a remote ROOT shell command in
    # devbox-verify and in devbox-gc, and into the docker label filter that
    # decides which workspaces gc is allowed to destroy. A machine id is hex, so
    # a file holding a space, a quote or a $(...) is not one, and a filter built
    # from it would match workspaces this machine does not own. Read the next
    # candidate instead of returning a value that cannot be a machine id.
    [[ "$id" =~ ^[0-9a-fA-F]+$ ]] || {
      echo "devbox_machine_id: $f does not hold a hex machine id, so it is ignored" >&2
      continue
    }
    printf '%s' "$id"
    return
  done
  # Refuse rather than fall back to the hostname. A fallback that is not unique
  # per machine silently reintroduces the collision this function exists to
  # prevent, and the failure would show up as two laptops sharing a database.
  echo "devbox_machine_id: no machine-id found; cannot tell this host apart from another" >&2
  return 1
}

# Postgres folds unquoted identifiers to lowercase and truncates silently at 63
# bytes. Truncating here instead means the role we create and the role we
# connect as are the same string.
devbox_pg_ident() {
  local ident="ws_${1//-/_}"
  [ "${#ident}" -le 63 ] && { printf '%s' "$ident"; return; }
  # Keep the discriminating tail. The last 6 characters of a slug are
  # devbox_slug's path hash, and they are the ONLY part that tells two
  # worktrees apart when their project and basename agree. Truncating left to
  # right drops them first, which is how two checkouts silently landed on one
  # Postgres role while their container names stayed distinct.
  printf '%s%s' "${ident:0:56}" "${ident: -7}"
}

# The sum of every live grant. Callers hold the pool lock while reading this.
pool_held() {
  local dir="$1" total=0 f n
  for f in "$dir"/*; do
    [ -e "$f" ] || continue
    read -r n <"$f" || continue
    # $((total + n)) reads a non-numeric or empty n as an unset variable name
    # and silently treats it as 0 (or, under a caller's set -u, crashes the
    # whole script with "unbound variable"). Either way a truncated or corrupt
    # grant file would under-count what is held, and pool_may_grant would then
    # approve a grant that pushes real usage over budget, the one thing the
    # pool exists to prevent. Reject explicitly instead.
    if ! [[ "$n" =~ ^[0-9]+$ ]]; then
      echo "pool_held: not a non-negative integer in $f: $n" >&2
      return 1
    fi
    total=$((total + n))
  done
  printf '%d' "$total"
}

# Both bounds must pass. Tokens bound CPU; max_jobs bounds MEMORY, because each
# workspace container has a memory cap and the host's RAM bounds how many caps
# fit at once. A further job can fit in tokens long before it fits in RAM.
pool_may_grant() {
  local total="$1" held="$2" jobs="$3" max_jobs="$4" want="$5"
  [ "$jobs" -lt "$max_jobs" ] || return 1
  [ $((total - held)) -ge "$want" ] || return 1
  return 0
}

# The ONE rule for comparing a `name=version` pin in the requires-token format
# against what a program reports for itself. It lives HERE because this library
# is the only file both halves already load, and because two programs compared
# that one token format with two hand-written rules: the server's image check
# dropped a Debian epoch before comparing and devbox-runner check-requires did not, so one token
# passed one program and failed the other. Three copies of one protocol rule is
# the drift this repository exists to prevent; two copies is the same drift one
# copy earlier.
#
# The two callers still compare in two places, because they must: the image
# check compares in bash on the laptop, after the binary's own output has come back
# over ssh, and check-requires renders a `grep -qF` into a probe script that the
# container's shell runs. What they share is the TEXT to look for, which is what
# they disagreed about.
#
# The rule. A pin is a Debian version, [epoch:]upstream[-revision], as in
# 2:1.4.0. Only the part AFTER the epoch is compared, and it is compared as
# literal text that must appear somewhere in the --version output. The epoch is
# dpkg's own ordering field: it exists to sort two upstream versions that would
# otherwise sort in the wrong order, and no program prints one, because no
# program has ever heard of it. A tool pinned at 2:1.4.0 reports
# 1.4.0-1+deb13u1, so comparing the raw pin makes a correctly pinned image
# report FAIL on every single run, and a check that always fails is a check
# nobody reads. The epoch is dropped for the COMPARISON only: both callers pass
# the token through to apt and to the build exactly as the deployment wrote it.
#
# An empty answer is a refusal, never a blank. `tool=2:` satisfies both
# callers' character checks, and an empty needle is contained in every string in
# the world, so a pin that normalized to nothing would report ok against every
# image ever built: the same silent pass an empty build-argument guard in the
# image exists to stop, arriving through the comparison instead of through the build.
# Nothing is printed on stdout on that path, for the reason
# devbox_lib_fingerprint records: a caller that read a failure as a value would
# compare the empty string.
devbox_version_match_text() {
  local pin="${1-}"
  # (.*) rather than (.+), so `7:` is caught by the emptiness check below
  # instead of silently keeping its own epoch and comparing as the text "7:".
  if [[ "$pin" =~ ^[0-9]+:(.*)$ ]]; then pin="${BASH_REMATCH[1]}"; fi
  if [ -z "$pin" ]; then
    echo "devbox_version_match_text: '${1-}' names no version once its epoch is removed, and an empty version matches every image" >&2
    return 1
  fi
  printf '%s' "$pin"
}

# The one exit of every guard here. It sets OWN_EXIT, which devbox-verify's
# strict mode reads to tell a refusal devbox chose from a step that died under
# set -e. Without the mark, a refused DEVBOX_PROJECT read as 65, "a step before
# the gate stopped", instead of 66, a refused config (tests/test-strict-mode.sh).
# The server half sources this file too, and no program there reads the mark.
devbox_guard_exit() {
  # shellcheck disable=SC2034  # read by devbox-verify's strict map, never here
  OWN_EXIT=1
  exit 2
}

# ── one rule per value that crosses to a devbox host ─────────────────────────
#
# These five guards lived in client/libexec/devbox-verify. They moved here in
# protocol 6, because the server half now applies the SAME rules: devbox-gate,
# the sshd ForceCommand of the gate account, checks every word a client sends,
# and gate-root checks each word again as root. One copy of each rule on both
# machines is what this file is for. Two copies is the drift that gave
# devbox-gc a handshake parse one field behind the other two clients.
#
# Each caller names itself in DEVBOX_GUARD_WHO ("devbox verify", "devbox-gate",
# "gate-root"), and every refusal starts with that name. A library that wrote
# "devbox verify:" into a line devbox-gate prints would send the reader to the
# wrong program. Every refusal exits 2, on both machines, through
# devbox_guard_exit below.
#
# DEVBOX_PROJECT arrives from a committed file, and it reaches the host as the
# workspace directory /home/dev/$DEVBOX_PROJECT: the rsync destination, the two
# `.git` writes, and the working directory of every `docker exec`. Before the
# gate account, each of those was a command string that ran AS ROOT on the
# shared devbox. The file is committed, so any contributor edits it, and the
# value then crosses to another machine. So it is checked before it leaves this
# laptop, on the rule the server install applies to the workspace image name,
# and checked again on the host, which must not trust its caller.
#
# devbox_slug sanitizes this same value, and that does not help here. The slug
# names the container, the volume and the Postgres role; the RAW value is what
# reaches $MOUNT/$DEVBOX_PROJECT. An all-dots value is refused on its own
# because each of its characters is already allowed, and it walks that
# destination out of the workspace: `..` climbs out of the workspace, and `.`
# and `...` collapse the destination onto /home/dev itself, where the sync's
# `--delete` then acts on every project on that workspace rather than on one.
#
# The guards are functions rather than one case statement per value, because
# they are one policy, and a policy that is written out once per value is the
# shape that let three of these four values ship unchecked.
#
# `+` is in the set, and it is the one character here that had to be argued for.
# It is not a shell metacharacter: unquoted it is a literal in a word, it is not
# a glob character, and no expansion reads it. git accepts it in a branch and in
# a worktree directory, so it reaches WORKTREE verbatim. MEASURED: a worktree
# named like `fix+example-branch` was refused here,
# `make verify`'s `| tail` hid the exit 2, and the session read a refused gate as
# a gate that had not run and reached for a local one. A guard that refuses a
# legitimate name costs the devbox the run it exists to take.
# require_safe_token already allows `+` for values that reach the same host.
require_safe_name() {
  local label="$1" value="$2" origin="$3"
  case "$value" in
    ""|-*|*[!A-Za-z0-9._+-]*) ;;
    # Stripping the dots tests every all-dots value at once. Listing them
    # instead is what left `.` and `...` accepted while `..` was refused.
    *) [ -z "${value//./}" ] || return 0 ;;
  esac
  echo "${DEVBOX_GUARD_WHO:-devbox}: refusing $label '$value' from $origin: allowed characters are A-Za-z0-9._+-, and it may not be all dots or start with a dash" >&2
  devbox_guard_exit
}
# A name from DEVBOX_FORWARD_ENV, which becomes a NAME=value line in an env file
# on the host and then a variable the gate's shell defines. The POSIX shape and
# nothing wider: a letter or underscore, then letters, digits and underscores.
# Its own function, beside the policy above, because that is where the next
# reader will look for it and because a test can extract and RUN it there.
#
# The third argument names the list the value came from. The client reads it
# from DEVBOX_FORWARD_ENV; gate-root reads the same names back off the env
# header on stdin, and a refusal there that blamed DEVBOX_FORWARD_ENV would
# send an operator to a file on a laptop they cannot see.
require_env_name() {
  local value="$1" origin="$2" list="${3:-DEVBOX_FORWARD_ENV}"
  case "$value" in
    ""|[!A-Za-z_]*|*[!A-Za-z0-9_]*) ;;
    *) return 0 ;;
  esac
  echo "${DEVBOX_GUARD_WHO:-devbox}: refusing '$value' in $list from $origin: an environment variable name is a letter or underscore, then letters, digits and underscores" >&2
  devbox_guard_exit
}
# A machine id from the wire: hex and nothing else, the rule devbox_machine_id
# applies where the laptop reads the value and devbox-runner's assert_machine_id
# applies where the host uses it. The gate verbs `ensure-workspace` and `gc`
# check their machine id with require_safe_name, which accepts any name, so a
# word that is not hex reaches root through sudo and gate-root and is refused
# only there, by the runner. The `status` verb checks it with this guard in
# devbox-gate and in gate-root, so such a word starts nothing as root.
require_machine_id() {
  local value="$1" origin="$2"
  [[ "$value" =~ ^[0-9a-fA-F]+$ ]] && return 0
  echo "${DEVBOX_GUARD_WHO:-devbox}: refusing machine id '$value' from $origin: a machine id is hex" >&2
  devbox_guard_exit
}
# The digit test on its own, because two callers need it and only one of them
# may end the run. require_uint refuses a value that is about to cross to the
# host; the OOM counter devbox-verify reads comes back FROM that host, which may
# not be able to answer, and an unreadable counter must degrade to "I could not
# look" rather than kill the run or, worse, be read as a zero.
is_uint() {
  case "${1-}" in
    ""|*[!0-9]*) return 1 ;;
  esac
  return 0
}
require_uint() {
  local label="$1" value="$2" origin="$3"
  if ! is_uint "$value"; then
    echo "${DEVBOX_GUARD_WHO:-devbox}: refusing $label '$value' from $origin: it must be a non-negative integer" >&2
    devbox_guard_exit
  fi
}
# A gate's wall-clock limit, DEVBOX_GATE_MAX_SECONDS. No gate had one
# before the watchdog. MEASURED: pytest runs spun at 100% of one core in an
# endless loop until a person noticed, and no rule bounded how long a gate may
# run. The client reads the value from a committed file, and devbox-gate and
# gate-root read it from the wire, so all three apply this one rule. The ceiling
# is four hours, far above what any measured gate cost, so a limit past that is
# no limit. Zero is refused with the rest, because a limit of no seconds stops
# every gate on the watchdog's next pass.
DEVBOX_GATE_MAX_SECONDS_CEILING=14400
require_gate_max_seconds() {
  local value="$1" origin="$2"
  if [[ "$value" =~ ^[1-9][0-9]{0,4}$ ]] && [ "$value" -le "$DEVBOX_GATE_MAX_SECONDS_CEILING" ]; then
    return 0
  fi
  echo "${DEVBOX_GUARD_WHO:-devbox}: refusing DEVBOX_GATE_MAX_SECONDS '$value' from $origin: write a whole number of seconds from 1 to $DEVBOX_GATE_MAX_SECONDS_CEILING, as in 3600" >&2
  devbox_guard_exit
}
# The same policy for a DEVBOX_REQUIRES token. The class is wider than
# require_safe_name's by five characters, and every one of them is required by a
# token form the server defines: `/` by an absolute path, `=` by name=version,
# and `:`, `+` and `~` by a Debian version such as 2:1.4.0-1+deb12u1, whose
# epoch and revision are not decoration. None of the five can RUN anything in
# a shell: no space, no semicolon, no pipe, no backquote, no dollar, no bracket
# and no quote survives this class, which is the whole job here.
#
# It is deliberately the UNION of the three token forms rather than a copy of
# devbox-runner's three per-form regular expressions. This side decides what may
# cross to a host; that side decides whether a token is a well-formed
# requirement and refuses one that is not with its own message. Two copies of
# one regular expression, on two machines, is the drift this repository already
# has a handshake for.
require_safe_token() {
  local label="$1" value="$2" origin="$3"
  case "$value" in
    ""|-*|*[!A-Za-z0-9._:/+~=-]*) ;;
    # The same all-dots test require_safe_name applies, and for the same reason:
    # every character of `..` is already allowed, and a bare `..` is a token
    # that names nothing a project can require.
    *) [ -z "${value//./}" ] || return 0 ;;
  esac
  echo "${DEVBOX_GUARD_WHO:-devbox}: refusing $label '$value' from $origin: allowed characters are A-Za-z0-9._:/+~=-, and it may not be all dots or start with a dash" >&2
  devbox_guard_exit
}

# The script that finishes a sync inside the workspace, printed rather than run,
# so both places that need it run ONE copy: gate-root pipes it into the
# workspace container as `dev`, and devbox-runpod pipes it into a rented pod. It
# takes the workspace directory as $1 and, for a linked worktree, the worktree
# name as $2. Both arrive as arguments of `bash -s`, never inside the text.
#
# A linked worktree's `.git` is a one-line `gitdir:` pointer at a path on THE
# LAPTOP, so the copy the sync just made dangles and git in the workspace
# answers `fatal: not a git repository`. Every test that reads the checkout's
# own history then fails, which is not hypothetical for a project whose
# rsync-filter syncs `.git` on purpose: any test that reads git history.
# `commondir` inside the private gitdir is relative (`../..`) and
# resolves on its own once both sides are in the workspace, so only the two
# ABSOLUTE pointers need rewriting: the worktree's `.git` and the back-pointer
# beside its index.
#
# The copy lands INSIDE the checkout, so git counts every file under it as
# untracked. MEASURED: a workspace reported thousands of untracked files
# against a handful on the laptop. A project tool that reads every untracked
# file grew past the workspace memory cap and was killed, twice, on an idle box,
# while locally it used a few MB.
#
# info/exclude rather than .gitignore, because .gitignore is the PROJECT'S
# committed file and this directory is the devbox's own artefact: a sync must
# not put a line in a file the developer then sees as a local modification.
# info/exclude is per clone, is never committed, and lives in the common dir.
# Appended only when absent: the rsync refreshes this file from the laptop's own
# copy on every run, so a blind append would add one line per gate for the life
# of the workspace. It runs AFTER the gitdir pointers, which are what make the
# common dir a git directory at all.
#
# Excluding a path also PROTECTS it from `--delete`, so the sync's exclude rules
# stop a new bad symlink arriving and cannot remove one already there. The last
# loop repairs it, because a workspace `.venv` or `node_modules` is always a
# real directory: anything else is the bug devbox-sync's comment records.
devbox_sync_finish_script() {
  cat <<'SCRIPT'
set -eu
dir="$1"
wt="${2:-}"
if [ -n "$wt" ]; then
  printf 'gitdir: %s/.git-common/worktrees/%s\n' "$dir" "$wt" >"$dir/.git"
  printf 'gitdir: %s/.git\n' "$dir" >"$dir/.git-common/worktrees/$wt/gitdir"
  mkdir -p "$dir/.git-common/info"
  grep -qxF '.git-common/' "$dir/.git-common/info/exclude" 2>/dev/null \
    || printf '%s\n' '.git-common/' >>"$dir/.git-common/info/exclude"
fi
for d in .venv node_modules; do
  if [ -L "$dir/$d" ]; then rm -f "$dir/$d"; fi
done
SCRIPT
}

# ── the probe line ───────────────────────────────────────────────────────────
#
# A client used to ask a host three questions, one round trip each:
# `devbox-runner version`, `devbox-pool queue-estimate` and, with the watchdog,
# its health. Over the internet each round trip to a public target costs a
# password authentication and a handshake, and a client that chooses among
# several targets asks every one of them. So the host answers all three in ONE
# line, and the format lives here, once, because the host writes it and the
# laptop reads it:
#
#   <protocol> <lib-sha256> <health> <health-age-seconds> <queue-verdict>
#   <queue-seconds> <tokens> <jobs> <queued> [<health reason>...]
#
# on one line. The health reason is the rest of the line, because the
# watchdog's reason ("disk 93%") holds spaces and the client prints it in the
# line that names a skipped target. A field the host could not read is `-`, so
# every line has nine words before the reason.

# Build the probe line from the three answers. Pure: it is handed the text of
# each answer and the current epoch, so tests/test-devbox-lib.sh drives it with
# no host.
#
#   $1  the answer of `devbox-runner version`
#   $2  the answer of `devbox-pool queue-estimate <want> <min>`
#   $3  the first line of /run/devbox/health: `<epoch> ok`, or
#       `<epoch> degraded <reason>`, or `<epoch> down <reason>`
#   $4  the current epoch
#
# A version word that holds a character outside the safe set is rewritten, not
# dropped: an older runner that prints its usage still reaches the client as
# "not a protocol version", which is the diagnosis the handshake owes it. An
# estimate that does not parse is `unknown`, the verdict the pool itself gives
# when it will not put a number on a wait. A missing health file is `missing`
# with age -1, and one that does not parse is `invalid` with age -1: before the
# watchdog runs there is no file, and a client must read that as "not healthy",
# never as "ok".
devbox_probe_line() {
  local version="${1-}" estimate="${2-}" health_line="${3-}" now="${4-}"
  local proto fp _rest verdict secs tokens jobs queued health age reason=""
  version="${version%%$'\n'*}"
  read -r proto fp _rest <<<"$version" || true
  proto="${proto//[!A-Za-z0-9._:+-]/_}"
  fp="${fp//[!A-Za-z0-9._:+-]/_}"
  estimate="${estimate%%$'\n'*}"
  if [[ "$estimate" =~ ^(now|wait|never|unknown)\ ([0-9]+|-)\ [0-9]+\ ([0-9]+/[0-9]+)\ ([0-9]+/[0-9]+)\ ([0-9]+)$ ]]; then
    verdict="${BASH_REMATCH[1]}"; secs="${BASH_REMATCH[2]}"
    tokens="${BASH_REMATCH[3]}"; jobs="${BASH_REMATCH[4]}"; queued="${BASH_REMATCH[5]}"
  else
    verdict=unknown; secs=-; tokens=-; jobs=-; queued=-
  fi
  read -r health age reason <<<"$(devbox_health_fields "$health_line" "$now")" || true
  printf '%s %s %s %s %s %s %s %s %s%s\n' "${proto:--}" "${fp:--}" "$health" "$age" \
    "$verdict" "$secs" "$tokens" "$jobs" "$queued" "${reason:+ $reason}"
}

# The watchdog's health line, read into `<health> <age> [<reason>...]`. The probe
# line and the status reply both carry it, and both read it here, so a host
# cannot answer `ok` to one and `invalid` to the other.
#
#   $1  the first line of /run/devbox/health
#   $2  the current epoch
#
# The rules are the probe's, moved here unchanged when the status reply needed
# them too. A missing health file is `missing` with age -1, and one that does
# not parse is `invalid` with age -1: before the watchdog runs there is no file,
# and a client must read that as "not healthy", never as "ok".
devbox_health_fields() {
  local health_line="${1-}" now="${2-}" health age reason="" epoch state
  health_line="${health_line%%$'\n'*}"
  read -r epoch state reason <<<"$health_line" || true
  if [ -z "$health_line" ]; then
    health=missing; age=-1
  elif [[ "$epoch" =~ ^[0-9]+$ ]] && [[ "$now" =~ ^[0-9]+$ ]] \
       && { [ "$state" = ok ] || [ "$state" = degraded ] || [ "$state" = down ]; }; then
    health="$state"
    age=$((now - epoch))
    # A health line from the future is a clock that moved, not a stale watchdog.
    [ "$age" -ge 0 ] || age=0
  else
    health=invalid; age=-1; reason=""
  fi
  reason="${reason//[![:print:]]/}"
  printf '%s %s%s\n' "$health" "$age" "${reason:+ $reason}"
}

# Read one probe line into PROBE_PROTOCOL, PROBE_LIB, PROBE_HEALTH,
# PROBE_HEALTH_AGE, PROBE_VERDICT, PROBE_SECS, PROBE_TOKENS, PROBE_JOBS,
# PROBE_QUEUED and PROBE_REASON. Returns 1 when the line is not a probe line.
#
# The first two words are set whatever the rest says, with `-` read back as
# empty, so a caller can still run the handshake over them. A line from a host
# on another protocol may carry other fields, and the handshake, not this
# parser, is what names that repair.
# shellcheck disable=SC2034  # every PROBE_ variable is read by the caller
devbox_probe_parse() {
  local line="${1-}"
  line="${line%%$'\n'*}"
  line="${line//[^[:print:]]/}"
  PROBE_PROTOCOL=""; PROBE_LIB=""; PROBE_HEALTH=""; PROBE_HEALTH_AGE=""; PROBE_VERDICT=""
  PROBE_SECS=""; PROBE_TOKENS=""; PROBE_JOBS=""; PROBE_QUEUED=""; PROBE_REASON=""
  read -r PROBE_PROTOCOL PROBE_LIB PROBE_HEALTH PROBE_HEALTH_AGE PROBE_VERDICT PROBE_SECS \
    PROBE_TOKENS PROBE_JOBS PROBE_QUEUED PROBE_REASON <<<"$line" || true
  [ "$PROBE_PROTOCOL" != - ] || PROBE_PROTOCOL=""
  [ "$PROBE_LIB" != - ] || PROBE_LIB=""
  case "$PROBE_HEALTH" in ok|degraded|down|missing|invalid) ;; *) return 1 ;; esac
  [[ "$PROBE_HEALTH_AGE" =~ ^(-1|[0-9]+)$ ]] || return 1
  case "$PROBE_VERDICT" in now|wait|never|unknown) ;; *) return 1 ;; esac
  [[ "$PROBE_SECS" =~ ^([0-9]+|-)$ ]] || return 1
  [[ "$PROBE_TOKENS" =~ ^([0-9]+/[0-9]+|-)$ ]] || return 1
  [[ "$PROBE_JOBS" =~ ^([0-9]+/[0-9]+|-)$ ]] || return 1
  [[ "$PROBE_QUEUED" =~ ^([0-9]+|-)$ ]] || return 1
  # A wait with no number is not a wait this client can compare with another.
  # A malformed seconds field, which only a drifted or older server sends, once
  # crashed the client's `-gt` test with a raw bash error the developer never
  # asked for. Every numeric field is therefore checked here, and a line that
  # fails is not a probe line: the caller skips that target and names it,
  # rather than read text as a number.
  if [ "$PROBE_VERDICT" = wait ] && [ "$PROBE_SECS" = - ]; then return 1; fi
  return 0
}

# ── the status reply ─────────────────────────────────────────────────────────
#
# The answer of the `status` verb, one record per line:
#
#   <protocol> <lib-sha256> <host-epoch>
#   host <health> <health-age> <held> <total> <jobs> <max-jobs> <queued> <load1> <cores> <mem-avail> <mem-total> [<health reason>...]
#   run <run-id> <owner> <slug> <tokens> <granted-epoch> <max-seconds> <median> <samples> <cpu-pct> <mem-bytes> <mem-max-bytes> <oom-kills> <state> [<stop reason>...]
#   ticket <position> <owner> <slug> <want> <min> <queued-epoch> <start-seconds>
#   end
#
# The host writes it with devbox_status_line and the laptop reads it with
# devbox_status_parse, and both take every field's shape from
# _devbox_status_shapes below. The probe line is the precedent: one copy of a
# format that both halves apply. Three copies of the version parse once let gc
# fall one field behind the other two clients.
#
# The first line carries the handshake, as the probe line does, and the client
# runs devbox_handshake_verdict on it before it reads any other line. A field
# the host could not read is `-`. A free-text field is the rest of its line,
# because a reason holds spaces. `end` is the last line: a reply without it was
# cut by a timeout or a dropped connection, and a view built from part of a
# reply would show a host with fewer gates than it runs.

# The shape of each word of one record kind, one extended regular expression
# per line, after the kind word. Every field except the owner, the state and
# the health may also be `-`. A trailing `+` line means the kind takes a
# free-text field after its words.
#
# `max` is a memory cap: cgroup v2 writes it into memory.max for a container
# with no limit, and that is a reading, not a field the host could not read.
_devbox_status_shapes() {
  local n='[0-9]+'
  case "${1-}" in
    head)   printf '%s\n' '[A-Za-z0-9._:+-]+' '[A-Za-z0-9._:+-]+' "$n" ;;
    host)   printf '%s\n' 'ok|degraded|down|missing|invalid' '-1|[0-9]+' "$n" "$n" "$n" "$n" "$n" \
              '[0-9]+(\.[0-9]+)?' "$n" "$n" "$n" '+' ;;
    run)    printf '%s\n' '[0-9]+\.([0-9]+|-)' 'me|other' '[A-Za-z0-9._-]+' "$n" "$n" "$n" "$n" "$n" \
              "$n" "$n" 'max|[0-9]+' "$n" 'running|stopping' '+' ;;
    ticket) printf '%s\n' "$n" 'me|other' '[A-Za-z0-9._-]+' "$n" "$n" "$n" "$n" ;;
    end)    ;;
    *)      return 1 ;;
  esac
}

# Is $2 a word of shape $1? `-` passes for every shape that admits it.
_devbox_status_word_ok() {
  local shape="$1" word="$2"
  if [ "$word" = - ]; then
    case "$shape" in 'ok|degraded|down|missing|invalid'|'me|other'|'running|stopping') return 1 ;; esac
    return 0
  fi
  [[ "$word" =~ ^($shape)$ ]]
}

# Print one record of the status reply. $1 is the kind (head, host, run,
# ticket, end), then its words in the order above, then, for host and run, an
# optional free-text field. Pure: a test drives it with no host.
#
# A word that does not have its field's shape is sent as `-`, never as found.
# Most of these values come out of files and out of docker, and a word with a
# space in it would shift every field after it on the laptop. The free text
# loses every character that is not printable, because the laptop prints it on
# a terminal, and is cut at 300 characters, as devbox-pool cuts a stop reason.
# A word count that does not fit the kind is this program's own bug: it prints
# nothing and returns 1, so the reply ends without `end` and the client says
# the answer was incomplete.
devbox_status_line() {
  local kind="${1-}" shape i free="" word record
  local -a shapes=()
  [ "$#" -gt 0 ] && shift
  mapfile -t shapes < <(_devbox_status_shapes "$kind") || true
  _devbox_status_shapes "$kind" >/dev/null || { echo "devbox_status_line: no record kind '$kind'" >&2; return 1; }
  if [ "${#shapes[@]}" -gt 0 ] && [ "${shapes[${#shapes[@]} - 1]}" = + ]; then
    free=1
    unset 'shapes[${#shapes[@]}-1]'
  fi
  if [ "$#" -ne "${#shapes[@]}" ] && { [ -z "$free" ] || [ "$#" -ne $(( ${#shapes[@]} + 1 )) ]; }; then
    echo "devbox_status_line: a $kind record takes ${#shapes[@]} words, and $# were given" >&2
    return 1
  fi
  if [ "$kind" = head ]; then record=""; else record="$kind"; fi
  for ((i = 0; i < ${#shapes[@]}; i++)); do
    word="${1-}"; shift
    shape="${shapes[i]}"
    _devbox_status_word_ok "$shape" "$word" || word=-
    # A word that must name a state and does not is the one place `-` is not
    # allowed. The safe value is sent in its place: an owner the host cannot
    # prove is not the caller's, and a health it cannot read is invalid.
    if [ "$word" = - ]; then
      case "$shape" in
        'me|other') word=other ;;
        'running|stopping') word=running ;;
        'ok|degraded|down|missing|invalid') word=invalid ;;
      esac
    fi
    record="${record:+$record }$word"
  done
  if [ -n "$free" ] && [ "$#" -gt 0 ]; then
    word="${1//[![:print:]]/}"
    word="${word:0:300}"
    # Leading and trailing spaces would not survive the parse's `read`, so
    # they are dropped here and the two sides agree on the text.
    word="${word#"${word%%[! ]*}"}"
    word="${word%"${word##*[! ]}"}"
    [ -z "$word" ] || record="$record $word"
  fi
  printf '%s\n' "$record"
}

# Read one status reply into the STATUS_ variables. Returns 0 for a complete
# reply, 2 for a reply with no `end` record, which a timeout or a dropped
# connection cuts, and 1 for a reply in which a record is not one of this
# format.
#
# STATUS_PROTOCOL and STATUS_LIB are set from the first line whatever the rest
# says, with `-` read back as empty, so the caller can run the handshake over
# them first. A host on another protocol may send other records, and the
# handshake, not this parser, names that repair. The cut reply is checked
# before any record is read: its last line may be half a record, and a half
# record is a cut, not a malformed one.
#
# Every other field keeps its `-`, so a caller tells a field the host could not
# read from one it read as 0.
#
#   STATUS_EPOCH, and STATUS_HEALTH, STATUS_HEALTH_AGE, STATUS_HELD,
#   STATUS_TOTAL, STATUS_JOBS, STATUS_MAX_JOBS, STATUS_QUEUED, STATUS_LOAD1,
#   STATUS_CORES, STATUS_MEM_AVAIL, STATUS_MEM_TOTAL, STATUS_HEALTH_REASON
#   STATUS_RUN_COUNT and the arrays STATUS_RUN_ID, STATUS_RUN_OWNER,
#   STATUS_RUN_SLUG, STATUS_RUN_TOKENS, STATUS_RUN_GRANTED, STATUS_RUN_MAX,
#   STATUS_RUN_MEDIAN, STATUS_RUN_SAMPLES, STATUS_RUN_CPU, STATUS_RUN_MEM,
#   STATUS_RUN_MEM_MAX, STATUS_RUN_OOM, STATUS_RUN_STATE, STATUS_RUN_REASON
#   STATUS_TICKET_COUNT and the arrays STATUS_TICKET_POS, STATUS_TICKET_OWNER,
#   STATUS_TICKET_SLUG, STATUS_TICKET_WANT, STATUS_TICKET_MIN,
#   STATUS_TICKET_QUEUED, STATUS_TICKET_START
# shellcheck disable=SC2034  # every STATUS_ variable is read by the caller
devbox_status_parse() {
  local reply="${1-}" line kind i last="" n_host=0 rest
  local -a lines=() shapes=() words=()
  STATUS_PROTOCOL=""; STATUS_LIB=""; STATUS_EPOCH=""
  STATUS_HEALTH=""; STATUS_HEALTH_AGE=""; STATUS_HELD=""; STATUS_TOTAL=""; STATUS_JOBS=""
  STATUS_MAX_JOBS=""; STATUS_QUEUED=""; STATUS_LOAD1=""; STATUS_CORES=""; STATUS_MEM_AVAIL=""
  STATUS_MEM_TOTAL=""; STATUS_HEALTH_REASON=""
  STATUS_RUN_COUNT=0; STATUS_RUN_ID=(); STATUS_RUN_OWNER=(); STATUS_RUN_SLUG=(); STATUS_RUN_TOKENS=()
  STATUS_RUN_GRANTED=(); STATUS_RUN_MAX=(); STATUS_RUN_MEDIAN=(); STATUS_RUN_SAMPLES=()
  STATUS_RUN_CPU=(); STATUS_RUN_MEM=(); STATUS_RUN_MEM_MAX=(); STATUS_RUN_OOM=()
  STATUS_RUN_STATE=(); STATUS_RUN_REASON=()
  STATUS_TICKET_COUNT=0; STATUS_TICKET_POS=(); STATUS_TICKET_OWNER=(); STATUS_TICKET_SLUG=()
  STATUS_TICKET_WANT=(); STATUS_TICKET_MIN=(); STATUS_TICKET_QUEUED=(); STATUS_TICKET_START=()
  [ -n "$reply" ] || return 2
  mapfile -t lines <<<"$reply"
  # A trailing newline is not a record.
  while [ "${#lines[@]}" -gt 0 ] && [ -z "${lines[${#lines[@]} - 1]}" ]; do
    unset 'lines[${#lines[@]}-1]'
  done
  read -r STATUS_PROTOCOL STATUS_LIB STATUS_EPOCH _ <<<"${lines[0]:-}" || true
  # These two reach the terminal through the handshake's refusal BEFORE any
  # shape check runs, and the free text below reaches it as the health and stop
  # reasons. Both come from a host, so a host that sends ESC bytes could
  # rewrite the developer's terminal. Only printable characters are kept.
  STATUS_PROTOCOL="${STATUS_PROTOCOL//[^[:print:]]/}"
  STATUS_LIB="${STATUS_LIB//[^[:print:]]/}"
  [ "$STATUS_PROTOCOL" != - ] || STATUS_PROTOCOL=""
  [ "$STATUS_LIB" != - ] || STATUS_LIB=""
  [ "${#lines[@]}" -ge 2 ] && last="${lines[${#lines[@]} - 1]}"
  [ "$last" = end ] || return 2
  # The head record, with the same shapes the builder applied.
  mapfile -t shapes < <(_devbox_status_shapes head)
  read -r -a words <<<"${lines[0]}"
  [ "${#words[@]}" -eq 3 ] || return 1
  for i in 0 1 2; do _devbox_status_word_ok "${shapes[i]}" "${words[i]}" || return 1; done
  for ((i = 1; i < ${#lines[@]} - 1; i++)); do
    line="${lines[i]}"
    kind="${line%% *}"
    case "$kind" in host|run|ticket) ;; *) return 1 ;; esac
    # Exactly one host record, and it comes first: a view needs it before any run.
    if [ "$kind" = host ]; then
      [ "$i" -eq 1 ] || return 1
      n_host=1
    fi
    mapfile -t shapes < <(_devbox_status_shapes "$kind")
    local nw="${#shapes[@]}" free=""
    if [ "${shapes[nw - 1]}" = + ]; then free=1; nw=$((nw - 1)); fi
    # The words are taken one at a time off the front, so the free text keeps
    # its own spacing. The builder writes one space between words.
    rest="${line#"$kind"}"
    words=()
    local j
    for ((j = 0; j < nw; j++)); do
      [ "${rest:0:1}" = " " ] || return 1
      rest="${rest:1}"
      words+=("${rest%% *}")
      rest="${rest#"${words[j]}"}"
      [ -n "${words[j]}" ] || return 1
      _devbox_status_word_ok "${shapes[j]}" "${words[j]}" || return 1
    done
    if [ -n "$rest" ]; then
      if [ -z "$free" ] || [ "${rest:0:1}" != " " ]; then return 1; fi
      rest="${rest:1}"
      rest="${rest//[^[:print:]]/}"
    fi
    case "$kind" in
      host)
        STATUS_HEALTH="${words[0]}"; STATUS_HEALTH_AGE="${words[1]}"; STATUS_HELD="${words[2]}"
        STATUS_TOTAL="${words[3]}"; STATUS_JOBS="${words[4]}"; STATUS_MAX_JOBS="${words[5]}"
        STATUS_QUEUED="${words[6]}"; STATUS_LOAD1="${words[7]}"; STATUS_CORES="${words[8]}"
        STATUS_MEM_AVAIL="${words[9]}"; STATUS_MEM_TOTAL="${words[10]}"; STATUS_HEALTH_REASON="$rest" ;;
      run)
        STATUS_RUN_ID+=("${words[0]}"); STATUS_RUN_OWNER+=("${words[1]}"); STATUS_RUN_SLUG+=("${words[2]}")
        STATUS_RUN_TOKENS+=("${words[3]}"); STATUS_RUN_GRANTED+=("${words[4]}"); STATUS_RUN_MAX+=("${words[5]}")
        STATUS_RUN_MEDIAN+=("${words[6]}"); STATUS_RUN_SAMPLES+=("${words[7]}"); STATUS_RUN_CPU+=("${words[8]}")
        STATUS_RUN_MEM+=("${words[9]}"); STATUS_RUN_MEM_MAX+=("${words[10]}"); STATUS_RUN_OOM+=("${words[11]}")
        STATUS_RUN_STATE+=("${words[12]}"); STATUS_RUN_REASON+=("$rest")
        STATUS_RUN_COUNT=$((STATUS_RUN_COUNT + 1)) ;;
      ticket)
        STATUS_TICKET_POS+=("${words[0]}"); STATUS_TICKET_OWNER+=("${words[1]}"); STATUS_TICKET_SLUG+=("${words[2]}")
        STATUS_TICKET_WANT+=("${words[3]}"); STATUS_TICKET_MIN+=("${words[4]}"); STATUS_TICKET_QUEUED+=("${words[5]}")
        STATUS_TICKET_START+=("${words[6]}")
        STATUS_TICKET_COUNT=$((STATUS_TICKET_COUNT + 1)) ;;
    esac
  done
  [ "$n_host" -eq 1 ] || return 1
  return 0
}
