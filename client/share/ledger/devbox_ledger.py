"""A pytest plugin that writes one ledger line per test file as it starts and as
it ends, and on a resume deselects every test of a file that passed earlier.
docs/specs/2026-11-13-resumable-gates-design.md sections 3.3 and 4.1 hold the
contract.

    PYTHONPATH="$DEVBOX_LEDGER_TOOLS" pytest -p devbox_ledger

With DEVBOX_LEDGER unset the plugin does nothing, so the same command also runs
outside devbox. Standard library only, and Python 3.8 syntax, because the
plugin runs in whatever interpreter a project's workspace holds.

ledger-core.mjs applies the same rules to vitest in JavaScript: the last record
of a unit decides, and a path is relative to the nearest directory that holds
.devbox/config.env. A change to either rule changes both files.

With DEVBOX_TRACE_DIR set, the plugin also records what each test file read,
and writes $DEVBOX_TRACE_DIR/pytest-<pid>.trace in every process, xdist workers
included. docs/specs/2026-11-14-learned-selection-design.md sections 5.1, 5.4
and 5.6 hold that contract. With DEVBOX_TRACE_DIR unset nothing of it starts.
"""

import builtins
import errno
import importlib
import os
import sys
import sysconfig
import time
import types

try:
    import pytest

    _hookimpl = pytest.hookimpl
except ImportError:
    # Under pytest this import cannot fail, because pytest is what loaded this
    # module. tests/test-ledger-tools.sh drives the hooks on a machine with no
    # pytest, and the markers are then no-ops.
    pytest = None

    def _hookimpl(**_opts):
        return lambda fn: fn


RUNNER = "pytest"


def valid_unit(name):
    """A record is one line of tab-separated fields, so a tab in a path splits it
    into fields that the readers take for an outcome, and a newline forges a
    second record. A forged `pass` would skip a file that never ran."""
    return isinstance(name, str) and name != "" and "\t" not in name and "\n" not in name


def format_file_line(runner, path, outcome, seconds=None):
    if not valid_unit(runner) or not valid_unit(path):
        raise ValueError("devbox_ledger: refusing the unit %r: a name holds a tab or a newline, or is empty" % (path,))
    fields = ["file", runner, path, outcome]
    if outcome != "start":
        fields.append(str(seconds))
    return "\t".join(fields) + "\n"


def passed_files(text, runner):
    """The files of one runner whose LAST record is `pass`. A stop leaves a
    file's `start` with no later line, and only a later `pass` may mark it done.
    A `start` written after a `pass` means a later run began the file again and
    did not finish it, so the file runs again too."""
    last = {}
    for line in text.split("\n"):
        record = line.split("\t")
        if len(record) >= 4 and record[0] == "file" and record[1] == runner:
            last[record[2]] = record[3]
    return {path for path, outcome in last.items() if outcome == "pass"}


