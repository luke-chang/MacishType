#include "session.h"

#include <algorithm>
#include <set>
#include <vector>

#include <fcitx-utils/utf8.h>
#include <fcitx/candidatelist.h>
#include <fcitx/inputpanel.h>
#include <fcitx/text.h>

#include "i18n.h"
#include <macishtype/qjsutil.h>
#include "log.h"

namespace macishtype {

namespace {

// An engine can hand us a sparse JS array whose `length` is up to UINT32_MAX
// while holding no elements; the loops that materialize such arrays run in a
// native callback the JS watchdog cannot interrupt, so cap the count. No real
// candidate or associated-word list approaches this bound.
constexpr uint32_t kMaxListItems = 100000;

// Reverse-lookup display caps: distinct query characters (one row each) and
// codes shown per character before eliding with "…" (both signal truncation
// rather than silently dropping).
constexpr size_t kReverseLookupMaxChars = 200;
constexpr size_t kReverseLookupMaxCodes = 12;

// Joins a character's reverse-lookup codes into one comment string: codes
// two-space-separated, each optional annotation parenthesized right after its
// code (the panel drops the dim styling macOS uses over DBus, so parentheses
// carry the grouping). Capped with "…", or "—" when the character has no codes.
std::string
joinReverseCodes(const std::vector<JsEngineHost::ReverseCode> &codes) {
    if (codes.empty()) {
        return "\xE2\x80\x94"; // em dash
    }
    std::string result;
    size_t shown = std::min(codes.size(), kReverseLookupMaxCodes);
    for (size_t i = 0; i < shown; i++) {
        if (i > 0) {
            result += "  ";
        }
        result += codes[i].code;
        if (!codes[i].annotation.empty()) {
            result += " (" + codes[i].annotation + ")";
        }
    }
    if (codes.size() > shown) {
        result += "  \xE2\x80\xA6"; // …
    }
    return result;
}

// Character indices in the JS contract count extended grapheme clusters.
// Resolves one string's boundaries once, so every character index -> byte
// offset lookup below is O(1).
class GraphemeIndex {
public:
    GraphemeIndex(JsEngineHost &host, const std::string &text) {
        if (fcitx::utf8::validate(text)) {
            boundaries_ = host.graphemeBoundaries(text);
        }
        if (boundaries_.empty()) {
            // Invalid UTF-8 (or unusable ICU) degrades to byte indices.
            boundaries_.resize(text.size() + 1);
            for (size_t i = 0; i < boundaries_.size(); i++) {
                boundaries_[i] = i;
            }
        }
    }
    int count() const { return static_cast<int>(boundaries_.size()) - 1; }
    size_t byteOffset(int characterIndex) const {
        return boundaries_[static_cast<size_t>(
            std::clamp(characterIndex, 0, count()))];
    }

private:
    std::vector<size_t> boundaries_;
};

// True when `text` is exactly one extended grapheme cluster. The all-ASCII
// path keeps the per-keystroke gates (including named keys like "Enter")
// off the segmenter.
bool isSingleGrapheme(JsEngineHost &host, const std::string &text) {
    bool allAscii = std::all_of(text.begin(), text.end(), [](char byte) {
        return static_cast<unsigned char>(byte) <= 0x7F;
    });
    if (allAscii || !fcitx::utf8::validate(text)) {
        return text.size() == 1;
    }
    auto boundaries = host.graphemeBoundaries(text);
    if (boundaries.empty()) {
        return text.size() == 1;
    }
    return boundaries.size() == 2;
}

bool isEscapeLikeKey(const WebKeyEvent &web) {
    return web.code == "Escape" || web.key == "Clear";
}

std::optional<int> intProperty(JSContext *ctx, JSValueConst object,
                               const char *name) {
    qjs::Value value(ctx, JS_GetPropertyStr(ctx, object, name));
    if (value.isUndefined() || value.isException() ||
        JS_IsNull(value.get()) || !JS_IsNumber(value.get())) {
        return std::nullopt;
    }
    int32_t number = 0;
    if (JS_ToInt32(ctx, &number, value.get()) != 0) {
        return std::nullopt;
    }
    return number;
}

std::optional<bool> boolProperty(JSContext *ctx, JSValueConst object,
                                 const char *name) {
    qjs::Value value(ctx, JS_GetPropertyStr(ctx, object, name));
    if (value.isUndefined() || value.isException() ||
        !JS_IsBool(value.get())) {
        return std::nullopt;
    }
    return JS_ToBool(ctx, value.get()) == 1;
}

std::optional<std::string> stringProperty(JSContext *ctx, JSValueConst object,
                                          const char *name) {
    qjs::Value value(ctx, JS_GetPropertyStr(ctx, object, name));
    if (value.isUndefined() || value.isException() ||
        !JS_IsString(value.get())) {
        return std::nullopt;
    }
    return qjs::toString(ctx, value.get());
}

} // namespace

EngineSession::EngineSession(JsEngineHost *host,
                             fcitx::InputContext *inputContext)
    : host_(host), inputContext_(inputContext) {
    // Unconditional, paired with the dtor's decrement: an invalid session
    // (createInstance fails below) is still destroyed by the caller, and an
    // unbalanced count would keep the host's fetch pipeline armed forever.
    host_->incrementActive();
    instanceId_ = host_->createInstance();
    windowConfig_ = resolvedCandidateWindowConfig(*host_);
}

EngineSession::~EngineSession() {
    // Invalidate any pending reverse-lookup callback capturing this session
    // (no-op unless this session owns the current lookup). The input panel's
    // candidate list is left to the input-context teardown, as elsewhere.
    host_->cancelReverseLookupWait(reverseLookupToken_);
    host_->decrementActive();
    freeCandidates(candidates_);
    if (instanceId_ != 0) {
        host_->destroyInstance(instanceId_);
    }
}

int EngineSession::currentPageItemCount() const {
    auto *list = candidateList();
    if (!list) {
        return 0;
    }
    int pageSize = std::max(1, list->pageSize());
    int start = list->currentPage() * pageSize;
    return std::min(pageSize, static_cast<int>(candidates_.size()) - start);
}

// Key pipeline ------------------------------------------------------------

void EngineSession::handleKey(fcitx::KeyEvent &keyEvent) {
    if (!valid() || keyEvent.isRelease()) {
        return;
    }
    if (keyEvent.rawKey().isModifier()) {
        // Modifier-only presses never reach engines on macOS either.
        return;
    }
    WebKeyEvent web = translateKeyEvent(keyEvent.rawKey());

    // Reverse-lookup read-only display owns every key while shown: Escape and
    // page keys are consumed; anything else dismisses it and falls through so
    // the keystroke starts composing normally (typing is never blocked).
    if (reverseLookupVisible_) {
        if (isEscapeLikeKey(web)) {
            hideReverseLookup();
            keyEvent.filterAndAccept();
            return;
        }
        if (auto direction = navigationDirectionFor(web)) {
            bool forward = *direction == "pageDown" || *direction == "down" ||
                           *direction == "right";
            bool backward = *direction == "pageUp" || *direction == "up" ||
                            *direction == "left";
            auto *list = candidateList();
            if ((forward || backward) && list != nullptr &&
                list->totalPages() > 1) {
                reverseLookupPage(forward);
                keyEvent.filterAndAccept();
                return;
            }
        }
        hideReverseLookup();
        // Not accepted: fall through to the normal pipeline below.
    }

    // Tier 1a: candidate window owns policy-gated keys.
    if (dispatchCandidateWindowKey(web)) {
        keyEvent.filterAndAccept();
        return;
    }

    // Tier 1b/2: associated mode. A handled key stops here; anything else
    // dismisses associated mode (committing the held char) and falls
    // through to handleKey on the reset context.
    if (associating_) {
        if (host_->instanceHasHook(instanceId_, "handleAssociatedKey")) {
            auto handled = invokeEngineMethod("handleAssociatedKey",
                                              makeEvent(&web, nullptr, -1));
            if (handled.value_or(false)) {
                keyEvent.filterAndAccept();
                return;
            }
            applyActions({FlushStagedAction{}});
        } else if (isEscapeLikeKey(web)) {
            applyActions({FlushStagedAction{}});
            keyEvent.filterAndAccept();
            return;
        } else {
            applyActions({FlushStagedAction{}});
        }
    }

    auto handled =
        invokeEngineMethod("handleKey", makeEvent(&web, nullptr, -1));
    if (handled.value_or(false)) {
        keyEvent.filterAndAccept();
    }
}

bool EngineSession::dispatchCandidateWindowKey(const WebKeyEvent &web) {
    if (!candidatesVisible_) {
        return false;
    }
    if (web.ctrlKey || web.metaKey) {
        return false;
    }
    // " " labels are blank slots (position reserved, not selectable), so a
    // space key never matches them.
    if (windowConfig_.handleIndexLabelKeys && !web.altKey &&
        isSingleGrapheme(*host_, web.key) && web.key != " ") {
        int labelIndex = 0;
        bool matched = false;
        auto range = fcitx::utf8::MakeUTF8CharRange(windowConfig_.indexLabels);
        for (auto iterator = std::begin(range); iterator != std::end(range);
             ++iterator, ++labelIndex) {
            if (std::string(iterator.charRange().first,
                            iterator.charRange().second) == web.key) {
                matched = true;
                break;
            }
        }
        if (matched && labelIndex < currentPageItemCount()) {
            auto *list = candidateList();
            confirmCandidateAt(static_cast<size_t>(
                list->currentPage() * std::max(1, list->pageSize()) +
                labelIndex));
            return true;
        }
    }
    if (windowConfig_.handleNavigationKeys) {
        if (auto direction = navigationDirectionFor(web)) {
            navigate(*direction, false);
            return true;
        }
        if (web.key == "Enter" && !web.shiftKey && !web.altKey) {
            applyActions({CommitSelectedAction{}});
            return true;
        }
    }
    return false;
}

std::optional<std::string>
EngineSession::navigationDirectionFor(const WebKeyEvent &web) {
    if (web.code == "ArrowUp") {
        return "up";
    }
    if (web.code == "ArrowDown") {
        return "down";
    }
    if (web.code == "ArrowLeft") {
        return "left";
    }
    if (web.code == "ArrowRight") {
        return "right";
    }
    if (web.code == "PageUp") {
        return "pageUp";
    }
    if (web.code == "PageDown") {
        return "pageDown";
    }
    if (web.code == "Home") {
        return "home";
    }
    if (web.code == "End") {
        return "end";
    }
    if (web.code == "Tab") {
        return web.shiftKey ? "itemBackward" : "itemForward";
    }
    return std::nullopt;
}

// Session lifecycle ---------------------------------------------------------

void EngineSession::invokeActivateHook() {
    if (!valid()) {
        return;
    }
    invokeEngineMethod("activate", JS_UNDEFINED);
}

void EngineSession::resetFromClient() {
    if (!valid()) {
        return;
    }
    if (reverseLookupVisible_) {
        hideReverseLookup();
    }
    // fcitx5's reset abandons the input; discard the whole composition
    // (staged and composing alike) rather than committing, matching the
    // platform convention. Unlike focus-out, reset does not auto-commit
    // the preedit, so nothing is left behind.
    endComposition("");
    invokeEngineMethod("compositionEnded", JS_UNDEFINED);
}

void EngineSession::endFromDeactivate(bool preeditAlreadyCommitted) {
    if (!valid()) {
        return;
    }
    if (reverseLookupVisible_) {
        hideReverseLookup();
    }
    // macOS parity: deactivating commits the staged prefix and drops the
    // composing rest. On a focus-out fcitx5 has already committed the
    // committable client preedit (the staged prefix; the composing rest is
    // flagged DontCommit), so committing again would duplicate it. Any other
    // deactivation — switching input method by hand — gets no such
    // auto-commit, so we commit the staged prefix ourselves.
    endComposition(preeditAlreadyCommitted ? std::string() : stagedText_);
    invokeEngineMethod("compositionEnded", JS_UNDEFINED);
    invokeEngineMethod("deactivate", JS_UNDEFINED);
}

// Invocation plumbing -------------------------------------------------------

std::optional<bool> EngineSession::invokeEngineMethod(const char *method,
                                                      JSValue eventObject) {
    queueStack_.emplace_back();
    std::optional<bool> result;
    {
        JsEngineHost::ScopedActionHandler handler(
            *host_, [this](const std::string &name, int argc,
                           JSValueConst *argv) {
                queueAction(name, argc, argv);
            });
        result = host_->invokeHook(instanceId_, method, eventObject);
    }
    auto actions = std::move(queueStack_.back());
    queueStack_.pop_back();
    applyActions(std::move(actions));
    return result;
}

void EngineSession::queueAction(const std::string &name, int argc,
                                JSValueConst *argv) {
    JSContext *ctx = host_->context();
    if (queueStack_.empty()) {
        return;
    }
    auto &queue = queueStack_.back();

    auto candidateFromValue = [&](JSValueConst value) -> CandidateData {
        CandidateData candidate;
        if (JS_IsString(value)) {
            candidate.text = qjs::toString(ctx, value);
            return candidate;
        }
        if (JS_IsObject(value)) {
            if (auto text = stringProperty(ctx, value, "candidate")) {
                candidate.text = *text;
            }
            if (auto annotation = stringProperty(ctx, value, "annotation")) {
                candidate.annotation = *annotation;
            }
            qjs::Value payload(ctx,
                               JS_GetPropertyStr(ctx, value, "payload"));
            if (!payload.isUndefined() && !payload.isException()) {
                candidate.payload = payload.release();
                candidate.hasPayload = true;
            }
        }
        return candidate;
    };

    if (name == "updateMarkedText") {
        UpdateMarkedTextAction action;
        if (argc >= 1) {
            action.text = qjs::toString(ctx, argv[0]);
        }
        if (argc >= 2 && JS_IsObject(argv[1])) {
            action.cursor = intProperty(ctx, argv[1], "cursor");
            action.staged = intProperty(ctx, argv[1], "staged");
            qjs::Value emphasis(ctx,
                                JS_GetPropertyStr(ctx, argv[1], "emphasis"));
            if (JS_IsObject(emphasis.get())) {
                auto start = intProperty(ctx, emphasis.get(), "start");
                auto end = intProperty(ctx, emphasis.get(), "end");
                if (start && end && *end > *start) {
                    action.emphasis = std::make_pair(*start, *end);
                }
            }
        }
        queue.push_back(std::move(action));
        return;
    }
    if (name == "updateCandidates") {
        UpdateCandidatesAction action;
        if (argc >= 1 && JS_IsArray(argv[0])) {
            qjs::Value length(ctx,
                              JS_GetPropertyStr(ctx, argv[0], "length"));
            uint32_t count = 0;
            JS_ToUint32(ctx, &count, length.get());
            if (count > kMaxListItems) {
                MACISHTYPE_WARN() << host_->engineId()
                                  << ": candidate list truncated from "
                                  << count << " to " << kMaxListItems;
                count = kMaxListItems;
            }
            for (uint32_t i = 0; i < count; i++) {
                qjs::Value item(ctx, JS_GetPropertyUint32(ctx, argv[0], i));
                action.items.push_back(candidateFromValue(item.get()));
            }
        }
        if (argc >= 2 && JS_IsObject(argv[1])) {
            action.options.initialHighlight =
                intProperty(ctx, argv[1], "initialHighlight");
            action.options.pageSize = intProperty(ctx, argv[1], "pageSize");
            action.options.indexLabels =
                stringProperty(ctx, argv[1], "indexLabels");
            action.options.layoutDirection =
                stringProperty(ctx, argv[1], "layoutDirection");
            action.options.handleNavigationKeys =
                boolProperty(ctx, argv[1], "handleNavigationKeys");
            action.options.handleIndexLabelKeys =
                boolProperty(ctx, argv[1], "handleIndexLabelKeys");
        }
        queue.push_back(std::move(action));
        return;
    }
    if (name == "commit") {
        CommitAction action;
        if (argc >= 1) {
            action.candidate = candidateFromValue(argv[0]);
        }
        queue.push_back(std::move(action));
        return;
    }
    if (name == "commitSelectedCandidate") {
        queue.push_back(CommitSelectedAction{});
        return;
    }
    if (name == "commitCandidateAtIndex") {
        CommitAtIndexAction action;
        int32_t index = 0;
        if (argc >= 1 && JS_ToInt32(ctx, &index, argv[0]) == 0) {
            action.index = index;
        }
        queue.push_back(action);
        return;
    }
    if (name == "navigateCandidates") {
        NavigateAction action;
        if (argc >= 1) {
            action.direction = qjs::toString(ctx, argv[0]);
        }
        if (argc >= 2 && JS_IsObject(argv[1])) {
            action.wrapping =
                boolProperty(ctx, argv[1], "wrapping").value_or(false);
        }
        queue.push_back(std::move(action));
        return;
    }
    if (name == "resetContext") {
        queue.push_back(ResetAction{});
        return;
    }
    if (name == "flushStaged") {
        FlushStagedAction action;
        if (argc >= 1 && JS_IsString(argv[0])) {
            action.append = qjs::toString(ctx, argv[0]);
        }
        queue.push_back(std::move(action));
        return;
    }
    if (name == "enterAssociatedMode") {
        EnterAssociatedAction action;
        if (argc >= 1) {
            action.heldChar = qjs::toString(ctx, argv[0]);
        }
        if (argc >= 2 && JS_IsArray(argv[1])) {
            std::vector<std::string> candidates;
            qjs::Value length(ctx,
                              JS_GetPropertyStr(ctx, argv[1], "length"));
            uint32_t count = 0;
            JS_ToUint32(ctx, &count, length.get());
            if (count > kMaxListItems) {
                MACISHTYPE_WARN() << host_->engineId()
                                  << ": associated list truncated from "
                                  << count << " to " << kMaxListItems;
                count = kMaxListItems;
            }
            for (uint32_t i = 0; i < count; i++) {
                qjs::Value item(ctx, JS_GetPropertyUint32(ctx, argv[1], i));
                candidates.push_back(qjs::toString(ctx, item.get()));
            }
            action.candidates = std::move(candidates);
        }
        queue.push_back(std::move(action));
        return;
    }
    MACISHTYPE_WARN() << host_->engineId() << ": unknown mutator ignored: "
                      << name;
}

// Action executor -----------------------------------------------------------

void EngineSession::applyActions(std::vector<Action> actions) {
    for (auto &action : actions) {
        std::visit(
            [this](auto &&value) {
                using T = std::decay_t<decltype(value)>;
                if constexpr (std::is_same_v<T, UpdateMarkedTextAction>) {
                    applyUpdateMarkedText(value);
                } else if constexpr (std::is_same_v<T,
                                                    UpdateCandidatesAction>) {
                    applyUpdateCandidates(std::move(value));
                } else if constexpr (std::is_same_v<T, CommitAction>) {
                    confirmCandidate(value.candidate, -1);
                    if (value.candidate.hasPayload) {
                        JS_FreeValue(host_->context(), value.candidate.payload);
                        value.candidate.hasPayload = false;
                    }
                } else if constexpr (std::is_same_v<T,
                                                    CommitSelectedAction>) {
                    // Window verbs are no-ops without a visible window; with
                    // one, a suspended highlight reports an empty commit so
                    // the engine decides — the host never picks a candidate.
                    auto *list = candidateList();
                    if (list && !candidates_.empty()) {
                        int cursor = list->globalCursorIndex();
                        if (cursor < 0) {
                            confirmCandidate(CandidateData{}, -1);
                        } else {
                            confirmCandidateAt(static_cast<size_t>(cursor));
                        }
                    }
                } else if constexpr (std::is_same_v<T, CommitAtIndexAction>) {
                    auto *list = candidateList();
                    if (list && value.index >= 0 &&
                        value.index < currentPageItemCount()) {
                        confirmCandidateAt(static_cast<size_t>(
                            list->currentPage() *
                                std::max(1, list->pageSize()) +
                            value.index));
                    }
                } else if constexpr (std::is_same_v<T, NavigateAction>) {
                    navigate(value.direction, value.wrapping);
                } else if constexpr (std::is_same_v<T, ResetAction>) {
                    endComposition("");
                } else if constexpr (std::is_same_v<T, FlushStagedAction>) {
                    endComposition(stagedText_ + value.append);
                } else if constexpr (std::is_same_v<T,
                                                    EnterAssociatedAction>) {
                    enterAssociatedMode(value.heldChar,
                                        std::move(value.candidates));
                }
            },
            std::move(action));
    }
}

void EngineSession::applyUpdateMarkedText(
    const UpdateMarkedTextAction &action) {
    markedText_ = action.text;
    GraphemeIndex index(*host_, markedText_);
    int total = index.count();
    int stagedCount = 0;
    if (action.staged) {
        stagedCount = *action.staged < 0
                          ? total
                          : std::min(std::max(*action.staged, 0), total);
    }
    stagedText_ = markedText_.substr(0, index.byteOffset(stagedCount));

    fcitx::Text preedit;
    if (!markedText_.empty()) {
        // Split the preedit into uniform-flag runs at the staged boundary
        // and any emphasis range. The composing (post-staged) region is
        // flagged DontCommit, so fcitx5's focus-out auto-commit
        // (clientPreedit().toStringForCommit()) takes only the staged
        // prefix and drops the composing code — the macOS deactivate
        // behavior of committing staged text and discarding the rest,
        // without us committing it a second time.
        int emphasisStart =
            action.emphasis
                ? std::min(std::max(action.emphasis->first, 0), total)
                : -1;
        int emphasisEnd = action.emphasis
                              ? std::min(std::max(action.emphasis->second, 0),
                                         total)
                              : -1;
        std::set<int> cutSet{0, total, stagedCount};
        if (action.emphasis) {
            cutSet.insert(emphasisStart);
            cutSet.insert(emphasisEnd);
        }
        std::vector<int> cuts(cutSet.begin(), cutSet.end());
        for (size_t i = 0; i + 1 < cuts.size(); i++) {
            int from = cuts[i];
            int to = cuts[i + 1];
            fcitx::TextFormatFlags flags{fcitx::TextFormatFlag::Underline};
            if (from >= stagedCount) {
                flags |= fcitx::TextFormatFlag::DontCommit;
            }
            if (action.emphasis && from >= emphasisStart &&
                from < emphasisEnd) {
                flags |= fcitx::TextFormatFlag::Bold;
            }
            size_t byteFrom = index.byteOffset(from);
            size_t byteTo = index.byteOffset(to);
            preedit.append(markedText_.substr(byteFrom, byteTo - byteFrom),
                           flags);
        }
        int cursorCharacters =
            action.cursor ? std::min(std::max(*action.cursor, 0), total)
                          : total;
        preedit.setCursor(static_cast<int>(index.byteOffset(cursorCharacters)));
    }
    auto &inputPanel = inputContext_->inputPanel();
    if (inputContext_->capabilityFlags().test(
            fcitx::CapabilityFlag::Preedit)) {
        inputPanel.setClientPreedit(preedit);
        inputContext_->updatePreedit();
    } else {
        inputPanel.setPreedit(preedit);
        inputContext_->updateUserInterface(
            fcitx::UserInterfaceComponent::InputPanel);
    }
}

void EngineSession::applyUpdateCandidates(UpdateCandidatesAction action) {
    freeCandidates(candidates_);
    candidates_ = std::move(action.items);

    if (candidates_.empty()) {
        hideCandidates();
        return;
    }

    // Per-update overrides start from the session base config.
    windowConfig_ = resolvedCandidateWindowConfig(*host_);
    if (action.options.pageSize) {
        windowConfig_.pageSize = std::max(1, *action.options.pageSize);
    }
    if (action.options.indexLabels) {
        windowConfig_.indexLabels = *action.options.indexLabels;
    }
    if (action.options.layoutDirection) {
        windowConfig_.vertical = *action.options.layoutDirection == "vertical";
    }
    if (action.options.handleNavigationKeys) {
        windowConfig_.handleNavigationKeys =
            *action.options.handleNavigationKeys;
    }
    if (action.options.handleIndexLabelKeys) {
        windowConfig_.handleIndexLabelKeys =
            *action.options.handleIndexLabelKeys;
    }

    int total = static_cast<int>(candidates_.size());
    int initialHighlight = action.options.initialHighlight.value_or(0);
    int initialCursor =
        initialHighlight < 0 ? -1 : std::min(initialHighlight, total - 1);
    candidatesVisible_ = true;
    renderCandidates(initialCursor);
    // The initial selection counts as a selection change (macOS parity:
    // the window notifies when moving from no-selection to the initial
    // highlight), so engines can render replace previews on open.
    if (initialCursor >= 0) {
        fireSelectionChanged();
    }
}

// Candidate word pushed into the fcitx input panel; select() (mouse click)
// commits by absolute index.
class MacishCandidateWord : public fcitx::CandidateWord {
public:
    MacishCandidateWord(int index, const CandidateData &candidate,
                        std::function<void(int)> onSelect)
        : fcitx::CandidateWord(fcitx::Text(candidate.text)), index_(index),
          onSelect_(std::move(onSelect)) {
        if (!candidate.annotation.empty()) {
            setComment(fcitx::Text(candidate.annotation));
        }
    }

