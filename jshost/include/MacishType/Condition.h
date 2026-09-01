#pragma once

#include <map>
#include <string>
#include <vector>

#include "MacishType/JsonValue.h"

namespace MacishType {

// A parsed disabledWhen/hiddenWhen condition (settings and menu share the
// grammar). A leaf carries exactly one operator: Equals/NotEquals hold one
// operand, In/NotIn hold every listed one.
struct Condition {
    enum class Kind { Leaf, AllOf, AnyOf, Not };
    enum class Op { Equals, NotEquals, In, NotIn };

    Kind kind = Kind::AllOf;
    // Leaf only.
    std::string key;
    Op op = Op::Equals;
    std::vector<JsonValue> operands;
    // AllOf/AnyOf children; exactly one for Not.
    std::vector<Condition> children;
};

// Evaluates against a flat key→value map. Missing keys read as JSON null,
// so notEquals/notIn against an unknown key are permanently true.
bool evaluateCondition(const Condition &condition,
                       const std::map<std::string, JsonValue> &values);

} // namespace MacishType
