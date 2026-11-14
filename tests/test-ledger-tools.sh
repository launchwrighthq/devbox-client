#!/bin/bash
# The three ledger tools a gate command wires in: the step helper, the vitest
# reporter and the pytest plugin. docs/specs/2026-11-13-resumable-gates-design.md
# sections 3.3 and 4.1 hold the contract, and rows D1, D2 and D4 of its section 10.
#
# The risk this file guards is a writer that records `pass` for a unit that did
# not finish: a resume then skips it, and the gate goes green on code that never
# ran. Each writer is therefore stopped mid-unit, and the unit must run again.
#
# node and python3 are required. A missing one FAILS this file, because a test
# file that skipped its writers and stayed green is this repository's recorded
# failure. The vitest reporter is driven through fake vitest objects of the two
# reporter shapes it supports, so no vitest install is needed. The pytest plugin
# is driven through fake pytest objects always, and through a real
# `python3 -m pytest` as well when pytest is importable; the output names which.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
# shellcheck source=tests/lib.sh
source ./lib.sh
REPO="$(cd .. && pwd)"
TOOLS="$REPO/client/share/ledger"
STEP="$TOOLS/devbox-ledger"

TMP="$(mktemp -d)" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
unset DEVBOX_LEDGER DEVBOX_RESUME DEVBOX_LEDGER_TOOLS
# Importing devbox_ledger from client/share/ledger would write a __pycache__
# beside it, inside the payload both packages ship.
export PYTHONDONTWRITEBYTECODE=1

# The outcomes of one unit, in ledger order, space-joined: "start pass".
# step_outcomes <ledger> <name>; file_outcomes <ledger> <runner> <path>.
step_outcomes() {
  LEDGER_NAME="$2" awk -F '\t' '$1 == "step" && $2 == ENVIRON["LEDGER_NAME"] { o = o (o == "" ? "" : " ") $3 } END { print o }' "$1"
}
file_outcomes() {
  LEDGER_RUNNER="$2" LEDGER_PATH="$3" awk -F '\t' '
    $1 == "file" && $2 == ENVIRON["LEDGER_RUNNER"] && $3 == ENVIRON["LEDGER_PATH"] { o = o (o == "" ? "" : " ") $4 }
    END { print o }' "$1"
}
# The value of key=<json string> in a driver's output, as the JSON text.
val() { sed -n "s/^$2=//p" "$1"; }
new_ledger() { printf 'key\t%s\nresume\t0\n' 0123456789abcdef >"$1"; }

# ── prerequisites ────────────────────────────────────────────────────────────

for tool in node python3; do
  if command -v "$tool" >/dev/null 2>&1; then
    _pass "$tool is on PATH"
  else
    _fail "$tool is on PATH" "the ledger tools' tests need $tool; a missing one fails this file, never skips it"
  fi
done

assert_ok "devbox-ledger is executable" test -x "$STEP"
assert_ok "vitest-ledger.mjs is in the payload" test -f "$TOOLS/vitest-ledger.mjs"
assert_ok "ledger-core.mjs is in the payload" test -f "$TOOLS/ledger-core.mjs"
assert_ok "devbox_ledger.py is in the payload" test -f "$TOOLS/devbox_ledger.py"

# ── row D4: both packages carry client/share/ledger ──────────────────────────
#
# Neither manifest names the tools. Each ships client/ whole, and these two
# lines are what put client/share/ledger in the npm package and the wheel.
npm_client="$(awk '/"files": \[/ { f = 1; next } f && /\]/ { f = 0 } f' "$REPO/package.json" | grep -c '"client/"')"
assert_eq "1" "$npm_client" "package.json files names client/, so the npm package carries client/share/ledger"
wheel_client="$(awk '/^\[tool\.hatch\.build\.targets\.wheel\.force-include\]/ { f = 1; next } /^\[/ { f = 0 } f' "$REPO/pyproject.toml" | grep -c '^"client" = ')"
assert_eq "1" "$wheel_client" "pyproject.toml force-includes client, so the wheel carries client/share/ledger"

# The manifest lines above prove the intent. npm's own file list proves the
# result, file by file: a `files` entry, an .npmignore or an ignore rule npm
# applies by default can drop one file of a directory that the manifest names.
# --dry-run builds no tarball and reaches no registry. npm ships with node,
# which this file already requires, so a missing npm fails here and never skips.
if pack="$(cd "$REPO" && npm pack --dry-run --json --ignore-scripts 2>/dev/null)"; then
  _pass "npm pack --dry-run lists the package"
