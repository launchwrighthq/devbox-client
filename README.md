# devbox-client

devbox runs a project's verify gate on a remote machine. It syncs the checkout, runs the
project's own setup and gate commands there, and returns the gate's exit code. A laptop that
runs a full gate locally is unusable while the gate runs. devbox moves that load off the
laptop and keeps the exit code that `make verify` or `npm run verify` reads.

devbox runs the gate on one of several targets. A deployed target is a host that runs the
devbox server half all the time. A rented target is a host that the client rents per hour and
that deletes itself when it is idle: a RunPod pod or a Hetzner Cloud server. Before each run,
the client probes every deployed target in parallel and takes the target that ran this
worktree last when it can take the gate now. It prints one line for each target it skips.

This repository holds the client half only: the `devbox` command, the shared library, and the
runtimes that the client starts on a rented pod or server. The server half is not part of this
repository. A deployed target needs a host where an operator installed the devbox server half.
RunPod needs only a RunPod account. Hetzner needs a Hetzner project that holds a devbox
snapshot, which the operator of the server half builds.

The client is bash. It needs `bash`, `git`, `rsync`, `ssh` (OpenSSH 8.4 or later), `flock` and
`timeout` on the laptop. A rented target also needs `jq`, `curl` and `ssh-keygen`.
`devbox doctor` checks each one.

## Install

Pin an exact tag. `VERSION` holds the release version, and each release has a tag
`v<VERSION>`. The client and the server compare a protocol version before every run, so pin
the release that matches the server half you use.

**npm.** The command lands at `node_modules/.bin/devbox`.

```json
{
  "devDependencies": {
    "@launchwrighthq/devbox-client": "github:launchwrighthq/devbox-client#v3.2.0"
  }
}
```

**uv or pip.** The command lands at `.venv/bin/devbox`.

```toml
[dependency-groups]
dev = ["devbox-client @ git+https://github.com/launchwrighthq/devbox-client@v3.2.0"]
```

```sh
uv pip install "devbox-client @ git+https://github.com/launchwrighthq/devbox-client@v3.2.0"
```

**A vendored copy.** A project in neither ecosystem clones a tag into `vendor/devbox`. The
command is then `vendor/devbox/client/bin/devbox`. Remove `vendor/devbox/.git` if you commit
the copy. The sync never sends `/vendor/` to the remote machine.

```sh
git clone --depth 1 --branch v3.2.0 https://github.com/launchwrighthq/devbox-client vendor/devbox
```

Each executable finds `lib/devbox-lib.sh` through its real path, so a symlink to
`client/bin/devbox` from `~/.local/bin` also works.

A CI runner does not need the client. Put it in a dependency group that CI does not install.
Without a `.devbox.env`, `devbox verify` runs the gate locally, and CI never has that file.

## The gate guard

The guard finds the installed client first and `PATH` second. If it finds no client, it says
so and runs the local gate.

```make
DEVBOX := $(firstword $(wildcard .venv/bin/devbox) $(wildcard node_modules/.bin/devbox) \
                      $(wildcard vendor/devbox/client/bin/devbox) $(shell command -v devbox))
verify:
	@if [ -n "$(DEVBOX)" ]; then $(DEVBOX) verify; else \
	  echo "verify: no devbox client found, running the local gate." >&2; \
	  $(MAKE) verify-local; fi
```

Keep the message in the else branch. A failed install leaves no client. Without the message,
the local gate runs, passes, and nothing reports that the remote gate did not run.

**`DEVBOX_VERIFY` must call the project's local gate target, never this guard.** The guard
chooses between remote and local. A call to it from inside `DEVBOX_VERIFY` recurses.

## Configuration

Three files. The split decides who owns each value.

| File | Committed | Owner | Holds |
|---|---|---|---|
| `.devbox/config.env` | yes | the project | how to set up, how to verify, how much machine to ask for |
| `.devbox/exclude` | yes | the project | rsync patterns for files that must not reach the workspace |
| `.devbox.env` | no, add it to `.gitignore` | the developer | which targets, the gate password, what to rent, and how long to queue |

### `.devbox/config.env`

