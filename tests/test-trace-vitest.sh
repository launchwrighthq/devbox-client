#!/bin/bash
# The vitest half of the read trace: docs/specs/2026-11-14-learned-selection-design.md
# sections 5.2, 5.4, 5.6 and 5.7, and rows D1, A1, A1a, A2, A3 and A5 of its
# section 15 for vitest.
#
# The risk this file guards is a trace that misses a read: the plan then
# carries a test file that the change broke. The recorded trap is the module
# cache. Two test files import one helper that reads a data file when it loads;
# with isolate: false the second file gets the helper from the cache, the
# helper does not run again, and a trace of file opens alone gives the data
# file to the first test file only.
#
# devbox-trace-hook.mjs runs under plain node, loaded through NODE_OPTIONS as
# the runner loads it, in a fake vitest worker: the global
# __vitest_worker__.filepath that vitest 2, 3 and 4 set is the one field the
# hook reads. A forked child and a worker thread stand for the two pools. The
# reporter's graph is driven through fake vitest objects of the two shapes it
# supports. node is required: a missing one FAILS this file, never skips it.
#
# DEVBOX_TEST_VITEST_INSTALLS, a space-separated list of directories that each
# hold node_modules/vitest, also runs three real fixtures per install and pool:
# the module cache, the Worker and child handoff, and a shared Worker.
# This file installs nothing and reaches no registry, so without that variable
# the output says the real runs did not happen.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
# shellcheck source=tests/lib.sh
source ./lib.sh
REPO="$(cd .. && pwd)"
TOOLS="$REPO/client/share/ledger"
HOOK="$TOOLS/devbox-trace-hook.mjs"

TMP="$(mktemp -d)" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
unset DEVBOX_TRACE_DIR DEVBOX_TRACE_ROOT DEVBOX_LEDGER DEVBOX_RESUME NODE_OPTIONS

if command -v node >/dev/null 2>&1; then
  _pass "node is on PATH"
else
  _fail "node is on PATH" "the trace tests need node; a missing one fails this file, never skips it"
fi
assert_ok "devbox-trace-hook.mjs is in the payload" test -f "$HOOK"

