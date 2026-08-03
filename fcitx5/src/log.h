#pragma once

#include <fcitx-utils/log.h>

namespace macishtype {

FCITX_DECLARE_LOG_CATEGORY(macishtype_logcategory);

#define MACISHTYPE_DEBUG()                                                     \
    FCITX_LOGC(::macishtype::macishtype_logcategory, Debug)
#define MACISHTYPE_INFO()                                                      \
    FCITX_LOGC(::macishtype::macishtype_logcategory, Info)
#define MACISHTYPE_WARN()                                                      \
    FCITX_LOGC(::macishtype::macishtype_logcategory, Warn)
#define MACISHTYPE_ERROR()                                                     \
    FCITX_LOGC(::macishtype::macishtype_logcategory, Error)

} // namespace macishtype
