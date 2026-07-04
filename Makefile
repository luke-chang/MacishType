.PHONY: help build test debug reload release release-universal install uninstall pkg prepare update-resources clean-resources clean log log-js log-history preview

APP_NAME = MacishType
BUNDLE_ID = net.lukechang.inputmethod.$(APP_NAME)
BUILD_NUMBER := $(shell date +%Y%m%d%H%M)
LOG_SHOW_LAST = 1h
# Component install destination; rebased under the user home by the installer's
# currentUserHome domain, so this resolves to ~/Library/Input Methods.
PKG_INSTALL_LOCATION = /Library/Input Methods

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

# Extract and key-sort a plist's ComponentInputModeDict to JSON for a stable
# comparison. Prints empty string when the file or key is absent. $(1) = path.
EXTRACT_MODE_DICT = plutil -extract ComponentInputModeDict json -o - "$(1)" 2>/dev/null | python3 -c 'import json,sys; raw=sys.stdin.read().strip(); print(json.dumps(json.loads(raw), sort_keys=True) if raw else "")' 2>/dev/null

# $(call INSTALL_APP,<Debug|Release>): deploy ./build/<config>/$(APP_NAME).app.
# Logout hint mirrors the pkg's onConclusionScript: the Settings input source
# picker has a per-login cache that no observable plist or service restart can
# flush, so prompt a re-login only when the declared input mode set changed
# (first install, or the installed ComponentInputModeDict differs from the new
# build's). A plain upgrade that keeps the same modes installs silently.
define INSTALL_APP
echo "Installing input method..."; \
NEW_APP="./build/$(1)/$(APP_NAME).app"; \
if [ ! -d "$$NEW_APP" ]; then \
	echo "✗ Error: No .app file found"; \
	exit 1; \
fi; \
OLD_APP=~/Library/Input\ Methods/$(APP_NAME).app; \
relogin=true; \
if [ -d "$$OLD_APP" ]; then \
	old_modes=$$($(call EXTRACT_MODE_DICT,$$OLD_APP/Contents/Info.plist)); \
	new_modes=$$($(call EXTRACT_MODE_DICT,$$NEW_APP/Contents/Info.plist)); \
	[ "$$old_modes" = "$$new_modes" ] && relogin=false; \
	echo "Removing old version..."; \
	rm -rf "$$OLD_APP"; \
fi; \
echo "Killing input method processes..."; \
killall $(APP_NAME) 2>/dev/null || true; \
cp -r "$$NEW_APP" ~/Library/Input\ Methods/; \
echo "✓ Installed $(1) version"; \
if $$relogin; then \
	echo ""; \
	echo "ℹ Input mode set changed (or first install). $(APP_NAME) may not appear"; \
	echo "  or update in System Settings → Keyboard → Input Sources until you log"; \
	echo "  out and back in."; \
	if [ -t 0 ]; then \
		echo ""; \
		printf "  Log out now? [y/N] "; \
		read answer; \
		case "$$answer" in \
			[Yy]*) \
				echo "  Logging out (save your work — apps may prompt)..."; \
				osascript -e 'tell application "System Events" to log out'; \
				;; \
			*) \
				echo "  Skipped. Log out manually when convenient."; \
				;; \
		esac; \
	fi; \
fi
endef

