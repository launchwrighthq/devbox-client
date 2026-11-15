// A vitest reporter that writes one ledger line per test module as it starts and
// as it ends, and passedFiles(), the files a resume leaves out of test.exclude.
// docs/specs/2026-11-13-resumable-gates-design.md sections 3.3 and 4.1 hold the
// contract. The ledger logic lives in ledger-core.mjs, which runs without vitest.
//
// A project wires both into its vitest config, as an instance:
//
//   const ledger = process.env.DEVBOX_LEDGER_TOOLS ? await import(`${process.env.DEVBOX_LEDGER_TOOLS}/vitest-ledger.mjs`) : null;
//   test: { exclude: [...configDefaults.exclude, ...(ledger ? ledger.passedFiles() : [])],
//           reporters: ['default', ...(ledger ? [new ledger.default()] : [])] }
//
// MEASURED with vitest 3.2: `--reporter=<path>` to this file failed at startup
// with "Failed to load custom Reporter", because vitest 3 loads a reporter path
// through vite-node, which did not load a module outside the project root, and
// DEVBOX_LEDGER_TOOLS is outside it. The same flag loaded on vitest 2, 4 and 5.
// The config imports the module with node's own import, which every major
// accepted.
//
// With DEVBOX_LEDGER unset the reporter writes nothing and passedFiles() is
// empty, so the same config also runs outside devbox.
//
// With DEVBOX_TRACE_DIR set, the reporter also writes the module graph of each
// test file when the run ends, as section 5.6 of
// docs/specs/2026-11-14-learned-selection-design.md defines the trace lines.
// devbox-trace-hook.mjs writes what each worker reads; the graph adds what each
// test file imports, because a worker fetches every module from the main
// process and never opens its source. Each of the two variables works alone.

import fs from 'node:fs';
import path from 'node:path';
import {
  FileRecorder, TraceBlockWriter, excludePatterns, findProjectRoot, graphTraceLines, moduleIdPath,
  readModuleReads, traceFileName, traceRoot,
} from './ledger-core.mjs';

const RUNNER = 'vitest';

// The files the ledger records as passed for vitest, as test.exclude patterns
// relative to root, the vitest root of the config that calls this. Empty unless
// DEVBOX_RESUME=1.
export function passedFiles(root = process.cwd()) {
  const ledger = process.env.DEVBOX_LEDGER;
  if (process.env.DEVBOX_RESUME !== '1' || !ledger) return [];
  let text;
  try {
    text = fs.readFileSync(ledger, 'utf8');
  } catch (err) {
    // A resume with no ledger file has no passed file: every file runs, which
    // is the safe direction. Any other read error stops the config loudly.
    if (err && err.code === 'ENOENT') return [];
    throw err;
  }
  return excludePatterns(text, RUNNER, findProjectRoot(root), root);
}

function majorOf(version) {
  const major = Number.parseInt(String(version ?? ''), 10);
  return Number.isFinite(major) ? major : 0;
}

// vitest 2 offers onTaskUpdate, whose packs carry each File task's state: `run`
// when the module starts, `pass` or `fail` when it ends. vitest 3 added
// onTestModuleStart and onTestModuleEnd, and vitest 3 to 5 still call
// onTaskUpdate as well, so one path is chosen per run: the module hooks from
// major 3, read from the Vitest instance in onInit, or from the first module
// hook call when the instance names no version. Either path alone writes each
// line once; both at once would write `start` twice for a module.
export default class DevboxLedgerReporter {
  constructor() {
    this.recorder = null;
    this.ctx = null;
    this.moduleHooks = false;
    this.traceDir = null;
    this.traced = false;
  }

  onInit(ctx) {
    this.ctx = ctx;
    this.traceDir = process.env.DEVBOX_TRACE_DIR || null;
    const ledger = process.env.DEVBOX_LEDGER;
    if (!ledger) return;
    const root = findProjectRoot(ctx?.config?.root ?? process.cwd());
    this.recorder = new FileRecorder({ ledger, runner: RUNNER, root });
    this.moduleHooks = majorOf(ctx?.version) >= 3;
  }

  // vitest 3 and later: the TestModules of the run. vitest 3 calls
  // onFinished too, and the graph is written once.
  onTestRunEnd(testModules) {
    if (!this.traceDir || this.traced) return;
    this.traced = true;
    writeGraph(this.ctx, this.traceDir, (testModules ?? []).map((m) => [m.moduleId, m.project]));
  }

  // vitest 2: the File tasks of the run, each naming its project by name.
  onFinished(files) {
    if (!this.traceDir || this.traced) return;
    this.traced = true;
    const projects = this.ctx?.projects ?? [];
    const byName = (name) => projects.find((p) => (typeof p.getName === 'function' ? p.getName() : p.name) === name);
    writeGraph(this.ctx, this.traceDir, (files ?? []).map((f) => [f.filepath, byName(f.projectName ?? '')]));
  }

  // vitest 3 and later.
  onTestModuleStart(testModule) {
    this.moduleHooks = true;
    if (!this.recorder) return;
    this.recorder.begin(moduleKey(testModule), testModule.moduleId);
  }

