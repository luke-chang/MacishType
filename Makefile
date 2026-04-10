.PHONY: help build debug reload release release-universal install uninstall clean log log-history candidate-window-test

APP_NAME = MacishType
BUNDLE_ID = net.lukechang.inputmethod.$(APP_NAME)
LOG_SHOW_LAST = 1h

# Default target: show help
help:
	@echo "$(APP_NAME) - Available Commands:"
	@echo ""
	@echo "  make build                  - Build Debug version"
	@echo "  make debug                  - Build Debug, deploy, and reload"
	@echo "  make reload                 - Force restart input method by killing its process"
	@echo "  make release                - Build Release version (current architecture)"
	@echo "  make release-universal      - Build Release version (universal binary)"
	@echo "  make install                - Build Release, deploy, and reload"
	@echo "  make uninstall              - Remove installed input method"
	@echo "  make clean                  - Clean build artifacts"
	@echo "  make log                    - Stream live OSLog output"
	@echo "  make log-history            - Show recent log history (default $(LOG_SHOW_LAST), use LOG_SHOW_LAST=24h to override)"
	@echo "  make candidate-window-test  - Build and run standalone CandidateWindow test app"
	@echo ""
	@echo "Quick Start:"
	@echo "  make debug"
	@echo "  Then go to System Settings → Keyboard → Input Sources to add $(APP_NAME)"

# Build Debug version
build:
	@echo "Building Debug version..."
	xcodebuild -configuration Debug ARCHS=$(shell uname -m)

# Build Debug, deploy, and reload
debug: build
	@echo "Installing input method..."
	@if [ -d "./build/Debug/$(APP_NAME).app" ]; then \
		if [ -d ~/Library/Input\ Methods/$(APP_NAME).app ]; then \
			echo "Removing old version..."; \
			rm -rf ~/Library/Input\ Methods/$(APP_NAME).app; \
		fi; \
		echo "Killing input method processes..."; \
		killall $(APP_NAME) 2>/dev/null || true; \
		cp -r ./build/Debug/$(APP_NAME).app ~/Library/Input\ Methods/; \
		echo "✓ Installed Debug version"; \
	else \
		echo "✗ Error: No .app file found"; \
		exit 1; \
	fi
	@echo "✓ Installation complete"

# Force restart input method by killing its process
reload:
	@echo "Restarting input method services..."
	@killall $(APP_NAME) 2>/dev/null || true
	@echo "✓ Services restarted"

# Build Release version (current architecture)
release:
	@echo "Building Release version..."
	xcodebuild -configuration Release ARCHS=$(shell uname -m)

# Build Release version (universal binary)
release-universal:
	@echo "Building Release universal version..."
	xcodebuild -configuration Release ARCHS="arm64 x86_64"

# Build Release, deploy, and reload
install: release
	@echo "Installing input method..."
	@if [ -d "./build/Release/$(APP_NAME).app" ]; then \
		if [ -d ~/Library/Input\ Methods/$(APP_NAME).app ]; then \
			echo "Removing old version..."; \
			rm -rf ~/Library/Input\ Methods/$(APP_NAME).app; \
		fi; \
		echo "Killing input method processes..."; \
		killall $(APP_NAME) 2>/dev/null || true; \
		cp -r ./build/Release/$(APP_NAME).app ~/Library/Input\ Methods/; \
		echo "✓ Installed Release version"; \
	else \
		echo "✗ Error: No .app file found"; \
		exit 1; \
	fi
	@echo "✓ Installation complete"

# Uninstall input method
uninstall:
	@echo "Uninstalling $(APP_NAME) input method..."
	@if [ -d ~/Library/Input\ Methods/$(APP_NAME).app ]; then \
		killall $(APP_NAME) 2>/dev/null || true; \
		rm -rf ~/Library/Input\ Methods/$(APP_NAME).app; \
		echo "✓ $(APP_NAME).app removed"; \
		echo "Note: Please remove $(APP_NAME) from System Settings → Keyboard → Input Sources"; \
	else \
		echo "$(APP_NAME).app not found, nothing to uninstall"; \
	fi

# Clean build artifacts
clean:
	@echo "Cleaning build artifacts..."
	rm -rf ./build
	@echo "✓ Clean complete"

# Stream live OSLog output
log:
	@echo "Streaming OSLog for $(APP_NAME) ($(BUNDLE_ID))..."
	@echo "Press Ctrl+C to stop"
	@echo ""
	log stream --predicate 'subsystem == "$(BUNDLE_ID)"' --level debug --style compact

# Build and run CandidateWindow test app
candidate-window-test:
	@echo "Building CandidateWindow test app..."
	@mkdir -p ./build/CandidateWindowTest.app/Contents/MacOS
	@cp CandidateWindowTest/Info.plist ./build/CandidateWindowTest.app/Contents/
	@swiftc -o ./build/CandidateWindowTest.app/Contents/MacOS/CandidateWindowTest \
		-framework Cocoa -target $(shell uname -m)-apple-macos14.0 \
		CandidateWindowTest/main.swift \
		MacishType/CandidateWindow.swift \
		MacishType/SequoiaCandidateWindow/SequoiaCandidateWindow.swift \
		MacishType/SequoiaCandidateWindow/SequoiaBasePanel.swift \
		MacishType/SequoiaCandidateWindow/SequoiaHorizontalBasePanel.swift \
		MacishType/SequoiaCandidateWindow/SequoiaHorizontalExpandablePanel.swift \
		MacishType/SequoiaCandidateWindow/SequoiaHorizontalSimplePanel.swift \
		MacishType/SequoiaCandidateWindow/SequoiaVerticalPanel.swift \
		MacishType/SequoiaCandidateWindow/SequoiaCandidateItemView.swift \
		MacishType/SequoiaCandidateWindow/SequoiaChevronView.swift \
		MacishType/SequoiaCandidateWindow/SequoiaPageArrowView.swift \
		MacishType/SequoiaCandidateWindow/SequoiaHighlightView.swift \
		MacishType/SequoiaCandidateWindow/SequoiaSeparatorView.swift \
		MacishType/ThemeManager.swift \
		MacishType/Logger.swift
	@echo "✓ Built. Launching..."
	@killall CandidateWindowTest 2>/dev/null || true
	@sleep 0.3
	@open ./build/CandidateWindowTest.app

# Show recent log history
log-history:
	@echo "Showing log history for $(APP_NAME) ($(BUNDLE_ID)) for the last $(LOG_SHOW_LAST)..."
	log show --predicate 'subsystem == "$(BUNDLE_ID)"' --debug --style compact --last $(LOG_SHOW_LAST)
