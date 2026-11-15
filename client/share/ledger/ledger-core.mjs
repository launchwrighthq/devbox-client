// The ledger logic of the vitest reporter, apart from vitest. It imports node
// built-ins only, so tests/test-ledger-tools.sh proves it under plain `node`
// with no vitest installed. docs/specs/2026-11-13-resumable-gates-design.md
// section 3.3 holds the record format.
//
// devbox_ledger.py applies the same rules to pytest in Python: the last record
// of a unit decides, and a path is relative to the nearest directory that holds
// .devbox/config.env. A change to either rule changes both files.

import fs from 'node:fs';
import path from 'node:path';

// A record is one line of tab-separated fields, so a tab in a path splits it
// into fields that the readers take for an outcome, and a newline forges a
// second record. A forged `pass` would skip a file that never ran.
export function validUnit(name) {
  return typeof name === 'string' && name !== '' && !/[\t\n]/.test(name);
}

export function formatFileLine(runner, file, outcome, seconds) {
  if (!validUnit(runner) || !validUnit(file)) {
    throw new Error(`devbox-ledger: refusing the unit ${JSON.stringify(file)}: a name holds a tab or a newline, or is empty`);
  }
  const fields = ['file', runner, file, outcome];
  if (outcome !== 'start') fields.push(String(seconds));
  return `${fields.join('\t')}\n`;
}

export function parseLedger(text) {
  return text.split('\n').filter((line) => line !== '').map((line) => line.split('\t'));
}

// The files of one runner whose LAST record is `pass`. A test file runs in a
// worker, so a stop leaves its `start` with no later line, and only a later
// `pass` may mark it done. A `start` written after a `pass` means a later run
// began the file again and did not finish it, so the file runs again too.
export function passedFiles(text, runner) {
  const last = new Map();
  for (const record of parseLedger(text)) {
    if (record[0] === 'file' && record[1] === runner && record.length >= 4) {
      last.set(record[2], record[3]);
    }
  }
  return [...last].filter(([, outcome]) => outcome === 'pass').map(([file]) => file);
}

// One write of the whole line on a descriptor opened with O_APPEND, so that
// parallel workers interleave whole lines and never fragments of two records.
export function appendLine(ledger, line) {
  const buf = Buffer.from(line, 'utf8');
  const fd = fs.openSync(ledger, 'a', 0o600);
  try {
    const written = fs.writeSync(fd, buf, 0, buf.length);
    if (written !== buf.length) {
      throw new Error(`devbox-ledger: wrote ${written} of ${buf.length} bytes to ${ledger}`);
    }
  } finally {
    fs.closeSync(fd);
  }
}

// The project root is the nearest directory, from start upward, that holds
// .devbox/config.env, the file every devbox project commits. A runner's own
// root can be a subdirectory of a monorepo, and two apps there can each hold a
// src/a.test.ts: paths relative to the runner's root would make the pass of one
// skip the other, which never ran.
export function findProjectRoot(start) {
  let dir = path.resolve(start);
  for (;;) {
    if (fs.existsSync(path.join(dir, '.devbox', 'config.env'))) return dir;
    const parent = path.dirname(dir);
    if (parent === dir) return path.resolve(start);
    dir = parent;
  }
}

// vitest reads test.exclude as globs, so a path such as app/[id]/page.test.ts
// must not match as a character class. An escape the glob library does not
// honour leaves the file unexcluded, so it runs again: the safe direction.
export function globEscape(file) {
  return file.replace(/[\\*?[\]{}()!+@]/g, '\\$&');
}

// The passed files of a runner as test.exclude patterns relative to runRoot,
// the root the runner matches its patterns against. A passed file outside
// runRoot is left out, because no pattern of this runner can name it.
export function excludePatterns(text, runner, projectRoot, runRoot) {
  const out = [];
  for (const file of passedFiles(text, runner)) {
    const rel = path.relative(runRoot, path.join(projectRoot, file));
    if (rel === '' || rel === '..' || rel.startsWith(`..${path.sep}`) || path.isAbsolute(rel)) continue;
    out.push(globEscape(rel.split(path.sep).join('/')));
  }
  return out;
}

