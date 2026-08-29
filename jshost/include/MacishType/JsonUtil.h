#pragma once

#include <cstdio>
#include <string>
#include <string_view>

namespace MacishType {

// Escapes text for embedding inside a JSON string literal.
inline std::string jsonEscape(std::string_view text) {
    std::string escaped;
    escaped.reserve(text.size() + 8);
    for (char ch : text) {
        switch (ch) {
        case '"':
            escaped += "\\\"";
            break;
        case '\\':
            escaped += "\\\\";
            break;
        case '\n':
            escaped += "\\n";
            break;
        case '\r':
            escaped += "\\r";
            break;
        case '\t':
            escaped += "\\t";
            break;
        default:
            if (static_cast<unsigned char>(ch) < 0x20) {
                char buffer[8];
                std::snprintf(buffer, sizeof(buffer), "\\u%04x",
                              static_cast<unsigned char>(ch));
                escaped += buffer;
            } else {
                escaped += ch;
            }
        }
    }
    return escaped;
}

} // namespace MacishType
