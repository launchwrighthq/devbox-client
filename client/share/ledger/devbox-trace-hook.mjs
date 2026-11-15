// The read trace of one vitest worker: docs/specs/2026-11-14-learned-selection-design.md
// sections 5.2, 5.4 and 5.6. The runner loads this file into every node
// process of a traced vitest step with NODE_OPTIONS=--import=<this file>, so it
// reaches each worker of the forks pool (a child process) and of the threads
// pool (a worker thread). It wraps the fs read, stat and directory functions
// and the child_process functions, and writes each repository path a test file
// reads to $DEVBOX_TRACE_DIR/vitest-<pid>[-<thread id>].trace, owned by the
// test file the worker runs at that moment.
//
// The owner is __vitest_worker__.filepath, the test file vitest 2, 3 and 4 set
// in the worker's global state before it imports the file. MEASURED with
// vitest 2, 3 and 4: the hook loaded from NODE_OPTIONS ran in
// every forks child and every threads worker, and that field named the file
// each one ran when a helper it imported read a data file. A call with no test
// file running, which is every call of the main vitest process, of npx and of
// the pool's own startup, records nothing, so such a process writes no file.
//
// vitest fetches every transformed module from the main process over its RPC,
// so a worker never opens the source of a module it imports. The reporter adds
// those from vitest's module graph. What this hook adds is the files a test
// reads at run time: data files, fixtures, directory listings.
//
// A read whose innermost repository frame is a module other than the test file
// (a helper that reads a data file when it loads) also goes to
// vitest-<pid>[-<thread id>].modules as `<kind>\t<module>\t<path>`. With
// isolate: false a second test file gets the helper from the module cache, the
// helper does not run again, and this hook sees no read for that file. The
// reporter gives the module's reads to every test file whose graph holds it.
//
// With DEVBOX_TRACE_DIR unset this file wraps nothing.

import fs from 'node:fs';
import path from 'node:path';
import childProcess from 'node:child_process';
import workerThreads from 'node:worker_threads';
import { syncBuiltinESMExports } from 'node:module';
import { fileURLToPath } from 'node:url';
import { TraceWriter, classifyPath, formatTraceLine, traceFileName, traceRoot } from './ledger-core.mjs';

const TRACE_DIR = process.env.DEVBOX_TRACE_DIR;
const HERE = path.dirname(fileURLToPath(import.meta.url));

let busy = false;
let trace = null;
let modules = null;
const roots = new Map();

function writers() {
  if (trace === null) {
    trace = new TraceWriter(path.join(TRACE_DIR, traceFileName('vitest', process.pid, workerThreads.threadId)));
    modules = new TraceWriter(path.join(TRACE_DIR, traceFileName('vitest', process.pid, workerThreads.threadId, 'modules')));
  }
  return { trace, modules };
}

// The test file running in this worker and the repository root, or null.
function current() {
  const state = globalThis.__vitest_worker__;
  const file = state?.filepath;
  if (typeof file !== 'string' || file === '') return null;
  const runnerRoot = state.config?.root ?? process.cwd();
  let root = roots.get(runnerRoot);
  if (root === undefined) {
    root = traceRoot(runnerRoot);
    roots.set(runnerRoot, root);
  }
  const owner = classifyPath(root, file);
  if (!owner || owner.kind !== 'read') return null;
  return { root, owner: owner.rel };
}

// A path as fs takes it: a string, a file URL or a Buffer. vitest's error
// printer stats the file of every stack frame, `node:fs` included, which names
// no file of the repository.
function toAbs(p) {
  if (typeof p === 'string') return p.startsWith('node:') ? null : path.resolve(p);
  if (p instanceof URL) return p.protocol === 'file:' ? fileURLToPath(p) : null;
  if (Buffer.isBuffer(p)) return path.resolve(p.toString('utf8'));
  return null;
}