    void select(fcitx::InputContext *inputContext) const override {
        FCITX_UNUSED(inputContext);
        onSelect_(index_);
    }

private:
    int index_;
    std::function<void(int)> onSelect_;
};

// CommonCandidateList that funnels native paging (a click on the panel's
// prev/next arrows, or a client PrevPage/NextPage) back through navigate(), so
// mouse and keyboard paging share one path: both move the highlight onto the
// new page and fire candidateSelectionChanged.
class MacishCandidateList : public fcitx::CommonCandidateList {
public:
    explicit MacishCandidateList(
        std::function<void(const std::string &)> onPage)
        : onPage_(std::move(onPage)) {}

    void prev() override { onPage_("pageBackward"); }
    void next() override { onPage_("pageForward"); }

private:
    std::function<void(const std::string &)> onPage_;
};

fcitx::CommonCandidateList *EngineSession::candidateList() const {
    if (!candidatesVisible_) {
        return nullptr;
    }
    return dynamic_cast<fcitx::CommonCandidateList *>(
        inputContext_->inputPanel().candidateList().get());
}

int EngineSession::selectedIndex() const {
    auto *list = candidateList();
    return list ? list->globalCursorIndex() : -1;
}

void EngineSession::renderCandidates(int initialCursor) {
    // Full-list native pagination: append every candidate and let the list
    // page itself so hasPrev()/hasNext() drive the panel's page indicators and
    // mouse paging. The list owns cursor/page; initialCursor is an absolute
    // index, or -1 for a suspended (no-selection) highlight.
    auto list = std::make_unique<MacishCandidateList>(
        [this](const std::string &direction) { navigate(direction, false); });
    int total = static_cast<int>(candidates_.size());
    int pageSize = std::max(1, windowConfig_.pageSize);
    list->setPageSize(pageSize);
    list->setLayoutHint(windowConfig_.vertical
                            ? fcitx::CandidateLayoutHint::Vertical
                            : fcitx::CandidateLayoutHint::Horizontal);

    // Blank labels are selection-disabled placeholders; the panels prepend
    // label text to the candidate, so render them as no label at all to keep
    // rows aligned. One page's worth; the list applies them per page.
    std::vector<std::string> labels;
    auto labelRange =
        fcitx::utf8::MakeUTF8CharRange(windowConfig_.indexLabels);
    for (auto iterator = std::begin(labelRange);
         iterator != std::end(labelRange) &&
         labels.size() < static_cast<size_t>(pageSize);
         ++iterator) {
        std::string labelText(iterator.charRange().first,
                              iterator.charRange().second);
        labels.push_back(labelText == " " ? "" : labelText + " ");
    }
    labels.resize(pageSize, "");
    list->setLabels(labels);

    auto onSelect = [this](int absoluteIndex) {
        confirmCandidateAt(static_cast<size_t>(absoluteIndex));
    };
    for (int i = 0; i < total; i++) {
        list->append(
            std::make_unique<MacishCandidateWord>(i, candidates_[i], onSelect));
    }
    // Cursor first, then page: with currentPage_ freshly 0 from setPageSize,
    // cursorIndex() reads -1 for an off-page cursor so setPage's
    // fixCursorAfterPaging leaves the global index intact.
    if (initialCursor < 0) {
        list->setGlobalCursorIndex(-1);
    } else {
        list->setGlobalCursorIndex(initialCursor);
        list->setPage(initialCursor / pageSize);
    }
    auto &inputPanel = inputContext_->inputPanel();
    inputPanel.setCandidateList(std::move(list));
    // A header labels the candidates as associated words; cleared otherwise.
    inputPanel.setAuxUp(associating_
                            ? fcitx::Text(translated("Associated words"))
                            : fcitx::Text());
    inputContext_->updateUserInterface(
        fcitx::UserInterfaceComponent::InputPanel);
}

void EngineSession::hideCandidates() {
    candidatesVisible_ = false;
    freeCandidates(candidates_);
    auto &inputPanel = inputContext_->inputPanel();
    inputPanel.setCandidateList(nullptr);
    inputPanel.setAuxUp(fcitx::Text());
    inputContext_->updateUserInterface(
        fcitx::UserInterfaceComponent::InputPanel);
}

// Reverse lookup (read-only Find Input Code display) --------------------

void EngineSession::showReverseLookup(const std::string &query) {
    if (!valid()) {
        return;
    }
    // Refresh: drop any existing reverse display so a re-trigger re-queries
    // with the new selection (index kept host-side, so re-prepare is cheap).
    if (reverseLookupVisible_) {
        hideReverseLookup();
    }
    // Only from idle: never disturb an in-progress composition.
    if (!markedText_.empty() || associating_ || candidatesVisible_) {
        return;
    }
    reverseLookupVisible_ = true;

    // One entry per grapheme cluster, dropping single-byte (ASCII) ones:
    // those are typed directly, with no input code to look up.
    std::vector<std::string> characters;
    if (fcitx::utf8::validate(query)) {
        auto boundaries = host_->graphemeBoundaries(query);
        for (size_t i = 0; i + 1 < boundaries.size(); i++) {
            if (boundaries[i + 1] - boundaries[i] > 1) {
                characters.push_back(query.substr(
                    boundaries[i], boundaries[i + 1] - boundaries[i]));
            }
        }
    }

    if (characters.empty()) {
        // Nothing to look up (no selection, or an all-ASCII one): a hint row
        // teaches the operation.
        std::vector<CandidateData> rows(1);
        rows[0].text = translated("Select text first, then run Find Input Code");
        renderReverseLookup(std::move(rows));
        return;
    }

    reverseLookupRendered_ = false;
    reverseLookupToken_ =
        host_->prepareReverseLookup([this, characters](bool ready) {
            if (!ready) {
                reverseLookupAux(translated("Failed to load this input method"));
                reverseLookupRendered_ = true;
                return;
            }
            // One row per unique character (capped); its codes are joined
            // into the comment.
            std::vector<CandidateData> rows;
            std::set<std::string> seen;
            for (const auto &ch : characters) {
                if (!seen.insert(ch).second) {
                    continue;
                }
                if (rows.size() >= kReverseLookupMaxChars) {
                    MACISHTYPE_WARN()
                        << host_->engineId()
                        << ": reverse lookup query truncated at "
                        << kReverseLookupMaxChars << " characters";
                    break;
                }
                CandidateData row;
                row.text = ch;
                row.annotation = joinReverseCodes(host_->reverseLookup(ch));
                rows.push_back(std::move(row));
            }
            renderReverseLookup(std::move(rows));
            reverseLookupRendered_ = true;
        });

    // Anti-flash: draw the loading line only if prepare has not already
    // settled synchronously (a fetch-backed prepare settles on a later turn).
    if (!reverseLookupRendered_) {
        reverseLookupAux(translated("Loading…"));
    }
}

void EngineSession::renderReverseLookup(std::vector<CandidateData> rows) {
    freeCandidates(candidates_);
    candidates_ = std::move(rows);
    // Read-only: paging routes to the read-only pager (keeps suspended), and
    // clicking a row only dismisses. Fixed vertical, no index labels.
    auto list = std::make_unique<MacishCandidateList>(
        [this](const std::string &direction) {
            reverseLookupPage(direction == "pageForward");
        });
    int total = static_cast<int>(candidates_.size());
    int pageSize = std::max(1, windowConfig_.pageSize);
    list->setPageSize(pageSize);
    list->setLayoutHint(fcitx::CandidateLayoutHint::Vertical);
    list->setLabels(std::vector<std::string>(pageSize, ""));
    auto onSelect = [this](int) { hideReverseLookup(); };
    for (int i = 0; i < total; i++) {
        list->append(
            std::make_unique<MacishCandidateWord>(i, candidates_[i], onSelect));
    }
    list->setGlobalCursorIndex(-1); // suspended: never highlight a code
    auto &inputPanel = inputContext_->inputPanel();
    inputPanel.setCandidateList(std::move(list));
    inputPanel.setAuxUp(fcitx::Text());
    candidatesVisible_ = true;
    inputContext_->updateUserInterface(
        fcitx::UserInterfaceComponent::InputPanel);
}

void EngineSession::reverseLookupAux(const std::string &message) {
    freeCandidates(candidates_);
    candidatesVisible_ = false; // aux-only (loading/failure): no candidate list
    auto &inputPanel = inputContext_->inputPanel();
    inputPanel.setCandidateList(nullptr);
    inputPanel.setAuxUp(fcitx::Text(message));
    inputContext_->updateUserInterface(
        fcitx::UserInterfaceComponent::InputPanel);
}

void EngineSession::reverseLookupPage(bool forward) {
    auto *list = candidateList();
    if (list == nullptr) {
        return;
    }
    int pageSize = std::max(1, list->pageSize());
    int lastPage = (static_cast<int>(candidates_.size()) - 1) / pageSize;
    int page = list->currentPage() + (forward ? 1 : -1);
    page = std::max(0, std::min(page, lastPage));
    list->setPage(page);
    list->setGlobalCursorIndex(-1); // stay suspended
    inputContext_->updateUserInterface(
        fcitx::UserInterfaceComponent::InputPanel);
}

void EngineSession::hideReverseLookup() {
    host_->cancelReverseLookupWait(reverseLookupToken_);
    reverseLookupVisible_ = false;
    reverseLookupRendered_ = false;
    hideCandidates();
}

void EngineSession::navigate(const std::string &direction, bool wrapping) {
    auto *list = candidateList();
    if (!list || candidates_.empty()) {
        return;
    }
    int total = static_cast<int>(candidates_.size());
    int pageSize = std::max(1, list->pageSize());
    int cursor = list->globalCursorIndex();
    bool wasSuspended = cursor < 0;
    int pageStart = list->currentPage() * pageSize;
    if (wasSuspended) {
        // First navigation from a suspended highlight: arrow / item keys only
        // reveal the current page's first candidate without moving it, but
        // page keys and Home/End navigate right away, treating the suspended
        // state as index 0 of the page (MacishType parity).
        cursor = pageStart;
        bool revealOnly = direction == "up" || direction == "down" ||
                          direction == "left" || direction == "right" ||
                          direction == "itemForward" ||
                          direction == "itemBackward";
        if (revealOnly) {
            list->setGlobalCursorIndex(cursor);
            inputContext_->updateUserInterface(
                fcitx::UserInterfaceComponent::InputPanel);
            fireSelectionChanged();
            return;
        }
        // Page keys / Home / End fall through and navigate from index 0.
    }

    std::string resolved = direction;
    if (windowConfig_.vertical) {
        if (direction == "up") {
            resolved = "itemBackward";
        } else if (direction == "down") {
            resolved = "itemForward";
        } else if (direction == "left") {
            resolved = "pageBackward";
        } else if (direction == "right") {
            resolved = "pageForward";
        }
    } else {
        if (direction == "left") {
            resolved = "itemBackward";
        } else if (direction == "right") {
            resolved = "itemForward";
        } else if (direction == "up") {
            resolved = "pageBackward";
        } else if (direction == "down") {
            resolved = "pageForward";
        }
    }
    if (resolved == "pageUp") {
        resolved = "pageBackward";
    } else if (resolved == "pageDown") {
        resolved = "pageForward";
    }

    int previousCursor = wasSuspended ? -1 : cursor;
    if (resolved == "itemForward") {
        if (cursor + 1 < total) {
            cursor++;
        } else if (wrapping) {
            cursor = 0;
        }
    } else if (resolved == "itemBackward") {
        if (cursor > 0) {
            cursor--;
        } else if (wrapping) {
            cursor = total - 1;
        }
    } else if (resolved == "pageForward") {
        int offset = cursor - pageStart;
        if (pageStart + pageSize < total) {
            pageStart += pageSize;
        } else if (wrapping) {
            pageStart = 0;
        }
        cursor = std::min(pageStart + offset, total - 1);
    } else if (resolved == "pageBackward") {
        int offset = cursor - pageStart;
        if (pageStart - pageSize >= 0) {
            pageStart -= pageSize;
        } else if (wrapping) {
            pageStart = (total - 1) / pageSize * pageSize;
        }
        cursor = std::min(pageStart + offset, total - 1);
    } else if (resolved == "home") {
        cursor = windowConfig_.vertical ? 0 : pageStart;
    } else if (resolved == "end") {
        cursor = windowConfig_.vertical
                     ? total - 1
                     : std::min(pageStart + pageSize, total) - 1;
    } else {
        MACISHTYPE_WARN() << host_->engineId()
                          << ": unknown navigation direction: " << direction;
        return;
    }
    // Cursor first, then page (see renderCandidates): keeps the absolute cursor
    // intact when it crosses a page boundary.
    list->setGlobalCursorIndex(cursor);
    list->setPage(cursor / pageSize);
    inputContext_->updateUserInterface(
        fcitx::UserInterfaceComponent::InputPanel);
    if (cursor != previousCursor || wasSuspended) {
        fireSelectionChanged();
    }
}

// Confirm / selection flows ---------------------------------------------

void EngineSession::confirmCandidateAt(size_t absoluteIndex) {
    if (absoluteIndex >= candidates_.size()) {
        return;
    }
    // Copy: the confirm flow may replace the candidate list while running.
    CandidateData copy = copyCandidate(host_->context(),
                                       candidates_[absoluteIndex]);
    confirmCandidate(copy, static_cast<int>(absoluteIndex));
    if (copy.hasPayload) {
        JS_FreeValue(host_->context(), copy.payload);
    }
}

void EngineSession::confirmCandidate(const CandidateData &candidate,
                                     int absoluteIndex) {
    auto handled = invokeEngineMethod(
        "candidateConfirmed", makeEvent(nullptr, &candidate, absoluteIndex));
    if (handled.value_or(false)) {
        return;
    }
    // Host fallback: commit the staged prefix plus this candidate. A
    // single-character candidate can enter associated mode; the length gate
    // reads the candidate alone (not staged + candidate) and the staged
    // prefix folds into the held text so it is never dropped.
    std::string committed = stagedText_ + candidate.text;
    if (!associating_ && isSingleGrapheme(*host_, candidate.text)) {
        enterAssociatedMode(committed, std::nullopt);
        return;
    }
    endComposition(committed);
}

void EngineSession::fireSelectionChanged() {
    int index = selectedIndex();
    if (index < 0 || static_cast<size_t>(index) >= candidates_.size()) {
        return;
    }
    CandidateData copy =
        copyCandidate(host_->context(), candidates_[index]);
    invokeEngineMethod("candidateSelectionChanged",
                       makeEvent(nullptr, &copy, index));
    if (copy.hasPayload) {
        JS_FreeValue(host_->context(), copy.payload);
    }
}

void EngineSession::enterAssociatedMode(
    const std::string &heldChar,
    std::optional<std::vector<std::string>> candidates) {
    // Engine-supplied candidates always apply; without them, fall back to
    // the host dictionary only when the setting is on (contract semantics).
    std::vector<std::string> resolved =
        candidates ? std::move(*candidates)
        : host_->associatedModeEnabled()
            ? host_->associatedFollowups(heldChar)
            : std::vector<std::string>{};
    if (resolved.empty()) {
        // No follow-ups: don't enter associated mode, just commit the held
        // text.
        endComposition(heldChar);
        return;
    }
    clearCompositionState();
    associating_ = true;

    UpdateMarkedTextAction marked;
    marked.text = heldChar;
    marked.staged = -1;
    applyUpdateMarkedText(marked);

    UpdateCandidatesAction update;
    for (auto &text : resolved) {
        CandidateData candidate;
        candidate.text = std::move(text);
        update.items.push_back(std::move(candidate));
    }
    update.options.initialHighlight = -1;
    applyUpdateCandidates(std::move(update));
}

void EngineSession::endComposition(const std::string &insertion) {
    if (!insertion.empty()) {
        // TODO: transformCommittedText (outputToSimplified) belongs here.
        inputContext_->commitString(insertion);
    }
    UpdateMarkedTextAction clearMarked;
    applyUpdateMarkedText(clearMarked);
    hideCandidates();
    clearCompositionState();
}

void EngineSession::clearCompositionState() {
    markedText_.clear();
    stagedText_.clear();
    associating_ = false;
    windowConfig_ = resolvedCandidateWindowConfig(*host_);
}

// Event objects -----------------------------------------------------------

JSValue EngineSession::makeEvent(const WebKeyEvent *web,
                                 const CandidateData *candidate,
                                 int absoluteIndex) {
    JSContext *ctx = host_->context();
    EventStaging staging{markedText_, stagedText_, associating_,
                         candidatesVisible_, currentPageItemCount()};
    EventKeyFields keys;
    const EventKeyFields *keyFields = nullptr;
    if (web != nullptr) {
        // Named assignments: field growth in the contract vocabulary must
        // not silently re-bind a positional copy.
        keys.key = web->key;
        keys.code = web->code;
        keys.keyIgnoringModifiers = web->keyIgnoringModifiers;
        keys.shiftKey = web->shiftKey;
        keys.ctrlKey = web->ctrlKey;
        keys.altKey = web->altKey;
        keys.metaKey = web->metaKey;
        keys.capsLock = web->capsLock;
        keys.numLock = web->numLock;
        keys.repeat = web->repeat;
        keys.location = web->location;
        keyFields = &keys;
    }
    EventCandidate confirming;
    const EventCandidate *confirmingPtr = nullptr;
    if (candidate != nullptr) {
        confirming = {candidate->text, candidate->annotation,
                      candidate->payload, candidate->hasPayload};
        confirmingPtr = &confirming;
    }
    qjs::Value data(ctx, buildEventData(ctx, staging, keyFields,
                                        confirmingPtr, absoluteIndex,
                                        windowConfig_));
    qjs::Value global(ctx, JS_GetGlobalObject(ctx));
    qjs::Value maker(
        ctx, JS_GetPropertyStr(ctx, global.get(), c_MakeEventHook));
    if (!maker.isFunction()) {
        MACISHTYPE_ERROR() << "hostglue.js did not define "
                           << c_MakeEventHook;
        return data.release();
    }
    JSValue argument = data.get();
    JSValue event = JS_Call(ctx, maker.get(), JS_UNDEFINED, 1, &argument);
    if (JS_IsException(event)) {
        MACISHTYPE_ERROR() << "makeEvent failed: " << qjs::exceptionText(ctx);
        return data.release();
    }
    return event;
}

// Candidate memory ---------------------------------------------------------

CandidateData EngineSession::copyCandidate(JSContext *ctx,
                                           const CandidateData &candidate) {
    CandidateData copy;
    copy.text = candidate.text;
    copy.annotation = candidate.annotation;
    if (candidate.hasPayload) {
        copy.payload = JS_DupValue(ctx, candidate.payload);
        copy.hasPayload = true;
    }
    return copy;
}

void EngineSession::freeCandidates(std::vector<CandidateData> &candidates) {
    for (auto &candidate : candidates) {
        if (candidate.hasPayload) {
            JS_FreeValue(host_->context(), candidate.payload);
            candidate.hasPayload = false;
        }
    }
    candidates.clear();
}

} // namespace macishtype