else
  _fail "npm pack --dry-run lists the package" "npm pack --dry-run failed in $REPO, so the npm payload cannot be read"
  pack=""
fi
for name in devbox-ledger vitest-ledger.mjs ledger-core.mjs devbox_ledger.py; do
  assert_ok "D4: the npm package carries client/share/ledger/$name" \
    grep -qF "\"path\": \"client/share/ledger/$name\"" <<<"$pack"
done

# ── the step helper ──────────────────────────────────────────────────────────

RUNS="$TMP/runs"
L="$TMP/step.ledger"
new_ledger "$L"
# note <word> [<rc>] appends the word to $RUNS and exits rc, so a test sees which
# step commands ran. note-stop appends and then kills its parent, the helper.
export LEDGER_TEST_RUNS="$RUNS"
NOTE="$TMP/note"
cat >"$NOTE" <<'SH'
#!/bin/sh
echo "$1" >>"$LEDGER_TEST_RUNS"
exit "${2:-0}"
SH
cat >"$TMP/note-stop" <<'SH'
#!/bin/sh
echo "$1" >>"$LEDGER_TEST_RUNS"
kill -9 "$PPID"
SH
chmod +x "$NOTE" "$TMP/note-stop"

# Outside devbox: no ledger, the command runs, its code comes back.
rc=0
(cd "$TMP" && "$STEP" step outside -- "$NOTE" outside 3) || rc=$?
assert_eq "3" "$rc" "with DEVBOX_LEDGER unset the command's own exit code comes back"
assert_eq "outside" "$(cat "$RUNS")" "with DEVBOX_LEDGER unset the command still runs"
: >"$RUNS"

export DEVBOX_LEDGER="$L"
rc=0
"$STEP" step build -- "$NOTE" build >/dev/null || rc=$?
assert_eq "0" "$rc" "a passing step exits 0"
assert_eq "start pass" "$(step_outcomes "$L" build)" "a passing step records start, then pass"
assert_ok "the pass record carries whole seconds" \
  grep -q $'^step\tbuild\tpass\t[0-9][0-9]*$' "$L"

rc=0
"$STEP" step lint -- "$NOTE" lint 5 >/dev/null || rc=$?
assert_eq "5" "$rc" "a failing step exits with the command's own code"
assert_eq "start fail" "$(step_outcomes "$L" lint)" "a failing step records start, then fail"

# A stop mid-step: the command kills the helper itself, as the watchdog's stop
# takes the whole gate down, so no line after `start` is ever written.
# bash reports the killed helper with a "Killed" line on the stderr of the shell
# that waited for it. The `:` keeps the subshell from replacing itself with the
# helper, so that shell is the subshell, whose stderr goes nowhere.
("$STEP" step typecheck -- "$TMP/note-stop" typecheck >/dev/null; :) 2>/dev/null
assert_eq "start" "$(step_outcomes "$L" typecheck)" "a step stopped mid-run stays start only"

# A name with a backslash is matched as written. awk -v would read `a\tb` as a
# tab and miss the step on resume.
"$STEP" step 'gen\tdocs' -- true >/dev/null
assert_eq "start pass" "$(step_outcomes "$L" 'gen\tdocs')" "a name holding a backslash is recorded verbatim"

lines_before="$(wc -l <"$L")"
: >"$RUNS"
export DEVBOX_RESUME=1
out="$("$STEP" step build -- "$NOTE" build)"; rc=$?
assert_eq "0" "$rc" "on resume a passed step exits 0"
assert_eq "" "$(cat "$RUNS")" "on resume a passed step does not run"
assert_eq "1" "$(printf '%s\n' "$out" | grep -c 'skipped step build')" "on resume a passed step prints one line saying it skipped"
"$STEP" step 'gen\tdocs' -- "$NOTE" gen >/dev/null
assert_eq "$lines_before" "$(wc -l <"$L")" "a skipped step writes no record"
"$STEP" step lint -- "$NOTE" lint >/dev/null
"$STEP" step typecheck -- "$NOTE" typecheck >/dev/null
assert_eq "lint typecheck" "$(paste -sd ' ' "$RUNS")" \
  "on resume the failed step and the step stopped mid-run run again, and no passed one does"
assert_eq "start fail start pass" "$(step_outcomes "$L" lint)" "the rerun of a failed step records its new outcome"
assert_eq "start start pass" "$(step_outcomes "$L" typecheck)" "the rerun of a stopped step records its new outcome"

: >"$RUNS"
export DEVBOX_RESUME=0
"$STEP" step build -- "$NOTE" build >/dev/null
assert_eq "build" "$(cat "$RUNS")" "with DEVBOX_RESUME=0 a passed step runs, because only a resume skips"
unset DEVBOX_RESUME

