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
"""

import errno
import os
import sys
import time

try:
    import pytest

    _hookimpl = pytest.hookimpl
except ImportError:
    # Under pytest this import cannot fail, because pytest is what loaded this
    # module. tests/test-ledger-tools.sh drives the hooks on a machine with no
    # pytest, and the markers are then no-ops.
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
