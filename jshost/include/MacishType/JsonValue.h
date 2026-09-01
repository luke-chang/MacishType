#pragma once

#include <string>
#include <utility>
#include <variant>
#include <vector>

namespace MacishType {

// Structural JSON value for manifest condition comparisons; monostate is
// JSON null. Objects are entry vectors rather than a std::map, which is
// not guaranteed to accept an incomplete value type — producers must sort
// them by key (Qjs::toJsonValue does), which is what leaves the defaulted
// equality deep and key-order-insensitive as the contract requires.
struct JsonValue {
    std::variant<std::monostate, bool, double, std::string,
                 std::vector<JsonValue>,
                 std::vector<std::pair<std::string, JsonValue>>>
        data;

    bool operator==(const JsonValue &) const = default;
};

} // namespace MacishType
