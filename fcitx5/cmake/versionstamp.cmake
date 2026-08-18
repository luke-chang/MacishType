# Build-time generator run as `cmake -P` on every build: composes the full
# version (PROJECT_VERSION plus the stamp from STAMP_SCRIPT) and writes
# versionstamp.cpp / version-full.txt into OUTPUT_DIR. Files are rewritten
# only when their content changes, so an unchanged stamp triggers neither a
# recompile nor a relink. A dirty tree's stamp carries the build time, which
# costs those builds this one generated source plus a relink.
execute_process(COMMAND "${STAMP_SCRIPT}"
    RESULT_VARIABLE stamp_result
    OUTPUT_VARIABLE stamp
    OUTPUT_STRIP_TRAILING_WHITESPACE)
if(NOT stamp_result EQUAL 0)
    message(FATAL_ERROR "${STAMP_SCRIPT} failed (${stamp_result})")
endif()

if(stamp STREQUAL "")
    set(full_version "${PROJECT_VERSION}")
else()
    set(full_version "${PROJECT_VERSION}+${stamp}")
endif()

function(write_if_changed path content)
    if(EXISTS "${path}")
        file(READ "${path}" previous)
        if(previous STREQUAL content)
            return()
        endif()
    endif()
    file(WRITE "${path}" "${content}")
endfunction()

write_if_changed("${OUTPUT_DIR}/version-full.txt" "${full_version}\n")
write_if_changed("${OUTPUT_DIR}/versionstamp.cpp"
    "// Generated at build time; do not edit.
namespace macishtype {
const char *versionStampFull() { return \"${full_version}\"; }
} // namespace macishtype
")
