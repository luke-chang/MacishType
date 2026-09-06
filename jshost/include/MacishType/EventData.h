#pragma once

#include <string>

#include <quickjs.h>

namespace MacishType {

class JsEngineHost;

// The hostglue hook that wraps the event data for engines.
inline constexpr char c_MakeEventHook[] = "__MacishTypeHost_makeEvent";

// Effective candidate window behavior: the engine/manifest overlay
// resolved against the contract defaults.
struct CandidateWindowConfig {
    std::string indexLabels = "1234567890";
    int pageSize = 9;
    bool vertical = false;
    bool handleNavigationKeys = true;
    bool handleIndexLabelKeys = true;
    bool indexLabelDigitsRequireShift = false;
};

CandidateWindowConfig resolvedCandidateWindowConfig(const JsEngineHost &host);

// The host's associated-mode selection-keys setting.
enum class AssociatedSelectionKeys { FollowEngine, Numbers, ShiftNumbers };

CandidateWindowConfig
resolvedAssociatedCandidateWindowConfig(const JsEngineHost &host,
                                        AssociatedSelectionKeys userPolicy);

// Key fields in the contract's web KeyboardEvent vocabulary.
struct EventKeyFields {
    std::string key;
    std::string code;
    std::string keyIgnoringModifiers;
    bool shiftKey = false;
    bool ctrlKey = false;
    bool altKey = false;
    bool metaKey = false;
    bool capsLock = false;
    bool numLock = false;
    bool repeat = false;
    int location = 0;
};

// A candidate being confirmed; payload is borrowed from the caller.
struct EventCandidate {
    std::string text;
    std::string annotation;
    JSValueConst payload = JS_UNDEFINED;
    bool hasPayload = false;
};

// The embedder's staging snapshot the event exposes to the engine
// (call-scoped views: the strings are borrowed, not owned).
struct EventStaging {
    const std::string &markedText;
    const std::string &stagedText;
    // Empty when no message is showing; the event field reads null.
    const std::string &message;
    bool isAssociating = false;
    bool candidatesVisible = false;
    int pageItemCount = 0;
};

// The __MacishTypeHost_makeEvent input: fields, modifierStates (key events
// only), and candidateWindow. web/candidate may be null.
JSValue buildEventData(JSContext *ctx, const EventStaging &staging,
                       const EventKeyFields *web,
                       const EventCandidate *candidate, int absoluteIndex,
                       const CandidateWindowConfig &window);

} // namespace MacishType
