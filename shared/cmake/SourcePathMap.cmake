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
    # cl.exe ignores /pathmap (D9007) unless deterministic mode is on, and
    # that mode both rejects /ZI and cannot read the cache incremental link
    # time code generation leaves behind. CMake defaults MSVC to /Zi, so only
    # the latter needs care here: a project turning on interprocedural
    # optimization has to ask for the full mode, or a rebuild that recompiles
    # anything fails with C1354.
    add_compile_options("/experimental:deterministic"
                        "/pathmap:${MACISHTYPE_REPO_ROOT}=.")
    # The compiler option does not reach the pdb path the linker writes into
    # the image. GNU and Clang need no counterpart.
    add_link_options("/PDBALTPATH:%_PDB%")
endif()