The file is data. devbox reads it line by line and never sources it. Each line is one
`KEY=value`, a `#` comment, or blank. devbox strips one pair of matching outer quotes and
expands nothing. An unknown key, a key set twice, or an unclosed quote stops the run and names
the file and line.

```sh
DEVBOX_PROJECT=my-app
DEVBOX_WANT_TOKENS=10
DEVBOX_MIN_TOKENS=3
DEVBOX_REQUIRES="jq=1.7 shellcheck"
DEVBOX_SETUP="npm ci"
DEVBOX_VERIFY="npm run verify:local"
```

| Key | Required | Holds |
|---|---|---|
| `DEVBOX_PROJECT` | yes | the directory name of this checkout on the remote machine; `A-Za-z0-9._+-` only, not all dots |
| `DEVBOX_WANT_TOKENS`, `DEVBOX_MIN_TOKENS` | yes | the vCPU count the gate asks for, and the count below which it waits |
| `DEVBOX_SETUP` | yes | the command that installs dependencies in the workspace |
| `DEVBOX_VERIFY` | yes | the command that is the gate |
| `DEVBOX_ENVIRONMENT` | no | a command that runs in the same shell before every other command |
| `DEVBOX_PROVISION` | no | a command that RunPod runs as root before setup |
| `DEVBOX_REQUIRES` | no | what the workspace image must carry |
| `DEVBOX_FORWARD_ENV` | no | names of variables that the gate receives from the laptop |
| `DEVBOX_NEEDS_POSTGRES`, `DEVBOX_DB_URL_VAR` | no | `1` for a per-worktree Postgres database, and the variable that receives its URL |
| `DEVBOX_RUNPOD_IMAGE` | no | the RunPod image; a value in `.devbox.env` wins |
| `DEVBOX_GATE_MAX_SECONDS` | no | the gate's wall-clock limit on a deployed target, counted from the moment the gate starts; default `7200`, at most `14400` |
| `DEVBOX_LANES` | no | how many workspaces this worktree may hold on each target, so that many of its runs can run there at once; default `2`, `1` to `4` |
| `DEVBOX_MAX_RESUMES` | no | how many times a stopped gate may resume from its ledger; default `1`, `0` to `9`, `0` turns resuming off |

Each command key becomes the body of a shell function. The function text goes to the
workspace on stdin, so no command becomes part of an ssh argument list. Put a command longer
than one line in a committed script, for example `DEVBOX_SETUP="bash .devbox/setup.sh"`.

`DEVBOX_LANES` sets how many runs of one worktree can run at once on one target. Each lane is a
full workspace with its own container, volumes, Postgres role and lock, so each one costs the
project disk and memory on every target. A run takes lane 1 when it is free, because lane 1 is
the warm one. `devbox gc` keeps every lane up to this count. A value outside 1 to 4 exits 2.

`DEVBOX_FORWARD_ENV` may not name a key of `.devbox.env`. A name such as
`DEVBOX_GATE_PASSWORD` is refused with exit 2, so the password never reaches a gate.

`DEVBOX_REQUIRES` takes three token forms, separated by spaces:

| Token | Satisfied when |
|---|---|
| `/absolute/path` | the path exists in the image |
| `name=version` | the output of `name --version` contains the version string |
| `name` | `command -v name` succeeds |

`devbox verify` checks these tokens before the sync. A target whose image does not satisfy
one is skipped, and the run exits 6 when no target satisfies it. This check stops a remote
gate that is weaker than the local gate. A project's first remote run reported green after a
set of its tests errored on an image that lacked a required system tool, and the skip count
changed with no warning.

### Resumable gates

A gate keeps a ledger of the steps and test files that finished. When the watchdog stops it
(exit 10), the memory cap kills it (exit 7) or the client dies before it returns, `devbox verify`
resumes it with only the units that had not passed, up to `DEVBOX_MAX_RESUMES` times. A gate that
returned a failure is not resumed. A ledger is valid only for the exact files the sync sends,
`.devbox/config.env`, the forwarded variables and the client version. `devbox verify --fresh`
ignores it.

A verify gate runs with `DEVBOX_LEDGER`, `DEVBOX_RESUME` (`0` or `1`) and `DEVBOX_LEDGER_TOOLS`,
the directory of three tools the client writes into the workspace:

- `"$DEVBOX_LEDGER_TOOLS/devbox-ledger" step <name> -- <command...>` records one step, and skips
  it on a resume when it passed;
- `vitest-ledger.mjs`, a vitest reporter with `passedFiles()` for `test.exclude`, both wired in the
  vitest config (vitest 3 refuses a `--reporter` file outside the project folder):

```js
const ledger = process.env.DEVBOX_LEDGER_TOOLS ? await import(`${process.env.DEVBOX_LEDGER_TOOLS}/vitest-ledger.mjs`) : null;
test: { exclude: [...configDefaults.exclude, ...(ledger ? ledger.passedFiles() : [])], reporters: ['default', ...(ledger ? [new ledger.default()] : [])] }
```

- `devbox_ledger.py`, a pytest plugin: `PYTHONPATH="$DEVBOX_LEDGER_TOOLS" pytest -p devbox_ledger`.

A verify gate that recorded nothing gets one warning line, and its exit code is unchanged.

### `.devbox.env`

The file is data, read by the same parser as `.devbox/config.env`, and never sourced. The
client unsets each of its keys before it reads the file and exports none of them, so a value
from an earlier shell never stands in for a missing line.

| Key | Holds |
|---|---|
| `DEVBOX_TARGETS` | the deployed targets, in order, separated by commas: lowercase letters and digits |
| `DEVBOX_TARGET_<NAME>` | one per listed target: its address, or `address:port`. The user is always `devbox-gate` |
| `DEVBOX_TARGET_<NAME>_HOSTKEY` | one per listed target: the pin, the SHA256 fingerprint of the host's ed25519 key as `ssh-keygen -lf` prints it, `SHA256:` and 43 characters |
| `DEVBOX_GATE_PASSWORD` | the one password of every deployed target |
| `DEVBOX_RENT` | the rented targets, in order: `runpod`, `hetzner`, or both. Empty by default |
| `DEVBOX_MAX_QUEUE_WAIT` | the longest queue wait in seconds; unset or `0` is no ceiling |
| `DEVBOX_QUEUE_FULL_ACTION` | `fail`, the default, exits 8; `local` runs the gate here when this machine satisfies `DEVBOX_REQUIRES` |
| `DEVBOX_AFFINITY_GRACE` | how long, in seconds, a run waits on the target that ran this worktree last before it joins the others; default `60`, `0` turns it off |
| `RUNPOD_KEY` | the RunPod account API key; read from this file only |
| `DEVBOX_RUNPOD_CPUS` | vCPUs for a new pod; default `16` |
| `DEVBOX_RUNPOD_IDLE_SECONDS` | idle time before the pod terminates itself; default `7200`, at most `28800` |
| `DEVBOX_RUNPOD_MAX_HOURLY` | the highest accepted price in USD per hour; default `1` |
| `DEVBOX_RUNPOD_REGIONS` | an optional comma-separated list of data centers |
| `HCLOUD_TOKEN`, `DEVBOX_HETZNER_*` | the Hetzner project token and the server settings; see below |

A listed target without its `DEVBOX_TARGET_<NAME>` line or its `DEVBOX_TARGET_<NAME>_HOSTKEY`
line is refused, and so is a pin that is not `SHA256:` and 43 characters, and either line for a
target that the list does not name. `runpod`, `hetzner` and `local` are
not deployed target names. A file with neither `DEVBOX_TARGETS` nor `DEVBOX_RENT` runs the
gate locally, as a missing file does.

`DEVBOX_QUEUE_FULL_ACTION=local` never runs a gate here when the project sets
`DEVBOX_NEEDS_POSTGRES=1`. Only the remote machine provisions that database. A local run
without it skipped its database tests and still exited 0.

Give `.devbox.env` mode 0600, because it holds the gate password. A worktree uses its own file
when one exists, and otherwise the file of the main checkout.

This example names two deployed targets in order: one on a LAN, one on the internet with sshd
on port 2222.

