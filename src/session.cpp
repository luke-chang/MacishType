#include "session.h"

#include <algorithm>

#include <fcitx-utils/utf8.h>
#include <fcitx/candidatelist.h>
#include <fcitx/inputpanel.h>
#include <fcitx/text.h>

#include "jshost/qjsutil.h"
#include "log.h"

namespace macishtype {

namespace {

// Character indices in the JS contract count grapheme clusters; code points
// approximate that (correct for the CJK text engines emit; ZWJ sequences
// and combining marks would need a real segmenter).
int characterCount(const std::string &text) {
    if (!fcitx::utf8::validate(text)) {
        return static_cast<int>(text.size());
    }
    return static_cast<int>(fcitx::utf8::length(text));
}

size_t byteOffsetForCharacter(const std::string &text, int characterIndex) {
    if (characterIndex <= 0) {
        return 0;
    }
    if (!fcitx::utf8::validate(text)) {
        return std::min(text.size(), static_cast<size_t>(characterIndex));
    }
    int total = characterCount(text);
    int clamped = std::min(characterIndex, total);
    return static_cast<size_t>(
        fcitx::utf8::ncharByteLength(text.begin(), clamped));
}

std::string characterPrefix(const std::string &text, int characterCount) {
    return text.substr(0, byteOffsetForCharacter(text, characterCount));
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

EngineSession::EngineSession(JsEngineHost *host,
                             fcitx::InputContext *inputContext)
    : host_(host), inputContext_(inputContext) {
    instanceId_ = host_->createInstance();
    windowConfig_ = sessionWindowConfig();
}

EngineSession::~EngineSession() {
    freeCandidates(candidates_);
    if (instanceId_ != 0) {
        host_->destroyInstance(instanceId_);
    }
}

// Window config -----------------------------------------------------------

EngineSession::WindowConfig EngineSession::sessionWindowConfig() const {
    WindowConfig config;
    auto stringField = [&](const char *name) -> std::optional<std::string> {
        auto value = host_->candidateWindowField(name);
        if (value) {
            if (auto *text = std::get_if<std::string>(&*value)) {
                return *text;
            }
        }
        return std::nullopt;
    };
    auto boolField = [&](const char *name) -> std::optional<bool> {
        auto value = host_->candidateWindowField(name);
        if (value) {
            if (auto *flag = std::get_if<bool>(&*value)) {
                return *flag;
            }
        }
        return std::nullopt;
    };
    auto numberField = [&](const char *name) -> std::optional<int> {
        auto value = host_->candidateWindowField(name);
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
    }
    if (auto navigation = boolField("handleNavigationKeys")) {
        config.handleNavigationKeys = *navigation;
    }
    if (auto labelsKeys = boolField("handleIndexLabelKeys")) {
        config.handleIndexLabelKeys = *labelsKeys;
    }
    return config;
}

int EngineSession::currentPageItemCount() const {
    if (!candidatesVisible_) {
        return 0;
    }
    int total = static_cast<int>(candidates_.size());
    return std::min(windowConfig_.pageSize, total - pageStart_);
}

int EngineSession::pageStartFor(int highlight) const {
    if (highlight <= 0) {
        return 0;
    }
    return (highlight / windowConfig_.pageSize) * windowConfig_.pageSize;
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
        characterCount(web.key) == 1 && web.key != " ") {
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
            confirmCandidateAt(
                static_cast<size_t>(pageStart_ + labelIndex));
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
    endComposition("");
    invokeEngineMethod("compositionEnded", JS_UNDEFINED);
}

void EngineSession::endFromDeactivate() {
    if (!valid()) {
        return;
    }
    endComposition(stagedText_);
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
                    if (candidatesVisible_ && !candidates_.empty()) {
                        size_t index = highlightSuspended_
                                           ? static_cast<size_t>(pageStart_)
                                           : static_cast<size_t>(highlight_);
                        confirmCandidate(candidates_[index],
                                         highlightSuspended_
                                             ? -1
                                             : static_cast<int>(index));
                    }
                } else if constexpr (std::is_same_v<T, CommitAtIndexAction>) {
                    if (candidatesVisible_ && value.index >= 0 &&
                        value.index < currentPageItemCount()) {
                        confirmCandidateAt(
                            static_cast<size_t>(pageStart_ + value.index));
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
    int total = characterCount(markedText_);
    int stagedCount = 0;
    if (action.staged) {
        stagedCount = *action.staged < 0
                          ? total
                          : std::min(std::max(*action.staged, 0), total);
    }
    stagedText_ = characterPrefix(markedText_, stagedCount);

    fcitx::Text preedit;
    if (!markedText_.empty()) {
        fcitx::TextFormatFlags base{fcitx::TextFormatFlag::Underline};
        if (action.emphasis) {
            size_t emphasisStart =
                byteOffsetForCharacter(markedText_, action.emphasis->first);
            size_t emphasisEnd =
                byteOffsetForCharacter(markedText_, action.emphasis->second);
            if (emphasisStart > 0) {
                preedit.append(markedText_.substr(0, emphasisStart), base);
            }
            preedit.append(
                markedText_.substr(emphasisStart, emphasisEnd - emphasisStart),
                base | fcitx::TextFormatFlag::Bold);
            if (emphasisEnd < markedText_.size()) {
                preedit.append(markedText_.substr(emphasisEnd), base);
            }
        } else {
            preedit.append(markedText_, base);
        }
        int cursorCharacters =
            action.cursor ? std::min(std::max(*action.cursor, 0), total)
                          : total;
        preedit.setCursor(static_cast<int>(
            byteOffsetForCharacter(markedText_, cursorCharacters)));
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
    windowConfig_ = sessionWindowConfig();
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
    if (initialHighlight < 0) {
        highlightSuspended_ = true;
        highlight_ = 0;
        pageStart_ = 0;
    } else {
        highlightSuspended_ = false;
        highlight_ = std::min(initialHighlight, total - 1);
        pageStart_ = pageStartFor(highlight_);
    }
    candidatesVisible_ = true;
    renderCandidates();
    // The initial selection counts as a selection change (macOS parity:
    // the window notifies when moving from no-selection to the initial
    // highlight), so engines can render replace previews on open.
    if (!highlightSuspended_) {
        fireSelectionChanged();
    }
}

// Candidate word pushed into the fcitx input panel; select() fires when the
// user clicks a candidate in the UI.
class MacishCandidateWord : public fcitx::CandidateWord {
public:
    MacishCandidateWord(int pageRelativeIndex, const CandidateData &candidate,
                        std::function<void(int)> onSelect)
        : fcitx::CandidateWord(fcitx::Text(candidate.text)),
          pageRelativeIndex_(pageRelativeIndex), onSelect_(std::move(onSelect)) {
        if (!candidate.annotation.empty()) {
            setComment(fcitx::Text(candidate.annotation));
        }
    }

    void select(fcitx::InputContext *inputContext) const override {
        FCITX_UNUSED(inputContext);
        onSelect_(pageRelativeIndex_);
    }

private:
    int pageRelativeIndex_;
    std::function<void(int)> onSelect_;
};

void EngineSession::renderCandidates() {
    auto list = std::make_unique<fcitx::CommonCandidateList>();
    int pageItems = currentPageItemCount();
    list->setPageSize(std::max(1, pageItems));
    list->setLayoutHint(windowConfig_.vertical
                            ? fcitx::CandidateLayoutHint::Vertical
                            : fcitx::CandidateLayoutHint::Horizontal);

    // Blank labels are selection-disabled placeholders; the panels prepend
    // label text to the candidate, so render them as no label at all to
    // keep rows aligned.
    std::vector<std::string> labels;
    auto labelRange =
        fcitx::utf8::MakeUTF8CharRange(windowConfig_.indexLabels);
    for (auto iterator = std::begin(labelRange);
         iterator != std::end(labelRange) &&
         labels.size() < static_cast<size_t>(pageItems);
         ++iterator) {
        std::string labelText(iterator.charRange().first,
                              iterator.charRange().second);
        labels.push_back(labelText == " " ? "" : labelText + " ");
    }
    labels.resize(pageItems, "");
    list->setLabels(labels);

    auto onSelect = [this](int pageRelativeIndex) {
        confirmCandidateAt(static_cast<size_t>(pageStart_ + pageRelativeIndex));
    };
    for (int i = 0; i < pageItems; i++) {
        list->append(std::make_unique<MacishCandidateWord>(
            i, candidates_[pageStart_ + i], onSelect));
    }
    list->setGlobalCursorIndex(highlightSuspended_ ? -1
                                                   : highlight_ - pageStart_);
    inputContext_->inputPanel().setCandidateList(std::move(list));
    inputContext_->updateUserInterface(
        fcitx::UserInterfaceComponent::InputPanel);
}

void EngineSession::hideCandidates() {
    candidatesVisible_ = false;
    highlightSuspended_ = false;
    highlight_ = 0;
    pageStart_ = 0;
    freeCandidates(candidates_);
    inputContext_->inputPanel().setCandidateList(nullptr);
    inputContext_->updateUserInterface(
        fcitx::UserInterfaceComponent::InputPanel);
}

void EngineSession::navigate(const std::string &direction, bool wrapping) {
    if (!candidatesVisible_ || candidates_.empty()) {
        return;
    }
    if (highlightSuspended_) {
        // First navigation reveals the highlight without moving it.
        highlightSuspended_ = false;
        highlight_ = pageStart_;
        renderCandidates();
        fireSelectionChanged();
        return;
    }

    int total = static_cast<int>(candidates_.size());
    int pageSize = windowConfig_.pageSize;
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

    int previousHighlight = highlight_;
    if (resolved == "itemForward") {
        if (highlight_ + 1 < total) {
            highlight_++;
        } else if (wrapping) {
            highlight_ = 0;
        }
    } else if (resolved == "itemBackward") {
        if (highlight_ > 0) {
            highlight_--;
        } else if (wrapping) {
            highlight_ = total - 1;
        }
    } else if (resolved == "pageForward") {
        int offset = highlight_ - pageStart_;
        if (pageStart_ + pageSize < total) {
            pageStart_ += pageSize;
        } else if (wrapping) {
            pageStart_ = 0;
        }
        highlight_ = std::min(pageStart_ + offset, total - 1);
    } else if (resolved == "pageBackward") {
        int offset = highlight_ - pageStart_;
        if (pageStart_ - pageSize >= 0) {
            pageStart_ -= pageSize;
        } else if (wrapping) {
            pageStart_ = pageStartFor(total - 1);
        }
        highlight_ = std::min(pageStart_ + offset, total - 1);
    } else if (resolved == "home") {
        highlight_ = windowConfig_.vertical ? 0 : pageStart_;
    } else if (resolved == "end") {
        highlight_ = windowConfig_.vertical
                         ? total - 1
                         : std::min(pageStart_ + pageSize, total) - 1;
    } else {
        MACISHTYPE_WARN() << host_->engineId()
                          << ": unknown navigation direction: " << direction;
        return;
    }
    pageStart_ = pageStartFor(highlight_);
    renderCandidates();
    if (highlight_ != previousHighlight) {
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
    // Host fallback (macOS parity): in associated mode flush held+picked;
    // otherwise flush staged plus this candidate. The associated-follow-up
    // branch needs the host AssociatedDictionary, which has no Linux data
    // source yet.
    endComposition(stagedText_ + candidate.text);
}

void EngineSession::fireSelectionChanged() {
    if (highlight_ < 0 ||
        static_cast<size_t>(highlight_) >= candidates_.size()) {
        return;
    }
    CandidateData copy =
        copyCandidate(host_->context(), candidates_[highlight_]);
    invokeEngineMethod("candidateSelectionChanged",
                       makeEvent(nullptr, &copy, highlight_));
    if (copy.hasPayload) {
        JS_FreeValue(host_->context(), copy.payload);
    }
}

void EngineSession::enterAssociatedMode(
    const std::string &heldChar,
    std::optional<std::vector<std::string>> candidates) {
    clearCompositionState();
    associating_ = true;
    // TODO: fall back to a host associated dictionary when `candidates` is
    // absent; there is no Linux data source yet.
    std::vector<std::string> resolved =
        candidates ? std::move(*candidates) : std::vector<std::string>{};

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
    windowConfig_ = sessionWindowConfig();
}

// Event objects -----------------------------------------------------------

JSValue EngineSession::buildEventData(const WebKeyEvent *web,
                                      const CandidateData *candidate,
                                      int absoluteIndex) {
    JSContext *ctx = host_->context();
    JSValue data = JS_NewObject(ctx);

    JSValue fields = JS_NewObject(ctx);
    setStringField(ctx, fields, "markedText", markedText_);
    setStringField(ctx, fields, "stagedText", stagedText_);
    setBoolField(ctx, fields, "isComposing", !markedText_.empty());
    setBoolField(ctx, fields, "isAssociating", associating_);
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
        JS_SetPropertyStr(ctx, data, "modifierStates", states);
    }

    JSValue window = JS_NewObject(ctx);
    setBoolField(ctx, window, "isVisible", candidatesVisible_);
    setStringField(ctx, window, "indexLabels", windowConfig_.indexLabels);
    setIntField(ctx, window, "pageSize", windowConfig_.pageSize);
    setStringField(ctx, window, "layoutDirection",
                   windowConfig_.vertical ? "vertical" : "horizontal");
    setBoolField(ctx, window, "handleNavigationKeys",
                 windowConfig_.handleNavigationKeys);
    setBoolField(ctx, window, "handleIndexLabelKeys",
                 windowConfig_.handleIndexLabelKeys);
    setIntField(ctx, window, "pageItemCount", currentPageItemCount());
    JS_SetPropertyStr(ctx, data, "candidateWindow", window);

    return data;
}

JSValue EngineSession::makeEvent(const WebKeyEvent *web,
                                 const CandidateData *candidate,
                                 int absoluteIndex) {
    JSContext *ctx = host_->context();
    qjs::Value data(ctx, buildEventData(web, candidate, absoluteIndex));
    qjs::Value global(ctx, JS_GetGlobalObject(ctx));
    qjs::Value maker(ctx, JS_GetPropertyStr(ctx, global.get(),
                                            "__MacishTypeHost_makeEvent"));
    if (!maker.isFunction()) {
        MACISHTYPE_ERROR() << "hostglue.js did not define "
                              "__MacishTypeHost_makeEvent";
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