# The refusals: exit 2 and a `devbox-ledger:` line, before the command runs.
: >"$RUNS"
lines_before="$(wc -l <"$L")"
err="$("$STEP" step $'type\tcheck' -- "$NOTE" ran 2>&1 >/dev/null)"; rc=$?
assert_eq "2" "$rc" "a step name holding a tab is refused with exit 2"
assert_eq "1" "$(printf '%s\n' "$err" | grep -c '^devbox-ledger: ')" "the tab refusal names devbox-ledger"
rc=0
"$STEP" step $'type\ncheck' -- "$NOTE" ran >/dev/null 2>&1 || rc=$?
assert_eq "2" "$rc" "a step name holding a newline is refused with exit 2"
rc=0
"$STEP" step '' -- "$NOTE" ran >/dev/null 2>&1 || rc=$?
assert_eq "2" "$rc" "an empty step name is refused with exit 2"
rc=0
"$STEP" step build "$NOTE" ran >/dev/null 2>&1 || rc=$?
assert_eq "2" "$rc" "a call without -- is refused with exit 2"
assert_eq "" "$(cat "$RUNS")" "no refused command ran"
assert_eq "$lines_before" "$(wc -l <"$L")" "no refused call wrote a record"

rc=0
DEVBOX_LEDGER="$TMP/no-such-dir/x.ledger" "$STEP" step build -- "$NOTE" ran >/dev/null 2>&1 || rc=$?
assert_eq "2" "$rc" "a ledger that cannot be written stops the step with exit 2"
assert_eq "" "$(cat "$RUNS")" "and the command did not run unrecorded"
unset DEVBOX_LEDGER

# ── ledger-core.mjs under plain node ─────────────────────────────────────────

mkdir -p "$TMP/proj/.devbox" "$TMP/proj/apps/web/src" "$TMP/plain/apps/web"
: >"$TMP/proj/.devbox/config.env"
PROJ="$(cd "$TMP/proj" && pwd -P)"

{
  printf 'key\t0123456789abcdef\nresume\t1\n'
  printf 'file\tvitest\tsrc/a.test.ts\tstart\n'
  printf 'file\tpytest\ttests/test_p.py\tstart\n'
  printf 'file\tvitest\tsrc/b.test.ts\tstart\n'
  printf 'file\tvitest\tsrc/c.test.ts\tstart\n'
  printf 'file\tvitest\tsrc/a.test.ts\tpass\t4\n'
  printf 'file\tvitest\tsrc/b.test.ts\tfail\t2\n'
  printf 'file\tpytest\ttests/test_p.py\tpass\t1\n'
  printf 'file\tvitest\tsrc/d.test.ts\tstart\nfile\tvitest\tsrc/d.test.ts\tfail\t1\n'
  printf 'file\tvitest\tsrc/d.test.ts\tstart\nfile\tvitest\tsrc/d.test.ts\tpass\t1\n'
  printf 'file\tvitest\tsrc/e.test.ts\tpass\t1\nfile\tvitest\tsrc/e.test.ts\tstart\n'
  printf 'step\tsrc/f.test.ts\tpass\t1\n'
} >"$TMP/mixed.ledger"
{
  printf 'file\tvitest\tapps/web/src/x.test.ts\tpass\t1\n'
  printf 'file\tvitest\tapps/api/src/x.test.ts\tpass\t1\n'
  printf 'file\tvitest\tapps/web/app/[id]/page.test.ts\tpass\t1\n'
} >"$TMP/mono.ledger"

cat >"$TMP/core-driver.mjs" <<'JS'
import { pathToFileURL } from 'node:url';
import fs from 'node:fs';
import path from 'node:path';
const [tools, tmp, proj] = process.argv.slice(2);
const core = await import(pathToFileURL(path.join(tools, 'ledger-core.mjs')).href);
const out = (k, v) => process.stdout.write(`${k}=${JSON.stringify(v)}\n`);
const refused = (fn) => { try { fn(); return 'no'; } catch (e) { return e.message.startsWith('devbox-ledger:') ? 'yes' : e.message; } };

