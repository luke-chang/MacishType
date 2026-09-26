#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <limits>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include <quickjs.h>

#include "MacishType/JsonValue.h"

namespace MacishType::Qjs {

// Move-only RAII owner for a JSValue reference.
class Value {
public:
    Value() = default;
    Value(JSContext *ctx, JSValue value) : ctx_(ctx), value_(value) {}
    Value(const Value &) = delete;
    Value &operator=(const Value &) = delete;
    Value(Value &&other) noexcept
        : ctx_(other.ctx_), value_(other.value_) {
        other.ctx_ = nullptr;
        other.value_ = JS_UNDEFINED;
    }
    Value &operator=(Value &&other) noexcept {
        if (this != &other) {
            reset();
            ctx_ = other.ctx_;
            value_ = other.value_;
            other.ctx_ = nullptr;
            other.value_ = JS_UNDEFINED;
        }
        return *this;
    }
    ~Value() { reset(); }

    JSValue get() const { return value_; }
    JSValue release() {
        JSValue value = value_;
        ctx_ = nullptr;
        value_ = JS_UNDEFINED;
        return value;
    }
    Value dup() const { return Value(ctx_, JS_DupValue(ctx_, value_)); }
    bool isException() const { return JS_IsException(value_); }
    bool isUndefined() const { return JS_IsUndefined(value_); }
    bool isFunction() const {
        return ctx_ != nullptr && JS_IsFunction(ctx_, value_);
    }

private:
    void reset() {
        if (ctx_ != nullptr) {
            JS_FreeValue(ctx_, value_);
        }
        ctx_ = nullptr;
        value_ = JS_UNDEFINED;
    }

