#include "MacishType/EventData.h"

#include <algorithm>
#include <optional>
#include <variant>

#include "MacishType/EngineHost.h"

namespace MacishType {

namespace {

void setStringField(JSContext *ctx, JSValueConst object, const char *name,
                    const std::string &value) {
    JS_SetPropertyStr(ctx, object, name,
                      JS_NewStringLen(ctx, value.c_str(), value.size()));
}

void setBoolField(JSContext *ctx, JSValueConst object, const char *name,
                  bool value) {
    JS_SetPropertyStr(ctx, object, name, JS_NewBool(ctx, value));
}

void setIntField(JSContext *ctx, JSValueConst object, const char *name,
                 int value) {
    JS_SetPropertyStr(ctx, object, name, JS_NewInt32(ctx, value));
}

} // namespace

CandidateWindowConfig resolvedCandidateWindowConfig(const JsEngineHost &host) {
    CandidateWindowConfig config;
    auto stringField = [&](const char *name) -> std::optional<std::string> {
        auto value = host.candidateWindowField(name);
        if (value) {
            if (auto *text = std::get_if<std::string>(&*value)) {
                return *text;
            }
        }
        return std::nullopt;
    };
    auto boolField = [&](const char *name) -> std::optional<bool> {
        auto value = host.candidateWindowField(name);
        if (value) {
            if (auto *flag = std::get_if<bool>(&*value)) {
                return *flag;
            }
        }
        return std::nullopt;
    };
    auto numberField = [&](const char *name) -> std::optional<int> {
        auto value = host.candidateWindowField(name);
        if (value) {
            if (auto *number = std::get_if<double>(&*value)) {
                return static_cast<int>(*number);
            }
        }
        return std::nullopt;
    };
    if (auto labels = stringField("indexLabels")) {
        config.indexLabels = *labels;
    }
    if (auto pageSize = numberField("pageSize")) {
        config.pageSize = std::max(1, *pageSize);
    }
    if (auto direction = stringField("layoutDirection")) {
        config.vertical = *direction == "vertical";
    } else {
        // No manifest direction: the host holds the resolved per-input-method
        // orientation setting (macOS parity).
        config.vertical = host.layoutVertical();
    }
    if (auto navigation = boolField("handleNavigationKeys")) {
        config.handleNavigationKeys = *navigation;
    }
    if (auto labelsKeys = boolField("handleIndexLabelKeys")) {
        config.handleIndexLabelKeys = *labelsKeys;
    }
    if (auto requireShift = boolField("indexLabelDigitsRequireShift")) {
        config.indexLabelDigitsRequireShift = *requireShift;
    }
    return config;
}

CandidateWindowConfig
resolvedAssociatedCandidateWindowConfig(const JsEngineHost &host,
                                        AssociatedSelectionKeys userPolicy) {
    CandidateWindowConfig config = resolvedCandidateWindowConfig(host);
    auto applyDigitLabels = [&config](bool requireShift) {
        config.indexLabels = "1234567890";
        config.pageSize = std::min(config.pageSize, 10);
        config.indexLabelDigitsRequireShift = requireShift;
    };
    switch (userPolicy) {
    case AssociatedSelectionKeys::Numbers:
        applyDigitLabels(false);
        return config;
    case AssociatedSelectionKeys::ShiftNumbers:
        applyDigitLabels(true);
        return config;
    case AssociatedSelectionKeys::FollowEngine:
        break;
    }
    std::string declaration = "numbers";
    if (auto value = host.candidateWindowField("associatedModeIndexLabels")) {
        if (auto *text = std::get_if<std::string>(&*value)) {
            declaration = *text;
        }
    }
    if (declaration == "inherit") {
        return config;
    }
    applyDigitLabels(declaration == "shiftNumbers");
    return config;
}

JSValue buildEventData(JSContext *ctx, const EventStaging &staging,
                       const EventKeyFields *web,
                       const EventCandidate *candidate, int absoluteIndex,
                       const CandidateWindowConfig &window) {
    JSValue data = JS_NewObject(ctx);

    JSValue fields = JS_NewObject(ctx);
    setStringField(ctx, fields, "markedText", staging.markedText);
    setStringField(ctx, fields, "stagedText", staging.stagedText);
    setBoolField(ctx, fields, "isComposing", !staging.markedText.empty());
    setBoolField(ctx, fields, "isAssociating", staging.isAssociating);
    if (staging.message.empty()) {
        JS_SetPropertyStr(ctx, fields, "message", JS_NULL);
    } else {
        setStringField(ctx, fields, "message", staging.message);
    }
    if (web != nullptr) {
        setStringField(ctx, fields, "key", web->key);
        setStringField(ctx, fields, "code", web->code);
        setStringField(ctx, fields, "keyIgnoringModifiers",
                       web->keyIgnoringModifiers);
        setBoolField(ctx, fields, "shiftKey", web->shiftKey);
        setBoolField(ctx, fields, "ctrlKey", web->ctrlKey);
        setBoolField(ctx, fields, "altKey", web->altKey);
        setBoolField(ctx, fields, "metaKey", web->metaKey);
        setBoolField(ctx, fields, "repeat", web->repeat);
        setIntField(ctx, fields, "location", web->location);
    }
    if (candidate != nullptr) {
        setStringField(ctx, fields, "candidate", candidate->text);
        setIntField(ctx, fields, "absoluteIndex", absoluteIndex);
        if (!candidate->annotation.empty()) {
            setStringField(ctx, fields, "annotation", candidate->annotation);
        }
        if (candidate->hasPayload) {
            JS_SetPropertyStr(ctx, fields, "payload",
                              JS_DupValue(ctx, candidate->payload));
        }
    }
    JS_SetPropertyStr(ctx, data, "fields", fields);

    if (web != nullptr) {
        JSValue states = JS_NewObject(ctx);
        setBoolField(ctx, states, "Shift", web->shiftKey);
        setBoolField(ctx, states, "Control", web->ctrlKey);
        setBoolField(ctx, states, "Alt", web->altKey);
        setBoolField(ctx, states, "Meta", web->metaKey);
        setBoolField(ctx, states, "CapsLock", web->capsLock);
        setBoolField(ctx, states, "NumLock", web->numLock);
        setBoolField(ctx, states, "AltGraph", web->altGraph);
        JS_SetPropertyStr(ctx, data, "modifierStates", states);
    }

    JSValue candidateWindow = JS_NewObject(ctx);
    setBoolField(ctx, candidateWindow, "isVisible", staging.candidatesVisible);
    setStringField(ctx, candidateWindow, "indexLabels", window.indexLabels);
    setIntField(ctx, candidateWindow, "pageSize", window.pageSize);
    setStringField(ctx, candidateWindow, "layoutDirection",
                   window.vertical ? "vertical" : "horizontal");
    setBoolField(ctx, candidateWindow, "handleNavigationKeys",
                 window.handleNavigationKeys);
    setBoolField(ctx, candidateWindow, "handleIndexLabelKeys",
                 window.handleIndexLabelKeys);
    setBoolField(ctx, candidateWindow, "indexLabelDigitsRequireShift",
                 window.indexLabelDigitsRequireShift);
    setIntField(ctx, candidateWindow, "pageItemCount", staging.pageItemCount);
    JS_SetPropertyStr(ctx, data, "candidateWindow", candidateWindow);

    return data;
}

} // namespace MacishType