out('start_line', core.formatFileLine('vitest', 'src/a.test.ts', 'start'));
out('pass_line', core.formatFileLine('vitest', 'src/a.test.ts', 'pass', 3));
out('tab_refused', refused(() => core.formatFileLine('vitest', 'src/a\tb.test.ts', 'start')));
out('newline_refused', refused(() => core.formatFileLine('vitest', 'src/a\nb.test.ts', 'start')));
const mixed = fs.readFileSync(path.join(tmp, 'mixed.ledger'), 'utf8');
out('passed_vitest', core.passedFiles(mixed, 'vitest').sort().join(' '));
out('passed_pytest', core.passedFiles(mixed, 'pytest').sort().join(' '));
const mono = fs.readFileSync(path.join(tmp, 'mono.ledger'), 'utf8');
out('exclude', core.excludePatterns(mono, 'vitest', '/p', '/p/apps/web').join(' '));
out('root', core.findProjectRoot(path.join(proj, 'apps', 'web')));
out('root_none', core.findProjectRoot(path.join(tmp, 'plain', 'apps', 'web')));

let t = 0;
const ledger = path.join(tmp, 'recorder.ledger');
const rec = new core.FileRecorder({ ledger, runner: 'vitest', root: proj, now: () => t });
const f = (name) => path.join(proj, 'src', name);
rec.begin('k1', f('a.test.ts')); t = 2000; rec.end('k1', 'pass');
rec.begin('k2', f('b.test.ts')); rec.begin('k3', f('b.test.ts')); rec.end('k2', 'pass'); rec.end('k3', 'fail');
rec.begin('k4', f('c.test.ts'));
rec.begin('k5', f('d.test.ts')); rec.end('k5', null);
rec.end('k1', 'fail');
rec.begin('k1', f('a.test.ts'));
const warned = [];
const rec2 = new core.FileRecorder({ ledger, runner: 'vitest', root: proj, warn: (m) => warned.push(m) });
rec2.begin('k6', f('tab\there.test.ts')); rec2.end('k6', 'pass');
out('tab_warned', warned.length === 1 && warned[0].startsWith('devbox-ledger:') ? 'yes' : warned.join('|'));
out('recorder_passed', core.passedFiles(fs.readFileSync(ledger, 'utf8'), 'vitest').join(' '));
JS

node "$TMP/core-driver.mjs" "$TOOLS" "$TMP" "$PROJ" >"$TMP/core.out" 2>"$TMP/core.err"; rc=$?
assert_eq "0" "$rc" "the ledger-core driver runs under plain node: $(head -3 "$TMP/core.err")"
C="$TMP/core.out"
assert_eq '"file\tvitest\tsrc/a.test.ts\tstart\n"' "$(val "$C" start_line)" "a start line is file, runner, path, start"
assert_eq '"file\tvitest\tsrc/a.test.ts\tpass\t3\n"' "$(val "$C" pass_line)" "a pass line carries whole seconds"
assert_eq '"yes"' "$(val "$C" tab_refused)" "a path holding a tab is refused by name"
assert_eq '"yes"' "$(val "$C" newline_refused)" "a path holding a newline is refused by name"
assert_eq '"src/a.test.ts src/d.test.ts"' "$(val "$C" passed_vitest)" \
  "passed files: a pass, a fail then pass; never a fail, a start only, a start after a pass, a step or another runner's file"
assert_eq '"tests/test_p.py"' "$(val "$C" passed_pytest)" "the pytest records are a separate runner"
assert_eq '"src/x.test.ts app/\\[id\\]/page.test.ts"' "$(val "$C" exclude)" \
  "exclude patterns are relative to the vitest root, leave out another app's file of the same name, and escape glob characters"
assert_eq "\"$PROJ\"" "$(val "$C" root)" "the project root is the nearest directory holding .devbox/config.env"
assert_eq "\"$(cd "$TMP/plain/apps/web" && pwd -P)\"" "$(val "$C" root_none)" "with no .devbox/config.env above, the start directory is the root"

R="$TMP/recorder.ledger"
assert_eq "start pass" "$(file_outcomes "$R" vitest src/a.test.ts)" "the recorder writes start, then pass, and ignores a second end of one run"
assert_ok "the recorder's pass carries the elapsed whole seconds" grep -q $'^file\tvitest\tsrc/a.test.ts\tpass\t2$' "$R"
assert_eq "start fail" "$(file_outcomes "$R" vitest src/b.test.ts)" "two runs of one path in flight write one start and fail when either fails"
assert_eq "start" "$(file_outcomes "$R" vitest src/c.test.ts)" "a module still running at the stop stays start only"
assert_eq "start" "$(file_outcomes "$R" vitest src/d.test.ts)" "a skipped module writes no end, so it runs again"
assert_eq '"yes"' "$(val "$C" tab_warned)" "a test path holding a tab is named in a warning and not recorded"
assert_eq '"src/a.test.ts"' "$(val "$C" recorder_passed)" "after a stop mid-run only the finished passing file counts as passed"

