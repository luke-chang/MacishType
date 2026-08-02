#!/bin/sh
# Emits a preprocessor header consumed by INFOPLIST_PREPROCESS, so Info.plist can
# embed the git commit hash at processing time. This replaces a post-build script
# that edited the processed Info.plist: the build system re-runs ProcessInfoPlistFile
# on incremental builds when it sees that output was modified, which clobbered the
# edit. Injecting through the preprocessor keeps the value part of the generated
# plist, so it survives re-processing.
#
# Runs on every build (the phase opts out of dependency analysis) so the value
# tracks the current git state. Works identically for Xcode and xcodebuild/make.
#
# CFBundleVersion is intentionally not handled here: GENERATE_INFOPLIST_FILE owns
# it via CURRENT_PROJECT_VERSION, which the Makefile sets to a build date.
set -e

header="${DERIVED_FILE_DIR}/BuildInfo.h"
mkdir -p "${DERIVED_FILE_DIR}"

git_hash=$(git -C "${PROJECT_DIR}" describe --always --dirty 2>/dev/null || echo unknown)

# Bare token (no quotes): the preprocessor substitutes it verbatim into the plist
# string value, e.g. <string>GIT_COMMIT_HASH</string> -> <string>abc123</string>.
printf '#define GIT_COMMIT_HASH %s\n' "${git_hash}" > "${header}"