# Every line of the traces of one directory, sorted and de-duplicated, as the
# runner's transport sends them.
traces() { cat "$1"/*.trace 2>/dev/null | sort -u; }
has_line() { grep -qxF "$2" <<<"$1"; }

# ── the fixture project ──────────────────────────────────────────────────────

mkdir -p "$TMP/proj/.devbox" "$TMP/proj/src" "$TMP/proj/data" "$TMP/proj/fixtures" "$TMP/proj/node_modules/dep"
: >"$TMP/proj/.devbox/config.env"
PROJ="$(cd "$TMP/proj" && pwd -P)"
printf '{"x":1}\n' >"$PROJ/data/data.json"
printf 'one\n' >"$PROJ/fixtures/one.txt"
printf 'dep\n' >"$PROJ/node_modules/dep/index.txt"
printf 'outside\n' >"$TMP/outside.txt"
cat >"$PROJ/src/helper.mjs" <<'JS'
import { readFileSync } from 'node:fs';
export const data = JSON.parse(readFileSync('data/data.json', 'utf8'));
JS
# The body of a test file: named ESM imports of fs, so the hook must reach the
# bindings a module took when it loaded, and fs.promises.
cat >"$PROJ/src/a.test.mjs" <<'JS'
import { readdirSync, existsSync, openSync, closeSync, statSync } from 'node:fs';
import fsp from 'node:fs/promises';
export async function run() {
  readdirSync('fixtures');
  existsSync('missing.txt');
  statSync('node_modules/dep/index.txt');
  closeSync(openSync('written.txt', 'w'));
  await fsp.readFile('fixtures/one.txt');
}
JS

# ── the hook in one worker ───────────────────────────────────────────────────

cat >"$TMP/worker-driver.mjs" <<'JS'
import fs from 'node:fs';
import path from 'node:path';
import { execSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';
const [proj, outside] = process.argv.slice(2);
process.chdir(proj);
const set = (file) => { globalThis.__vitest_worker__ = file ? { filepath: path.join(proj, file), config: { root: proj } } : undefined; };
// No test file runs yet: the worker's startup reads nothing into the trace.
fs.readFileSync('data/data.json');
set('src/a.test.mjs');
await import(pathToFileURL(path.join(proj, 'src/helper.mjs')).href);
await (await import(pathToFileURL(path.join(proj, 'src/a.test.mjs')).href)).run();
fs.readFileSync(outside);
fs.readFileSync(new URL(pathToFileURL(path.join(proj, 'fixtures/one.txt'))));
// isolate: false: b imports the helper from the module cache, so it reads nothing.
set('src/b.test.mjs');
await import(pathToFileURL(path.join(proj, 'src/helper.mjs')).href);
set('src/c.test.mjs');
execSync('true');
set(null);
execSync('true');
process.stdout.write(`wrapped=${String(fs.readFileSync).includes('record(kind, target)')}\n`);
JS

TR="$TMP/trace1"
mkdir -p "$TR"
out="$(DEVBOX_TRACE_DIR="$TR" NODE_OPTIONS="--import=$HOOK" node "$TMP/worker-driver.mjs" "$PROJ" "$TMP/outside.txt" 2>&1)"; rc=$?
assert_eq "0" "$rc" "the worker driver runs with the hook loaded through NODE_OPTIONS: $(head -3 <<<"$out")"
T1="$(traces "$TR")"
assert_ok "D1: a helper that reads a data file when it loads gives the read to the test file that loaded it" \
  has_line "$T1" $'read\tsrc/a.test.mjs\tdata/data.json'
assert_ok "a directory a test lists is a list line ending in /" has_line "$T1" $'list\tsrc/a.test.mjs\tfixtures/'
assert_ok "a stat of a missing file counts, because the test depends on its absence" has_line "$T1" $'read\tsrc/a.test.mjs\tmissing.txt'
assert_ok "fs.promises reads are traced" has_line "$T1" $'read\tsrc/a.test.mjs\tfixtures/one.txt'
assert_ok "a read under node_modules is a setup line with no path" has_line "$T1" $'setup\tsrc/a.test.mjs'
assert_fail "a file opened only to write is no read" grep -qF 'written.txt' <<<"$T1"
assert_fail "a path outside the repository is dropped" grep -qF 'outside' <<<"$T1"
assert_fail "a read with no test file running is no line" grep -qP '^read\t-\t' <<<"$T1"
assert_ok "a child process marks its test file partial" has_line "$T1" $'partial\tsrc/c.test.mjs\tchild_process'
assert_eq "1" "$(grep -c '^partial' <<<"$T1")" "a child process with no test file running marks nothing"
assert_fail "the hook gives b no read of its own: the cache served the helper" grep -qP '^read\tsrc/b\.test\.mjs\t' <<<"$T1"
assert_ok "the hook writes the helper's read to the modules file for the reporter" \
  grep -qxF $'read\tsrc/helper.mjs\tdata/data.json' "$TR"/*.modules
assert_eq "1" "$(find "$TR" -name 'vitest-*.trace' | wc -l)" "one process writes one trace file, named vitest-<pid>.trace"
assert_eq "0" "$(awk -F'\t' 'NF < 2 || NF > 3 || ($1 == "setup") != (NF == 2)' "$TR"/*.trace | wc -l)" \
  "a setup line has 2 tab-separated fields and every other line 3"
assert_eq "wrapped=true" "$(grep '^wrapped=' <<<"$out")" "with DEVBOX_TRACE_DIR set the hook wraps fs.readFileSync"

out="$(NODE_OPTIONS="--import=$HOOK" node "$TMP/worker-driver.mjs" "$PROJ" "$TMP/outside.txt" 2>&1)"; rc=$?
assert_eq "0" "$rc" "the driver runs with the hook loaded and DEVBOX_TRACE_DIR unset"
assert_eq "wrapped=false" "$(grep '^wrapped=' <<<"$out")" "with DEVBOX_TRACE_DIR unset the hook wraps nothing"

# DEVBOX_TRACE_ROOT wins over the .devbox/config.env above the vitest root.
TR="$TMP/trace-root"
mkdir -p "$TR"
DEVBOX_TRACE_ROOT="$PROJ/src" DEVBOX_TRACE_DIR="$TR" NODE_OPTIONS="--import=$HOOK" \
  node "$TMP/worker-driver.mjs" "$PROJ" "$TMP/outside.txt" >/dev/null 2>&1
T2="$(traces "$TR")"
assert_ok "DEVBOX_TRACE_ROOT sets the root every path is relative to" has_line "$T2" $'read\ta.test.mjs\thelper.mjs'
assert_fail "a read outside DEVBOX_TRACE_ROOT is dropped" grep -qF 'data.json' <<<"$T2"

# Section 5.4: a child process marks its test file partial only when it may
# read repository files. One test file per child, because every such line has
# the one reason `child_process`.
mkdir -p "$PROJ/bin"
printf '#!/bin/sh\nexit 0\n' >"$PROJ/bin/repo-tool"
chmod +x "$PROJ/bin/repo-tool"
cat >"$TMP/child-driver.mjs" <<'JS'
import path from 'node:path';
import { execFileSync, spawnSync } from 'node:child_process';
const [proj, outside] = process.argv.slice(2);
process.chdir(proj);
const set = (file) => { globalThis.__vitest_worker__ = { filepath: path.join(proj, file), config: { root: proj } }; };
set('src/quiet.test.mjs');
spawnSync('git', ['rev-parse', 'HEAD']);
spawnSync('true');
execFileSync('cat', [outside]);
set('src/cat.test.mjs');
execFileSync('cat', ['data/data.json']);
set('src/root.test.mjs');
spawnSync('head', ['-c1', 'data/data.json'], { cwd: path.dirname(proj) });
set('src/env.test.mjs');
spawnSync('/usr/bin/env', ['python3', '-c', 'pass']);
set('src/tool.test.mjs');
spawnSync('repo-tool', [], { env: { ...process.env, PATH: `${path.join(proj, 'bin')}:${process.env.PATH}` } });
JS
TR="$TMP/trace-child"
mkdir -p "$TR"
out="$(DEVBOX_TRACE_DIR="$TR" NODE_OPTIONS="--import=$HOOK" node "$TMP/child-driver.mjs" "$PROJ" "$TMP/outside.txt" 2>&1)"; rc=$?
assert_eq "0" "$rc" "the child driver runs: $(head -3 <<<"$out")"
TC="$(traces "$TR")"
assert_fail "section 5.4: git rev-parse HEAD, true and a cat of a file outside the root mark nothing partial" \
  grep -qF $'partial\tsrc/quiet.test.mjs' <<<"$TC"
assert_ok "section 5.4: cat of a repository file relative to the child's directory marks partial" \
  has_line "$TC" $'partial\tsrc/cat.test.mjs\tchild_process'
assert_ok "section 5.4: a word that names a repository file relative to the root marks partial" \
  has_line "$TC" $'partial\tsrc/root.test.mjs\tchild_process'
assert_ok "section 5.4: /usr/bin/env python3 -c names an interpreter, so it marks partial" \
  has_line "$TC" $'partial\tsrc/env.test.mjs\tchild_process'
assert_ok "section 5.4: a program that resolves inside the repository through PATH marks partial" \
  has_line "$TC" $'partial\tsrc/tool.test.mjs\tchild_process'
assert_fail "section 5.4: deciding a child records no read of the paths it tested" grep -q '^read' <<<"$TC"

# A path holding a tab cannot be written as a line, so its test file is partial.
TR="$TMP/trace-tab"
mkdir -p "$TR"
cat >"$TMP/tab-driver.mjs" <<'JS'
import fs from 'node:fs';
import path from 'node:path';
const [proj] = process.argv.slice(2);
globalThis.__vitest_worker__ = { filepath: path.join(proj, 'src/a.test.mjs'), config: { root: proj } };
fs.existsSync(path.join(proj, 'a\tb.txt'));
JS
DEVBOX_TRACE_DIR="$TR" NODE_OPTIONS="--import=$HOOK" node "$TMP/tab-driver.mjs" "$PROJ" >/dev/null 2>&1
assert_eq $'partial\tsrc/a.test.mjs\ta path holds a tab or a newline' "$(traces "$TR")" \
  "a path holding a tab marks its test file partial and writes no read"

# ── the hook in both pools ───────────────────────────────────────────────────
#
# The forks pool runs each worker as a child process, and the threads pool as a
# worker thread of one process. Each must load the hook from NODE_OPTIONS, and
# each must write its own file: two threads share one pid.

cat >"$TMP/pool-driver.mjs" <<'JS'
import fs from 'node:fs';
import path from 'node:path';
import { fork } from 'node:child_process';
import { Worker, isMainThread, workerData } from 'node:worker_threads';
const self = new URL(import.meta.url).pathname;
const work = (proj, file) => {
  globalThis.__vitest_worker__ = { filepath: path.join(proj, file), config: { root: proj } };
  fs.readFileSync(path.join(proj, 'data/data.json'));
};
const [mode, proj, file] = process.argv.slice(2);
if (!isMainThread) {
  work(workerData.proj, workerData.file);
} else if (mode === 'child') {
  work(proj, file);
} else {
  await new Promise((ok, no) => fork(self, ['child', proj, 'src/fork.test.mjs']).on('exit', (c) => (c === 0 ? ok() : no(new Error(`child ${c}`)))));
  for (const f of ['src/t1.test.mjs', 'src/t2.test.mjs']) {
    await new Promise((ok, no) => new Worker(self, { workerData: { proj, file: f } }).on('exit', ok).on('error', no));
  }
}
JS
TR="$TMP/trace-pools"
mkdir -p "$TR"
out="$(DEVBOX_TRACE_DIR="$TR" NODE_OPTIONS="--import=$HOOK" node "$TMP/pool-driver.mjs" main "$PROJ" 2>&1)"; rc=$?
assert_eq "0" "$rc" "the pool driver runs: $(head -3 <<<"$out")"
TP="$(traces "$TR")"
assert_ok "a forked child loads the hook from NODE_OPTIONS and traces its test file" has_line "$TP" $'read\tsrc/fork.test.mjs\tdata/data.json'
assert_ok "a worker thread loads the hook and traces its test file" has_line "$TP" $'read\tsrc/t1.test.mjs\tdata/data.json'
assert_ok "a second worker thread traces its own test file" has_line "$TP" $'read\tsrc/t2.test.mjs\tdata/data.json'
assert_eq "2" "$(find "$TR" -name 'vitest-*-*.trace' | wc -l)" "each worker thread writes its own vitest-<pid>-<thread id>.trace"
assert_fail "starting the pool's workers from the main process marks nothing partial" grep -q '^partial' <<<"$TP"

# ── a Worker or a node child a test starts (section 5.7) ─────────────────────
#
# The parent hook hands the test file and a token to a Worker or a node child
# in a copy of its environment, and the hook there writes `covered <file>
# <token>` when it loads. The drivers below keep one vitest state object and
# assign its filepath, as vitest 2 to 5 do, because the shared Worker guard
# watches that assignment.

# The runner's rule of section 5.7, step 5, which row A4 builds in
# devbox-steps: a tokened partial that a covered line confirms goes, every
# covered line goes, and an unconfirmed one stays as a plain partial.
resolve() {
  awk -F'\t' -v OFS='\t' '
    NR == FNR { if ($1 == "covered") ok[$2 SUBSEP $3] = 1; next }
    $1 == "covered" { next }
    $1 == "partial" && NF == 4 { if (($2 SUBSEP $4) in ok) next; print $1, $2, $3; next }
    { print }' <(printf '%s\n' "$1") <(printf '%s\n' "$1") | sort -u
}
# The partial reasons of one test file in a trace, one per line.
reasons() { awk -F'\t' -v f="$2" '$1 == "partial" && $2 == f { print $3 }' <<<"$1" | sort -u; }
# The token of the one tokened partial line of a test file and reason.
token_of() { awk -F'\t' -v f="$2" -v r="$3" '$1 == "partial" && $2 == f && $3 == r && NF == 4 { print $4 }' <<<"$1"; }
# A test file whose tokened partial a covered line of the same token confirms.
confirmed() {
  local tok
  tok="$(token_of "$1" "$2" "$3")"
  [ -n "$tok" ] && [ "$(wc -l <<<"$tok")" = 1 ] && has_line "$1" "covered"$'\t'"$2"$'\t'"$tok"
}

for f in worker worker2 eval share noopts fork node path-node script sh-node grand npx sa sb sc sd sg sh; do
  printf '%s\n' "$f" >"$PROJ/data/$f.txt"
done
# The Worker script: it reads the file it is given, tells the parent whether a
# handoff variable is still in its environment, and holds on when asked.
cat >"$PROJ/src/reader.mjs" <<'JS'
import { readFileSync } from 'node:fs';
import { parentPort, workerData } from 'node:worker_threads';
readFileSync(workerData.file);
const leak = ['DEVBOX_TRACE_OWNER', 'DEVBOX_TRACE_TOKEN', 'DEVBOX_TRACE_PARENT'].some((k) => k in process.env);
parentPort.postMessage({ leak });
if (workerData.hold) setInterval(() => {}, 1000);
JS
# The node child: it reads its argument, exits 3 when a handoff variable is
# still in its environment, and with `hold` says ready and waits to be killed.
cat >"$PROJ/src/child.mjs" <<'JS'
import { readFileSync } from 'node:fs';
readFileSync(process.argv[2]);
if (['DEVBOX_TRACE_OWNER', 'DEVBOX_TRACE_TOKEN', 'DEVBOX_TRACE_PARENT'].some((k) => k in process.env)) process.exit(3);
if (process.argv[3] === 'hold') {
  process.stdout.write('ready\n');
  setInterval(() => {}, 1000);
}
JS
# A child the hook did not reach, which starts node again with the hook: the
# grandchild inherits the handoff of a parent that is not its own.
cat >"$PROJ/src/mid.mjs" <<'JS'
import { spawnSync } from 'node:child_process';
const r = spawnSync(process.execPath, ['src/grand.mjs', process.argv[2]], {
  env: { ...process.env, NODE_OPTIONS: process.env.DEVBOX_TEST_HOOK_OPTIONS }, stdio: 'inherit' });
process.exit(r.status ?? 1);
JS
printf "import { readFileSync } from 'node:fs';\nreadFileSync(process.argv[2]);\n" >"$PROJ/src/grand.mjs"
printf '#!/usr/bin/env node\nrequire("node:fs").readFileSync(process.argv[2]);\n' >"$PROJ/bin/node-script"
chmod +x "$PROJ/bin/node-script"
mkdir -p "$TMP/fakebin"
printf '#!/usr/bin/env node\nrequire("node:fs").readFileSync(process.argv[2]);\n' >"$TMP/fakebin/npx"
chmod +x "$TMP/fakebin/npx"
# One Worker for every test file that imports this module: with isolate: false
# the second file takes it from the module cache.
cat >"$PROJ/src/pool.mjs" <<'JS'
import { Worker } from 'node:worker_threads';
const w = new Worker(new URL('./pool-worker.mjs', import.meta.url));
w.unref();
export function readThrough(file) {
  return new Promise((ok) => { w.once('message', ok); w.postMessage(file); });
}
JS
cat >"$PROJ/src/pool-worker.mjs" <<'JS'
import { readFileSync } from 'node:fs';
import { parentPort } from 'node:worker_threads';
parentPort.on('message', (file) => parentPort.postMessage(readFileSync(file, 'utf8').length));
JS

cat >"$TMP/handoff-driver.mjs" <<'JS'
import fs from 'node:fs';
import path from 'node:path';
import { Worker, SHARE_ENV } from 'node:worker_threads';
import { fork, spawn, spawnSync, execFileSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';
const [mode, proj, fakebin] = process.argv.slice(2);
process.chdir(proj);
const state = { filepath: '', config: { root: proj } };
globalThis.__vitest_worker__ = state;
const set = (f) => { state.filepath = path.join(proj, f); };
const say = (line) => process.stdout.write(`${line}\n`);
const reader = path.join(proj, 'src/reader.mjs');
// A Worker of reader.mjs, its first message, and a promise of its exit.
const start = (opts) => {
  const w = new Worker(reader, opts);
  const exited = new Promise((ok) => w.once('exit', ok));
  return new Promise((ok, no) => { w.once('message', (m) => ok({ w, m, exited })); w.once('error', no); });
};
const child = (name, r) => say(`status ${name} ${r.status}`);
const { NODE_OPTIONS: hookOptions, ...bare } = process.env;
if (mode === 'handoff') {
  set('src/w-term.test.mjs');
  let r = await start({ workerData: { file: 'data/worker.txt', hold: true } });
  say(`leak w-term ${r.m.leak}`);
  await r.w.terminate();
  set('src/w-empty.test.mjs');
  r = await start({ workerData: { file: 'data/worker2.txt' }, execArgv: [] });
  say(`leak w-empty ${r.m.leak}`);
  await r.exited;
  set('src/w-eval.test.mjs');
  await new Promise((ok, no) => new Worker("require('node:fs').readFileSync('data/eval.txt')", { eval: true }).on('exit', ok).on('error', no));
  set('src/w-share.test.mjs');
  r = await start({ workerData: { file: 'data/share.txt' }, env: SHARE_ENV });
  say(`leak w-share ${r.m.leak}`);
  await r.exited;
  set('src/w-noopts.test.mjs');
  r = await start({ workerData: { file: 'data/noopts.txt' }, env: bare });
  await r.exited;
  set('src/c-fork.test.mjs');
  say(`status c-fork ${await new Promise((ok) => fork(path.join(proj, 'src/child.mjs'), ['data/fork.txt']).on('exit', ok))}`);
  set('src/c-node.test.mjs');
  child('c-node', spawnSync(process.execPath, [path.join(proj, 'src/child.mjs'), 'data/node.txt']));
  set('src/c-path.test.mjs');
  execFileSync('node', ['src/child.mjs', 'data/path-node.txt']);
  say('status c-path 0');
  set('src/c-script.test.mjs');
  execFileSync('bin/node-script', ['data/script.txt']);
  say('status c-script 0');
  set('src/c-sh.test.mjs');
  child('c-sh', spawnSync('sh', ['-c', 'node src/child.mjs data/sh-node.txt']));
  set('src/c-npx.test.mjs');
  child('c-npx', spawnSync(path.join(fakebin, 'npx'), ['data/npx.txt']));
  set('src/c-grand.test.mjs');
  child('c-grand', spawnSync(process.execPath, ['src/mid.mjs', 'data/grand.txt'], { env: { ...bare, DEVBOX_TEST_HOOK_OPTIONS: hookOptions } }));
  const parentLeak = ['DEVBOX_TRACE_OWNER', 'DEVBOX_TRACE_TOKEN', 'DEVBOX_TRACE_PARENT'].some((k) => k in process.env);
  say(`leak parent ${parentLeak}`);
} else if (mode === 'shared-worker') {
  set('src/s-a.test.mjs');
  const pool = await import(pathToFileURL(path.join(proj, 'src/pool.mjs')).href);
  await pool.readThrough('data/sa.txt');
  set('src/s-b.test.mjs');
  await pool.readThrough('data/sb.txt');
  // vitest gave this worker a new state object, which the setter does not
  // watch yet: the post to the live Worker is what tells.
  globalThis.__vitest_worker__ = { filepath: path.join(proj, 'src/s-c.test.mjs'), config: { root: proj } };
  await pool.readThrough('data/sc.txt');
} else if (mode === 'shared-child') {
  set('src/s-d.test.mjs');
  const c = spawn(process.execPath, ['src/child.mjs', 'data/sd.txt', 'hold']);
  await new Promise((ok) => c.stdout.once('data', ok));
  set('src/s-e.test.mjs');
  const gone = new Promise((ok) => c.once('exit', ok));
  c.kill();
  await gone;
  set('src/s-f.test.mjs');
  fs.readFileSync('data/sd.txt');
} else if (mode === 'ended') {
  set('src/s-g.test.mjs');
  const r = await start({ workerData: { file: 'data/sg.txt', hold: true } });
  await r.w.terminate();
  set('src/s-h.test.mjs');
  fs.readFileSync('data/sh.txt');
}
JS
TOKEN_RE='^[A-Za-z0-9._-]{8,64}$'

TR="$TMP/trace-handoff"
mkdir -p "$TR"
out="$(DEVBOX_TRACE_DIR="$TR" NODE_OPTIONS="--import=$HOOK" node "$TMP/handoff-driver.mjs" handoff "$PROJ" "$TMP/fakebin" 2>&1)"; rc=$?
assert_eq "0" "$rc" "the handoff driver runs: $(grep -v '^status \|^leak ' <<<"$out" | head -3)"
TH="$(traces "$TR")"
RH="$(resolve "$TH")"
assert_eq "" "$(grep -v '^status .* 0$\|^leak .* false$' <<<"$out")" \
  "section 5.7: every Worker and child ran, and none of them nor the parent kept a handoff variable"
for c in w-term:worker w-empty:worker2; do
  f="src/${c%%:*}.test.mjs"
  assert_ok "A1 ${c%%:*}: the Worker's read of a fixture file is under the test file that started it" \
    has_line "$TH" $'read\t'"$f"$'\tdata/'"${c#*:}"'.txt'
  assert_ok "A1 ${c%%:*}: its tokened partial has a covered line of the same token" confirmed "$TH" "$f" worker_threads
  assert_eq "" "$(reasons "$RH" "$f")" "A1 ${c%%:*}: after the runner's rule the test file is complete"
done
assert_ok "A1: the Worker wrote its read to its own vitest-<pid>-<thread id>.trace" \
  grep -qxF $'read\tsrc/w-term.test.mjs\tdata/worker.txt' "$TR"/vitest-*-*.trace
tokens="$(awk -F'\t' '$1 == "partial" && NF == 4 { print $4 } $1 == "covered" { print $3 }' <<<"$TH")"
assert_eq "0" "$(grep -cvE "$TOKEN_RE" <<<"$tokens")" "section 5.7: every token matches $TOKEN_RE"
assert_eq "$(awk -F'\t' '$1 == "partial" && NF == 4' <<<"$TH" | wc -l)" \
  "$(awk -F'\t' '$1 == "partial" && NF == 4 { print $4 }' <<<"$TH" | sort -u | wc -l)" "section 5.7: each start has a token of its own"
assert_ok "A1a: an eval Worker leaves the plain partial worker_threads" has_line "$TH" $'partial\tsrc/w-eval.test.mjs\tworker_threads'
assert_ok "A1a: a SHARE_ENV Worker leaves the plain partial worker_threads" has_line "$TH" $'partial\tsrc/w-share.test.mjs\tworker_threads'
assert_fail "A1a: a SHARE_ENV Worker records no read, because it has no owner" grep -qF 'data/share.txt' <<<"$TH"
assert_ok "A1a: a Worker whose env leaves out NODE_OPTIONS gets a tokened partial" \
  test -n "$(token_of "$TH" src/w-noopts.test.mjs worker_threads)"
assert_fail "A1a: and no covered line, because the hook never loaded there" grep -qP '^covered\tsrc/w-noopts\.test\.mjs\t' <<<"$TH"
for f in w-eval w-share w-noopts; do
  assert_eq "worker_threads" "$(reasons "$RH" "src/$f.test.mjs")" "A1a $f: after the runner's rule the test file stays partial"
done
for c in c-fork:fork c-node:node c-path:path-node c-script:script; do
  f="src/${c%%:*}.test.mjs"
  assert_ok "A2 ${c%%:*}: the node child's read is under the test file that started it" \
    has_line "$TH" $'read\t'"$f"$'\tdata/'"${c#*:}"'.txt'
  assert_ok "A2 ${c%%:*}: its tokened partial has a covered line of the same token" confirmed "$TH" "$f" child_process
  assert_eq "" "$(reasons "$RH" "$f")" "A2 ${c%%:*}: after the runner's rule the test file is complete"
done
assert_ok "A2: node under sh -c keeps the plain partial child_process" has_line "$TH" $'partial\tsrc/c-sh.test.mjs\tchild_process'
assert_fail "A2: and its node records nothing for the test file" grep -qF 'data/sh-node.txt' <<<"$TH"
assert_ok "A2: a node script named npx keeps the plain partial child_process" has_line "$TH" $'partial\tsrc/c-npx.test.mjs\tchild_process'
assert_fail "A2: and confirms nothing" grep -qP '^covered\tsrc/c-npx\.test\.mjs\t' <<<"$TH"
assert_ok "A2: a child the hook did not reach has a tokened partial" test -n "$(token_of "$TH" src/c-grand.test.mjs child_process)"
assert_fail "A2: its node grandchild, which inherited the handoff, does not confirm in its place" \
  grep -qP '^covered\tsrc/c-grand\.test\.mjs\t' <<<"$TH"
assert_fail "A2: and records nothing for the test file" grep -qF 'data/grand.txt' <<<"$TH"
for f in c-sh c-npx c-grand; do
  assert_eq "child_process" "$(reasons "$RH" "src/$f.test.mjs")" "A2 $f: after the runner's rule the test file stays partial"
done

TR="$TMP/trace-shared"
mkdir -p "$TR"
out="$(DEVBOX_TRACE_DIR="$TR" NODE_OPTIONS="--import=$HOOK" node "$TMP/handoff-driver.mjs" shared-worker "$PROJ" 2>&1)"; rc=$?
assert_eq "0" "$rc" "the shared Worker driver runs: $(head -3 <<<"$out")"
TS="$(traces "$TR")"
assert_ok "A3: the file that started the Worker is complete once the Worker confirmed" \
  test -z "$(reasons "$(resolve "$TS")" src/s-a.test.mjs)"
assert_ok "A3: the Worker's reads are under the file that started it" has_line "$TS" $'read\tsrc/s-a.test.mjs\tdata/sa.txt'
assert_ok "A3: a later file that runs while that Worker is alive is partial with shared worker" \
  has_line "$TS" $'partial\tsrc/s-b.test.mjs\tshared worker'
assert_ok "A3: a later file under a new vitest state that posts to that Worker is partial with shared worker" \
  has_line "$TS" $'partial\tsrc/s-c.test.mjs\tshared worker'

TR="$TMP/trace-shared-child"
mkdir -p "$TR"
out="$(DEVBOX_TRACE_DIR="$TR" NODE_OPTIONS="--import=$HOOK" node "$TMP/handoff-driver.mjs" shared-child "$PROJ" 2>&1)"; rc=$?
assert_eq "0" "$rc" "the shared child driver runs: $(head -3 <<<"$out")"
TS="$(traces "$TR")"
assert_eq "" "$(reasons "$(resolve "$TS")" src/s-d.test.mjs)" "A3: the file that started a node child is complete once the child confirmed"
assert_ok "A3: a later file that runs while that child is alive is partial with shared worker" \
  has_line "$TS" $'partial\tsrc/s-e.test.mjs\tshared worker'
assert_eq "" "$(reasons "$TS" src/s-f.test.mjs)" "A3: a file that runs after the child exited is not partial"

TR="$TMP/trace-ended"
mkdir -p "$TR"
out="$(DEVBOX_TRACE_DIR="$TR" NODE_OPTIONS="--import=$HOOK" node "$TMP/handoff-driver.mjs" ended "$PROJ" 2>&1)"; rc=$?
assert_eq "0" "$rc" "the ended Worker driver runs: $(head -3 <<<"$out")"
TS="$(traces "$TR")"
assert_eq "" "$(reasons "$(resolve "$TS")" src/s-g.test.mjs)" "A1: a terminated Worker's file is complete"
assert_fail "A3: a file that runs after the Worker was terminated is not shared worker" grep -qF 'shared worker' <<<"$TS"
assert_ok "A3: and its own read is traced" has_line "$TS" $'read\tsrc/s-h.test.mjs\tdata/sh.txt'

# ── the reporter's module graph through fake vitest objects ──────────────────
#
# vitest 2: ctx.server, a project's server.moduleGraph, onFinished(files) with
# File tasks naming their project. vitest 3 and 4: ctx.vite, project.vite,
# onTestRunEnd(testModules). A module node's importedModules hold nodes whose
# id is an absolute path, a query or a virtual id included.

cat >"$TMP/graph-driver.mjs" <<'JS'
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
const [tools, proj, tr2, tr3, tr0] = process.argv.slice(2);
const Reporter = (await import(pathToFileURL(path.join(tools, 'vitest-ledger.mjs')).href)).default;
const p = (f) => path.join(proj, f);
const nodes = new Map();
const node = (id) => { if (!nodes.has(id)) nodes.set(id, { id, importedModules: new Set() }); return nodes.get(id); };
const edge = (a, b) => node(a).importedModules.add(node(b));
edge(p('src/a.test.ts'), p('src/helper.ts'));
edge(p('src/b.test.ts'), p('src/helper.ts') + '?v=123');
edge(p('src/helper.ts'), p('src/util.ts'));
edge(p('src/helper.ts'), '\0virtual:x');
edge(p('src/a.test.ts'), p('node_modules/dep/index.js'));
edge(p('setup.ts'), p('src/setup-helper.ts'));
node(p('src/helper.ts') + '?v=123').importedModules = node(p('src/helper.ts')).importedModules;
const graph = { getModuleById: (id) => nodes.get(id), getModulesByFile: (f) => [...nodes.values()].filter((n) => n.id.replace(/\?.*/, '') === f) };
const viteConfig = { configFile: p('vitest.config.ts'), configFileDependencies: [p('base.config.ts')] };
const testConfig = { root: proj, setupFiles: ['./setup.ts'], globalSetup: [] };