help:
	@echo "$(APP_NAME) - Available Commands:"
	@echo ""
	@echo "  make prepare            - Sync external resources to lock state (incremental; auto-run by builds)"
	@echo "  make update-resources   - Bump pinned upstream SHAs in lock and re-prepare"
	@echo "  make build              - Build Debug version"
	@echo "  make test               - Run unit tests"
	@echo "  make debug              - Build Debug, deploy, and reload"
	@echo "  make reload             - Force restart input method by killing its process"
	@echo "  make release            - Build Release version (current architecture)"
	@echo "  make release-universal  - Build Release version (universal binary)"
	@echo "  make install            - Build Release, deploy, and reload"
	@echo "  make uninstall          - Remove installed input method"
	@echo "  make pkg                - Build universal installer"
	@echo "  make clean              - Clean build artifacts"
	@echo "  make clean-resources    - Remove downloaded external resources and cache/stamp"
	@echo "  make log                - Stream live OSLog output"
	@echo "  make log-js             - Stream JS-originated logs (engine console.*, uncaught exceptions, rejections)"
	@echo "  make log-history        - Show recent log history (default $(LOG_SHOW_LAST), use LOG_SHOW_LAST=24h to override)"
	@echo "  make preview            - Build and run CandidateWindow preview app"
	@echo ""
	@echo "Quick Start:"
	@echo "  make debug"
	@echo "  Then go to System Settings → Keyboard → Input Sources to add $(APP_NAME)"

build: prepare
	@$(XCODE_CHECK)
	@echo "Building Debug version..."
	xcodebuild -target $(APP_NAME) -configuration Debug ARCHS=$(shell uname -m) CURRENT_PROJECT_VERSION=$(BUILD_NUMBER)

# No `prepare` dependency: the test bundle compiles sources only and
# never stages engine resources.
test:
	@$(XCODE_CHECK)
	@echo "Running unit tests..."
	xcodebuild test -scheme $(APP_NAME)Tests -destination "platform=macOS,arch=$(shell uname -m)"

debug: build
	@$(call INSTALL_APP,Debug)

reload:
	@echo "Restarting input method services..."
	@killall $(APP_NAME) 2>/dev/null || true
	@echo "✓ Services restarted"

release: prepare
	@$(XCODE_CHECK)
	@echo "Building Release version..."
	xcodebuild -target $(APP_NAME) -configuration Release ARCHS=$(shell uname -m) CURRENT_PROJECT_VERSION=$(BUILD_NUMBER)

release-universal: prepare
	@$(XCODE_CHECK)
	@echo "Building Release universal version..."
	xcodebuild -target $(APP_NAME) -configuration Release ARCHS="arm64 x86_64" CURRENT_PROJECT_VERSION=$(BUILD_NUMBER)

install: release
	@$(call INSTALL_APP,Release)

