#include "MacishType/Condition.h"

#include <algorithm>

namespace MacishType {

bool evaluateCondition(const Condition &condition,
                       const std::map<std::string, JsonValue> &values) {
    auto evaluateChild = [&](const Condition &child) {
        return evaluateCondition(child, values);
    };
    switch (condition.kind) {
    case Condition::Kind::AllOf:
        return std::all_of(condition.children.begin(),
                           condition.children.end(), evaluateChild);
    case Condition::Kind::AnyOf:
        return std::any_of(condition.children.begin(),
                           condition.children.end(), evaluateChild);
    case Condition::Kind::Not:
        return !condition.children.empty() &&
               !evaluateCondition(condition.children.front(), values);
    case Condition::Kind::Leaf:
        break;
    }

    JsonValue current;
    if (auto found = values.find(condition.key); found != values.end()) {
        current = found->second;
    }
    const bool matched = std::find(condition.operands.begin(),
                                   condition.operands.end(),
                                   current) != condition.operands.end();
    switch (condition.op) {
    case Condition::Op::Equals:
    case Condition::Op::In:
        return matched;
    case Condition::Op::NotEquals:
    case Condition::Op::NotIn:
        return !matched;
    }
    return false;
}

} // namespace MacishType