process.env.DEVBOX_TRACE_DIR = tr2;
const project2 = { getName: () => 'web', server: { moduleGraph: graph, config: viteConfig }, config: testConfig };
const r2 = new Reporter();
r2.onInit({ version: '2.0.0', config: { root: proj }, server: { config: {} }, projects: [project2], _workspaceConfigPath: p('vitest.workspace.ts') });
r2.onFinished([{ filepath: p('src/a.test.ts'), projectName: 'web' }, { filepath: p('src/b.test.ts'), projectName: 'web' }]);

process.env.DEVBOX_TRACE_DIR = tr3;
const project3 = { name: 'web', vite: { moduleGraph: graph, config: viteConfig }, config: testConfig };
const r3 = new Reporter();
r3.onInit({ version: '4.0.0', config: { root: proj }, vite: { config: {} }, projects: [project3] });
r3.onTestRunEnd([{ moduleId: p('src/a.test.ts'), project: project3 }, { moduleId: p('src/b.test.ts'), project: project3 }]);
// vitest 3 calls onFinished after onTestRunEnd: the graph is written once.
r3.onFinished([{ filepath: p('src/c.test.ts'), projectName: 'web' }]);

delete process.env.DEVBOX_TRACE_DIR;
const r0 = new Reporter();
r0.onInit({ version: '4.0.0', config: { root: proj }, projects: [project3] });
r0.onTestRunEnd([{ moduleId: p('src/a.test.ts'), project: project3 }]);
fs.writeFileSync(path.join(tr0, 'done'), 'yes');
JS

