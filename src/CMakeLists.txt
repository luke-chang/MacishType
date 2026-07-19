add_library(macishtype SHARED
    enginediscovery.cpp
    enginesettings.cpp
    enginewatcher.cpp
    i18n.cpp
    webkeymap.cpp
    jshost/enginehost.cpp
    jshost/fontcoverage.cpp
    jshost/manifest.cpp
    macishtype.cpp
    session.cpp
)
target_compile_definitions(macishtype PRIVATE
    FCITX_INSTALL_LOCALEDIR="${FCITX_INSTALL_LOCALEDIR}")
target_link_libraries(macishtype PRIVATE Fcitx5::Core Fcitx5::Module::Notifications qjs
    Fontconfig::Fontconfig)
install(TARGETS macishtype DESTINATION "${FCITX_INSTALL_LIBDIR}/fcitx5")

install(FILES
    "${CMAKE_SOURCE_DIR}/runtime/hostglue.js"
    "${CMAKE_SOURCE_DIR}/runtime/runtime.js"
    DESTINATION "${FCITX_INSTALL_PKGDATADIR}/macishtype")

configure_file(macishtype-addon.conf.in macishtype-addon.conf @ONLY)
install(FILES "${CMAKE_CURRENT_BINARY_DIR}/macishtype-addon.conf"
        RENAME macishtype.conf
        DESTINATION "${FCITX_INSTALL_PKGDATADIR}/addon")