# ── vitest-ledger.mjs through fake vitest objects ────────────────────────────
#
# vitest 2 calls onTaskUpdate with [id, result] packs and a File task per test
# module; vitest 3 and later call onTestModuleStart and onTestModuleEnd with a
# TestModule, and still call onTaskUpdate too. The fakes carry only the fields
# the reporter reads.

cat >"$TMP/reporter-driver.mjs" <<'JS'
import { pathToFileURL } from 'node:url';
import fs from 'node:fs';
import path from 'node:path';
const [tools, tmp, proj] = process.argv.slice(2);
const mod = await import(pathToFileURL(path.join(tools, 'vitest-ledger.mjs')).href);
const Reporter = mod.default;
const out = (k, v) => process.stdout.write(`${k}=${JSON.stringify(v)}\n`);
const web = path.join(proj, 'apps', 'web');
const src = (name) => path.join(web, 'src', name);

process.env.DEVBOX_LEDGER = path.join(tmp, 'v5.ledger');
const r5 = new Reporter();
r5.onInit({ version: '5.1.0', config: { root: web } });
const m = (file, state, project = '') => ({ moduleId: src(file), project: { name: project }, state: () => state });
r5.onTestModuleStart(m('a.test.ts', 'pending'));
r5.onTaskUpdate([['any-id', { state: 'run' }]]);
r5.onTestModuleEnd(m('a.test.ts', 'passed'));
r5.onTestModuleStart(m('b.test.ts', 'pending'));
r5.onTestModuleEnd(m('b.test.ts', 'failed'));
r5.onTestModuleStart(m('c.test.ts', 'pending'));
r5.onTestModuleEnd(m('e.test.ts', 'failed'));
r5.onTestModuleStart(m('s.test.ts', 'pending'));
r5.onTestModuleEnd(m('s.test.ts', 'skipped'));

process.env.DEVBOX_LEDGER = path.join(tmp, 'v2.ledger');
const file = (id, name) => { const t = { id, type: 'suite', filepath: src(name) }; t.file = t; return t; };
const fa = file('fa', 'a.test.ts'); const fb = file('fb', 'b.test.ts'); const fc = file('fc', 'c.test.ts');
const t1 = { id: 't1', type: 'test', file: fa };
const idMap = new Map([[fa.id, fa], [fb.id, fb], [fc.id, fc], [t1.id, t1]]);
const r2 = new Reporter();
r2.onInit({ version: '2.1.9', config: { root: web }, state: { idMap } });
r2.onTaskUpdate([['fa', { state: 'run' }], ['t1', { state: 'run' }]]);
r2.onTaskUpdate([['t1', { state: 'pass' }], ['fa', { state: 'pass' }]]);
r2.onTaskUpdate([['fb', { state: 'fail' }]]);
r2.onTaskUpdate([['fc', { state: 'run' }]]);
r2.onTaskUpdate([['fa', { state: 'pass' }]]);

delete process.env.DEVBOX_LEDGER;
const r0 = new Reporter();
r0.onInit({ version: '5.1.0', config: { root: web } });
r0.onTestModuleStart(m('a.test.ts', 'pending'));
r0.onTestModuleEnd(m('a.test.ts', 'passed'));
r0.onTaskUpdate([['fa', { state: 'pass' }]]);
out('unset_ok', 'yes');

process.env.DEVBOX_LEDGER = path.join(tmp, 'v5.ledger');
process.env.DEVBOX_RESUME = '1';
out('helper_resume', mod.passedFiles(web).join(' '));
out('helper_cwd', (process.chdir(web), mod.passedFiles()).join(' '));
process.env.DEVBOX_RESUME = '0';
out('helper_fresh', mod.passedFiles(web).join(' '));
process.env.DEVBOX_RESUME = '1';
process.env.DEVBOX_LEDGER = path.join(tmp, 'missing.ledger');
out('helper_missing', mod.passedFiles(web).join(' '));
JS

node "$TMP/reporter-driver.mjs" "$TOOLS" "$TMP" "$PROJ" >"$TMP/reporter.out" 2>"$TMP/reporter.err"; rc=$?
assert_eq "0" "$rc" "the reporter driver runs under plain node: $(head -3 "$TMP/reporter.err")"
V5="$TMP/v5.ledger"
assert_eq "start pass" "$(file_outcomes "$V5" vitest apps/web/src/a.test.ts)" \
  "vitest 3+: module start and end write start and pass, relative to the project root, and onTaskUpdate adds nothing"
