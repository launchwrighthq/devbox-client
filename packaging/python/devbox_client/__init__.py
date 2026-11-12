"""Console script that hands control to the bash CLI this distribution carries.

A bash program is not a python entry point, so pip cannot put client/bin/devbox in
.venv/bin by itself. Copying the script there instead of shimming would break the
library resolution that every devbox executable performs: each one looks for
devbox-lib.sh two levels above itself, and .venv/bin is not two levels above the
installed lib/. So the real CLI stays inside the package, at the same depth it has in
the repository, and this launcher points at it.
"""

import os
import sys

CLI = os.path.join(os.path.dirname(os.path.abspath(__file__)), "client", "bin", "devbox")


def main():
    if not os.path.isfile(CLI):
        sys.exit("devbox: the packaged CLI is missing at " + CLI)
    argv = sys.argv[1:]
    # os.exec* REPLACES this process, so the gate's exit code and its signals reach the
    # caller unchanged. `make verify` reads that exit code, and a subprocess wrapper
    # would have to forward both by hand.
    if os.access(CLI, os.X_OK):
        os.execv(CLI, [CLI] + argv)
    # A wheel is a zip and does not have to preserve the executable bit, so name the
    # interpreter rather than fail with EACCES on an installer that drops the mode.
    # bash is the real dependency of this package either way.
    os.execvp("bash", ["bash", CLI] + argv)