    JSContext *ctx_ = nullptr;
    JSValue value_ = JS_UNDEFINED;
};

// quickjs hands unpaired surrogates back as WTF-8 (0xED 0xA0-0xBF ..),
// which UTF-8 has no encoding for. Rewrite each to U+FFFD, three bytes
// either way, so byte offsets into the string still line up.
inline void replaceLoneSurrogates(std::string &text) {
    if (std::memchr(text.data(), 0xED, text.size()) == nullptr) {
        return;
    }
    for (size_t i = 0; i + 2 < text.size(); i++) {
        if (static_cast<uint8_t>(text[i]) == 0xED &&
            static_cast<uint8_t>(text[i + 1]) >= 0xA0 &&
            static_cast<uint8_t>(text[i + 1]) <= 0xBF) {
            text[i] = '\xEF';
            text[i + 1] = '\xBF';
            text[i + 2] = '\xBD';
            i += 2;
        }
    }
}

// JS_ToCString round trip; returns empty string on failure. The single
// funnel every engine string passes through to reach std::string, so the
// WTF-8 repair belongs here.
inline std::string toString(JSContext *ctx, JSValueConst value) {
    size_t len = 0;
    const char *cstr = JS_ToCStringLen(ctx, &len, value);
    if (cstr == nullptr) {
        // A Symbol, or a toString that throws. Take the exception rather
        // than leave it pending: the next error report to read the context
        // would print this one in place of its own.
        JS_FreeValue(ctx, JS_GetException(ctx));
        return {};
    }
    std::string result(cstr, len);
    JS_FreeCString(ctx, cstr);
    replaceLoneSurrogates(result);
    return result;
}

// Text the engine supplied where the contract asks for a string. undefined
// and null read as "not given" the way an omitted argument does; every other
// type stringifies, as it would anywhere else in JavaScript.
inline std::string optionalText(JSContext *ctx, JSValueConst value) {
    if (JS_IsUndefined(value) || JS_IsNull(value)) {
        return {};
    }
    return toString(ctx, value);
}

inline std::string textArgument(JSContext *ctx, int argc, JSValueConst *argv,
                                int index) {
    return argc <= index ? std::string() : optionalText(ctx, argv[index]);
}

inline std::optional<double> numberValue(JSContext *ctx, JSValueConst value) {
    double number = 0;
    if (!JS_IsNumber(value) || JS_ToFloat64(ctx, &number, value) != 0) {
        return std::nullopt;
    }
    return number;
}

// NaN reads as absent like a value of another type. Fractions truncate, and
// a number beyond an int, either infinity included, saturates rather than
// wrapping.
inline std::optional<int> intValue(JSContext *ctx, JSValueConst value) {
    auto number = numberValue(ctx, value);
    if (!number || std::isnan(*number)) {
        return std::nullopt;
    }
    return static_cast<int>(
        std::clamp(*number,
                   static_cast<double>(std::numeric_limits<int>::min()),
                   static_cast<double>(std::numeric_limits<int>::max())));
}

// Typed property reads: nullopt when the property is absent or of another
// type; numbers follow the value reads above.
inline std::optional<double> numberProperty(JSContext *ctx,
                                            JSValueConst object,
                                            const char *name) {
    Value value(ctx, JS_GetPropertyStr(ctx, object, name));
    return numberValue(ctx, value.get());
}

inline std::optional<int> intProperty(JSContext *ctx, JSValueConst object,
                                      const char *name) {
    Value value(ctx, JS_GetPropertyStr(ctx, object, name));
    return intValue(ctx, value.get());
}

inline std::optional<bool> boolProperty(JSContext *ctx, JSValueConst object,
                                        const char *name) {
    Value value(ctx, JS_GetPropertyStr(ctx, object, name));
    if (!JS_IsBool(value.get())) {
        return std::nullopt;
    }
    return JS_ToBool(ctx, value.get()) == 1;
}

inline std::optional<std::string> stringProperty(JSContext *ctx,
                                                 JSValueConst object,
                                                 const char *name) {
    Value value(ctx, JS_GetPropertyStr(ctx, object, name));
    if (!JS_IsString(value.get())) {
        return std::nullopt;
    }
    return toString(ctx, value.get());
}

inline std::string textProperty(JSContext *ctx, JSValueConst object,
                                const char *name) {
    Value value(ctx, JS_GetPropertyStr(ctx, object, name));
    return optionalText(ctx, value.get());
}

// JSON text of a JS value; empty for undefined or stringify failure.
inline std::string jsonStringify(JSContext *ctx, JSValueConst value) {
    if (JS_IsUndefined(value)) {
        return {};
    }
    Value json(ctx, JS_JSONStringify(ctx, value, JS_UNDEFINED, JS_UNDEFINED));
    if (!JS_IsString(json.get())) {
        return {};
    }
    return toString(ctx, json.get());
}

// Converts a JSON-shaped JS value (as produced by JS_ParseJSON) into a
// structural JsonValue, key-sorting object entries as JsonValue equality
// requires. Anything non-JSON (undefined, functions) maps to null.
inline JsonValue toJsonValue(JSContext *ctx, JSValueConst value) {
    JsonValue result;
    if (JS_IsBool(value)) {
        result.data = JS_ToBool(ctx, value) == 1;
    } else if (JS_IsNumber(value)) {
        double number = 0;
        JS_ToFloat64(ctx, &number, value);
        result.data = number;
    } else if (JS_IsString(value)) {
        result.data = toString(ctx, value);
    } else if (JS_IsArray(value)) {
        std::vector<JsonValue> elements;
        Value length(ctx, JS_GetPropertyStr(ctx, value, "length"));
        uint32_t count = 0;
        JS_ToUint32(ctx, &count, length.get());
        elements.reserve(count);
        for (uint32_t i = 0; i < count; i++) {
            Value element(ctx, JS_GetPropertyUint32(ctx, value, i));
            elements.push_back(toJsonValue(ctx, element.get()));
        }
        result.data = std::move(elements);
    } else if (JS_IsObject(value)) {
        std::vector<std::pair<std::string, JsonValue>> entries;
        JSPropertyEnum *properties = nullptr;
        uint32_t count = 0;
        if (JS_GetOwnPropertyNames(ctx, &properties, &count, value,
                                   JS_GPN_STRING_MASK | JS_GPN_ENUM_ONLY) ==
            0) {
            entries.reserve(count);
            for (uint32_t i = 0; i < count; i++) {
                const char *key = JS_AtomToCString(ctx, properties[i].atom);
                if (key != nullptr) {
                    Value propertyValue(
                        ctx, JS_GetProperty(ctx, value, properties[i].atom));
                    entries.emplace_back(
                        key, toJsonValue(ctx, propertyValue.get()));
                    JS_FreeCString(ctx, key);
                }
            }
            JS_FreePropertyEnum(ctx, properties, count);
        }
        std::sort(entries.begin(), entries.end(),
                  [](const auto &left, const auto &right) {
                      return left.first < right.first;
                  });
        result.data = std::move(entries);
    }
    return result;
}

// Renders an error value as "message\nstack" (stack appended when present).
// Works for any thrown/rejected value, not just the pending exception.
inline std::string errorText(JSContext *ctx, JSValueConst value) {
    std::string text = toString(ctx, value);
    if (JS_IsObject(value)) {
        Value stack(ctx, JS_GetPropertyStr(ctx, value, "stack"));
        if (!stack.isUndefined() && !stack.isException()) {
            std::string stackText = toString(ctx, stack.get());
            if (!stackText.empty()) {
                text += "\n" + stackText;
            }
        }
    }
    return text;
}

// Takes the pending exception and renders "message\nstack".
inline std::string exceptionText(JSContext *ctx) {
    Value exception(ctx, JS_GetException(ctx));
    return errorText(ctx, exception.get());
}

} // namespace MacishType::Qjs