mkdir -p "$TMP/g2" "$TMP/g3" "$TMP/g0"
# The hook's module reads, as a worker that loaded the helper once left them,
# and as two more test processes left the same reads under vitest's isolation.
printf 'read\tsrc/helper.ts\tdata/data.json\nlist\tsrc/util.ts\tfixtures\n' >"$TMP/g2/vitest-1.modules"
cp "$TMP/g2/vitest-1.modules" "$TMP/g2/vitest-2.modules"
cp "$TMP/g2/vitest-1.modules" "$TMP/g2/vitest-3.modules"
cp "$TMP/g2/vitest-"*.modules "$TMP/g3/"
# MEASURED: kept once per .modules file, a helper's reads were expanded again
# for every test file, and the reporter of a suite of a few thousand files
# ran over an hour after vitest's summary. Each read is kept once, whatever the number of files.
reads="$(node --input-type=module -e "
const core = await import(process.argv[1]);
const m = core.readModuleReads(process.argv[2]);
console.log([...m].map(([k, v]) => k + '=' + v.length).sort().join(' '));
" "$TOOLS/ledger-core.mjs" "$TMP/g2" 2>&1)"
assert_eq "src/helper.ts=1 src/util.ts=1" "$reads" "a module's reads from three .modules files are kept once each"
out="$(node "$TMP/graph-driver.mjs" "$TOOLS" "$PROJ" "$TMP/g2" "$TMP/g3" "$TMP/g0" 2>&1)"; rc=$?
assert_eq "0" "$rc" "the graph driver runs under plain node: $(head -3 <<<"$out")"
for shape in 2 3; do
  G="$(traces "$TMP/g$shape")"
  label="vitest $shape"
  [ "$shape" = 3 ] && label="vitest 3 and 4"
  assert_ok "$label: a test file reads the module it imports" has_line "$G" $'read\tsrc/a.test.ts\tsrc/helper.ts'
  assert_ok "$label: and every module that module imports" has_line "$G" $'read\tsrc/a.test.ts\tsrc/util.ts'
  assert_ok "$label: an import id with a query names the file" has_line "$G" $'read\tsrc/b.test.ts\tsrc/helper.ts'
  assert_ok "D1 $label: the second importer of a cached helper gets the helper's read of the data file" \
    has_line "$G" $'read\tsrc/b.test.ts\tdata/data.json'
  assert_ok "D1 $label: and the first importer gets it too" has_line "$G" $'read\tsrc/a.test.ts\tdata/data.json'
  assert_ok "$label: a module's directory listing reaches its importers" has_line "$G" $'list\tsrc/b.test.ts\tfixtures/'
  assert_ok "$label: an import under node_modules is a setup line" has_line "$G" $'setup\tsrc/a.test.ts'
  assert_ok "$label: the project's config is a read of every test file" has_line "$G" $'read\tsrc/b.test.ts\tvitest.config.ts'
  assert_ok "$label: a file the config imported is a read of every test file" has_line "$G" $'read\tsrc/b.test.ts\tbase.config.ts'
  assert_ok "$label: a setup file and its imports are reads of every test file" has_line "$G" $'read\tsrc/b.test.ts\tsrc/setup-helper.ts'
  assert_fail "$label: a virtual module is no read" grep -qF 'virtual' <<<"$G"
  assert_fail "$label: a test file is not a read of itself" has_line "$G" $'read\tsrc/a.test.ts\tsrc/a.test.ts'
