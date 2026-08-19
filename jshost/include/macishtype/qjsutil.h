#pragma once

#include <string>
#include <utility>

#include <quickjs.h>

namespace macishtype::qjs {

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

// JS_ToCString round trip; returns empty string on failure.
inline std::string toString(JSContext *ctx, JSValueConst value) {
    size_t len = 0;
    const char *cstr = JS_ToCStringLen(ctx, &len, value);
    if (cstr == nullptr) {
        return {};
    }
    std::string result(cstr, len);
    JS_FreeCString(ctx, cstr);
    return result;
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

} // namespace macishtype::qjs
