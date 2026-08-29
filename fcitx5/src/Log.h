#pragma once

#include <fcitx-utils/log.h>

namespace MacishType {

FCITX_DECLARE_LOG_CATEGORY(macishtype_logcategory);

#define MACISHTYPE_DEBUG()                                                     \
    FCITX_LOGC(::MacishType::macishtype_logcategory, Debug)
#define MACISHTYPE_INFO()                                                      \
    FCITX_LOGC(::MacishType::macishtype_logcategory, Info)
#define MACISHTYPE_WARN()                                                      \
    FCITX_LOGC(::MacishType::macishtype_logcategory, Warn)
#define MACISHTYPE_ERROR()                                                     \
    FCITX_LOGC(::MacishType::macishtype_logcategory, Error)

} // namespace MacishType