done
assert_ok "vitest 2: the workspace file it found is a read of every test file" \
  has_line "$(traces "$TMP/g2")" $'read\tsrc/a.test.ts\tvitest.workspace.ts'
assert_fail "vitest 3: onFinished after onTestRunEnd writes nothing more" grep -qF 'src/c.test.ts' <<<"$(traces "$TMP/g3")"
assert_eq "yes" "$(cat "$TMP/g0/done" 2>/dev/null)" "with DEVBOX_TRACE_DIR unset the reporter runs to the end"
assert_eq "1" "$(find "$TMP/g0" -type f | wc -l)" "with DEVBOX_TRACE_DIR unset the reporter writes no trace"

# ── the payload ──────────────────────────────────────────────────────────────

if pack="$(cd "$REPO" && npm pack --dry-run --json --ignore-scripts 2>/dev/null)"; then
  assert_ok "the npm package carries client/share/ledger/devbox-trace-hook.mjs" \
    grep -qF '"path": "client/share/ledger/devbox-trace-hook.mjs"' <<<"$pack"
else
  _fail "npm pack --dry-run lists the package" "npm pack --dry-run failed in $REPO"
fi

# ── real vitest installs, when named ─────────────────────────────────────────

if [ -n "${DEVBOX_TEST_VITEST_INSTALLS-}" ]; then
  for install in $DEVBOX_TEST_VITEST_INSTALLS; do
    version="$(node -e 'console.log(require(process.argv[1]).version)' "$install/node_modules/vitest/package.json" 2>/dev/null)"
    if [ -z "$version" ]; then
      _fail "a vitest install at $install" "it holds no node_modules/vitest/package.json"
      continue
    fi
    for pool in forks threads; do
      R="$TMP/real-$version-$pool"
      mkdir -p "$R/.devbox" "$R/src" "$R/data" "$R/trace"
      : >"$R/.devbox/config.env"
      ln -s "$install/node_modules" "$R/node_modules"
      printf '{"x":1}\n' >"$R/data/data.json"
      printf "import { readFileSync } from 'node:fs';\nexport const data = JSON.parse(readFileSync('data/data.json', 'utf8'));\n" >"$R/src/helper.ts"
      for t in a b; do
        printf "import { test, expect } from 'vitest';\nimport { data } from './helper';\ntest('x', () => { expect(data.x).toBe(1); });\n" >"$R/src/$t.test.ts"
      done
      # isolate: false on one worker (--no-file-parallelism, which vitest 2 to 4
      # accept; vitest 2 refuses --maxWorkers=1 alone): the second file gets the
      # helper from the module cache.
      (cd "$R" && DEVBOX_TRACE_DIR="$R/trace" NODE_OPTIONS="--import=$HOOK" \
        "$install/node_modules/.bin/vitest" run --pool="$pool" --no-isolate --no-file-parallelism \
        --reporter=default --reporter="$TOOLS/vitest-ledger.mjs" >"$R/out" 2>&1)
      rc=$?
      assert_eq "0" "$rc" "real vitest $version $pool: the run passes: $(grep -m1 -i error "$R/out")"
      RT="$(traces "$R/trace")"
      for t in a b; do
        assert_ok "D1 real vitest $version $pool isolate false: src/$t.test.ts lists the data file its helper reads" \
          has_line "$RT" $'read\tsrc/'"$t"$'.test.ts\tdata/data.json'
      done

      # A5: the handoff of section 5.7 under real vitest, one test file per case.
      R="$TMP/real-$version-$pool-handoff"
      mkdir -p "$R/.devbox" "$R/src" "$R/data" "$R/trace"
      : >"$R/.devbox/config.env"
      ln -s "$install/node_modules" "$R/node_modules"
      for f in worker fork node eval sh-node; do printf '%s\n' "$f" >"$R/data/$f.txt"; done
      cp "$PROJ/src/reader.mjs" "$PROJ/src/child.mjs" "$R/src/"
      cat >"$R/src/w.test.ts" <<'TS'