```sh
# Targets
DEVBOX_TARGETS=lan1,cloud1
DEVBOX_TARGET_LAN1=192.0.2.10
DEVBOX_TARGET_LAN1_HOSTKEY=SHA256:<from the operator>
DEVBOX_TARGET_CLOUD1=203.0.113.20:2222
DEVBOX_TARGET_CLOUD1_HOSTKEY=SHA256:<from the operator>
DEVBOX_GATE_PASSWORD=

# Rented
DEVBOX_RENT=

# Queue
DEVBOX_MAX_QUEUE_WAIT=600
DEVBOX_QUEUE_FULL_ACTION=fail
DEVBOX_AFFINITY_GRACE=60
```

The operator of the hosts gives each developer the addresses, the pins and the gate password.
The operator's deploy prints the address line and the pin line of each target, ready to paste.

### Choosing a target

`devbox verify` sends every deployed target one `probe`, in parallel, with a 3-second connect
timeout. The answer carries the protocol and library fingerprint, the watchdog's health record
and its age, and the pool's queue estimate.

A target is eligible when it is reachable, healthy, passes the handshake and
`DEVBOX_REQUIRES`, and its queue estimate is not `never`. It need not fit now, and an estimate
over `DEVBOX_MAX_QUEUE_WAIT` is joined too, because that queue may still grant first. **A run
waits in the queue of every eligible target and runs on the first that grants.** On each one it
first takes a free lane of this worktree, then a place in the queue. At the first grant every
other place is given up at once, and the sync, the setup and the gate run on the granted
target, under that grant. The client takes the first rule that matches:

1. The target that ran this worktree last, when it is eligible and fits now, or estimates at
   most `DEVBOX_AFFINITY_GRACE` seconds of queuing. Its workspace is warm, so the run waits on it
   alone first, and joins every other eligible target after the grace.
2. The first target in `DEVBOX_TARGETS` order that fits now. The run joins every eligible target.
3. Any other eligible target. The run joins every eligible target.
4. The first rented target in `DEVBOX_RENT`.
5. This machine, when `DEVBOX_QUEUE_FULL_ACTION=local`.
6. Otherwise exit 8, with one line per target that says why.

```
==> devbox: lan1 unreachable (no answer in 3s)
==> devbox: cloud1 skipped: degraded (disk 93%)
==> devbox: queuing on cloud2: 30/32 tokens, 3/3 jobs, 1 waiting: about 240s of queuing
==> devbox: queuing on cloud3: 4/16 tokens, 1/3 jobs, 0 waiting: this ask fits now
==> devbox: granted 12 tokens on cloud3 lane 1 after 2s (also queued on cloud2)
```

`DEVBOX_MAX_QUEUE_WAIT` counts from the first place in a queue, the grace included. When it runs
out with no grant, rules 4 to 6 apply. A run that gets no free lane on any eligible target
within `DEVBOX_LOCK_WAIT` (3600 seconds, from the environment) exits 4.

A target is healthy when its watchdog record says `ok` and is at most 90 seconds old. A
handshake mismatch, or an image that does not satisfy `DEVBOX_REQUIRES`, skips one target. On
every target, it exits 5 or 6. A refused gate password on every target exits 3. An unreachable
target is remembered for 60 seconds, so back-to-back runs off a LAN do not each wait for a
LAN-only target.

