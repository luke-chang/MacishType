file(GLOB po_files "${CMAKE_CURRENT_SOURCE_DIR}/*.po")
foreach(po_file ${po_files})
    get_filename_component(lang "${po_file}" NAME_WE)
    set(mo_file "${CMAKE_CURRENT_BINARY_DIR}/${lang}.mo")
    add_custom_command(
        OUTPUT "${mo_file}"
        COMMAND ${GETTEXT_MSGFMT_EXECUTABLE} -o "${mo_file}" "${po_file}"
        DEPENDS "${po_file}")
    add_custom_target(translation-${lang} ALL DEPENDS "${mo_file}")
    install(FILES "${mo_file}"
            DESTINATION "share/locale/${lang}/LC_MESSAGES"
            RENAME "fcitx5-macishtype.mo")
endforeach()
