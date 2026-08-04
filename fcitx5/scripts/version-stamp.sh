#!/bin/sh
# Build stamp: <date>.<hash>, plus `.dirty` when the tree carries
# uncommitted changes. The bare hash matches the macOS packaging
# convention; `.dirty` rather than git describe's `-dirty` because a `-`
# reads as a packaging revision to dpkg and is illegal in an rpm version.
# A preset VERSION_STAMP wins (empty means "no stamp") so `make pkg`
# computes the value exactly once for the binary and the package alike.
if [ -n "${VERSION_STAMP+x}" ]; then
    printf '%s\n' "$VERSION_STAMP"
    exit 0
fi
cd "$(dirname "$0")" || exit 1
hash=$(git rev-parse --short=7 HEAD 2> /dev/null || echo unknown)
dirty=$(git diff --quiet HEAD 2> /dev/null || echo .dirty)
echo "$(date +%Y%m%d).${hash}${dirty}"
