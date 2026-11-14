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