assert_eq "start fail" "$(file_outcomes "$V5" vitest apps/web/src/b.test.ts)" "vitest 3+: a failed module writes fail"
assert_eq "start" "$(file_outcomes "$V5" vitest apps/web/src/c.test.ts)" "vitest 3+: a module running at the stop stays start only"
assert_eq "start fail" "$(file_outcomes "$V5" vitest apps/web/src/e.test.ts)" "vitest 3+: a module that failed on import, an end with no start, writes start and fail"
assert_eq "start" "$(file_outcomes "$V5" vitest apps/web/src/s.test.ts)" "vitest 3+: a skipped module writes no end"
V2="$TMP/v2.ledger"
assert_eq "start pass" "$(file_outcomes "$V2" vitest apps/web/src/a.test.ts)" \
  "vitest 2: a File task's run and pass write start and pass, a test task and a repeated pack add nothing"
assert_eq "start fail" "$(file_outcomes "$V2" vitest apps/web/src/b.test.ts)" "vitest 2: a fail that arrives with no run before it writes start and fail"
assert_eq "start" "$(file_outcomes "$V2" vitest apps/web/src/c.test.ts)" "vitest 2: a module running at the stop stays start only"
assert_eq "5" "$(grep -c . "$V2")" "vitest 2: no other line was written"
O="$TMP/reporter.out"
assert_eq '"yes"' "$(val "$O" unset_ok)" "with DEVBOX_LEDGER unset the reporter writes nothing and throws nothing"
assert_eq '"src/a.test.ts"' "$(val "$O" helper_resume)" "passedFiles() on a resume names the passed file relative to the vitest root"
assert_eq '"src/a.test.ts"' "$(val "$O" helper_cwd)" "passedFiles() with no argument reads the root from the working directory"
assert_eq '""' "$(val "$O" helper_fresh)" "passedFiles() outside a resume is empty"
assert_eq '""' "$(val "$O" helper_missing)" "passedFiles() on a resume with no ledger file is empty, so every file runs"

# ── devbox_ledger.py through fake pytest objects ─────────────────────────────

cat >"$TMP/plugin-driver.py" <<'PY'
import os
import sys

tools, tmp, proj = sys.argv[1:4]
sys.path.insert(0, tools)
import devbox_ledger  # noqa: E402

for name in ("DEVBOX_LEDGER", "DEVBOX_RESUME"):
    os.environ.pop(name, None)


def out(key, value):
    sys.stdout.write("%s=%s\n" % (key, value))


class Hook:
    def __init__(self):
        self.deselected = []

    def pytest_deselected(self, items):
        self.deselected.extend(item.nodeid for item in items)


class PluginManager:
    def __init__(self):
        self.registered = []

    def register(self, plugin, name):
        self.registered.append(plugin)


class Config:
    def __init__(self, rootpath, worker=False):
        self.rootpath = rootpath
        self.hook = Hook()
        self.pluginmanager = PluginManager()
        if worker:
            self.workerinput = {"workerid": "gw0"}


class Item:
    def __init__(self, nodeid):
        self.nodeid = nodeid


class Report:
    def __init__(self, nodeid, when, outcome="passed"):
        self.nodeid = nodeid
        self.when = when
        self.failed = outcome == "failed"


def plugin_for(config):
    devbox_ledger.pytest_configure(config)
    return config.pluginmanager.registered[0] if config.pluginmanager.registered else None


def run_test(plugin, nodeid, outcome="passed", phases=("setup", "call", "teardown")):
    for when in phases:
        plugin.pytest_runtest_logreport(Report(nodeid, when, outcome if when == "call" else "passed"))


root = os.path.join(proj, "py")
A = ["tests/test_a.py::test_one", "tests/test_a.py::test_two[x::y]"]
B = ["tests/test_b.py::test_one"]
C = ["tests/test_c.py::test_one", "tests/test_c.py::test_two"]

# DEVBOX_LEDGER unset: nothing registers.
config = Config(root)
plugin_for(config)
out("unset_registered", len(config.pluginmanager.registered))

# A first run, stopped during tests/test_c.py.
os.environ["DEVBOX_LEDGER"] = os.path.join(tmp, "py-run.ledger")
config = Config(root)
plugin = plugin_for(config)
items = [Item(n) for n in A + B + C]
plugin.pytest_collection_modifyitems(None, config, items)
run_test(plugin, A[0])
run_test(plugin, A[1])
run_test(plugin, B[0], "failed")
run_test(plugin, C[0])

