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
    "@launchwrighthq/devbox-client": "github:launchwrighthq/devbox-client#v4.7.0"
  }
}
```

**uv or pip.** The command lands at `.venv/bin/devbox`.

```toml
[dependency-groups]
dev = ["devbox-client @ git+https://github.com/launchwrighthq/devbox-client@v4.7.0"]
```

```sh
uv pip install "devbox-client @ git+https://github.com/launchwrighthq/devbox-client@v4.7.0"
```

**A vendored copy.** A project in neither ecosystem clones a tag into `vendor/devbox`. The
command is then `vendor/devbox/client/bin/devbox`. Remove `vendor/devbox/.git` if you commit
the copy. The sync never sends `vendor/devbox/` to the remote machine.

```sh
git clone --depth 1 --branch v4.7.0 https://github.com/launchwrighthq/devbox-client vendor/devbox
```

Each executable finds `lib/devbox-lib.sh` through its real path, so a symlink to
`client/bin/devbox` from `~/.local/bin` also works.

A worktree keeps the client it installed until its dependencies are installed again. So
`devbox verify` and `devbox run` read the version the checkout pins: the
`@launchwrighthq/devbox-client` entry of the root `package.json` (`#vX.Y.Z`, a
`refs/tags/vX.Y.Z` URL or a plain `X.Y.Z`), or else the `devbox-client` requirement of
`pyproject.toml` (`@vX.Y.Z` or `==X.Y.Z`). When the running client is older, they print one
line before the target choice and go on:

```
==> devbox: this worktree runs devbox-client 3.0.0, and the checkout pins 3.3.1; install the dependencies again
```

A pin they cannot read prints nothing. The line never stops a run.

**CI.** This repository serves a reusable workflow that installs the client from the same
pin, the toolchain and the dependencies, caches the setup, and runs one job per step of
`.devbox/steps`. A project's CI is one job:

```yaml
jobs:
  gate:
    uses: launchwrighthq/devbox-client/.github/workflows/gate.yml@v4
    secrets: inherit
```

`v4` is a branch that each 4.x release moves. The workflow names no client version: it
installs the one `package.json` or `pyproject.toml` pins, and fails when that pin's major is
not 4. Its inputs are `client-from`, `prepare`, `runs-on`, `runners`, `skip-steps` and
`timeout-minutes`; `.github/workflows/gate.yml` describes each. Without a `.devbox.env`,
`devbox verify` runs the gate locally, and CI never has that file.

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

**A step's command must call the project's local gate target, never this guard.** The guard
chooses between remote and local. A call to it from inside a step recurses.

## Configuration

Four files. The split decides who owns each value.