A host grants a job when its free memory, less a reserve, covers a fixed headroom
(`DEVBOX_MEMORY_HEADROOM`, set by the host's operator). From the grant to the release the
workspace may use at most its granted tokens in cores, so a gate that needs more cores asks for
more tokens in `DEVBOX_WANT_TOKENS`. Above a soft memory limit, 90 % of the workspace's cap, the
host slows the workspace and pages it to swap instead of killing a process. The cap itself still
ends a gate that grows without end, which exits 7.

`--target <name>` forces one target: a name from `DEVBOX_TARGETS`, `runpod` or `hetzner`. The
probe and its checks still apply to a deployed target, and the run waits on that target alone,
with no grace.

### The gate password

A client reaches a deployed target as the account `devbox-gate`, with
`DEVBOX_GATE_PASSWORD`, and with no ssh key and no `~/.ssh/config` entry. That account runs
devbox gate commands and nothing else: it has no shell, and each call is one verb that the host
checks word by word. The password reaches ssh through `SSH_ASKPASS`, never through a command
argument.

Each run shares one ssh connection per target, and the gate itself takes one more, so a run
authenticates twice on the target it chooses. Both close when the run ends.

The password goes only to a host whose ed25519 key is its pin, `DEVBOX_TARGET_<NAME>_HOSTKEY`.
Before the first contact with a host, the client runs `ssh-keyscan` and records the key in
`~/.config/devbox/known_hosts` only when its fingerprint is the pin. Every run checks the
recorded key against the pin again. A key that is not the pin stops the run before any password
is sent, and exits 3: the message names the target and both fingerprints. It means a
reinstalled host, or a man in the middle on this network. Ask the operator before you change a
pin.

### RunPod

With `DEVBOX_RENT=runpod`, a run rents a CPU pod when no deployed target can take the gate.
`devbox verify --target runpod` rents one at once. Later runs reuse it. The pod terminates
itself after `DEVBOX_RUNPOD_IDLE_SECONDS` with no activity. A running test counts as activity.

```
devbox runpod up        rent or reuse the pod, and run no gate
devbox runpod status    compare the saved record with the provider
devbox runpod down      delete the pod now
```

The account key never enters a command argument, a log or the pod. Use a Debian-family image
with bash, curl and apt. With `DEVBOX_NEEDS_POSTGRES=1`, the pod gets pgvector Postgres 16 on
127.0.0.1:5435 and the URL in `DEVBOX_DB_URL_VAR`. Output and reports go to
`.build/devbox/runpod/`. A command can write reports into `$DEVBOX_RESULTS`, and devbox
downloads them even when the command fails.

### Hetzner

A Hetzner Cloud server is the second rented target. The client creates it from the newest
snapshot labelled `devbox=workspace` in the token's project. That snapshot is a deployed
devbox server, built by the operator of the server half. The client reaches the server as
`devbox-gate`, with a gate password and a host key that it makes for that server alone. The
server deletes itself after `DEVBOX_HETZNER_IDLE_SECONDS` with no gate.

```sh
DEVBOX_RENT=hetzner
HCLOUD_TOKEN=
DEVBOX_HETZNER_SERVER_TYPE=cx43,ccx33,ccx43
DEVBOX_HETZNER_LOCATION=nbg1
DEVBOX_HETZNER_IDLE_SECONDS=7200
```

| Key | Holds |
|---|---|
| `DEVBOX_RENT` | `hetzner` rents a server when no deployed target can take the gate |
| `HCLOUD_TOKEN` | a Read & Write API token of the Hetzner project; read from this file only |
| `DEVBOX_HETZNER_SERVER_TYPE` | the server types, comma-separated and tried in order; default `cx43,ccx33,ccx43`, not measured yet. A type with no capacity in the location (HTTP 412 `resource_unavailable`) passes to the next, and a type whose disk is smaller than the snapshot's is skipped |
| `DEVBOX_HETZNER_LOCATION` | the location; default `nbg1` |
| `DEVBOX_HETZNER_IDLE_SECONDS` | idle time before the server deletes itself; default `7200`, at most `28800` |

**Use a Hetzner project for devbox alone.** Hetzner has no token scoped to one server, so
each rented server holds the project token to delete itself. A project token can delete
every server of its project. In a project that holds only devbox servers and snapshots, a
leaked token can delete only devbox.

```
devbox hetzner up       create or reuse the server, wait until it takes a gate, run no gate
devbox hetzner status   compare the saved record with the API
devbox hetzner down     delete the server now, and confirm it is gone
```

`devbox verify --target hetzner` uses the server at once. The token reaches curl in a header
file and never in a command argument. The exit codes are 1 when an API call failed, 2 for a
wrong setting or a project with no snapshot, 3 when the server did not become ready in 10
minutes, and 4 when another run of this worktree held the creation for 15 minutes. Under
`DEVBOX_STRICT=1` these are 65, 66, 67 and 68.

## Commands

| Command | What it does |
|---|---|
| `devbox verify` | Waits in the queue of every eligible target, holding a free lane of this worktree on each, and on the first that grants syncs the worktree, runs `DEVBOX_SETUP` and `DEVBOX_VERIFY` there, and returns the gate's exit code. |
| `devbox verify --target <name>` | The same, on one target: a name from `DEVBOX_TARGETS`, `runpod` or `hetzner`. |
| `devbox verify --local` | Runs the local gate and opens no connection. |
| `devbox run [--target <name>] -- <command>` | Runs one command in the remote workspace after setup. It never runs locally. |
| `devbox runpod up\|status\|down` | Manages this checkout's RunPod pod. |
| `devbox hetzner up\|status\|down` | Manages this checkout's Hetzner server. |
| `devbox compare [--target <name>]` | Runs both gates and compares the passed, failed and skipped counts. |
| `devbox gc [--dry-run] [--yes] <root>...` | Removes remote workspaces whose local worktree is gone, on every target in `DEVBOX_TARGETS`, and every lane above a worktree's `DEVBOX_LANES`. Run `--dry-run` first. |
| `devbox doctor` | Checks every prerequisite and every target, and names each one that fails. |
| `devbox status [--target <name>]` | Shows the runs this laptop started and the phase each is in (probe, rent, lock, queued, sync, setup, gate), then each target in `DEVBOX_TARGETS`: its health and pool, every gate it runs or queues, which are this laptop's, and how long each has run and has left, then each RunPod pod and Hetzner server and what it has cost so far. It changes nothing. |
| `devbox requires-local <token>...` | Checks this machine against `DEVBOX_REQUIRES` tokens. |
| `devbox ssh-install --host <host>` | Writes a `Host` block in `~/.ssh/config` for an operator's root access. A client does not need it. `--print` writes it to stdout, and `--remove` deletes it. |
| `devbox version` | Prints the release version and the protocol version. |

`devbox server install` needs the devbox server half, which this repository does not
carry. Here the command exits 1 and says so.

`devbox gc` removes a container, its volume, its Postgres role and every database that role
owns. It reads the live worktree roots as a keep-list. It refuses an empty keep-list, and it
deletes nothing without `--yes`. A target that does not answer is printed as "not collected",
and the run exits 3.

## devbox doctor

Run `devbox doctor` first when anything is wrong. It changes nothing. It prints one `ok`,
`FAIL` or `skip` line per check, runs every check that can run, and exits 1 when a check
fails.

It checks the checkout, `.devbox/config.env`, `.devbox/exclude`, `.devbox.env`, the tools on
this laptop and the OpenSSH version. Then it prints one block per target: reachable, gate
password accepted, the host key pin and whether the recorded key matches it, the protocol
handshake, the watchdog's
health, the token pool, the CPU limit, the soft memory limit and the swap of the host, the
memory budget per worker, and each `DEVBOX_REQUIRES` token. The three host limits are `ok`, or
`skip` with the host's reason, and never `ok` for a limit the host cannot set. When
ssh fails, it names the cause: DNS, the network, a refused gate password or a host key that is
not its pin.

## devbox status

`devbox status` asks every target one `status` verb, in parallel. It prints one line per
target in `DEVBOX_TARGETS` order: health, then a bar each for reserved tokens, busy cores
against the core count and memory in use, then jobs, and swap while the host uses it. Then one table
lists every gate that runs, then the queue in line order, then the runs this laptop started
that no target holds yet (probe, rent, lock, sync, setup), then the lost ones. `lock` is the
wait for a free lane. A run that waits in several queues is one row, and its target cell names
each of those targets, joined by `+`. A run is lost when every target it names answered
without it for over a minute. A gate of this laptop shows as `<repository>/<worktree>`, and `▶` with a
bold name marks the gates of the repository you run the command in. A gate of another
laptop shows dim as `other laptop`, with no name. Every duration of a gate uses the host's
clock.

A target that cannot be read keeps its place, with one line that says why: unreachable, no
answer, a refused gate password, a changed host key, `deploy is due`, or an incomplete
answer. Colour shows only on a terminal, and never with `NO_COLOR` set or `TERM=dumb`.

It exits 0 when every target answered, 2 for a usage or configuration error, 3 when a target
did not answer or refused the gate password, and 5 when a target needs a deploy. With
several failures, the first in target order, then the providers, decides. Exit 1 means a
provider API call failed.

After the targets come the rentals. The RunPod block lists the pod of every worktree that a
record and RunPod agree on, with its idle countdown, each devbox pod no record knows
(`not recorded`), each record whose pod is gone, and a sum row. The rented Hetzner server of
this worktree has a target line while the API says it runs, and its gates are in the table.
The Hetzner block has one row per server. Every cost is the hourly price times the time up, and says `about`: RunPod in USD,
Hetzner in EUR, the price recorded when the server was created. A provider
that `DEVBOX_RENT` names with no key says `no key in .devbox.env, not checked`. Status never
deletes a rental and never changes a record.

`devbox status --watch [--interval <seconds>]` redraws the view in place every 3 seconds
(at least 2) until you press `q` or Ctrl-C, both exit 0. It sends the gate password once per
target for the whole watch, never stacks a second call on a target that has not answered,
and asks an unreachable target again every 30 seconds. A target line older than two
intervals ends with `(as of HH:MM:SS)`. It needs a terminal that can move its cursor.

`status` is a gate verb of protocol 7. Every target is deployed before a project moves its
pin to a client on protocol 7.

## The version handshake

`lib/devbox-lib.sh` sets `DEVBOX_PROTOCOL_VERSION`. Before every run, the client compares that
integer and the sha256 of its library with the values each target reports in its probe. A
difference skips that target, and exits 5 when it holds for every target. The message names
both sides and the fix. The library decides workspace names and Postgres role names, so two
copies that differ can put two checkouts on one Postgres role.

The protocol version is not the release version. The protocol version changes only when the
library or a gate verb changes.

## Exit codes

`devbox verify` returns the gate's own exit code. devbox uses these codes for itself:

| Code | Meaning |
|---|---|
| 1 | an internal failure before the gate |
| 2 | a configuration or usage error |
| 3 | no target answered, or every target refused the gate password or showed a host key that is not its pin |
| 4 | no lane of this worktree was free on any eligible target within `DEVBOX_LOCK_WAIT`: other runs of it hold every lane |
| 5 | the protocol handshake refused, on every deployed target |
| 6 | no target's workspace image satisfies `DEVBOX_REQUIRES` |
| 7 | the workspace memory limit killed the gate |
| 8 | no target can take this gate, or `DEVBOX_MAX_QUEUE_WAIT` ran out with no grant; the gate did not run |
| 9 | a Git LFS file is a pointer; run `git lfs pull` |
| 10 | the watchdog on the target stopped the gate: past `DEVBOX_GATE_MAX_SECONDS`, or no CPU used for too long. This is not a test result |
| 11 | the pool on the target lost the gate's queue ticket and could not restore it; the gate did not run |
| 12 | the pool released the grant because the sync and the setup took longer than the host's `DEVBOX_HOLD_PREP_SECONDS`; the gate did not run. This is not a test result. A cold lane is the usual cause, and the next run there is warm |
| 75 | the pool on the host stopped waiting and ran nothing |

A caller that must know whether the remote gate ran sets `DEVBOX_STRICT=1` in the environment.
Then devbox never falls back to a local gate, the environment wins over `.devbox.env`, and
devbox's own codes move to 64 to 79:

| Strict code | Code without strict | Name |
|---|---|---|
| 64 | a local run | `local-fallback` |
| 65 | 1 | `internal` |
| 66 | 2 | `config` |
| 67 | 3 | `unreachable`: no target answered |
| 68 | 4 | `locked` |
| 69 | 5 | `handshake` |
| 70 | 6 | `requires` |
| 71 | 7 | `oom` |
| 72 | 8 | `no-target` |
| 73 | 9 | `lfs` |
| 74 | 75 | `pool-deadline` |
| 75 | 3 | `auth`: every target refused the gate password, or showed a host key that is not its pin |
| 76 | 10 | `watchdog` |
| 77 | 11 | `pool-ticket` |
| 78 | 12 | `prep-limit` |

An OOM kill, a queue timeout, a watchdog stop, a lost ticket, a prep limit or a pool deadline
also prints one `::devbox-infra::<name>` line on stderr.

## Tests

```sh
bash tests/run-tests.sh
```

The tests use stubs for ssh and the remote host. They open no network connection.

## License

MIT. See `LICENSE`.
