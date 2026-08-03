#!/usr/bin/env python3
"""Copy the processed Array data tables into this engine folder.

The tables are produced into <repo>/tables/ by the shared external-resources
pipeline and are gitignored. This script copies them here under the same
names, running the pipeline first if any are missing.
"""

import os
import shutil
import subprocess
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(os.path.dirname(SCRIPT_DIR))
TABLES = [
    "Array30.txt", "ArrayShortCode.txt", "ArrayPhrase.txt", "ArraySymbol.txt",
]


def main():
    driver = os.path.join(REPO_ROOT, "scripts", "external-resources.py")
    if subprocess.run([sys.executable, driver, "--check"]).returncode:
        print("→ Tables are missing or stale; running the resource"
              " pipeline...")
        if subprocess.run([sys.executable, driver, "--prepare"]).returncode:
            sys.exit(1)
    for table in TABLES:
        shutil.copyfile(os.path.join(REPO_ROOT, "tables", table),
                        os.path.join(SCRIPT_DIR, table))
        print(f"  ✓ {table}")
    print(f"✓ Array tables synced to {SCRIPT_DIR}")


if __name__ == "__main__":
    main()