| File | Committed | Owner | Holds |
|---|---|---|---|
| `.devbox/config.env` | yes | the project | how to set up, which services, how much machine to ask for |
| `.devbox/steps` | yes | the project | the steps of the gate, their order, their runners and folders |
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
```

The gate itself is `.devbox/steps` beside this file. A `.devbox/config.env` with no
`.devbox/steps` beside it exits 2.

| Key | Required | Holds |
|---|---|---|
| `DEVBOX_PROJECT` | yes | the directory name of this checkout on the remote machine; `A-Za-z0-9._+-` only, not all dots |
| `DEVBOX_WANT_TOKENS`, `DEVBOX_MIN_TOKENS` | yes | the vCPU count the gate asks for, and the count below which it waits; on a host that admits on pressure, the cap of the worker hint, and a floor checked against the host's core count |
| `DEVBOX_SETUP` | yes | the command that installs dependencies in the workspace |
| `DEVBOX_RERUN` | no | `changed`, the default, carries unchanged steps and narrows or selects tests; `full` runs every step in full; the environment wins over the file |
| `DEVBOX_SETUP_INPUTS` | no | files, such as lock files, whose content decides whether `DEVBOX_SETUP` runs again |
| `DEVBOX_SHARED_INPUTS` | no | files every step reads; a change to one runs every step |
| `DEVBOX_LOCAL_GATE` | no | with no `.devbox.env`: `ci` (the default since 4.0) runs the gate on this machine only with `CI` set or `--local`, `always` runs it here, `never` exits 2 |
| `DEVBOX_ENVIRONMENT` | no | a command that runs in the same shell before every other command |
| `DEVBOX_PROVISION` | no | a command that RunPod runs as root before setup |
| `DEVBOX_REQUIRES` | no | what the workspace image must carry |
| `DEVBOX_FORWARD_ENV` | no | names of variables that the gate receives from the laptop |
| `DEVBOX_SERVICES` | no | some of `postgres redis rabbitmq minio`, separated by spaces; see "Services" |
| `DEVBOX_SERVICE_ENV` | no | `<name>=<VARIABLE>` pairs: the variable a service's value is exported under |
| `DEVBOX_WORKER_MEMORY` | no | the memory one test worker needs, `1536M` by default; it caps the worker count |
| `DEVBOX_STEP_MEMORY` | no | the memory a step without a runner reserves while it runs, `2G` by default |
| `DEVBOX_RUNPOD_IMAGE` | no | the RunPod image; a value in `.devbox.env` wins |
| `DEVBOX_GATE_MAX_SECONDS` | no | the gate's wall-clock limit on a deployed target, counted from the moment the gate starts; default `7200`, at most `14400` |
| `DEVBOX_LANES` | no | how many workspaces this worktree may hold on each target, so that many of its runs can run there at once; default `2`, `1` to `4` |
| `DEVBOX_MAX_RESUMES` | no | how many times a stopped gate may resume from its ledger; default `1`, `0` to `9`, `0` turns resuming off |

Refused in 4.0, each with exit 2 and one line that names the file, the line and what to write
instead. `.devbox.env` refuses `DEVBOX_VERIFY` with the same line.

| Refused | Write instead |
|---|---|
| `DEVBOX_VERIFY=<command>` | the line `verify -- <command>` in `.devbox/steps`, the one step the key ran |
| `DEVBOX_NEEDS_POSTGRES=1` | `DEVBOX_SERVICES=postgres` |
| `DEVBOX_DB_URL_VAR=<VARIABLE>` | `DEVBOX_SERVICE_ENV=postgres=<VARIABLE>`, or nothing for `DATABASE_URL` |
| `select=related` on a line of `.devbox/steps` | nothing: remove it, because every runner step selects its test files by what they read |

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

### `.devbox/steps`

`devbox verify` runs the steps of `.devbox/steps`, and a project without the file exits 2. One
step per line, `#` for a comment; the words
before ` -- ` are the name and its attributes, and the words after it are the command:

```
<name> [each=<dir>/] [after=<step>,<step>] [runner=vitest|pytest] [narrow=failed]
       [dir=<dir>/] [shards=<n>] [requires=<token>,<token>] [inputs=<path>,<path>]
       [memory=<size>] [rerun=always] -- <command>
```

| Attribute | Meaning |
|---|---|
| `each=apps/*/` | one step per matching directory; `{dir}` and `{name}` are replaced in the name, `inputs`, `after`, `dir` and the command |
| `after=a,b` | start once those steps ended, passed or not; steps that run at once share the grant, so `after=` is never needed for CPU |
| `runner=vitest\|pytest` | the client adds the ledger plug-in, the worker option and the test files to run on the command line |
| `narrow=failed` | after a failure of named test files with code 1, run only those and the changed test files, when the step cannot select |
| `dir=service/` | run the command in that folder of the checkout; test files reach the runner relative to it and the record from the root |
| `shards=4` | the number of CI jobs `devbox ci matrix` gives this runner step |
| `requires=tok,tok` | `DEVBOX_REQUIRES` tokens that only this step needs; a run asks the targets for the tokens of the steps it runs |
| `inputs=src/,tests/` | an override of what the step reads; a step without a runner that sets it is never traced |
| `memory=4G` | the memory of one worker of a runner step, or what a step without a runner reserves while it runs |
| `rerun=always` | always run in full |

`select=related` exits 2 since release 4.0, by its line: every runner step selects its test
files by what they read, so remove it.