def append_line(ledger, line):
    """One write of the whole line on a descriptor opened with O_APPEND, so that
    parallel processes interleave whole lines and never fragments of two."""
    data = line.encode("utf-8", "surrogateescape")
    fd = os.open(ledger, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
    try:
        written = os.write(fd, data)
    finally:
        os.close(fd)
    if written != len(data):
        raise OSError("devbox_ledger: wrote %d of %d bytes to %s" % (written, len(data), ledger))


def find_project_root(start):
    """The nearest directory, from start upward, that holds .devbox/config.env,
    the file every devbox project commits. pytest's rootdir can be a
    subdirectory of a monorepo, and two packages there can each hold a
    tests/test_a.py: paths relative to rootdir would make the pass of one skip
    the other, which never ran."""
    start = os.path.abspath(start)
    current = start
    while True:
        if os.path.isfile(os.path.join(current, ".devbox", "config.env")):
            return current
        parent = os.path.dirname(current)
        if parent == current:
            return start
        current = parent


def file_of(nodeid):
    return nodeid.split("::", 1)[0]


def pytest_configure(config):
    if _TRACER is not None:
        config.pluginmanager.register(TracePlugin(config, _TRACER), "devbox_trace_state")
    ledger = os.environ.get("DEVBOX_LEDGER")
    if not ledger:
        return
    config.pluginmanager.register(LedgerPlugin(config, ledger), "devbox_ledger_state")


class LedgerPlugin:
    def __init__(self, config, ledger, now=time.monotonic):
        self.ledger = ledger
        self.now = now
        rootdir = getattr(config, "rootpath", None) or config.rootdir
        self.rootdir = str(rootdir)
        self.root = find_project_root(self.rootdir)
        # Under pytest-xdist each worker collects and runs tests, and every
        # report also reaches the controller. A worker that wrote too would put
        # each line in the ledger twice, and a worker knows only its own share
        # of a file's tests, so it would write `pass` for a file whose other
        # tests run on another worker.
        self.worker = hasattr(config, "workerinput")
        self.expected = None
        self.files = {}

    def path_of(self, nodeid):
        rel = os.path.relpath(os.path.join(self.rootdir, file_of(nodeid)), self.root)
        return rel.replace(os.sep, "/")

    def read_passed(self):
        try:
            with open(self.ledger, encoding="utf-8", errors="surrogateescape") as handle:
                text = handle.read()
        except OSError as err:
            # A resume with no ledger file has no passed file: every test runs,
            # which is the safe direction. Any other read error stops the run.
            if err.errno == errno.ENOENT:
                return set()
            raise
        return passed_files(text, RUNNER)

    # trylast, so that the count below sees the items that remain after -k, -m
    # and every other plugin deselected theirs. A count that is too high leaves
    # a file `start` forever, and one that is too low writes `pass` before the
    # file's last test ran.
    @_hookimpl(trylast=True)
    def pytest_collection_modifyitems(self, session, config, items):
        if os.environ.get("DEVBOX_RESUME") == "1":
            passed = self.read_passed()
            keep = []
            drop = []
            for item in items:
                (drop if self.path_of(item.nodeid) in passed else keep).append(item)
            if drop:
                config.hook.pytest_deselected(items=drop)
                items[:] = keep
        self.set_expected(item.nodeid for item in items)

    # The xdist controller collects nothing itself. Each worker sends the node
    # ids it collected, after its own deselection, and every worker collects the
    # same list.
    @_hookimpl(optionalhook=True)
    def pytest_xdist_node_collection_finished(self, node, ids):
        self.set_expected(ids)

    def set_expected(self, nodeids):
        if self.expected is not None:
            return
        expected = {}
        for nodeid in nodeids:
            expected.setdefault(self.path_of(nodeid), set()).add(nodeid)
        self.expected = expected

    def pytest_runtest_logreport(self, report):
        if self.worker:
            return
        path = self.path_of(report.nodeid)
        state = self.files.get(path)
        if state is None:
            state = {"started": self.now(), "done": set(), "failed": False, "closed": False}
            self.files[path] = state
            if not valid_unit(path):
                sys.stderr.write(
                    "devbox_ledger: not recording %r: it holds a tab or a newline, so it runs again on a resume\n" % (path,)
                )
                state["closed"] = True
                return
            append_line(self.ledger, format_file_line(RUNNER, path, "start"))
        if state["closed"]:
            return
        if report.failed:
            state["failed"] = True
        # A test is done at its teardown report, which pytest sends even after a
        # failed setup. Done tests are counted as a set of node ids, because a
        # plugin that reruns a test sends its teardown more than once, and a
        # count of reports would close the file before its last test ran. A
        # report of a worker that crashed has no teardown, so its file stays
        # `start` and runs again.
        if report.when != "teardown":
            return
        expected = (self.expected or {}).get(path)
        if expected is None or report.nodeid not in expected:
            return
        state["done"].add(report.nodeid)
        if len(state["done"]) < len(expected):
            return
        state["closed"] = True
        outcome = "fail" if state["failed"] else "pass"
        seconds = int(round(self.now() - state["started"]))
        append_line(self.ledger, format_file_line(RUNNER, path, outcome, seconds))


# ── the read trace ───────────────────────────────────────────────────────────
#
# Each repository file is a node. A node's own reads are the files it opened and
# the directories it listed while it was the owner. The owner of an event is the
# innermost module whose top level is running, which is a module being imported,
# else the test file being collected or run, else nobody (`-`, the session).
# An import statement adds the edge importer -> imported on every execution,
# a cache hit included, and a test file's reads are the reads of every node it
# reaches through those edges. Under xdist `--dist loadfile` a worker imports a
# helper for its first test file only: a tracer that gave each open to the code
# running at that moment gave the helper's data file to that one test file, and
# a change to the data file then skipped every other test file that reads it.

TRACE_RUNNER = "pytest"

# A child process reads files this process cannot see, section 5.4.
CHILD_EVENTS = frozenset(
    ("subprocess.Popen", "os.system", "os.exec", "os.posix_spawn", "os.spawn", "os.fork", "os.forkpty")
)
READ_EVENTS = frozenset(("open", "os.listdir", "os.scandir"))
TRACE_EVENTS = READ_EVENTS | CHILD_EVENTS | frozenset(("exec",))

TRACED, SETUP, DROPPED = "traced", "setup", "dropped"
SETUP_DIRS = frozenset((".venv", "node_modules"))


def _under(path, base):
    return path == base or path.startswith(base.rstrip(os.sep) + os.sep)


class Tracer:
    """The state of one process's trace. Paths are absolute while the run
    goes; the repository root decides at write time which ones are kept."""

    def __init__(self):
        self.active = False
        self.broken = False
        self.window = None
        self.reads = {}
        self.setup = set()
        self.partial = {}
        self.children = {}
        self.edges = {}
        self.conftests = set()
        self.ran = set()
        self.empty = set()
        self.kinds = {}
        self.import_memo = {}
        self.base_codes = set()
        self.venv = sys.prefix if sys.prefix != getattr(sys, "base_prefix", sys.prefix) else None
        # The interpreter's own library directories, never its whole prefix: a
        # distribution Python's prefix is /usr, and a repository under /usr/src
        # would then drop every read, which records each test file as reading
        # nothing and carries it on any change.
        system = set()
        for key in ("stdlib", "platstdlib", "purelib", "platlib"):
            path = sysconfig.get_paths().get(key)
            if path:
                system.add(path)
        try:
            import site

            user = site.getusersitepackages()
            if isinstance(user, str):
                system.add(user)
        except (ImportError, AttributeError):
            # site is absent under python -S, and an embedded interpreter's site
            # can lack the function. A user site then counts as traced, and a
            # path outside the root is dropped at write time anyway.
            pass
        self.system = tuple(sorted(os.path.abspath(p) for p in system if p))

    def start(self):
        # The modules running at the plugin's own import are the entry script,
        # pytest's main and this plugin. One of them outside the library
        # directories, a /usr/bin/pytest script for one, would own every event
        # that no test file owns, so none of them is ever an owner.
        frame = sys._getframe(1)
        while frame is not None:
            if frame.f_code.co_name == "<module>":
                self.base_codes.add(frame.f_code)
            frame = frame.f_back
        self.original_import = builtins.__import__
        self.original_import_module = importlib.import_module
        self.active = True
        sys.addaudithook(_audit)
        builtins.__import__ = _traced_import
        importlib.import_module = _traced_import_module

    def fail(self, err):
        """A trace that missed one event is wrong in the unsafe direction: a
        test file with a missing read is carried when that file changes. The
        process therefore writes no trace file, and every test file it ran has
        no trace and runs again."""
        if self.active:
            sys.stderr.write("devbox_ledger: the read trace stopped, so this process writes no trace file: %r\n" % (err,))
        self.active = False
        self.broken = True

    def classify(self, path):
        """(kind, absolute path). A relative path is resolved against the
        working directory of the moment, so only an absolute one is memoised."""
        hit = self.kinds.get(path)
        if hit is not None:
            return hit
        if not path or path.startswith("<"):
            result = (DROPPED, path)
        else:
            full = os.path.abspath(path)
            parts = full.split(os.sep)
            if SETUP_DIRS.intersection(parts) or (self.venv is not None and _under(full, self.venv)):
                result = (SETUP, full)
            elif "__pycache__" in parts or any(_under(full, base) for base in self.system):
                result = (DROPPED, full)
            else:
                result = (TRACED, full)
        if os.path.isabs(path):
            self.kinds[path] = result
        return result

    def owner(self, frame):
        while frame is not None:
            code = frame.f_code
            if code.co_name == "<module>" and code not in self.base_codes:
                kind, full = self.classify(code.co_filename)
                if kind == TRACED:
                    return full
            frame = frame.f_back
        return self.window

    def enter(self, node):
        previous = self.window
        self.window = node
        return previous

    def leave(self, previous):
        self.window = previous

    def on_event(self, event, args, frame):
        if event == "exec":
            filename = getattr(args[0], "co_filename", None)
            if not isinstance(filename, str):
                return
            kind, full = self.classify(filename)
            if kind != TRACED:
                return
            if os.path.basename(full) == "conftest.py":
                self.conftests.add(full)
            # A module that runs is a node of whoever runs it, also when the
            # import came from a library, as a framework that imports a
            # settings module by name does, or from runpy.
            owner = self.owner(frame)
            if owner is not None and owner != full:
                self.edges.setdefault(owner, set()).add(full)
            return
        # The import system's own reads, the source and the cache of a module,
        # and the directory listings of its path finder. The module itself is
        # a node, so its source is read through the edge, and a listing of a
        # package directory would select a test file for every file added
        # beside a module it imports.
        if frame is not None and frame.f_code.co_filename.startswith("<frozen importlib"):
            return
        if event in CHILD_EVENTS:
            # A child with no owner is the session's own: xdist's controller
            # starts its workers through subprocess.Popen, which would mark
            # every traced step partial.
            owner = self.owner(frame)
            if owner is not None:
                self.children.setdefault(owner, []).append(_child_command(event, args))
            return
        path = args[0]
        if isinstance(path, int):
            return
        if path is None:
            path = "."
        path = os.fsdecode(path) if isinstance(path, bytes) else os.fspath(path)
        if event == "open":
            if not _opens_for_reading(args[1], args[2]):
                return
            # os.open raises the event without its dir_fd, so a name relative to
            # a directory descriptor reads as one relative to the working
            # directory. pytest's removal of old temporary directories opened
            # hundreds of entry names that way, and each read as a file at the
            # repository root; one that matched a directory there passed a
            # check for the file's existence. A relative os.open counts only
            # when repository code calls it: shutil.rmtree and os.fwalk, the
            # callers that pass a dir_fd, are library code.
            if args[1] is None and not os.path.isabs(path):
                if frame is None or self.classify(frame.f_code.co_filename)[0] != TRACED:
                    return
            kind = "read"
        else:
            kind = "list"
        pkind, full = self.classify(path)
        if pkind == DROPPED:
            return
        owner = self.owner(frame)
        if pkind == SETUP:
            self.setup.add(owner)
        else:
            self.reads.setdefault(owner, set()).add((kind, full))

    def on_import(self, module, name, globals_, fromlist, level, frame):
        importer = globals_.get("__file__") if isinstance(globals_, dict) else None
        key = (importer, name, level, tuple(fromlist) if fromlist else ())
        targets = self.import_memo.get(key)
        if targets is None:
            targets = self.import_targets(module, name, fromlist, level)
            self.import_memo[key] = targets
        traced, setup = targets
        if not traced and not setup:
            return
        ikind, ifull = self.classify(importer) if isinstance(importer, str) else (DROPPED, None)
        if ikind == TRACED:
            owner = ifull
        elif traced:
            # A library's import of a repository module is the owner's edge. Its
            # imports of other libraries mark nothing: every test reaches some.
            owner = self.owner(frame)
            setup = False
        else:
            return
        if owner is None:
            return
        if setup:
            self.setup.add(owner)
        for target in traced:
            if target != owner:
                self.edges.setdefault(owner, set()).add(target)

    def import_targets(self, module, name, fromlist, level):
        """The files an import statement depends on: the module it names, every
        package above it, and each module its from-list names. A package's
        submodule is looked up in sys.modules as well, because during a
        circular import it is not yet an attribute of the package."""
        modules = []
        if fromlist:
            base_name = getattr(module, "__name__", None)
            modules.append(module)
            for item in fromlist:
                if not isinstance(item, str) or item == "*":
                    continue
                sub = sys.modules.get("%s.%s" % (base_name, item)) if base_name else None
                if sub is None:
                    value = getattr(module, item, None)
                    sub = value if isinstance(value, types.ModuleType) else None
                if sub is not None:
                    modules.append(sub)
            full_name = base_name or ""
        else:
            full_name = name if level == 0 else getattr(module, "__name__", "")
        parts = full_name.split(".") if full_name else []
        for i in range(1, len(parts) + 1):
            found = sys.modules.get(".".join(parts[:i]))
            if found is not None:
                modules.append(found)
        traced = set()
        setup = False
        for found in modules:
            filename = getattr(found, "__file__", None)
            if not isinstance(filename, str):
                continue
            kind, full = self.classify(filename)
            if kind == TRACED:
                traced.add(full)
            elif kind == SETUP:
                setup = True
        return (tuple(sorted(traced)), setup)

    def closure(self, test_file):
        """The nodes a test file reaches: itself, the conftest.py files pytest
        applies to it, the __init__.py files of its packages, and every node
        any of them imports. pytest imports a conftest and a test file's
        package itself, so no import statement of the test file names them."""
        roots = [test_file]
        directory = os.path.dirname(test_file)
        for conftest in self.conftests:
            if _under(directory, os.path.dirname(conftest)):
                roots.append(conftest)
        while os.path.isfile(os.path.join(directory, "__init__.py")):
            roots.append(os.path.join(directory, "__init__.py"))
            parent = os.path.dirname(directory)
            if parent == directory:
                break
            directory = parent
        seen = set(roots)
        stack = list(roots)
        while stack:
            for target in self.edges.get(stack.pop(), ()):
                if target not in seen:
                    seen.add(target)
                    stack.append(target)
        return seen

    def lines(self, root, inipath):
        bases = [os.path.abspath(root)]
        real_root = os.path.realpath(root)
        if real_root not in bases:
            bases.append(real_root)
        relative = {}

        def rel(full):
            if full in relative:
                return relative[full]
            result = None
            # A fixture's node is no path, and realpath would resolve its name
            # against the working directory, which is often the root.
            if not os.path.isabs(full):
                relative[full] = None
                return None
            for candidate in (full, os.path.realpath(full)):
                for base in bases:
                    if candidate == base:
                        result = "."
                    elif candidate.startswith(base.rstrip(os.sep) + os.sep):
                        result = candidate[len(base.rstrip(os.sep)) + 1 :].replace(os.sep, "/")
                    if result is not None:
                        break
                if result is not None:
                    break
            relative[full] = result
            return result

        out = set()

        def node_lines(label, node, include_node):
            if include_node:
                path = rel(node)
                if path is not None:
                    add(label, "read", path)
            for kind, full in self.reads.get(node, ()):
                path = rel(full)
                if path is not None:
                    add(label, kind, path + "/" if kind == "list" else path)
            if node in self.setup:
                out.add("setup\t%s\n" % label)
            for reason in self.partial.get(node, ()):
                out.add("partial\t%s\t%s\n" % (label, reason))
            for reason, program, cwd, words in self.children.get(node, ()):
                if _child_may_read(program, cwd, words, bases):
                    out.add("partial\t%s\t%s\n" % (label, reason))

        def add(label, kind, path):
            # A path with a tab or a newline cannot be one field. Dropped, it
            # would be a read nobody records, so the test file is partial.
            if valid_unit(path):
                out.add("%s\t%s\t%s\n" % (kind, label, path))
            else:
                out.add("partial\t%s\ta read path holds a tab or a newline\n" % label)

        for test_file in self.ran | self.empty:
            label = rel(test_file)
            # A test file whose own path cannot be a field gets no line, so it
            # has no trace and runs every time.
            if label is None or label == "." or not valid_unit(label):
                continue
            if inipath:
                ini = rel(os.path.abspath(inipath))
                if ini is not None:
                    add(label, "read", ini)
            for node in self.closure(test_file):
                node_lines(label, node, True)
        node_lines("-", None, False)
        return sorted(out)

    def write(self, trace_dir, root, inipath):
        self.active = False
        if self.broken:
            return
        text = "".join(self.lines(root, inipath))
        target = os.path.join(trace_dir, "%s-%d.trace" % (TRACE_RUNNER, os.getpid()))
        # By rename: the runner joins every *.trace after the step, and a file
        # cut short by a killed process would be a read set with reads missing.
        temp = target + ".tmp"
        try:
            os.makedirs(trace_dir, exist_ok=True)
            with open(temp, "w", encoding="utf-8", errors="surrogateescape") as handle:
                handle.write(text)
            os.replace(temp, target)
        except OSError as err:
            sys.stderr.write("devbox_ledger: could not write the read trace %s, so its test files have no trace: %s\n" % (target, err))


# Section 5.4: an interpreter or a build tool reads the working directory
# without naming it, by program base name. devbox-trace-hook.mjs holds the same
# list for vitest, and the two share nothing but the spec's text.
INTERPRETERS = frozenset(
    (
        "node", "deno", "bun", "ruby", "perl", "php", "java", "sh", "bash", "dash", "zsh",
        "make", "npm", "npx", "pnpm", "yarn", "uv", "poetry", "cargo", "go",
    )
)


def _is_interpreter(word):
    name = os.path.basename(word)
    return name.startswith("python") or name in INTERPRETERS


def _text(value):
    if isinstance(value, bytes):
        return os.fsdecode(value)
    return os.fspath(value)


def _child_command(event, args):
    """(reason, program, cwd, words) of one child process, read while the event
    runs: the program resolved to an absolute path, or None when it does not
    resolve or the event runs no program (a fork), and every word of its
    command split on white space. The root is known only when the trace is
    written, so section 5.4's decision waits for _child_may_read."""
    cwd = os.getcwd()
    env = None
    if event == "subprocess.Popen":
        program, argv, child_cwd, env = args[0], args[1], args[2], args[3]
        if child_cwd is not None:
            cwd = os.path.join(cwd, _text(child_cwd))
    elif event == "os.system":
        program, argv = "/bin/sh", ["sh", "-c", args[0]]
    elif event in ("os.exec", "os.posix_spawn"):
        program, argv, env = args[0], args[1], args[2]
    elif event == "os.spawn":
        program, argv, env = args[1], args[2], args[3]
    else:
        return ("child process (%s -)" % event, None, cwd, ())
    if isinstance(argv, (str, bytes)) or not hasattr(argv, "__iter__"):
        argv = [argv]
    words = []
    for arg in argv:
        words.extend(_text(arg).split())
    program = _text(program) if program is not None else (words[0] if words else "")
    # On a real suite every test file was partial through one session fixture
    # whose library ran `git rev-parse HEAD`; the name in the reason is what
    # tells that child from one that reads the repository. os.system runs the
    # shell, and the reason names the command's first word.
    shown = words[2:3] if event == "os.system" else [program]
    name = os.path.basename(shown[0]) if shown else ""
    reason = "child process (%s %s)" % (event, name if name and valid_unit(name) else "-")
    return (reason, _resolve_program(program, cwd, env), cwd, tuple(words))


def _resolve_program(program, cwd, env):
    """The file the child executes, as the kernel finds it: a name with a slash
    against the child's working directory, a bare name through the PATH of the
    child's environment. None when nothing resolves."""
    if not program:
        return None
    if os.sep in program:
        return os.path.abspath(os.path.join(cwd, program))
    try:
        directories = os.get_exec_path(env)
    except (TypeError, ValueError):
        # An environment that is no mapping, or that holds PATH twice as text
        # and as bytes: the program is then unknown, and unknown is partial.
        return None
    for directory in directories:
        candidate = os.path.abspath(os.path.join(cwd, directory, program))
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    return None


def _child_may_read(program, cwd, words, bases):
    """Section 5.4: a child process reads no repository file when its program
    resolves outside the repository, no word of its command names a path that
    exists inside it, relative to the child's working directory or to the root,
    and no word names an interpreter or a build tool. Every word, the program
    included, is checked against that list, because a launcher such as
    `/usr/bin/env python3` names the interpreter in an argument."""

    def inside(path):
        for candidate in (path, os.path.realpath(path)):
            for base in bases:
                if candidate == base or candidate.startswith(base.rstrip(os.sep) + os.sep):
                    return True
        return False

    if program is None or inside(program) or _is_interpreter(program):
        return True
    for word in words:
        if _is_interpreter(word):
            return True
        for directory in (cwd,) + tuple(bases):
            path = os.path.abspath(os.path.join(directory, word))
            if inside(path) and os.path.lexists(path):
                return True
    return False


def _opens_for_reading(mode, flags):
    if isinstance(mode, str):
        return "r" in mode or "+" in mode
    if isinstance(flags, int):
        return flags & getattr(os, "O_ACCMODE", 3) != os.O_WRONLY
    return True


def _audit(event, args):
    if event not in TRACE_EVENTS or not _TRACER.active:
        return
    try:
        frame = sys._getframe(1)
    except ValueError:
        # An event raised from C with no Python frame: interpreter shutdown.
        frame = None
    try:
        _TRACER.on_event(event, args, frame)
    except Exception as err:  # noqa: BLE001 - Tracer.fail reports it and stops the trace
        _TRACER.fail(err)


def _traced_import(name, globals=None, locals=None, fromlist=(), level=0):  # noqa: A002 - the builtin's own names
    module = _TRACER.original_import(name, globals, locals, fromlist, level)
    if _TRACER.active:
        try:
            _TRACER.on_import(module, name, globals, fromlist, level, sys._getframe(1))
        except Exception as err:  # noqa: BLE001 - Tracer.fail reports it and stops the trace
            _TRACER.fail(err)
    return module


def _traced_import_module(name, package=None):
    module = _TRACER.original_import_module(name, package)
    if _TRACER.active:
        try:
            caller = sys._getframe(1).f_globals
            _TRACER.on_import(module, module.__name__, {"__file__": caller.get("__file__")}, None, 0, sys._getframe(1))
        except Exception as err:  # noqa: BLE001 - Tracer.fail reports it and stops the trace
            _TRACER.fail(err)
    return module


SHARED_SCOPES = frozenset(("session", "package"))


def _fixture_node(fixturedef):
    return "<fixture %s %d>" % (getattr(fixturedef, "argname", "?"), id(fixturedef))


def _node_path(node):
    path = getattr(node, "path", None) or getattr(node, "fspath", None)
    return str(path) if path is not None else None


class TracePlugin:
    """The pytest half of the trace: which test file owns the events of the
    moment, which test files ran in this process, and the write at the end."""

    def __init__(self, config, tracer):
        self.config = config
        self.tracer = tracer

    @_hookimpl(hookwrapper=True)
    def pytest_make_collect_report(self, collector):
        path = _node_path(collector) if isinstance(collector, pytest.File) else None
        if path is None:
            yield
            return
        previous = self.tracer.enter(os.path.abspath(path))
        try:
            outcome = yield
        finally:
            self.tracer.leave(previous)
        # A test file with no test is never in a worker's share, so it would
        # have no line and be selected on every run; pytest given only such
        # files exits 5. Every process collects it alike, so each may write it.
        if getattr(outcome, "excinfo", None) is None:
            report = outcome.get_result()
            if report.passed and not report.result:
                self.tracer.empty.add(os.path.abspath(path))

    # Only a test file that ran here gets lines from this process. Every xdist
    # worker collects every test file, and one that wrote lines for a file that
    # ran elsewhere would write its collection reads alone; a merge would then
    # keep them as the whole read set if the worker that ran it wrote none.
    @_hookimpl(hookwrapper=True)
    def pytest_runtest_protocol(self, item, nextitem):
        path = _node_path(item)
        if path is None:
            yield
            return
        test_file = os.path.abspath(path)
        fixtureinfo = getattr(item, "_fixtureinfo", None)
        for defs in getattr(fixtureinfo, "name2fixturedefs", {}).values():
            for fixturedef in defs:
                if getattr(fixturedef, "scope", None) in SHARED_SCOPES:
                    self.tracer.edges.setdefault(test_file, set()).add(_fixture_node(fixturedef))
        previous = self.tracer.enter(test_file)
        try:
            yield
        finally:
            self.tracer.leave(previous)
        self.tracer.ran.add(test_file)

    # A session or package fixture runs once, inside the first test that asks
    # for it, and every later test takes its value from pytest's cache: the
    # module cache's trap again. Its events go to a node of its own, and every
    # test file whose tests ask for it reaches that node.
    @_hookimpl(hookwrapper=True)
    def pytest_fixture_setup(self, fixturedef, request):
        if getattr(fixturedef, "scope", None) not in SHARED_SCOPES:
            yield
            return
        previous = self.tracer.enter(_fixture_node(fixturedef))
        try:
            yield
        finally:
            self.tracer.leave(previous)

    @_hookimpl(trylast=True)
    def pytest_unconfigure(self, config):
        root = os.environ.get("DEVBOX_TRACE_ROOT") or str(getattr(config, "rootpath", None) or config.rootdir)
        inipath = getattr(config, "inipath", None) or getattr(config, "inifile", None)
        self.tracer.write(os.environ["DEVBOX_TRACE_DIR"], root, str(inipath) if inipath else None)


_TRACER = None
if os.environ.get("DEVBOX_TRACE_DIR"):
    if hasattr(sys, "addaudithook"):
        _TRACER = Tracer()
        _TRACER.start()
    else:
        sys.stderr.write("devbox_ledger: Python %s has no audit hook, so this run writes no read trace\n" % sys.version.split()[0])
