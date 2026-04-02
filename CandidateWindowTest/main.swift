import Cocoa

// Minimal test app for CandidateWindow
// Usage: Run, edit candidates in textarea, click outside to unfocus, then use arrow keys

private let digits: [Character] = ["一", "二", "三", "四", "五", "六", "七", "八", "九", "十"]

private func randomCandidates() -> [String] {
    var candidates: [String] = []
    let count = Int.random(in: 8...20)
    for _ in 0..<count {
        let len = Int.random(in: 1...8)
        let word = String((0..<len).map { _ in digits.randomElement()! })
        candidates.append(word)
    }
    return candidates
}

// Clicking empty area resigns first responder so arrow keys route to CandidateWindow
class ClickableView: NSView {
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(nil)
    }
}

class KeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        // Let the responder chain handle it (avoids beep).
        // The local event monitor intercepts keys for CandidateWindow when needed.
        self.interpretKeyEvents([event])
    }
}

class TestDelegate: NSObject, NSApplicationDelegate, CandidateWindowDelegate, NSTextStorageDelegate {
    let candidateWindow = CandidateWindow.shared
    var defaultAnimationDuration: TimeInterval = 0
    var keyWindow: KeyWindow!
    var textView: NSTextView!

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Set up menu bar with Quit
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenuItem.submenu = editMenu
        NSApp.mainMenu = mainMenu

        candidateWindow.candidateDelegate = self
        candidateWindow.indexBase = 1
        candidateWindow.pageSize = 9
        defaultAnimationDuration = candidateWindow.animationDuration
        candidateWindow.animationDuration = 1.0

        // Create window
        let screenFrame = NSScreen.main?.visibleFrame ?? .zero
        let windowWidth: CGFloat = 420
        let windowHeight: CGFloat = 200
        let windowX = screenFrame.maxX - windowWidth - 20
        let titleBarHeight = NSWindow.frameRect(forContentRect: .zero, styleMask: [.titled, .closable, .resizable]).height
        let windowY = screenFrame.maxY - windowHeight - titleBarHeight - 20
        keyWindow = KeyWindow(
            contentRect: NSRect(x: windowX, y: windowY, width: windowWidth, height: windowHeight),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        keyWindow.title = "CandidateWindow Test"
        keyWindow.level = .floating
        keyWindow.minSize = NSSize(width: 320, height: 160)

        let contentView = ClickableView(frame: keyWindow.contentView!.bounds)
        contentView.autoresizingMask = [.width, .height]
        keyWindow.contentView = contentView

        let padding: CGFloat = 16

        // Title
        let titleLabel = NSTextField(labelWithString: "CandidateWindow Test")
        titleLabel.font = .boldSystemFont(ofSize: 16)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(titleLabel)

        // Instructions
        let instructionLabel = NSTextField(labelWithString: "• Separate candidates with spaces\n• Click outside the text area to navigate with arrow keys")
        instructionLabel.font = .systemFont(ofSize: 12)
        instructionLabel.textColor = .secondaryLabelColor
        instructionLabel.maximumNumberOfLines = 0
        instructionLabel.lineBreakMode = .byWordWrapping
        instructionLabel.preferredMaxLayoutWidth = windowWidth - padding * 2
        instructionLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(instructionLabel)

        // Slow motion checkbox
        let slowMotionCheckbox = NSButton(checkboxWithTitle: "Slow animations (1s)", target: self, action: #selector(slowMotionToggled(_:)))
        slowMotionCheckbox.state = .on
        slowMotionCheckbox.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(slowMotionCheckbox)

        // Text view with scroll view
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(scrollView)

        textView = NSTextView(frame: .zero)
        textView.autoresizingMask = [.width]
        textView.isEditable = true
        textView.isSelectable = true
        textView.font = .systemFont(ofSize: 14)
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.isRichText = false
        textView.allowsUndo = true
        scrollView.documentView = textView

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: padding),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: padding),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -padding),

            instructionLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            instructionLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: padding),
            instructionLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -padding),

            slowMotionCheckbox.topAnchor.constraint(equalTo: instructionLabel.bottomAnchor, constant: 8),
            slowMotionCheckbox.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: padding),

            scrollView.topAnchor.constraint(equalTo: slowMotionCheckbox.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: padding),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -padding),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -padding),
        ])

        // Set initial random candidates
        let candidates = randomCandidates()
        textView.string = candidates.joined(separator: " ")

        // Listen for text changes
        textView.textStorage?.delegate = self

        keyWindow.makeKeyAndOrderFront(nil)
        keyWindow.makeFirstResponder(nil)

        // Arrow keys go to CandidateWindow when textarea is not focused
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let isEditing = self.keyWindow.firstResponder === self.textView
            if event.keyCode == 53 { // Esc
                self.keyWindow.makeFirstResponder(nil)
                return nil
            }
            if isEditing { return event }
            switch event.keyCode {
            case 125: self.candidateWindow.handleNavigation(direction: .down); return nil
            case 126: self.candidateWindow.handleNavigation(direction: .up); return nil
            case 116: self.candidateWindow.handleNavigation(direction: .pageUp); return nil
            case 121: self.candidateWindow.handleNavigation(direction: .pageDown); return nil
            case 123: self.candidateWindow.handleNavigation(direction: .left); return nil
            case 124: self.candidateWindow.handleNavigation(direction: .right); return nil
            case 115: self.candidateWindow.handleNavigation(direction: .home); return nil
            case 119: self.candidateWindow.handleNavigation(direction: .end); return nil
            default: return event
            }
        }

        applyCandidates()
    }

    func applyCandidates() {
        let text = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = text.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard !candidates.isEmpty else { return }
        candidateWindow.updateCandidates(candidates)
        let rect = keyWindow.frame
        candidateWindow.showNear(rect: NSRect(x: rect.minX, y: rect.minY - 10, width: 0, height: 20))
    }

    // NSTextStorageDelegate — called on every text change
    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
        if editedMask.contains(.editedCharacters) {
            DispatchQueue.main.async { [weak self] in
                self?.applyCandidates()
            }
        }
    }

    @objc func slowMotionToggled(_ sender: NSButton) {
        candidateWindow.animationDuration = sender.state == .on ? 1.0 : defaultAnimationDuration
    }

    func candidateSelected(_ candidate: String) {
        print("Selected: \(candidate)")
    }

    func candidateSelectionChanged(_ candidate: String) {
        print("Changed: \(candidate)")
    }
}

let app = NSApplication.shared
let delegate = TestDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()
