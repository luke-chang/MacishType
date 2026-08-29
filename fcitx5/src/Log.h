#pragma once

#include <fcitx-utils/log.h>

namespace MacishType {

FCITX_DECLARE_LOG_CATEGORY(macishtype_logcategory);

// fcitx5 has no notice level, so NOTICE lands on its Warn — the same
// mapping FcitxLogger applies to Logger::Level::Notice. No FAULT for
// the same reason: fcitx5 stops at Error.
#define MACISHTYPE_DEBUG()                                                     \
    FCITX_LOGC(::MacishType::macishtype_logcategory, Debug)
#define MACISHTYPE_INFO()                                                      \
    FCITX_LOGC(::MacishType::macishtype_logcategory, Info)
#define MACISHTYPE_NOTICE()                                                    \
    FCITX_LOGC(::MacishType::macishtype_logcategory, Warn)
#define MACISHTYPE_ERROR()                                                     \
    FCITX_LOGC(::MacishType::macishtype_logcategory, Error)

} // namespace MacishType
