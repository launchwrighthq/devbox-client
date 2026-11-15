#!/bin/bash
# The vitest half of the read trace: docs/specs/2026-11-14-learned-selection-design.md
# sections 5.2, 5.4 and 5.6, and row D1 of its section 15 for vitest.
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
# hold node_modules/vitest, also runs one real fixture per install and pool.
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
# The hook's module reads, as a worker that loaded the helper once left them.
printf 'read\tsrc/helper.ts\tdata/data.json\nlist\tsrc/util.ts\tfixtures\n' >"$TMP/g2/vitest-1.modules"
cp "$TMP/g2/vitest-1.modules" "$TMP/g3/"
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
    done
  done
else
  echo "  real vitest: DEVBOX_TEST_VITEST_INSTALLS is unset, so no real vitest ran; the fakes above drove the hook and the reporter"
fi

printf '%d %d\n' "$TESTS_RUN" "$TESTS_FAILED"