# The resume: tests/test_a.py is deselected, b and c run whole.
os.environ["DEVBOX_RESUME"] = "1"
config = Config(root)
plugin = plugin_for(config)
items = [Item(n) for n in A + B + C]
plugin.pytest_collection_modifyitems(None, config, items)
out("resume_deselected", " ".join(config.hook.deselected))
out("resume_items", " ".join(item.nodeid for item in items))
run_test(plugin, B[0])
run_test(plugin, C[0])
run_test(plugin, C[1])
os.environ.pop("DEVBOX_RESUME")

# A rerun plugin sends a test's teardown twice: the file must not close early.
os.environ["DEVBOX_LEDGER"] = os.path.join(tmp, "py-rerun.ledger")
config = Config(root)
plugin = plugin_for(config)
plugin.pytest_collection_modifyitems(None, config, [Item(n) for n in C])
run_test(plugin, C[0])
run_test(plugin, C[0])

# xdist: a worker writes nothing, the controller counts from the ids a worker sent.
os.environ["DEVBOX_LEDGER"] = os.path.join(tmp, "py-xdist.ledger")
worker_config = Config(root, worker=True)
worker = plugin_for(worker_config)
worker.pytest_collection_modifyitems(None, worker_config, [Item(n) for n in A + C])
run_test(worker, A[0])
run_test(worker, A[1])
out("worker_wrote", "yes" if os.path.exists(os.environ["DEVBOX_LEDGER"]) else "no")
controller_config = Config(root)
controller = plugin_for(controller_config)
controller.pytest_xdist_node_collection_finished(None, A + C)
controller.pytest_xdist_node_collection_finished(None, A)
run_test(controller, A[1])
run_test(controller, C[0])
run_test(controller, A[0])
run_test(controller, C[1], "failed")

# A crashed worker's report has no teardown phase, so its file stays open.
os.environ["DEVBOX_LEDGER"] = os.path.join(tmp, "py-crash.ledger")
config = Config(root)
plugin = plugin_for(config)
plugin.pytest_collection_modifyitems(None, config, [Item(n) for n in B])
plugin.pytest_runtest_logreport(Report(B[0], "???", "failed"))

# Python 3.8 syntax: the plugin runs in whatever interpreter a workspace holds.
import ast  # noqa: E402

with open(os.path.join(tools, "devbox_ledger.py"), encoding="utf-8") as handle:
    ast.parse(handle.read(), feature_version=(3, 8))
out("py38", "yes")
PY

mkdir -p "$PROJ/py/tests"
python3 "$TMP/plugin-driver.py" "$TOOLS" "$TMP" "$PROJ" >"$TMP/plugin.out" 2>"$TMP/plugin.err"; rc=$?
assert_eq "0" "$rc" "the pytest plugin driver runs under plain python3: $(tail -3 "$TMP/plugin.err")"
P="$TMP/plugin.out"
echo "  pytest plugin: driven through fake pytest objects"
assert_eq "0" "$(val "$P" unset_registered)" "with DEVBOX_LEDGER unset the plugin registers nothing"
PR="$TMP/py-run.ledger"
assert_eq "start pass" "$(file_outcomes "$PR" pytest py/tests/test_a.py)" \
  "a file whose last collected test reported writes pass, relative to the project root"
assert_eq "start fail start pass" "$(file_outcomes "$PR" pytest py/tests/test_b.py)" \
  "a file with a failed test writes fail, and runs again on the resume"
assert_eq "start start pass" "$(file_outcomes "$PR" pytest py/tests/test_c.py)" \
  "a file stopped mid-run stays start only, and runs again whole on the resume"
assert_eq "tests/test_a.py::test_one tests/test_a.py::test_two[x::y]" "$(val "$P" resume_deselected)" \
  "on resume every item of the passed file is handed to pytest_deselected"
assert_eq "tests/test_b.py::test_one tests/test_c.py::test_one tests/test_c.py::test_two" "$(val "$P" resume_items)" \
  "on resume the failed file and the stopped file stay selected, every test of each"
assert_eq "start" "$(file_outcomes "$TMP/py-rerun.ledger" pytest py/tests/test_c.py)" \
  "a teardown reported twice for one test does not close its file early"
assert_eq "no" "$(val "$P" worker_wrote)" "an xdist worker writes no record"
PX="$TMP/py-xdist.ledger"
assert_eq "start pass" "$(file_outcomes "$PX" pytest py/tests/test_a.py)" "the xdist controller writes pass from the reports it receives"
assert_eq "start fail" "$(file_outcomes "$PX" pytest py/tests/test_c.py)" "the xdist controller writes fail for interleaved reports with one failure"
assert_eq "start" "$(file_outcomes "$TMP/py-crash.ledger" pytest py/tests/test_b.py)" "a crashed worker's file stays start only"
assert_eq "yes" "$(val "$P" py38)" "devbox_ledger.py parses as Python 3.8"