# Build a double-clickable installer. enable_currentUserHome installs into
# ~/Library/Input Methods without admin rights. A postinstall script kills any
# running process so the system relaunches the freshly installed binary.
# onConclusionScript runs Installer JavaScript that forces a re-login only when
# the declared input mode set changed (first install, or the installed
# ComponentInputModeDict differs), so the system re-reads the input source list.
pkg: release-universal
	@set -e; \
	APP_DIR="./build/Release/$(APP_NAME).app"; \
	if [ ! -d "$$APP_DIR" ]; then echo "✗ Error: $$APP_DIR not found"; exit 1; fi; \
	PLIST="$$APP_DIR/Contents/Info.plist"; \
	VERSION=$$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$$PLIST"); \
	BUILD_DATE=$$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$$PLIST" | cut -c1-8); \
	GIT_HASH=$$(/usr/libexec/PlistBuddy -c "Print :GitCommitHash" "$$PLIST"); \
	WORK_DIR="./build/pkg"; \
	rm -rf "$$WORK_DIR"; mkdir -p "$$WORK_DIR"; \
	COMPONENT_PKG="$$WORK_DIR/component.pkg"; \
	DIST_XML="$$WORK_DIR/distribution.xml"; \
	OUTPUT_PKG="$(APP_NAME)-v$$VERSION-$$BUILD_DATE-$$GIT_HASH-Universal.pkg"; \
	SCRIPTS_DIR="$$WORK_DIR/scripts"; \
	mkdir -p "$$SCRIPTS_DIR"; \
	printf '%s\n' '#!/bin/sh' 'killall $(APP_NAME) 2>/dev/null || true' 'exit 0' > "$$SCRIPTS_DIR/postinstall"; \
	chmod +x "$$SCRIPTS_DIR/postinstall"; \
	STAGE_DIR="$$WORK_DIR/root"; \
	mkdir -p "$$STAGE_DIR"; \
	cp -R "$$APP_DIR" "$$STAGE_DIR/"; \
	COMPONENT_PLIST="$$WORK_DIR/component.plist"; \
	pkgbuild --analyze --root "$$STAGE_DIR" "$$COMPONENT_PLIST" >/dev/null; \
	plutil -replace 0.BundleIsRelocatable -bool NO "$$COMPONENT_PLIST"; \
	echo "Building component package (universal)..."; \
	pkgbuild \
		--root "$$STAGE_DIR" \
		--component-plist "$$COMPONENT_PLIST" \
		--install-location "$(PKG_INSTALL_LOCATION)" \
		--scripts "$$SCRIPTS_DIR" \
		--identifier "$(BUNDLE_ID)" \
		--version "$$VERSION" \
		"$$COMPONENT_PKG"; \
	echo "Writing distribution definition..."; \
	MODE_DICT=$$(plutil -extract ComponentInputModeDict json -o - "$$PLIST"); \
	{ \
		printf '%s\n' \
			'<?xml version="1.0" encoding="utf-8"?>' \
			'<installer-gui-script minSpecVersion="2">' \
			'    <title>$(APP_NAME)</title>' \
			'    <license file="LICENSE"/>' \
			'    <options customize="never" hostArchitectures="arm64,x86_64"/>' \
			'    <domains enable_currentUserHome="true" enable_localSystem="false" enable_anywhere="false"/>' \
			'    <script><![CDATA['; \
		printf 'var macishNew = %s;\n' "$$MODE_DICT"; \
		cat Distribution/ConclusionDecision.js; \
		printf '%s\n' \
			']]></script>' \
			'    <choices-outline>' \
			'        <line choice="install"/>' \
			'    </choices-outline>' \
			'    <choice id="install" visible="false">' \
			'        <pkg-ref id="$(BUNDLE_ID)"/>' \
			'    </choice>' \
			"    <pkg-ref id=\"$(BUNDLE_ID)\" version=\"$$VERSION\" onConclusionScript=\"macishConclusion()\">component.pkg</pkg-ref>" \
			'</installer-gui-script>'; \
	} > "$$DIST_XML"; \
	awk 'BEGIN { RS = ""; ORS = "" } { gsub(/\n/, " "); printf "%s%s", separator, $$0; separator = "\n\n" }' LICENSE > "$$WORK_DIR/LICENSE"; \
	echo "Building product archive..."; \
	productbuild \
		--distribution "$$DIST_XML" \
		--package-path "$$WORK_DIR" \
		--resources "$$WORK_DIR" \
		"$$OUTPUT_PKG"; \
	rm -rf "$$WORK_DIR"; \
	echo ""; \
	echo "✓ Installer package created: $$OUTPUT_PKG"

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
			echo "ℹ $(APP_NAME) will still appear in System Settings → Keyboard → Input Sources"; \
			echo "  until you log out and back in to fully unregister it."; \
			if [ -t 0 ]; then \
				echo ""; \
				printf "  Log out now? [y/N] "; \
				read answer; \
				case "$$answer" in \
					[Yy]*) \
						echo "  Logging out (save your work — apps may prompt)..."; \
						osascript -e 'tell application "System Events" to log out'; \
						;; \
					*) \
						echo "  Skipped. Log out manually when convenient."; \
						;; \
				esac; \
			fi; \
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

preview: prepare
	@$(XCODE_CHECK)
	@echo "Building CandidateWindow preview app..."
	xcodebuild -target CandidateWindowPreview -configuration Debug ARCHS=$(shell uname -m)
	@echo "✓ Built. Launching..."
	@killall CandidateWindowPreview 2>/dev/null || true
	@sleep 0.3
	@open ./build/Debug/CandidateWindowPreview.app

prepare:
	@./Scripts/HandleExternalResources.sh --prepare

update-resources:
	@./Scripts/HandleExternalResources.sh --update

clean-resources:
	@./Scripts/HandleExternalResources.sh --clean