```
# .devbox/steps
typecheck   -- npm run typecheck
lint        -- npm run lint
test        runner=vitest narrow=failed shards=4 -- npx vitest run
service     runner=pytest narrow=failed dir=service/ -- uv run pytest
```

A step whose key passed in a complete record carries and does not run. The key is the client
version, `.devbox/config.env`, the step's line, the forwarded variables,
`DEVBOX_SHARED_INPUTS` and the content of the step's inputs. When every step carries,
`devbox verify` prints green and asks no host. A broken line exits 2 before any target is
asked. The last line of a run is `devbox: green (...)` or `devbox: red (...)`, and the exit
code is the code of the first failed step in plan order. A gate whose record does not carry ends
in `devbox: incomplete (run <run-id> does not carry: <reason>)`, such as `files changed while it
ran` or `stopped by SIGTERM`. A step that passed while a test file of it failed makes the verdict
red, and `devbox verify` exits 1.

**What a step reads.** A step without `inputs=` learns its inputs from `strace -f`. The runner
traces it when it has no valid trace, when its line, `.devbox/config.env` or the client's trace
format changed since its trace, and on `--full`, and runs it untraced in between, because the trace
made a type check and a lint run several times as long. The key then covers the content of the
files the trace read, the names of the entries directly in each directory it listed, and the
lock files when it read under `node_modules/` or `.venv/`, so an edit to a file the step only
listed carries it. With no usable trace, the key covers every synced file. A host
without `strace` runs the step untraced, and `devbox verify --plan` says `no trace: <reason>`.

**Learned selection.** A runner step is traced on every run, inside the runner: the vitest
reporter and a hook in every vitest worker record what each test file opens, lists or imports,
also through a cached module. When the step's key changed, it runs only the test files that
can see the change: `changed`, `failed`, `new`, `no trace`, `partial` or `read <path>`. No such
file carries the step with `no test read a changed file`. A missing map runs the step in full.

**One map per context.** A step keeps one map per context, at
`<git common dir>/devbox/maps/<step>.<context>.map`, and its 8 newest. A runner step's context
is the config, its line, the forwarded values and the lock files; a step with no runner's is the
config and its line. Neither holds the client version, so worktrees on other client versions or
other lock files keep their own maps and never reset each other's passes. A lock file edit
starts a new map for a runner step only. An older client's `<step>.map` is never read or
changed.

A `worker_threads` Worker, or a `node` child, that a test starts directly records its reads for
that test file. A test file is partial, because its trace may miss reads, when:

- it starts a Worker with `eval: true` or `env: SHARE_ENV`, or a Worker or child whose
  environment drops `NODE_OPTIONS`;
- it starts node under a shell, or through `npx` or `npm exec`;
- it starts another program, such as `bash` or `git`, that may read repository files;
- under vitest's `isolate: false`, it may reach a live Worker that an earlier test file started.

A partial file runs whenever an input of its step changed. Its reads still count among the
step's inputs, so an edit no test of the step read carries the step. `sh -c` of one plain
command marks nothing partial.

**Workers.** Every step gets `DEVBOX_WORKERS=<n>`. A vitest step gets `--maxWorkers=<n>`, plus `--minWorkers=1` on vitest 2 and 3, and a
pytest step `-n <n>` when pytest-xdist loads. `<n>` is the grant (`DEVBOX_TOKENS`, or the
cores of `nproc` on a laptop) divided by the runner steps running at that moment, capped by the
workspace memory less 4 GiB divided by the same runner steps and by `DEVBOX_WORKER_MEMORY`, and
by the step's file count. A
command that sets `--maxWorkers`, `--pool-options`, `-n` or `--numprocesses` keeps its value.
At most as many runner steps as the grant has tokens run at once. The steps that run at once
also share the workspace memory less 4 GiB: a runner step reserves its workers times their
memory, any other step its `memory=`, else `DEVBOX_STEP_MEMORY`, else 2G. A step starts only
while its reservation fits, the ready runner steps start before the steps without a runner, a
runner step first shrinks its workers to fit, and one line says
`<n> steps wait for memory` the first time a step waits. When no step runs, the next one starts
whatever its size. A runner step that starts below its fair share runs its files in waves, each
with the workers that fit when it starts, so it grows once the memory frees. The client never passes `--exclude`: a resumed or selected step gets the files it must
run, each under its `dir=` and a test file of its runner.