// One recorder per runner process. A key is one run of one test module: a
// vitest task id, or a module path with its project name. Two vitest projects
// can run the same file at once, so lines are written per path: `start` when
// the first run of a path begins, and the end when the last one in flight ends,
// `fail` when any of them failed. An end with no outcome (a skipped module)
// writes nothing, so the path stays `start` and runs again on a resume.
export class FileRecorder {
  constructor({ ledger, runner, root, now = () => Date.now(), append = appendLine, warn = (msg) => process.stderr.write(`${msg}\n`) }) {
    this.ledger = ledger;
    this.runner = runner;
    this.root = root;
    this.now = now;
    this.append = append;
    this.warn = warn;
    this.keys = new Map();
    this.done = new Set();
    this.paths = new Map();
  }

  relative(absPath) {
    return path.relative(this.root, path.resolve(this.root, absPath)).split(path.sep).join('/');
  }

  begin(key, absPath) {
    if (this.keys.has(key) || this.done.has(key)) return;
    const file = this.relative(absPath);
    if (!validUnit(file)) {
      this.warn(`devbox-ledger: not recording ${JSON.stringify(file)}: it holds a tab or a newline, so it runs again on a resume`);
      this.done.add(key);
      return;
    }
    this.keys.set(key, file);
    let agg = this.paths.get(file);
    if (!agg) {
      agg = { inflight: 0, started: this.now(), worst: 'pass' };
      this.paths.set(file, agg);
      this.append(this.ledger, formatFileLine(this.runner, file, 'start'));
    }
    agg.inflight += 1;
  }

  // outcome is 'pass', 'fail' or null.
  end(key, outcome) {
    const file = this.keys.get(key);
    if (file === undefined) return;
    this.keys.delete(key);
    this.done.add(key);
    const agg = this.paths.get(file);
    if (outcome === 'fail') agg.worst = 'fail';
    else if (outcome !== 'pass' && agg.worst === 'pass') agg.worst = null;
    agg.inflight -= 1;
    if (agg.inflight > 0) return;
    this.paths.delete(file);
    if (agg.worst === null) return;
    const seconds = Math.round((this.now() - agg.started) / 1000);
    this.append(this.ledger, formatFileLine(this.runner, file, agg.worst, seconds));
  }
}

// ── the trace of docs/specs/2026-11-14-learned-selection-design.md ──────────
//
// Section 5.6 holds the line format: `read`, `list`, `setup` and `partial`
// lines, tab-separated, every path relative to the repository root. The hook
// devbox-trace-hook.mjs writes the lines of a worker, and the reporter adds
// the module graph. Both call these functions, so the two halves of one
// vitest trace classify a path by one rule.

// The writer's own fs calls are taken when this module loads, before the hook
// wraps the fs module, so a trace write never traces itself.
const rawOpenSync = fs.openSync;
const rawWriteSync = fs.writeSync;
const rawReaddirSync = fs.readdirSync;
const rawReadFileSync = fs.readFileSync;

// A setup output: a path with one of these as a segment is read through the
// setup key (spec section 5.3), wherever in the repository the folder sits.
const SETUP_SEGMENTS = new Set(['node_modules', '.venv']);

// The repository root a trace is relative to: DEVBOX_TRACE_ROOT, which the
// runner sets, else the nearest .devbox/config.env above the runner's root,
// the rule the ledger applies, else that root itself.
export function traceRoot(runnerRoot) {
  const env = process.env.DEVBOX_TRACE_ROOT;
  return path.resolve(env || findProjectRoot(runnerRoot));
}

// One absolute path classified against root: { kind: 'read', rel } for a
// repository path, { kind: 'setup' } for one under a setup output, and null
// for a path outside the repository, which the trace drops. The root itself
// is `.`.
export function classifyPath(root, absPath) {
  const rel = path.relative(root, absPath);
  if (rel === '') return { kind: 'read', rel: '.' };
  if (rel === '..' || rel.startsWith(`..${path.sep}`) || path.isAbsolute(rel)) return null;
  const parts = rel.split(path.sep);
  if (parts.some((p) => SETUP_SEGMENTS.has(p))) return { kind: 'setup' };
  return { kind: 'read', rel: parts.join('/') };
}