import { test, expect } from 'vitest';
import { Worker } from 'node:worker_threads';
import path from 'node:path';
test('a Worker reads a data file, then the test terminates it', async () => {
  const w = new Worker(path.resolve('src/reader.mjs'), { workerData: { file: 'data/worker.txt', hold: true } });
  const m = await new Promise((ok, no) => w.once('message', ok).once('error', no));
  await w.terminate();
  expect(m).toEqual({ leak: false });
});
TS
      cat >"$R/src/f.test.ts" <<'TS'
import { test, expect } from 'vitest';
import { fork } from 'node:child_process';
import path from 'node:path';
test('a forked child reads a data file', async () => {
  const code = await new Promise((ok) => fork(path.resolve('src/child.mjs'), ['data/fork.txt']).on('exit', ok));
  expect(code).toBe(0);
});
TS
      cat >"$R/src/n.test.ts" <<'TS'
import { test } from 'vitest';
import { execFileSync } from 'node:child_process';
test('a node child reads a data file', () => {
  execFileSync(process.execPath, ['src/child.mjs', 'data/node.txt']);
});
TS
      cat >"$R/src/e.test.ts" <<'TS'
import { test } from 'vitest';
import { Worker } from 'node:worker_threads';
test('an eval Worker reads a data file', async () => {
  await new Promise((ok, no) => new Worker("require('node:fs').readFileSync('data/eval.txt')", { eval: true }).on('exit', ok).on('error', no));
});
TS
      cat >"$R/src/s.test.ts" <<'TS'
