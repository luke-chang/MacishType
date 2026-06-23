#!/bin/sh
# setup.sh — copy the processed Array data tables into this engine folder.
#
# This JS engine mirrors the bundled Swift Array engine, which reads its tables
# from the repo's build resources. Those tables are produced by `make prepare`
# (see Scripts/HandleExternalResources.sh) and are gitignored. This script copies
# them here under the same names; if any are missing, it runs `make prepare`
# first.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$SCRIPT_DIR/../.."

# Source (under REPO_ROOT) and destination (basename, under SCRIPT_DIR) pairs.
SOURCES="
MacishType/ArrayEngine/Resources/Array30.txt
MacishType/ArrayEngine/Resources/ArrayShortCode.txt
MacishType/ArrayEngine/Resources/ArrayPhrase.txt
MacishType/ArrayEngine/Resources/ArraySymbol.txt
"

missing=0
for src in $SOURCES; do
    test -f "$REPO_ROOT/$src" || missing=1
done

if [ "$missing" -eq 1 ]; then
    echo "→ Some source tables are missing; running \`make prepare\`..."
    make -C "$REPO_ROOT" prepare
fi

for src in $SOURCES; do
    cp "$REPO_ROOT/$src" "$SCRIPT_DIR/$(basename "$src")"
    echo "  ✓ $(basename "$src")"
done

echo "✓ Array tables synced to $SCRIPT_DIR"
