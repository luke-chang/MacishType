.PHONY: help build debug reload release release-universal install uninstall clean log log-js log-history preview

APP_NAME = MacishType
BUNDLE_ID = net.lukechang.inputmethod.$(APP_NAME)
LOG_SHOW_LAST = 1h

# Catch CLT-only or unset developer dir before xcodebuild's cryptic error.
define XCODE_CHECK
case "$$(xcode-select -p 2>/dev/null)" in \
	"") \
		echo "✗ No developer directory is set."; \
		echo "  Install Xcode from the App Store, then:"; \
		echo "    sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"; \
		exit 1 ;; \
	*CommandLineTools*) \
		echo "✗ xcodebuild requires full Xcode, but the active developer directory"; \
		echo "  is Command Line Tools: $$(xcode-select -p)"; \
		echo ""; \
		echo "  Install Xcode from the App Store, then:"; \
		echo "    sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"; \
		exit 1 ;; \
esac
endef

# $(call INSTALL_APP,<Debug|Release>): deploy ./build/<config>/$(APP_NAME).app.
# First-install heuristic for the logout hint: Settings input source picker has
# a per-login cache that no observable plist or service restart can flush.
define INSTALL_APP
echo "Installing input method..."; \
if [ ! -d "./build/$(1)/$(APP_NAME).app" ]; then \
	echo "✗ Error: No .app file found"; \
	exit 1; \
fi; \
first_install=true; \
if [ -d ~/Library/Input\ Methods/$(APP_NAME).app ]; then \
	first_install=false; \
	echo "Removing old version..."; \
	rm -rf ~/Library/Input\ Methods/$(APP_NAME).app; \
fi; \
echo "Killing input method processes..."; \
killall $(APP_NAME) 2>/dev/null || true; \
cp -r ./build/$(1)/$(APP_NAME).app ~/Library/Input\ Methods/; \
echo "✓ Installed $(1) version"; \
if $$first_install; then \
	echo ""; \
	echo "ℹ First install on this account. If $(APP_NAME) doesn't appear in"; \
	echo "  System Settings → Keyboard → Input Sources → +, log out and back in."; \
fi
endef

help:
	@echo "$(APP_NAME) - Available Commands:"
	@echo ""
	@echo "  make build              - Build Debug version"
	@echo "  make debug              - Build Debug, deploy, and reload"
	@echo "  make reload             - Force restart input method by killing its process"
	@echo "  make release            - Build Release version (current architecture)"
	@echo "  make release-universal  - Build Release version (universal binary)"
	@echo "  make install            - Build Release, deploy, and reload"
	@echo "  make uninstall          - Remove installed input method"
	@echo "  make clean              - Clean build artifacts"
	@echo "  make log                - Stream live OSLog output"
	@echo "  make log-js             - Stream JS-originated logs (engine console.*, uncaught exceptions, rejections)"
	@echo "  make log-history        - Show recent log history (default $(LOG_SHOW_LAST), use LOG_SHOW_LAST=24h to override)"
	@echo "  make preview            - Build and run CandidateWindow preview app"
	@echo ""
	@echo "Quick Start:"
	@echo "  make debug"
	@echo "  Then go to System Settings → Keyboard → Input Sources to add $(APP_NAME)"

build:
	@$(XCODE_CHECK)
	@echo "Building Debug version..."
	xcodebuild -target $(APP_NAME) -configuration Debug ARCHS=$(shell uname -m)

debug: build
	@$(call INSTALL_APP,Debug)

reload:
	@echo "Restarting input method services..."
	@killall $(APP_NAME) 2>/dev/null || true
	@echo "✓ Services restarted"

release:
	@$(XCODE_CHECK)
	@echo "Building Release version..."
	xcodebuild -target $(APP_NAME) -configuration Release ARCHS=$(shell uname -m)

release-universal:
	@$(XCODE_CHECK)
	@echo "Building Release universal version..."
	xcodebuild -target $(APP_NAME) -configuration Release ARCHS="arm64 x86_64"

install: release
	@$(call INSTALL_APP,Release)

# Container metadata is owned by containermanagerd via a kernel sandbox profile
# and cannot be removed from user space — Data/ is wiped, shell is left in place.
uninstall:
	@echo "Uninstalling $(APP_NAME) input method..."
	@removed=0; failed=0; removed_app=false; \
	for path in \
		"$$HOME/Library/Input Methods/$(APP_NAME).app" \
		"$$HOME/Library/Application Scripts/$(BUNDLE_ID)"; \
	do \
		if [ -e "$$path" ]; then \
			if rm -rf "$$path" 2>/dev/null && [ ! -e "$$path" ]; then \
				echo "  ✓ Removed $$path"; \
				removed=$$((removed+1)); \
				case "$$path" in *"Input Methods/$(APP_NAME).app") removed_app=true ;; esac; \
			else \
				echo "  ✗ Could not remove $$path"; \
				failed=$$((failed+1)); \
			fi; \
		fi; \
	done; \
	container="$$HOME/Library/Containers/$(BUNDLE_ID)"; \
	if [ -d "$$container/Data" ]; then \
		rm -rf "$$container/Data" 2>/dev/null; \
		if [ ! -e "$$container/Data" ]; then \
			echo "  ✓ Wiped user data in $$container (containermanagerd metadata kept — will be reused on reinstall)"; \
			removed=$$((removed+1)); \
		else \
			echo "  ✗ Could not remove $$container/Data"; \
			failed=$$((failed+1)); \
		fi; \
	fi; \
	killall -9 $(APP_NAME) 2>/dev/null || true; \
	if [ $$removed -eq 0 ] && [ $$failed -eq 0 ]; then \
		echo "Nothing found, $(APP_NAME) appears to be already uninstalled."; \
	else \
		echo ""; \
		if [ $$removed -gt 0 ]; then echo "✓ Removed $$removed item(s)"; fi; \
		if [ $$failed -gt 0 ]; then echo "⚠ $$failed item(s) could not be removed (see above)"; fi; \
		if $$removed_app; then \
			echo ""; \
			echo "ℹ If $(APP_NAME) still appears in System Settings → Keyboard → Input Sources,"; \
			echo "  log out and back in to fully unregister it."; \
		fi; \
	fi

clean:
	@echo "Cleaning build artifacts..."
	rm -rf ./build
	@echo "✓ Clean complete"

log:
	@echo "Streaming OSLog for $(APP_NAME) ($(BUNDLE_ID))..."
	@echo "Press Ctrl+C to stop"
	@echo ""
	log stream --predicate 'subsystem == "$(BUNDLE_ID)"' --level debug --style compact

log-js:
	@echo "Streaming JS-originated logs for $(APP_NAME) ($(BUNDLE_ID))..."
	@echo "Press Ctrl+C to stop"
	@echo ""
	log stream --predicate 'subsystem == "$(BUNDLE_ID)" AND category == "JavaScript"' --level debug --style compact

log-history:
	@echo "Showing log history for $(APP_NAME) ($(BUNDLE_ID)) for the last $(LOG_SHOW_LAST)..."
	log show --predicate 'subsystem == "$(BUNDLE_ID)"' --debug --style compact --last $(LOG_SHOW_LAST)

preview:
	@$(XCODE_CHECK)
	@echo "Building CandidateWindow preview app..."
	xcodebuild -target CandidateWindowPreview -configuration Debug ARCHS=$(shell uname -m)
	@echo "✓ Built. Launching..."
	@killall CandidateWindowPreview 2>/dev/null || true
	@sleep 0.3
	@open ./build/Debug/CandidateWindowPreview.app