# ── devbox_ledger.py under a real pytest, when one is importable ─────────────

if python3 -c 'import pytest' >/dev/null 2>&1; then
  echo "  pytest plugin: also driven by a real python3 -m pytest $(python3 -c 'import pytest; print(pytest.__version__)')"
  PY="$PROJ/real"
  mkdir -p "$PY/tests"
  : >"$PY/pytest.ini"
  cat >"$PY/tests/conftest.py" <<'PYC'
import os


def pytest_runtest_call(item):
    with open(os.environ["LEDGER_TEST_LOG"], "a") as handle:
        handle.write(item.nodeid + "\n")
PYC
  printf 'def test_one():\n    pass\n\n\ndef test_two():\n    pass\n' >"$PY/tests/test_a.py"
  printf 'def test_one():\n    assert False\n' >"$PY/tests/test_b.py"
  cat >"$PY/tests/test_c.py" <<'PYC'
import os
import signal


def test_one():
    pass


def test_two():
    if os.environ.get("LEDGER_KILL") == "1":
        os.kill(os.getpid(), signal.SIGKILL)
PYC
  RL="$TMP/real.ledger"
  new_ledger "$RL"
  export LEDGER_TEST_LOG="$TMP/real-run1.log"
  # The `:` keeps bash's "Killed" report inside the silenced subshell, as above.
  (cd "$PY" && DEVBOX_LEDGER="$RL" LEDGER_KILL=1 PYTHONPATH="$TOOLS" \
    python3 -m pytest -q -p no:cacheprovider -p devbox_ledger tests >"$TMP/real1.out" 2>&1; :) 2>/dev/null
  assert_eq "start pass" "$(file_outcomes "$RL" pytest real/tests/test_a.py)" "real pytest: a passing file writes start, then pass"
  assert_eq "start fail" "$(file_outcomes "$RL" pytest real/tests/test_b.py)" "real pytest: a failing file writes start, then fail"
  assert_eq "start" "$(file_outcomes "$RL" pytest real/tests/test_c.py)" "real pytest: a file killed mid-run stays start only"
  export LEDGER_TEST_LOG="$TMP/real-run2.log"
  (cd "$PY" && DEVBOX_LEDGER="$RL" DEVBOX_RESUME=1 PYTHONPATH="$TOOLS" \
    python3 -m pytest -q -p no:cacheprovider -p devbox_ledger tests >"$TMP/real2.out" 2>&1)
  assert_eq "tests/test_b.py::test_one tests/test_c.py::test_one tests/test_c.py::test_two" \
    "$(paste -sd ' ' "$LEDGER_TEST_LOG")" "real pytest: the resume runs the failed and the killed file whole, and not the passed one"
  assert_ok "real pytest: the resume reports the passed file's two tests as deselected" grep -q '2 deselected' "$TMP/real2.out"
  assert_eq "start start pass" "$(file_outcomes "$RL" pytest real/tests/test_c.py)" "real pytest: the killed file passes on the resume"
  if python3 -c 'import xdist' >/dev/null 2>&1; then
    echo "  pytest plugin: also driven under pytest-xdist"
    XL="$TMP/xdist.ledger"
    new_ledger "$XL"
    export LEDGER_TEST_LOG="$TMP/xdist.log"
    (cd "$PY" && DEVBOX_LEDGER="$XL" PYTHONPATH="$TOOLS" \
      python3 -m pytest -q -p no:cacheprovider -p devbox_ledger -n 2 tests >"$TMP/xdist.out" 2>&1)
    assert_eq "start pass" "$(file_outcomes "$XL" pytest real/tests/test_a.py)" "real xdist: a passing file writes one start and one pass"
    assert_eq "start fail" "$(file_outcomes "$XL" pytest real/tests/test_b.py)" "real xdist: a failing file writes one start and one fail"
    assert_eq "start pass" "$(file_outcomes "$XL" pytest real/tests/test_c.py)" "real xdist: the third file writes one start and one pass"
  else
    echo "  pytest plugin: pytest-xdist is not importable; the fake controller and worker above cover xdist"
  fi
  unset LEDGER_TEST_LOG
else
  echo "  pytest plugin: pytest is not importable here, so only the fake objects above drove it"
fi

printf '%d %d\n' "$TESTS_RUN" "$TESTS_FAILED"