Every gate writes a record under `<git common dir>/devbox/records/`. It gives each test file to
the step whose plan names it, else to the step whose `dir=` is the closest folder above it, a
step without `dir=` counting as the checkout root. `devbox result` prints the newest;
`--failed-steps`, `--failed-files` and `--json` give a landing tool what it needs, and
`devbox probe <rev>` runs the failed test files at another revision. A new `devbox verify`
cancels the older gate of the same worktree, which exits 14; `devbox cancel` does the same by
hand. A gate stopped by any other SIGTERM exits 143. With `DEVBOX_SETUP_INPUTS`, the workspace
skips the setup when the setup text and those files did not change since the last setup that
passed there. When the setup runs, its first line names why, such as each input that changed.
Name a setup script in `DEVBOX_SETUP_INPUTS` when a change to it must run the setup. A seed
copies `/home/dev` alone, so put system packages in the image, not in the setup.

**CI.** `devbox ci matrix` prints `{"include":[{"step":"lint","shard":"1/1"},...]}` from
`.devbox/steps`, one entry per step and shard. A job runs
`devbox verify --local --step <step> --shard <i>/<n>`, which splits the step's test files by
the seconds the records give each file. `--local` starts the declared services in docker.

### Services

`DEVBOX_SERVICES` in `.devbox/config.env` names what the gate needs. The client starts or
reaches each one before the first step of every gate, waits at most 60 s for its answer, and
exports its value:

| Service | Per run | Exported as, by default |
|---|---|---|
| `postgres` | this worktree's own role and database on the host's server | `DATABASE_URL` |
| `redis` | the workspace's own server | `REDIS_URL` |
| `rabbitmq` | a vhost `devbox-run-<run id>` on the host's broker | `AMQP_URL` |
| `minio` | a fresh server with random keys and a bucket `devbox-run-<run id>` | `S3_ENDPOINT_URL`, `S3_BUCKET`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` |

`DEVBOX_SERVICE_ENV="postgres=TEST_DATABASE_URL"` renames a value. The names are `postgres`,
`redis`, `rabbitmq`, `minio`, `minio-bucket`, `minio-access-key` and `minio-secret-key`. A
service that does not answer ends the gate with exit 3 and `devbox verify: service <name> did
not answer in 60 s`. The vhost and the bucket go when the gate ends. `--local` and CI start
the services in docker, and exit 2 when docker is absent.

A new workspace on a deployed target is seeded before its first sync: the host copies an idle
workspace of the same owner and project on that host, so the sync sends only the difference and
the setup can be skipped. The run prints one line, `==> seed: warm`,
`==> seed: copied <source-slug> <MiB> <seconds>` or `==> seed: cold <reason>`, and
`==> seed: skipped, <target> predates seed` from a host older than the verb. No outcome fails
the gate. A seed never copies the workspace's Postgres password, the contents of `.ssh` or the
ledger of a resumable gate.

### Resumable gates

A gate keeps a ledger of the steps and test files that finished. When the watchdog stops it
(exit 10), the memory cap kills it (exit 7) or the client dies before it returns, `devbox verify`
resumes it with only the units that had not passed, up to `DEVBOX_MAX_RESUMES` times. A resume
reruns every test file that failed or was still running in its own ledger, never what another
branch's record says. A gate that returned a failure is not resumed. A ledger is valid only for the exact files the sync sends,
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

A project with `.devbox/steps` wires none of the three: the runner records each step, adds the
plug-in of a `runner=` step, and gives a resumed step the files still to run. The same directory
holds `devbox-trace-hook.mjs`, the vitest worker hook the runner loads for learned selection.

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
| `DEVBOX_REJOIN_SECONDS` | how often, in seconds, a run with no grant probes again each target it skipped as unreachable or unhealthy; default `30`, `0` turns it off |
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
gate locally. A missing file runs it locally only as `DEVBOX_LOCAL_GATE` allows, by default in
CI or under `--local`.

`DEVBOX_QUEUE_FULL_ACTION=local` never runs a gate here when the project names `postgres` in
`DEVBOX_SERVICES`. Only the remote machine
provisions that database. A local run without it skipped its database tests and still exited 0.

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
DEVBOX_REJOIN_SECONDS=30
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
6. Otherwise, when a target was skipped as unhealthy, wait for one to clear (below). Else, or
   when none clears within the wait, exit 8, with one line per target that says why.

```
==> devbox: lan1 unreachable (no answer in 3s)
==> devbox: cloud1 skipped: degraded (disk 96%)
==> devbox: waiting for a host: no grant after 10s
==> devbox: queuing on cloud2: 30/32 tokens, 3/3 jobs, 1 waiting: about 240s of queuing
==> devbox: queuing on cloud3: 16/16 tokens, 3/3 jobs, 0 waiting: about 30s of queuing
==> devbox: granted 12 tokens on cloud3 lane 1 after 31s (also asked cloud2)
```

The join lines and the affinity grace line wait for a grant. A grant within 10 seconds of the
first join shows the grant line alone, as in
`==> devbox: granted 12 tokens on cloud3 lane 1 after 2s (also asked cloud2)`. With no grant by
then, the run prints one `waiting for a host` line with its wait so far, then every held line,
as above. A run that ends before any grant prints them too. `DEVBOX_JOIN_QUIET_SECONDS` (10
seconds, from the environment) sets the time, and 0 shows each line as its target is joined.

A target fits now when its host says `now`, and the client does no token arithmetic of its own.
The lines above are from hosts that admit on tokens. A host that admits on pressure, the
default since 3.4.0, decides on its idle cores, its memory and I/O pressure, a settle time
after each grant, its free memory and its job limit, and its token figures decide nothing.
Its line names the rule, the running jobs and the idle CPU share against its limit, then each
other reading that holds the next run:

```
==> devbox: queuing on cloud2: admits on pressure, 3 jobs running, cpu idle 18.40% (at least 25%), 0 waiting: about 2s of queuing
==> devbox: queuing on cloud3: admits on pressure, 1 job running, cpu idle 61.20% (at least 25%), 0 waiting: the host admits this ask now
```

`DEVBOX_MAX_QUEUE_WAIT` counts from the first place in a queue, the grace included. When it runs
out with no grant, rules 4 to 6 apply. A run that gets no free lane on any eligible target
within `DEVBOX_LOCK_WAIT` (3600 seconds, from the environment) exits 4.

While no place in a queue has a grant, the run probes again, every `DEVBOX_REJOIN_SECONDS`,
each target it skipped as unreachable or unhealthy, and joins one that is now eligible. It
prints `==> devbox: <target> answered again, so this run joins it too`. The first grant still
wins, and `DEVBOX_MAX_QUEUE_WAIT` still counts from the first place in a queue. Nothing is
probed during the affinity grace, and `--target` probes no other target. A target skipped for
its gate password, its host key, its protocol, its image or a `never` verdict is not probed
again.

When no target is eligible and one was skipped as unhealthy, the run waits rather than exit 8
at once. A degraded disk, swap past its limit or a broker restart clears by itself: two hosts
once degraded in the same minute, were healthy within 4 minutes, and every gate started in
between exited 8. The run probes the targets skipped as unhealthy or unreachable every
`DEVBOX_REJOIN_SECONDS` and joins the first that turns eligible. A target skipped for a reason
that does not pass within a run is named and not probed again, so one target that lacks a
`DEVBOX_REQUIRES` token and one that is degraded waits for the second. Rules 4 and 5 come
first, and a run whose only skips that can pass are unreachable exits as before. The wait lasts
at most `DEVBOX_MAX_QUEUE_WAIT` from its start, or 3600 seconds with no ceiling, then exits 8
with each target's last reason:

```
==> devbox: no target can take this gate now, so this run waits up to 600s for one to clear, and probes lan1 cloud1 again every 30s: lan1 skipped: degraded (disk 97%); cloud1 skipped: degraded (disk 96%)
==> devbox: cloud1 answered again, so this run joins it too
```

A target is healthy when its watchdog record says `ok` and is at most 90 seconds old. A
handshake mismatch, or an image that does not satisfy `DEVBOX_REQUIRES`, skips one target. On
every target, it exits 5 or 6. A refused gate password on every target exits 3. An unreachable
target is remembered for 60 seconds, so back-to-back runs off a LAN do not each wait for a
LAN-only target.

A host admits on pressure by default. It grants the next queued run when no run is running, or
when enough of its cores are idle, its memory and I/O pressure are below the limits its
operator set, and its last grant has settled, 30 seconds by default, so a project's token count
no longer decides when a run starts. The grant is a worker hint: the host's cores divided by its running gates plus this one, at least 2 and
at most `DEVBOX_WANT_TOKENS`. The gate gets it as `DEVBOX_TOKENS`, as before. A host whose
operator chose `DEVBOX_ADMISSION=tokens`, or one without pressure readings, grants while the
tokens a run asks for are free. On either rule, a host grants a job only when its free memory,
less a reserve, covers a fixed headroom (`DEVBOX_MEMORY_HEADROOM`, set by the host's operator).
When the host's operator turns the CPU limit on, the workspace may use at most its grant in
cores from the grant to the release. Above a soft memory limit, 90 % of the workspace's cap, the
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
with bash, curl and apt. With `postgres` in `DEVBOX_SERVICES`, the pod gets pgvector Postgres 16
on 127.0.0.1:5435 and the URL in `DATABASE_URL`, or the `postgres=` name of `DEVBOX_SERVICE_ENV`. Output and reports go to
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
| `devbox verify` | Plans the steps, cancels this checkout's older gate, waits in the queue of every eligible target, holding a free lane of this worktree on each, and on the first that grants syncs the worktree, runs `DEVBOX_SETUP` and every step that does not carry there, writes the record, and exits with the code of the first failed step. |
| `devbox verify --target <name>` | The same, on one target: a name from `DEVBOX_TARGETS`, `runpod` or `hetzner`. |
| `devbox verify --local` | Runs the same steps here, with the same runner and record, and opens no connection. |
| `devbox verify --full`, `--changed`, `--fresh` | `DEVBOX_RERUN` for this run; `--fresh` is `--full` and also discards the ledger of a stopped gate. |
| `devbox verify --step <name>` | Runs only the named steps; the record is partial and never green. |
| `devbox verify --step <name> --shard <i>/<n>` | Runs shard `<i>` of `<n>` of one runner step's test files; the record is partial. |
| `devbox verify --plan` | Prints what each step would do and why, with each selected test file and its reason, and runs nothing. |
| `devbox result [--failed-steps \| --failed-files [<step>] \| --log <step> \| --json]` | Prints the newest record, its failed steps, its failed test files, one step's saved log, or the record as one JSON object. |
| `devbox probe [--local] <rev>` | Runs the failed test files of the newest record at `<rev>` in a temporary worktree and prints `probe <step> <path> pass\|fail` per file. Exit 0 when every file ran, 1 when one could not, 2 for a revision that names no commit. |
| `devbox ci matrix` | Prints the GitHub Actions matrix of `.devbox/steps`, one entry per step and shard. Exit 2 for a broken steps file. |
| `devbox cancel` | Cancels this checkout's running gate, here and on its target. |
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
health, the token pool, the CPU limit, the soft memory limit and the swap of the host, its
admission rule with its pressure readings, the memory budget per worker, and each
`DEVBOX_REQUIRES` token. The three host limits and the admission rule are `ok`, or `skip` with
the host's reason, and never `ok` for a limit the host cannot set or a host that admits on
tokens. When
ssh fails, it names the cause: DNS, the network, a refused gate password or a host key that is
not its pin.

## devbox status

`devbox status` asks every target one `status` verb, in parallel. It prints one line per
target in `DEVBOX_TARGETS` order: health, then a bar each for reserved tokens, busy cores
against the core count and memory in use, then jobs, and swap while the host uses it. On a host
of 4.1.3 or earlier that admits on pressure the jobs show as a count alone, because no job
limit applies there, and on any host that admits on pressure the token bar is the running worker hints over the cores, never yellow when full. Then one table
lists every gate that runs, then the queue in line order, then the runs this laptop started
that no target holds yet (probe, rent, wait, lock, sync, setup), then the lost ones. `wait` is
the wait for an unhealthy target to clear, and `lock` is the wait for a free lane. A run that
waits in several queues is one row, and its target cell names each of those targets, joined by `+`. A run is lost when every target it names answered
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

The protocol version is not the release version. The protocol version moves with the release
major: when the library or a gate verb changes, and when a release refuses what a consumer's
files still say, as 4.0 refuses `DEVBOX_VERIFY`, `select=related`, `DEVBOX_NEEDS_POSTGRES` and
`DEVBOX_DB_URL_VAR`.

## Exit codes

`devbox verify` returns the gate's own exit code. devbox uses these codes for itself:

| Code | Meaning |
|---|---|
| 1 | an internal failure before the gate |
| 2 | a configuration or usage error |
| 3 | no target answered, or every target refused the gate password or showed a host key that is not its pin; or a service of `DEVBOX_SERVICES` did not answer in 60 s |
| 4 | no lane of this worktree was free on any eligible target within `DEVBOX_LOCK_WAIT`: other runs of it hold every lane |
| 5 | the protocol handshake refused, on every deployed target |
| 6 | no target's workspace image satisfies `DEVBOX_REQUIRES` |
| 7 | the workspace memory limit killed the gate |
| 8 | no target can take this gate, also after the wait for an unhealthy one to clear, or `DEVBOX_MAX_QUEUE_WAIT` ran out with no grant; the gate did not run |
| 9 | a Git LFS file is a pointer; run `git lfs pull` |
| 10 | the watchdog on the target stopped the gate: past `DEVBOX_GATE_MAX_SECONDS`, or no CPU used for too long. This is not a test result |
| 11 | the pool on the target lost the gate's queue ticket and could not restore it; the gate did not run |
| 12 | the pool released the grant twice because the sync and the setup took longer than the host's `DEVBOX_HOLD_PREP_SECONDS`; the gate did not run. The first release queues the run once more by itself. This is not a test result. The lane is warm afterwards |
| 13 | only with `DEVBOX_STRICT_TREE=1`: every step passed, and the synced files changed while the gate ran. The last line is `devbox: incomplete (run <run-id> does not carry: files changed while it ran)`. This is not a test result. Run the gate again on the files as they are now |
| 14 | a newer `devbox verify` of this checkout, or `devbox cancel`, cancelled this gate. This is not a test result |
| 75 | the pool on the host stopped waiting and ran nothing |

A SIGTERM from anything else gives 143 and `devbox verify: stopped by SIGTERM`.

13 is off by default. `DEVBOX_STRICT_TREE` is 0 when the environment does not set it, and
such a gate then exits 0. Only the environment of `devbox verify` sets it: `.devbox.env` and
`.devbox/config.env` do not. With `DEVBOX_STRICT_TREE=1`, a gate on a target, a rented pod and
`--local` each exit 13, after the stderr line
`devbox verify: DEVBOX_STRICT_TREE=1, so this gate exits 13: every step passed, and the files
are not the ones the gate ran on`. The record and the last line stay the same. A gate with a
failed step keeps that step's code, and a gate whose files did not change exits 0. A file list
that devbox cannot hash again after the gate counts as a change. `DEVBOX_STRICT=1` does not
move the 13, because the gate ran to its end. A caller that reads the output takes only
`devbox: green (` as a pass.

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
| 79 | 14 | `cancelled` |

An OOM kill, a queue timeout, a watchdog stop, a lost ticket, a prep limit, a cancel or a pool
deadline also prints one `::devbox-infra::<name>` line on stderr.

## Tests

```sh
bash tests/run-tests.sh
```

The tests use stubs for ssh and the remote host. They open no network connection.

## License

MIT. See `LICENSE`.
