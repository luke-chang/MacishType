#include "OptionName.h"

#include <fcitx-utils/charutils.h>

namespace MacishType::Fcitx5 {

std::string encodeOptionName(const std::string &key) {
    static constexpr char hexDigits[] = "0123456789ABCDEF";
    std::string encoded;
    encoded.reserve(key.size());
    for (unsigned char byte : key) {
        if (byte <= 0x20 || byte == '%' || byte == '=' || byte == '#' ||
            byte == '[' || byte == ']' || byte == '/') {
            encoded += '%';
            encoded += hexDigits[byte >> 4];
            encoded += hexDigits[byte & 0xF];
        } else {
            encoded += static_cast<char>(byte);
        }
    }
    return encoded;
}

std::string decodeOptionName(const std::string &name) {
    std::string decoded;
    decoded.reserve(name.size());
    for (size_t i = 0; i < name.size(); i++) {
        if (name[i] == '%' && i + 2 < name.size()) {
            int high = fcitx::charutils::fromHex(name[i + 1]);
            int low = fcitx::charutils::fromHex(name[i + 2]);
            if (high >= 0 && low >= 0) {
                decoded += static_cast<char>((high << 4) | low);
                i += 2;
                continue;
            }
        }
        decoded += name[i];
    }
    return decoded;
}

} // namespace MacishType::Fcitx5