// The repository path of the innermost stack frame that is a repository
// module, not under a setup output and not this hook, or null.
function callerModule(root) {
  const prepare = Error.prepareStackTrace;
  const limit = Error.stackTraceLimit;
  let sites;
  try {
    Error.prepareStackTrace = (_, callSites) => callSites;
    Error.stackTraceLimit = 25;
    const holder = {};
    Error.captureStackTrace(holder, callerModule);
    sites = holder.stack;
  } finally {
    Error.prepareStackTrace = prepare;
    Error.stackTraceLimit = limit;
  }
  if (!Array.isArray(sites)) return null;
  for (const site of sites) {
    let f = site.getFileName();
    if (typeof f !== 'string' || f === '') continue;
    if (f.startsWith('file://')) f = fileURLToPath(f.replace(/[?#].*$/, ''));
    if (!path.isAbsolute(f) || path.dirname(f) === HERE) continue;
    const c = classifyPath(root, f.replace(/[?#].*$/, ''));
    if (c && c.kind === 'read') return c.rel;
  }
  return null;
}

// Section 5.4: an interpreter or a build tool reads the working directory
// without naming it, by program base name. devbox_ledger.py holds the same
// list for pytest, and the two share nothing but the spec's text.
const INTERPRETERS = new Set(['node', 'deno', 'bun', 'ruby', 'perl', 'php', 'java', 'sh', 'bash', 'dash', 'zsh',
  'make', 'npm', 'npx', 'pnpm', 'yarn', 'uv', 'poetry', 'cargo', 'go']);

function isInterpreter(word) {
  const name = path.basename(word);
  return name.startsWith('python') || INTERPRETERS.has(name);
}

function isFile(p) {
  try {
    return fs.statSync(p).isFile();
  } catch {
    // A missing or unreadable candidate is no program: the search goes on.
    return false;
  }
}

// The file the child executes, as the kernel finds it: a name with a slash
// against the child's working directory, a bare name through the PATH of the
// child's environment. null when nothing resolves.
function resolveProgram(program, cwd, env) {
  if (program === '') return null;
  if (program.includes('/')) return path.resolve(cwd, program);
  for (const dir of (env.PATH ?? '').split(path.delimiter)) {
    const candidate = path.resolve(cwd, dir, program);
    if (!isFile(candidate)) continue;
    try {
      fs.accessSync(candidate, fs.constants.X_OK);
      return candidate;
    } catch {
      // Not executable: execvp skips it too.
    }
  }
  return null;
}

// The program, working directory and words of one child_process call, as node
// builds them. A shell option runs the command line through the shell.
function childCommand(name, args) {
  let [command, rest, options] = args;
  if (name === 'exec' || name === 'execSync') {
    options = typeof rest === 'object' && rest !== null ? rest : {};
    rest = [];
    options = { shell: true, ...options };
  } else if (!Array.isArray(rest)) {
    options = rest;
    rest = [];
  }
  options = typeof options === 'object' && options !== null ? options : {};
  const env = options.env ?? process.env;
  const cwd = options.cwd ? path.resolve(toAbs(options.cwd) ?? String(options.cwd)) : process.cwd();
  let argv = [String(command), ...rest.map(String)];
  let program = argv[0];
  if (name === 'fork') {
    program = options.execPath ?? process.execPath;
    argv = [program, ...argv];
  } else if (options.shell) {
    program = typeof options.shell === 'string' ? options.shell : '/bin/sh';
    argv = [program, '-c', argv.join(' ')];
  }
  const words = argv.flatMap((a) => a.split(/\s+/)).filter((w) => w !== '');
  return { program: resolveProgram(program, cwd, env), cwd, words };
}

// Section 5.4: a child process reads no repository file when its program
// resolves outside the repository, no word of its command names a path that
// exists inside it, relative to the child's working directory or to the root,
// and no word names an interpreter or a build tool. Every word, the program
// included, is checked against that list, because a launcher such as
// `/usr/bin/env python3` names the interpreter in an argument. On a real
// suite a session fixture whose library ran `git rev-parse HEAD` marked every
// test file partial, and selection then gave that suite nothing.
function childMayRead(root, name, args) {
  const { program, cwd, words } = childCommand(name, args);
  const inside = (p) => {
    let real = p;
    try {
      real = fs.realpathSync(p);
    } catch {
      // A path that does not resolve is tested as it is written.
    }
    return classifyPath(root, p) !== null || classifyPath(root, real) !== null;
  };
  if (program === null || inside(program) || isInterpreter(program)) return true;
  for (const word of words) {
    if (isInterpreter(word)) return true;
    for (const dir of [cwd, root]) {
      const p = path.resolve(dir, word);
      if (!inside(p)) continue;
      try {
        fs.lstatSync(p);
        return true;
      } catch {
        // The word names no file here.
      }
    }
  }
  return false;
}

function record(kind, target) {
  const cur = current();
  if (cur === null) return;
  const w = writers();
  if (kind === 'partial') {
    w.trace.write(formatTraceLine('partial', cur.owner, target));
    return;
  }
  if (kind === 'child') {
    if (childMayRead(cur.root, target.name, target.args)) {
      w.trace.write(formatTraceLine('partial', cur.owner, 'child_process'));
    }
    return;
  }
  const abs = toAbs(target);
  if (abs === null) return;
  const c = classifyPath(cur.root, abs);
  if (c === null) return;
  if (c.kind === 'setup') {
    w.trace.write(formatTraceLine('setup', cur.owner));
    return;
  }
  // vitest 2 and 3 stat the test file itself in the worker. A runner step's
  // inputs hold its test files already (section 5.6), so the line adds nothing.
  if (c.rel === cur.owner) return;
  const line = formatTraceLine(kind, cur.owner, c.rel);
  if (line === null) {
    w.trace.write(formatTraceLine('partial', cur.owner, 'a path holds a tab or a newline'));
    return;
  }
  w.trace.write(line);
  const mod = callerModule(cur.root);
  if (mod !== null && mod !== cur.owner) {
    const modLine = formatTraceLine(kind, mod, c.rel);
    if (modLine !== null) w.modules.write(modLine);
  }
}

// The trace runs before the wrapped call, so a read of a missing file counts:
// a test that checks for a file depends on that file not being there.
function wrap(obj, name, kind, argOf = (args) => args[0]) {
  const orig = obj[name];
  if (typeof orig !== 'function') return;
  const wrapped = function (...args) {
    if (!busy) {
      const target = argOf(args);
      if (target !== undefined) {
        busy = true;
        try {
          record(kind, target);
        } finally {
          busy = false;
        }
      }
    }
    return new.target ? Reflect.construct(orig, args, new.target) : Reflect.apply(orig, this, args);
  };
  Object.defineProperties(wrapped, Object.getOwnPropertyDescriptors(orig));
  obj[name] = wrapped;
}

// open reads unless its flags only write: `w` and `a` truncate or append, so
// the file's old content is no input of the test.
function openTarget(args) {
  const flags = typeof args[1] === 'function' ? undefined : args[1];
  if (flags === undefined || flags === null) return args[0];
  if (typeof flags === 'string') return flags.startsWith('r') ? args[0] : undefined;
  if (typeof flags === 'number') {
    const { O_WRONLY, O_TRUNC } = fs.constants;
    return (flags & 3) === O_WRONLY || (flags & O_TRUNC) !== 0 ? undefined : args[0];
  }
  return args[0];
}

if (TRACE_DIR) {
  const READS = ['readFile', 'readFileSync', 'createReadStream', 'stat', 'statSync', 'lstat', 'lstatSync',
    'exists', 'existsSync', 'access', 'accessSync', 'readlink', 'readlinkSync'];
  const LISTS = ['readdir', 'readdirSync', 'opendir', 'opendirSync'];
  for (const name of READS) wrap(fs, name, 'read');
  for (const name of LISTS) wrap(fs, name, 'list');
  wrap(fs, 'open', 'read', openTarget);
  wrap(fs, 'openSync', 'read', openTarget);
  for (const name of ['readFile', 'stat', 'lstat', 'access', 'readlink']) wrap(fs.promises, name, 'read');
  for (const name of ['readdir', 'opendir']) wrap(fs.promises, name, 'list');
  wrap(fs.promises, 'open', 'read', openTarget);
  // A child process reads files this process cannot see, so the test file
  // that starts one that may read repository files is partial (spec section
  // 5.4). The pool's own workers are started by the main vitest process,
  // where no test file runs.
  for (const name of ['spawn', 'spawnSync', 'exec', 'execSync', 'execFile', 'execFileSync', 'fork']) {
    wrap(childProcess, name, 'child', (args) => ({ name, args }));
  }
  wrap(workerThreads, 'Worker', 'partial', () => 'worker_threads');
  // An ESM `import { readFileSync } from 'node:fs'` binds the export as it was
  // when the module loaded. This copies the wrappers into those bindings.
  syncBuiltinESMExports();
}
