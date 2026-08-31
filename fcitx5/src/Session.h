#pragma once

#include <cstdint>
#include <optional>
#include <string>
#include <variant>
#include <vector>

#include <fcitx/inputcontext.h>

#include <MacishType/EngineHost.h>
#include <MacishType/EventData.h>
#include "WebKeyMap.h"

namespace fcitx {
class CommonCandidateList;
}

namespace MacishType {

// Candidate emitted by the engine; `payload` is an opaque JS value that
// round-trips back through confirm/selection events.
struct CandidateData {
    std::string text;
    std::string annotation;
    JSValue payload = JS_UNDEFINED;
    bool hasPayload = false;
};

// One engine session per focused input context: owns the JS instance, the
// composition state (marked/staged text, candidates, associated mode), and
// the mapping onto the fcitx input panel. Mirrors the macOS
// InputController's action executor.
class EngineSession {
public:
    EngineSession(JsEngineHost *host, fcitx::InputContext *inputContext,
                  AssociatedSelectionKeys selectionKeys);
    ~EngineSession();
    EngineSession(const EngineSession &) = delete;
    EngineSession &operator=(const EngineSession &) = delete;

    bool valid() const { return instanceId_ != 0; }
    const std::string &engineId() const { return host_->engineId(); }

    // Full key pipeline: candidate-window interception, associated-mode
    // tier, then the engine's handleKey. Calls filterAndAccept() when the
    // key is consumed.
    void handleKey(fcitx::KeyEvent &keyEvent);

    void invokeActivateHook();
    // Client reset (in-app commit, cursor move): abandon the composition,
    // matching fcitx5's reset semantics.
    void resetFromClient();
    // The input method is deactivated (focus-out or a by-hand input-method
    // switch): commit the staged prefix and drop the composing rest.
    // preeditAlreadyCommitted is true on focus-out, where fcitx5 has already
    // committed the staged prefix from the client preedit, so we must not
    // commit it again.
    void endFromDeactivate(bool preeditAlreadyCommitted);
    // Show a read-only reverse-lookup (Find Input Code) result for `query`
    // in the candidate window. One-shot; dismissed on the next key. No-op
    // while composing.
    void showReverseLookup(const std::string &query);

private:

    struct UpdateMarkedTextAction {
        std::string text;
        std::optional<int> cursor;
        std::optional<int> staged;
        std::optional<std::pair<int, int>> emphasis;
    };
    struct CandidateUpdateOptions {
        std::optional<int> initialHighlight;
        std::optional<int> pageSize;
        std::optional<std::string> indexLabels;
        std::optional<std::string> layoutDirection;
        std::optional<bool> handleNavigationKeys;
        std::optional<bool> handleIndexLabelKeys;
        std::optional<bool> indexLabelDigitsRequireShift;
    };
    struct UpdateCandidatesAction {
        std::vector<CandidateData> items;
        CandidateUpdateOptions options;
    };
    struct CommitAction {
        CandidateData candidate;
    };
    struct CommitSelectedAction {};
    struct CommitAtIndexAction {
        int index = 0;
    };
    struct NavigateAction {
        std::string direction;
        bool wrapping = false;
    };
    struct ResetAction {};
    struct FlushStagedAction {
        std::string append;
    };
    struct EnterAssociatedAction {
        std::string heldChar;
        std::optional<std::vector<std::string>> candidates;
    };
    using Action =
        std::variant<UpdateMarkedTextAction, UpdateCandidatesAction,
                     CommitAction, CommitSelectedAction, CommitAtIndexAction,
                     NavigateAction, ResetAction, FlushStagedAction,
                     EnterAssociatedAction>;

    // Host→JS invocation with an action queue on the stack; queued actions
    // apply after the hook (and its microtasks) return.
    std::optional<bool> invokeEngineMethod(const char *method,
                                           JSValue eventObject);
    void queueAction(const std::string &name, int argc, JSValueConst *argv);
    void applyActions(std::vector<Action> actions);

    // Tier 1a: policy-gated candidate window keys.
    bool dispatchCandidateWindowKey(const WebKeyEvent &web);
    static std::optional<std::string>
    navigationDirectionFor(const WebKeyEvent &web);

    void applyUpdateMarkedText(const UpdateMarkedTextAction &action);
    void applyUpdateCandidates(UpdateCandidatesAction action);
    void navigate(const std::string &direction, bool wrapping);
    void confirmCandidateAt(size_t absoluteIndex);
    void confirmCandidate(const CandidateData &candidate, int absoluteIndex);
    void fireSelectionChanged();
    void enterAssociatedMode(const std::string &heldChar,
                             std::optional<std::vector<std::string>> candidates);
    // Commits `insertion` when non-empty, clears composition and candidate
    // state either way. The macOS endComposition equivalent.
    void endComposition(const std::string &insertion);

    void renderCandidates(int initialCursor);
    void hideCandidates();
    void clearCompositionState();

    // Reverse-lookup (read-only) display. renderReverseLookup shows the given
    // rows suspended/non-selectable; reverseLookupAux shows a transient
    // message (loading/failure); reverseLookupPage flips pages keeping the
    // suspended cursor; hideReverseLookup tears down and cancels the wait.
    void renderReverseLookup(std::vector<CandidateData> rows);
    void reverseLookupAux(const std::string &message);
    void reverseLookupPage(bool forward);
    void hideReverseLookup();

    // The live candidate list (our CommonCandidateList subclass) when visible,
    // else nullptr. Cursor/page state lives here — it is the source of truth.
    fcitx::CommonCandidateList *candidateList() const;
    // Absolute index of the selected candidate, or -1 when none (suspended).
    int selectedIndex() const;
    int currentPageItemCount() const;

    JSValue makeEvent(const WebKeyEvent *web, const CandidateData *candidate,
                      int absoluteIndex);

    static CandidateData copyCandidate(JSContext *ctx,
                                       const CandidateData &candidate);
    void freeCandidates(std::vector<CandidateData> &candidates);

    JsEngineHost *host_;
    fcitx::InputContext *inputContext_;
    uint64_t instanceId_ = 0;

    std::string markedText_;
    std::string stagedText_;
    bool associating_ = false;

    // Candidate payloads (source for confirm/selection events), indexed
    // absolutely. Cursor/page selection state lives in the CommonCandidateList
    // (see candidateList()), not here.
    std::vector<CandidateData> candidates_;
    bool candidatesVisible_ = false;
    CandidateWindowConfig windowConfig_;
    // Associated-mode window behavior, resolved once at construction —
    // the policy is fixed for the session.
    CandidateWindowConfig associatedWindowConfig_;

    // Reverse-lookup read-only display: visible flag (its handleKey branch
    // owns keys while set), the host lookup token, and a transient flag set
    // once the results/aux are drawn (anti-flash: loading is drawn only if
    // prepare hasn't already settled synchronously).
    bool reverseLookupVisible_ = false;
    uint64_t reverseLookupToken_ = 0;
    bool reverseLookupRendered_ = false;

    std::vector<std::vector<Action>> queueStack_;
};

} // namespace MacishType
