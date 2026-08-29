# Keep the build machine's directory layout out of the artifacts: __FILE__,
# std::source_location and debug info all record whatever path the compiler
# was handed, which for an out-of-tree build is absolute. Mapping the repo
# root makes them relative, so a shipped package carries no trace of where
# it was built.
#
# The root is derived from this file rather than from the including project,
# so it stays correct wherever the projects sit.
get_filename_component(MACISHTYPE_REPO_ROOT "${CMAKE_CURRENT_LIST_DIR}/../.."
                       ABSOLUTE)
if(CMAKE_CXX_COMPILER_ID MATCHES "GNU|Clang")
    add_compile_options("-ffile-prefix-map=${MACISHTYPE_REPO_ROOT}=.")
elseif(MSVC)
    add_compile_options("/pathmap:${MACISHTYPE_REPO_ROOT}=.")
endif()
