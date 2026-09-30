#!/usr/bin/env python3
"""Copy the processed Array data tables into this engine folder.

The tables are produced into <repo>/tables/ by the shared external-resources
pipeline and are gitignored. This script copies them here under the same
names, running the pipeline first if its tables are missing or stale; a copy
already matching its table is left untouched.

With --check nothing is changed: the exit status is 1 when a sync would
change something, 0 otherwise.
"""

import filecmp
import os
import shutil
import subprocess
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(os.path.dirname(SCRIPT_DIR))
TABLES = [
    "Array30.txt", "ArrayShortCode.txt", "ArrayPhrase.txt", "ArraySymbol.txt",
]


def is_current(table):
    copy = os.path.join(SCRIPT_DIR, table)
    return os.path.isfile(copy) and filecmp.cmp(
        os.path.join(REPO_ROOT, "tables", table), copy, shallow=False)


def main():
    # Keep the ✓/→ output printable on consoles that default to a non-UTF-8
    # encoding (Windows), where an unencodable glyph would otherwise abort
    # the copy midway.
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(errors="replace")

    check_only = sys.argv[1:] == ["--check"]
    if sys.argv[1:] and not check_only:
        print("Usage: setup.py [--check]", file=sys.stderr)
        sys.exit(2)

    driver = os.path.join(REPO_ROOT, "scripts", "ExternalResources.py")
    if subprocess.run([sys.executable, driver, "--check"]).returncode:
        if check_only:
            sys.exit(1)
        print("→ Tables are missing or stale; running the resource"
              " pipeline...")
        if subprocess.run([sys.executable, driver, "--prepare"]).returncode:
            sys.exit(1)
    if check_only:
        stale = [table for table in TABLES if not is_current(table)]
        for table in stale:
            print(f"  ✗ {table} (out of date)")
        sys.exit(1 if stale else 0)
    for table in TABLES:
        if is_current(table):
            print(f"  = {table}")
            continue
        shutil.copyfile(os.path.join(REPO_ROOT, "tables", table),
                        os.path.join(SCRIPT_DIR, table))
        print(f"  ✓ {table}")
    print(f"✓ Array tables synced to {SCRIPT_DIR}")


if __name__ == "__main__":
    main()
