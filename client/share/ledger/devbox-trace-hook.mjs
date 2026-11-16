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
// A worker_threads Worker or a node child that a test starts gets the test file
// and a token in a copy of its environment (spec section 5.7). The hook loads
// there through NODE_OPTIONS, owns every read there by that test file, and
// writes `covered <test file> <token>` at once, which confirms the parent's
// `partial <test file> <reason> <token>` line. The runner drops a confirmed
// pair before it packs the trace, so a file whose Worker the hook reached is
// complete. Anything the hook cannot confirm keeps its file partial.
//
// With DEVBOX_TRACE_DIR unset this file wraps nothing.

import fs from 'node:fs';
import path from 'node:path';
import childProcess from 'node:child_process';
import workerThreads from 'node:worker_threads';
import { syncBuiltinESMExports } from 'node:module';
import { fileURLToPath } from 'node:url';
import { randomBytes } from 'node:crypto';
import { TraceWriter, classifyPath, formatTraceLine, traceFileName, traceRoot, validUnit } from './ledger-core.mjs';

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

// The test file vitest runs in this worker and the repository root, or null.
function vitestOwner() {
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

// A trace line of the handoff, which carries a token as its last field, or
// null when a field holds a tab or a newline.
function tokenLine(kind, owner, ...fields) {
  const parts = [kind, owner, ...fields];
  return parts.every(validUnit) ? `${parts.join('\t')}\n` : null;
}

// Section 5.7, step 3: the test file and token a parent hook handed to this
// Worker or node child, or null. The three variables leave this environment in
// every case, so a child of this process starts without them. A node child
// takes the handoff only when its parent is the process that wrote the token,
// so a grandchild that inherited the variables from a child the hook did not
// reach never confirms in that child's place. A Worker takes it only when the
// token names this process, so a Worker of such a child does not confirm
// either. A handoff with no DEVBOX_TRACE_ROOT is refused: a root guessed from
// the working directory can drop every read as outside the repository, and
// the file would then look complete with its reads missing.
const TOKEN_FORM = /^[A-Za-z0-9._-]{8,64}$/;

function takeHandoff() {
  const { DEVBOX_TRACE_OWNER: owner, DEVBOX_TRACE_TOKEN: token, DEVBOX_TRACE_PARENT: parent, DEVBOX_TRACE_ROOT: root } = process.env;
  delete process.env.DEVBOX_TRACE_OWNER;
  delete process.env.DEVBOX_TRACE_TOKEN;
  delete process.env.DEVBOX_TRACE_PARENT;
  if (!validUnit(owner) || typeof token !== 'string' || !TOKEN_FORM.test(token) || !root) return null;
  const writer = token.split('.')[0];
  const direct = workerThreads.isMainThread
    ? parent !== undefined && parent === String(process.ppid) && writer === parent
    : parent === undefined && writer === String(process.pid);
  return direct ? { root: path.resolve(root), owner, token } : null;
}

const handed = TRACE_DIR ? takeHandoff() : null;

// The owner of a read here: the test file a parent handed over, else the one
// vitest runs, else null.
function current() {
  return handed ?? vitestOwner();
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
  return { program: resolveProgram(program, cwd, env), cwd, words, argv, env };
}

// 4.0.1 D3: the shell of one plain command runs that command. On real suites
// `execSync("git rev-parse --short HEAD")` reached this hook as `/bin/sh -c
// "git rev-parse ..."`, and sh is an interpreter, so its test file was
// partial, although git run directly is not. Only `sh -c` or `bash -c` with
// one command string unwraps, and only when every character of that string
// is a plain word character or a blank. Any other character, a `;`, `&&`, a
// pipe, `$`, a backquote, a redirection, a quote, a glob, a brace or a tilde,
// is shell syntax: the shell then runs other words than the ones split here,
// and a quote, a glob or a variable can name a repository file no word names.
// The words of the inner command, or null.
const SHELLS = new Set(['sh', 'bash']);
const PLAIN_COMMAND = /^[A-Za-z0-9_.,:=+@%/ \t-]+$/;

function plainShellCommand(program, argv) {
  if (program === null || !SHELLS.has(path.basename(program))) return null;
  if (argv.length !== 3 || argv[1] !== '-c' || !PLAIN_COMMAND.test(argv[2])) return null;
  const words = argv[2].split(/[ \t]+/).filter((w) => w !== '');
  return words.length > 0 ? words : null;
}

// Section 5.4: a child process reads no repository file when its program
// resolves outside the repository, no word of its command names a path that
// exists inside it, relative to the child's working directory or to the root,
// and no word names an interpreter or a build tool. Every word, the program
// included, is checked against that list, because a launcher such as
// `/usr/bin/env python3` names the interpreter in an argument. On a real
// suite a session fixture whose library ran `git rev-parse HEAD` marked every
// test file partial, and selection then gave that suite nothing.
//
// A program under node_modules/ or .venv/ is inside the repository, so it
// stays partial. esbuild's service binary is one: its build() reads entry
// files of the repository inside the binary, where this hook sees nothing, and
// a test file that called it would look complete with those reads missing.
function childMayRead(root, name, args) {
  let { program, cwd, words, argv, env } = childCommand(name, args);
  const inner = plainShellCommand(program, argv);
  if (inner !== null) {
    program = resolveProgram(inner[0], cwd, env);
    words = inner;
  }
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

// Section 5.7, step 2: a child is node itself when it is a fork, when its
// program's base name is node or it is this node, or when the program is a
// script whose first line names node. Under a shell option the program is the
// shell, which runs whatever its command line says. npm, npx and the other
// package runners are node scripts that start the tool they run under a shell
// or a program of their own, so those keep the plain partial of section 5.4.
const PACKAGE_RUNNERS = new Set(['npm', 'npx', 'pnpm', 'pnpx', 'yarn', 'corepack']);

function shebangNamesNode(file) {
  const head = Buffer.alloc(256);
  let fd = null;
  let n = 0;
  try {
    fd = fs.openSync(file, 'r');
    n = fs.readSync(fd, head, 0, head.length, 0);
  } catch {
    // A program this process cannot read is not taken for node, so its test
    // file keeps the plain partial: the safe direction.
    return false;
  } finally {
    if (fd !== null) fs.closeSync(fd);
  }
  const text = head.toString('utf8', 0, n);
  if (!text.startsWith('#!')) return false;
  return text.slice(2).split('\n')[0].split(/\s+/).some((word) => path.basename(word) === 'node');
}

function isNodeChild(name, args) {
  if (name === 'fork') return true;
  const { program } = childCommand(name, args);
  if (program === null || PACKAGE_RUNNERS.has(path.basename(program))) return false;
  if (path.basename(program) === 'node') return true;
  let real;
  try {
    real = fs.realpathSync(program);
  } catch {
    // A program that does not resolve starts no node: the plain partial stays.
    return false;
  }
  if (PACKAGE_RUNNERS.has(path.basename(real))) return false;
  return real === fs.realpathSync(process.execPath) || shebangNamesNode(real);
}

let tokens = 0;

function newToken() {
  tokens += 1;
  return `${process.pid}.${workerThreads.threadId}.${tokens}.${randomBytes(4).toString('hex')}`;
}

// The environment a Worker or child starts with: a copy of the one the call
// names, or of process.env, plus the handoff. process.env itself is never
// written, because every test file of this worker reads it, and two test files
// would then share one owner.
function handoffEnv(base, cur, token, child) {
  const env = { ...(base == null ? process.env : base) };
  env.DEVBOX_TRACE_ROOT = cur.root;
  env.DEVBOX_TRACE_OWNER = cur.owner;
  env.DEVBOX_TRACE_TOKEN = token;
  if (child) env.DEVBOX_TRACE_PARENT = String(process.pid);
  else delete env.DEVBOX_TRACE_PARENT;
  return env;
}

function isOptions(o) {
  return typeof o === 'object' && o !== null && !Array.isArray(o);
}

// The arguments of one spawn, execFile or fork call with the handoff in its
// options, placed where node's own parse looks for them: after the argument
// array when there is one, before a callback.
function withHandoff(args, cur, token) {
  const out = [...args];
  let i = Array.isArray(out[1]) || (out.length > 2 && out[1] == null) ? 2 : 1;
  if (isOptions(out[i])) {
    out[i] = { ...out[i], env: handoffEnv(out[i].env, cur, token, true) };
    return out;
  }
  const options = { env: handoffEnv(undefined, cur, token, true) };
  if (i === 1) {
    if (out.length > 1 && out[1] == null) out[1] = [];
    else out.splice(1, 0, []);
    i = 2;
  }
  if (out[i] == null) out[i] = options;
  else out.splice(i, 0, options);
  return out;
}

// The shared Worker guard of section 5.7. Every Worker and every child that
// outlives the call that started it, and that the hook marked partial for a
// test file, stays here until it exits. With isolate: false, a Worker one test
// file started and a later file reused recorded the later file's reads against
// the first file, and the later file looked complete with those reads missing.
// So a test file that runs while another file's Worker or child is alive, or
// posts to such a Worker, is partial.
const live = new Set();
const watched = new WeakSet();

function sharedCheck() {
  if (live.size === 0) return;
  const cur = vitestOwner();
  if (cur === null) return;
  for (const entry of live) {
    if (entry.owner !== cur.owner) {
      writers().trace.write(formatTraceLine('partial', cur.owner, 'shared worker'));
      return;
    }
  }
}

function quietly(fn) {
  if (busy) return fn();
  busy = true;
  try {
    return fn();
  } finally {
    busy = false;
  }
}

// vitest 2 to 5 assign the next test file to `filepath` of one state object, so
// a setter there sees each change of file. A state object vitest replaces, or
// one whose filepath cannot be redefined, is still checked at each traced call
// and at each postMessage to a live Worker.
function watchState() {
  const state = globalThis.__vitest_worker__;
  if (typeof state !== 'object' || state === null || watched.has(state)) return;
  watched.add(state);
  const d = Object.getOwnPropertyDescriptor(state, 'filepath');
  if (d === undefined ? !Object.isExtensible(state) : !d.configurable || !('value' in d)) return;
  let file = d?.value;
  Object.defineProperty(state, 'filepath', {
    configurable: true,
    enumerable: d?.enumerable ?? true,
    get: () => file,
    set: (value) => {
      file = value;
      quietly(sharedCheck);
    },
  });
}

function track(handle, owner, worker) {
  if (!worker && handle?.pid === undefined) return;
  const entry = { owner };
  live.add(entry);
  handle.once('exit', () => live.delete(entry));
  quietly(watchState);
  if (worker) {
    const post = handle.postMessage;
    handle.postMessage = function (...args) {
      quietly(() => {
        watchState();
        sharedCheck();
      });
      return Reflect.apply(post, this, args);
    };
  }
}

// A record of a child or a Worker returns the arguments the call runs with and
// what to do with what it returns; every other record returns undefined.
function record(kind, target) {
  if (live.size > 0) {
    watchState();
    sharedCheck();
  }
  const cur = current();
  if (cur === null) return undefined;
  const w = writers();
  if (kind === 'worker') {
    const [file, given, ...rest] = target;
    const options = isOptions(given) ? given : {};
    const started = (worker) => track(worker, cur.owner, true);
    // An eval Worker does not load the hook, and a SHARE_ENV Worker has no
    // environment of its own to carry the handoff (section 5.7).
    if (options.eval || options.env === workerThreads.SHARE_ENV) {
      w.trace.write(formatTraceLine('partial', cur.owner, 'worker_threads'));
      return { args: target, started };
    }
    const token = newToken();
    w.trace.write(tokenLine('partial', cur.owner, 'worker_threads', token));
    return { args: [file, { ...options, env: handoffEnv(options.env, cur, token, false) }, ...rest], started };
  }
  if (kind === 'child') {
    if (!childMayRead(cur.root, target.name, target.args)) return undefined;
    const started = target.name.endsWith('Sync') ? null : (child) => track(child, cur.owner, false);
    if (isNodeChild(target.name, target.args)) {
      const token = newToken();
      w.trace.write(tokenLine('partial', cur.owner, 'child_process', token));
      return { args: withHandoff(target.args, cur, token), started };
    }
    w.trace.write(formatTraceLine('partial', cur.owner, 'child_process'));
    return { args: target.args, started };
  }
  const abs = toAbs(target);
  if (abs === null) return;
  const c = classifyPath(cur.root, abs);
  if (c === null) return;
  // The git database of a workspace, the `.git` file of a worktree and
  // `.git-common/`, changes with every commit and is no synced input. A test
  // that ran git once recorded reads of `.git-common/refs/`, so a commit
  // selected it (4.0.1 D3b).
  if (c.kind === 'read' && /^\.git(-common)?(\/|$)/.test(c.rel)) return;
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
    let call = args;
    let started = null;
    if (!busy) {
      const target = argOf(args);
      if (target !== undefined) {
        busy = true;
        try {
          const handoff = record(kind, target);
          if (handoff !== undefined) ({ args: call, started } = handoff);
        } finally {
          busy = false;
        }
      }
    }
    const result = new.target ? Reflect.construct(orig, call, new.target) : Reflect.apply(orig, this, call);
    if (started !== null) started(result);
    return result;
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
  wrap(workerThreads, 'Worker', 'worker', (args) => args);
  // Section 5.7, step 3: confirm at load, never at exit, because a Worker's
  // exit handler does not run on terminate().
  if (handed !== null) writers().trace.write(tokenLine('covered', handed.owner, handed.token));
  // An ESM `import { readFileSync } from 'node:fs'` binds the export as it was
  // when the module loaded. This copies the wrappers into those bindings.
  syncBuiltinESMExports();
}