// One trace line, or null when a field holds a tab or a newline: such a field
// would split into other fields or forge a second line, so the caller marks
// the owner partial instead. A `list` path ends in `/`.
export function formatTraceLine(kind, owner, field) {
  if (!validUnit(owner)) return null;
  if (kind === 'setup') return `setup\t${owner}\n`;
  if (!validUnit(field)) return null;
  return kind === 'list' ? `list\t${owner}\t${field}/\n` : `${kind}\t${owner}\t${field}\n`;
}

// The file of one process: <kind>-<pid>.trace, with the thread id after the
// pid in a worker thread, because the threads pool runs every worker in one
// process and two workers must not share a file.
export function traceFileName(kind, pid, threadId, suffix = 'trace') {
  return threadId ? `${kind}-${pid}-${threadId}.${suffix}` : `${kind}-${pid}.${suffix}`;
}

// Appends each distinct line once, on a descriptor opened with O_APPEND at the
// first line, so a process that owns no read creates no file, and a worker
// killed mid-run keeps every line it wrote before. One write per line, so two
// writers of one file interleave whole lines.
export class TraceWriter {
  constructor(file) {
    this.file = file;
    this.fd = null;
    this.seen = new Set();
  }

  write(line) {
    if (this.seen.has(line)) return;
    if (this.fd === null) this.fd = rawOpenSync(this.file, 'a', 0o600);
    const buf = Buffer.from(line, 'utf8');
    const written = rawWriteSync(this.fd, buf, 0, buf.length);
    if (written !== buf.length) throw new Error(`devbox-trace: wrote ${written} of ${buf.length} bytes to ${this.file}`);
    this.seen.add(line);
  }
}

// The module reads the hook wrote beside the traces, from every *.modules file
// in dir: a map from a module's repository path to the [kind, path] pairs of
// the reads whose innermost repository frame was that module.
export function readModuleReads(dir) {
  const byModule = new Map();
  for (const name of rawReaddirSync(dir)) {
    if (!name.endsWith('.modules')) continue;
    for (const line of rawReadFileSync(path.join(dir, name), 'utf8').split('\n')) {
      const f = line.split('\t');
      if (f.length !== 3 || f[1] === '') continue;
      if (!byModule.has(f[1])) byModule.set(f[1], []);
      byModule.get(f[1]).push([f[0], f[2]]);
    }
  }
  return byModule;
}

// The absolute file a module graph id names, or null for a virtual id. A query
// or a hash is cut first.
export function moduleIdPath(id) {
  if (typeof id !== 'string' || id === '' || id.startsWith('\0') || id.startsWith('virtual:')) return null;
  let p = id.replace(/[?#].*$/, '');
  if (p.startsWith('/@fs/')) p = p.slice(4);
  if (p.startsWith('file://')) p = decodeURIComponent(new URL(p).pathname);
  return path.isAbsolute(p) ? p : null;
}

// The trace lines of one test file from the module graph: every module in the
// closure of the test file and of entries, the files every test file of its
// project loads (the config, its imports, the setup files), and every read the
// hook tied to one of those modules. importedOf(absPath) returns the absolute
// paths that module imports. A module served from the module cache keeps its
// edge in the graph, so the second test file that imports it gets it and its
// reads too, which a trace of file opens alone gives only the first.
export function graphTraceLines({ root, testFile, entries, importedOf, moduleReads }) {
  const owner = classifyPath(root, testFile);
  if (!owner || owner.kind !== 'read') return [];
  const lines = [];
  const seen = new Set();
  const stack = [testFile, ...entries];
  while (stack.length > 0) {
    const abs = stack.pop();
    if (seen.has(abs)) continue;
    seen.add(abs);
    const c = classifyPath(root, abs);
    if (!c) continue;
    if (c.kind === 'setup') {
      lines.push(formatTraceLine('setup', owner.rel));
      continue;
    }
    if (abs !== testFile) lines.push(formatTraceLine('read', owner.rel, c.rel));
    for (const [kind, p] of moduleReads.get(c.rel) ?? []) lines.push(formatTraceLine(kind, owner.rel, p));
    for (const next of importedOf(abs)) stack.push(next);
  }
  return lines.filter((l) => l !== null);
}