  onTestModuleEnd(testModule) {
    this.moduleHooks = true;
    if (!this.recorder) return;
    const key = moduleKey(testModule);
    // A module that failed on import is reported as an end with no start.
    this.recorder.begin(key, testModule.moduleId);
    const state = testModule.state();
    this.recorder.end(key, state === 'passed' ? 'pass' : state === 'failed' ? 'fail' : null);
  }

  // vitest 2. The runner batches updates for 10 ms and sends the File task's
  // current state, so a short module can arrive as `pass` with no `run` before
  // it: an end therefore begins the module first. A module still running when
  // the process is killed never reaches `pass`, so it stays `start`.
  onTaskUpdate(packs) {
    if (!this.recorder || this.moduleHooks) return;
    const idMap = this.ctx?.state?.idMap;
    // A reporter that cannot map a pack to its file would write no line, and
    // the gate would pass with a ledger that cannot resume it.
    if (!idMap) throw new Error('devbox-ledger: this vitest offers neither onTestModuleStart nor state.idMap, so no test file can be recorded');
    for (const pack of packs) {
      const [id, result] = pack;
      const task = idMap.get(id);
      if (!task || task.file !== task || typeof task.filepath !== 'string') continue;
      const state = result?.state;
      if (state === 'run') {
        this.recorder.begin(id, task.filepath);
      } else if (state === 'pass' || state === 'fail') {
        this.recorder.begin(id, task.filepath);
        this.recorder.end(id, state);
      } else if (state === 'skip' || state === 'todo') {
        this.recorder.end(id, null);
      }
    }
  }
}

function moduleKey(testModule) {
  return `${testModule.moduleId}\0${testModule.project?.name ?? ''}`;
}

// The Vite server of a vitest 2 project or Vitest instance is `server`, and of
// vitest 3 and 4 `vite`. Its `moduleGraph` answers for every environment the
// tests ran in: MEASURED with vitest 2, 3 and 4, the importedModules of
// a test file there named the helper it imports, in the forks and the threads
// pools.
function viteOf(x) {
  return x?.vite ?? x?.server ?? null;
}

function importedOf(graph) {
  return (abs) => {
    const out = [];
    const mods = new Set();
    const byId = graph?.getModuleById?.(abs);
    if (byId) mods.add(byId);
    for (const m of graph?.getModulesByFile?.(abs) ?? []) mods.add(m);
    for (const m of mods) {
      for (const dep of m.importedModules ?? []) {
        const p = moduleIdPath(dep.id ?? dep.file);
        if (p !== null) out.push(p);
      }
    }
    return out;
  };
}

// The files every test file of a project loads before its own imports: the
// project's config and the files the config imported, the root config and
// the workspace file of the Vitest instance, the setup files and the global
// setup files. A change to any of them can change every test of the project.
function projectEntries(ctx, project) {
  const out = [];
  for (const v of [viteOf(ctx), viteOf(project)]) {
    const c = v?.config;
    if (typeof c?.configFile === 'string') out.push(c.configFile);
    for (const dep of c?.configFileDependencies ?? []) out.push(path.resolve(dep));
  }
  // vitest 2 and 3 keep the workspace file they found in _workspaceConfigPath,
  // and config.workspace only when the command line named one.
  for (const workspace of [ctx?._workspaceConfigPath, ctx?.config?.workspace]) {
    if (typeof workspace === 'string') out.push(path.resolve(ctx.config?.root ?? process.cwd(), workspace));
  }
  const tc = project?.config ?? ctx?.config;
  for (const key of ['setupFiles', 'globalSetup']) {
    const v = tc?.[key];
    for (const f of Array.isArray(v) ? v : typeof v === 'string' ? [v] : []) {
      if (typeof f === 'string') out.push(path.resolve(tc.root ?? process.cwd(), f));
    }
  }
  return out;
}

// One test file at a time, with the lines of every project that ran it in one
// set, so each line is written once and no set outlives its test file.
function writeGraph(ctx, dir, runs) {
  const root = traceRoot(ctx?.config?.root ?? process.cwd());
  const moduleReads = readModuleReads(dir);
  const byFile = new Map();
  for (const [file, project] of runs) {
    if (typeof file !== 'string' || file === '') continue;
    const abs = path.resolve(file);
    if (!byFile.has(abs)) byFile.set(abs, []);
    byFile.get(abs).push(project);
  }
  const writer = new TraceBlockWriter(path.join(dir, traceFileName('vitest', process.pid, 0)));
  for (const [testFile, projects] of byFile) {
    const lines = new Set();
    for (const project of projects) {
      const graph = viteOf(project ?? ctx)?.moduleGraph ?? viteOf(ctx)?.moduleGraph;
      for (const line of graphTraceLines({
        root, testFile, entries: projectEntries(ctx, project), importedOf: importedOf(graph), moduleReads,
      })) lines.add(line);
    }
    for (const line of lines) writer.add(line);
  }
  writer.close();
}
