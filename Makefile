# Thin entry points over CMake, mirroring the macOS repo's workflow. The
# real build system is CMake; see README.md.

BUILD_DIR := build
MACHINE := $(shell gcc -dumpmachine 2> /dev/null || echo x86_64-linux-gnu)
USER_LIB := $(HOME)/.local/lib/fcitx5
USER_SHARE := $(HOME)/.local/share/fcitx5
# FCITX_ADDON_DIRS replaces fcitx5's default addon search path, so the
# system directory must stay listed.
ADDON_DIRS := $(USER_LIB):/usr/lib/$(MACHINE)/fcitx5

.PHONY: help build prepare debug dev-install dev-uninstall install \
	uninstall restart test clean log log-js log-history
.DEFAULT_GOAL := help

# Window for `make log-history`, systemd time syntax (override:
# LOG_SHOW_LAST=24h).
LOG_SHOW_LAST = 1h
# Both launch paths land in the user journal: the session-autostarted
# fcitx5 under its desktop identifier, `make restart` under systemd-cat's.
LOG_MATCH = -t fcitx5 -t org.fcitx.Fcitx5.desktop
# fcitx5 log lines carry their source file; matching this repo's sources
# scopes the stream to the addon (the moral equivalent of the macOS
# Makefile's subsystem filter). Derived from src/, so new files join
# automatically.
empty :=
space := $(empty) $(empty)
LOG_SOURCES = $(notdir $(wildcard src/*.cpp src/jshost/*.cpp))
LOG_PATTERN = ($(subst $(space),|,$(strip $(LOG_SOURCES)))):[0-9]+\]
# `-o cat` drops the journal prefix (its date/host/pid duplicate what the
# fcitx line already carries); this trims the fcitx timestamp to
# month-day + time: "07-19 04:22:33.418 I macishtype.cpp:86] ...".
LOG_SIMPLIFY = sed -u -E 's/^([A-Z])[0-9]{4}-([0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3})[0-9]*/\2 \1/'

help:
	@echo "fcitx5-macishtype development entry points:"
	@echo ""
	@echo "  make build          - CMake configure + build"
	@echo "  make prepare        - Sync pinned module data tables"
	@echo "  make test           - Acceptance suite against an isolated fcitx5"
	@echo "  make debug          - prepare + build + dev-install + restart"
	@echo "  make dev-install    - Install into ~/.local (no restart)"
	@echo "  make dev-uninstall  - Remove the ~/.local install (keeps engines)"
	@echo "  make install        - Production install into /usr (sudo) + restart"
	@echo "  make uninstall      - Remove the production install + restart"
	@echo "  make restart        - Restart the live fcitx5 (interrupts typing;"
	@echo "                        LOG_DEBUG=1 enables per-key Debug logging)"
	@echo "  make log            - Follow the addon's log (user journal)"
	@echo "  make log-js         - Follow engine console.* output only"
	@echo "  make log-history    - Recent addon log (default $(LOG_SHOW_LAST); LOG_SHOW_LAST=24h)"
	@echo "  make clean          - Remove the build directory"
	@echo ""
	@echo "Quick start: make debug, then add the input methods in fcitx5-configtool."

build:
	cmake -B $(BUILD_DIR) -G Ninja
	cmake --build $(BUILD_DIR) -j

# Module data tables (wordFrequency / symbolNames), pinned in
# scripts/external-resources.lock.
prepare:
	scripts/external-resources.sh --prepare

# Development install into ~/.local plus a fcitx5 restart. Restarting
# interrupts typing in the current session — run this yourself.
debug:
	$(MAKE) prepare
	$(MAKE) build
	$(MAKE) dev-install
	$(MAKE) restart

# User-dir install; no root needed. Engine folders go into
# ~/.local/share/fcitx5/macishtype/engines/<name>/.
dev-install:
	install -D -m 755 $(BUILD_DIR)/src/libmacishtype.so $(USER_LIB)/libmacishtype.so
	install -D -m 644 $(BUILD_DIR)/src/macishtype-addon.conf $(USER_SHARE)/addon/macishtype.conf
	install -D -m 644 runtime/runtime.js $(USER_SHARE)/macishtype/runtime.js
	install -D -m 644 runtime/hostglue.js $(USER_SHARE)/macishtype/hostglue.js
	@mkdir -p $(USER_SHARE)/macishtype/engines
	install -D -m 644 $(BUILD_DIR)/po/zh_TW.mo \
	    $(HOME)/.local/share/locale/zh_TW/LC_MESSAGES/fcitx5-macishtype.mo
	@if [ -d data/modules ]; then \
	    mkdir -p $(USER_SHARE)/macishtype/modules; \
	    cp data/modules/* $(USER_SHARE)/macishtype/modules/; \
	    cp data/*.LICENSE.txt $(USER_SHARE)/macishtype/modules/ 2> /dev/null || true; \
	fi

# Reverses dev-install but keeps user data (the engines folder). Run this
# before switching to `make install`: user-dir files shadow the system
# install, so a stale dev copy would keep winning. The FCITX_ADDON_DIRS
# entry in ~/.config/environment.d is not an install artifact and stays.
dev-uninstall:
	rm -f $(USER_LIB)/libmacishtype.so
	rm -f $(USER_SHARE)/addon/macishtype.conf
	rm -f $(USER_SHARE)/macishtype/runtime.js
	rm -f $(USER_SHARE)/macishtype/hostglue.js
	rm -rf $(USER_SHARE)/macishtype/modules
	rm -f $(HOME)/.local/share/locale/*/LC_MESSAGES/fcitx5-macishtype.mo
	@rmdir $(USER_SHARE)/macishtype/engines $(USER_SHARE)/macishtype \
	    2> /dev/null || true

# Production install (addon .so, confs, shared runtime, and any prepared
# module data). Run `make prepare` first if the data tables should be
# included. The distro fcitx5 only loads addons from /usr, so the install
# prefix must be /usr — /usr/local would be ignored.
install:
	@if [ -f $(USER_LIB)/libmacishtype.so ] || \
	    [ -f $(USER_SHARE)/addon/macishtype.conf ]; then \
	    echo "A dev install exists in ~/.local and would shadow the" >&2; \
	    echo "system install. Run \`make dev-uninstall\` first (engine" >&2; \
	    echo "folders are kept)." >&2; \
	    exit 1; \
	fi
	$(MAKE) prepare
	cmake -B $(BUILD_DIR) -G Ninja -DCMAKE_INSTALL_PREFIX=/usr
	cmake --build $(BUILD_DIR) -j
	sudo cmake --install $(BUILD_DIR)
	$(MAKE) restart

# Restarts the LIVE fcitx5 with the user-dir addon visible — interrupts
# typing, so run it yourself. Output goes to the user journal (see `make
# log`), same as a session-autostarted fcitx5. Per-key Debug logging is
# off by default; enable with LOG_DEBUG=1.
restart:
	FCITX_ADDON_DIRS="$(ADDON_DIRS)" systemd-cat -t fcitx5 \
	    fcitx5 -rd $(if $(LOG_DEBUG),--verbose macishtype=5)

# Live addon log stream from the user journal, both launch paths included.
# For the full fcitx5 stream use journalctl directly.
log:
	@journalctl --user -f -o cat $(LOG_MATCH) | grep --line-buffered -E '$(LOG_PATTERN)' | $(LOG_SIMPLIFY)

# JS-originated lines only: engine console.* arrives via the host's log
# bridge, prefixed with the engine id in brackets.
log-js:
	@journalctl --user -f -o cat $(LOG_MATCH) | grep --line-buffered -E '\] \[[a-z0-9_-]+\]' \
	    | $(LOG_SIMPLIFY) | sed -u -E 's/ [a-z]+\.cpp:[0-9]+\]//'

log-history:
	@journalctl --user --since "-$(LOG_SHOW_LAST)" -o cat $(LOG_MATCH) \
	    | grep -E '$(LOG_PATTERN)' | $(LOG_SIMPLIFY) || true

# Removes a production install, using the manifest cmake wrote during the
# last `make install`, and restarts fcitx5 so the removal takes effect —
# fcitx5 then drops this addon's entries from the profile, which is
# the correct cleanup for a real removal. Switching to a dev install
# instead? Run `make debug` first so the addon never disappears and the
# profile keeps its entries.
uninstall:
	@test -f $(BUILD_DIR)/install_manifest.txt || \
	    { echo "No install manifest; nothing recorded to uninstall." >&2; exit 1; }
	sudo xargs rm -f < $(BUILD_DIR)/install_manifest.txt
	@sudo rmdir /usr/share/fcitx5/macishtype/modules \
	    /usr/share/fcitx5/macishtype 2> /dev/null || true
	$(MAKE) restart

# Acceptance suite against an isolated fcitx5; safe to run any time.
test: build
	test/acceptance.sh
	test/reload.sh
	test/storage.sh
	test/settings.sh
	test/compositionend.sh
	test/associated.sh

clean:
	rm -rf $(BUILD_DIR)