import { test } from 'vitest';
import { execSync } from 'node:child_process';
test('node under a shell reads a data file', () => {
  execSync('node src/child.mjs data/sh-node.txt');
});
TS
      (cd "$R" && DEVBOX_TRACE_DIR="$R/trace" NODE_OPTIONS="--import=$HOOK" \
        "$install/node_modules/.bin/vitest" run --pool="$pool" --reporter=default >"$R/out" 2>&1)
      rc=$?
      assert_eq "0" "$rc" "A5 real vitest $version $pool: the handoff run passes: $(grep -m1 -i error "$R/out")"
      RT="$(traces "$R/trace")"
      RR="$(resolve "$RT")"
      for c in w:worker:worker_threads f:fork:child_process n:node:child_process; do
        IFS=: read -r t data reason <<<"$c"
        assert_ok "A5 real vitest $version $pool: src/$t.test.ts holds the read of data/$data.txt" \
          has_line "$RT" $'read\tsrc/'"$t"$'.test.ts\tdata/'"$data"'.txt'
        assert_ok "A5 real vitest $version $pool: src/$t.test.ts has its $reason token confirmed" \
          confirmed "$RT" "src/$t.test.ts" "$reason"
        assert_eq "" "$(reasons "$RR" "src/$t.test.ts")" "A5 real vitest $version $pool: src/$t.test.ts is complete"
      done
      assert_eq "worker_threads" "$(reasons "$RR" src/e.test.ts)" "A5 real vitest $version $pool: an eval Worker leaves its file partial"
      assert_eq "child_process" "$(reasons "$RR" src/s.test.ts)" "A5 real vitest $version $pool: node under a shell leaves its file partial"

      # A5: two files share one Worker under isolate: false. The file that
      # starts it is complete, and the other is partial with shared worker.
      R="$TMP/real-$version-$pool-shared"
      mkdir -p "$R/.devbox" "$R/src" "$R/data" "$R/trace"
      : >"$R/.devbox/config.env"
      ln -s "$install/node_modules" "$R/node_modules"
      cp "$PROJ/src/pool.mjs" "$PROJ/src/pool-worker.mjs" "$R/src/"
      for t in a b; do
        printf '%s\n' "$t" >"$R/data/$t.txt"
        printf "import { test } from 'vitest';\nimport { readThrough } from './pool.mjs';\ntest('reads through the shared Worker', async () => { await readThrough('data/%s.txt'); });\n" "$t" >"$R/src/$t.test.ts"
      done
      (cd "$R" && DEVBOX_TRACE_DIR="$R/trace" NODE_OPTIONS="--import=$HOOK" \
        "$install/node_modules/.bin/vitest" run --pool="$pool" --no-isolate --no-file-parallelism \
        --reporter=default >"$R/out" 2>&1)
      rc=$?
      assert_eq "0" "$rc" "A5 real vitest $version $pool: the shared Worker run passes: $(grep -m1 -i error "$R/out")"
      RT="$(traces "$R/trace")"
      first="$(awk -F'\t' '$1 == "partial" && $3 == "worker_threads" && NF == 4 { print $2 }' <<<"$RT")"
      case "$first" in
        src/a.test.ts) later=src/b.test.ts ;;
        src/b.test.ts) later=src/a.test.ts ;;
        *) later="" ;;
      esac
      assert_ok "A5 real vitest $version $pool isolate false: one file started the shared Worker ($first)" test -n "$later"
      assert_ok "A5 real vitest $version $pool isolate false: the file that started the Worker is complete" \
        test -n "$first" -a -z "$(reasons "$(resolve "$RT")" "$first")"
      assert_ok "A5 real vitest $version $pool isolate false: the later file $later is partial with shared worker" \
        has_line "$RT" $'partial\t'"$later"$'\tshared worker'
    done
  done
else
  echo "  real vitest: DEVBOX_TEST_VITEST_INSTALLS is unset, so no real vitest ran; the fakes above drove the hook and the reporter"
fi

printf '%d %d\n' "$TESTS_RUN" "$TESTS_FAILED"
