# Thin entry points over CMake, mirroring the macOS repo's workflow. The
# real build system is CMake; see README.md.

BUILD_DIR := build
MACHINE := $(shell gcc -dumpmachine 2> /dev/null || echo x86_64-linux-gnu)
USER_LIB := $(HOME)/.local/lib/fcitx5
USER_SHARE := $(HOME)/.local/share/fcitx5
# Where the addon links engine icons at runtime (XDG data home, not fcitx's
# own data directory).
ICON_LINK_DIR := $(if $(XDG_DATA_HOME),$(XDG_DATA_HOME),$(HOME)/.local/share)/icons/hicolor
# FCITX_ADDON_DIRS replaces fcitx5's default addon search path, so the
# system directory must stay listed.
ADDON_DIRS := $(USER_LIB):/usr/lib/$(MACHINE)/fcitx5

.PHONY: help build prepare update-resources clean-resources debug \
	dev-install dev-uninstall install uninstall remove-icon-links restart \
	test clean log log-js log-history
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
LOG_SOURCES_RE = $(subst $(space),|,$(strip $(LOG_SOURCES)))
# A fcitx log record starts at a level+timestamp header; a multi-line message
# (a JS stack trace) wraps onto following lines that carry no prefix. Keep a
# record together with those continuation lines, gated on the header naming one
# of this repo's sources (or, for -js, an engine tag) — a plain per-line grep
# would drop the stack frames. perl (not awk): mawk block-buffers stdin, which
# stalls the `make log` follow stream; perl with $| stays line-buffered.
LOG_SCOPE = perl -ne 'BEGIN{$$|=1} if(/^[A-Z][0-9]{4}-[0-9]{2}-[0-9]{2} /){$$k=/($(LOG_SOURCES_RE)):[0-9]+\]/} print if $$k'
LOG_SCOPE_JS = perl -ne 'BEGIN{$$|=1} if(/^[A-Z][0-9]{4}-[0-9]{2}-[0-9]{2} /){$$k=/\] \[[a-z0-9_-]+\]/} print if $$k'
# `-o cat` drops the journal prefix (its date/host/pid duplicate what the fcitx
# line already carries). Rewrite the fcitx prefix to a balanced, brace-matched
# form, trimming the timestamp to month-day + time:
# "I2026-... enginehost.cpp:86]" -> "[07-19 04:22:33.418 I] enginehost.cpp:86".
LOG_SIMPLIFY = sed -u -E 's/^([A-Z])[0-9]{4}-([0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3})[0-9]* ([A-Za-z0-9_]+\.cpp:[0-9]+)\]/[\2 \1] \3/'

help:
	@echo "fcitx5-macishtype development entry points:"
	@echo ""
	@echo "  make build          - CMake configure + build"
	@echo "  make prepare        - Sync pinned module data tables"
	@echo "  make update-resources - Bump pinned upstream SHAs and re-prepare"
	@echo "  make clean-resources  - Remove downloaded tables and cache/stamp"
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

# Module data tables (wordFrequency / symbolNames), pinned in the repo-level
# scripts/external-resources.lock and shared with the other platforms.
prepare:
	../scripts/external-resources.py --prepare

update-resources:
	@../scripts/external-resources.py --update

clean-resources:
	@../scripts/external-resources.py --clean

# Development install into ~/.local plus a fcitx5 restart. Restarting
# interrupts typing in the current session — run this yourself.
debug:
	$(MAKE) prepare
	$(MAKE) build
	$(MAKE) dev-install
	$(MAKE) restart

# User-dir install; no root needed. Engine folders go into
# ~/.local/share/fcitx5/macishtype/engines/<name>/. The freshness check keeps
# stale data tables from being copied silently (`make prepare` to sync).
dev-install:
	@../scripts/external-resources.py --check
	install -D -m 755 $(BUILD_DIR)/src/libmacishtype.so $(USER_LIB)/libmacishtype.so
	install -D -m 644 $(BUILD_DIR)/src/macishtype-addon.conf $(USER_SHARE)/addon/macishtype.conf
	install -D -m 644 ../runtime/runtime.js $(USER_SHARE)/macishtype/runtime.js
	install -D -m 644 ../runtime/hostglue.js $(USER_SHARE)/macishtype/hostglue.js
	@mkdir -p $(USER_SHARE)/macishtype/engines
	@for mo in $(BUILD_DIR)/po/*.mo; do \
	    lang=$$(basename $$mo .mo); \
	    install -D -m 644 $$mo \
	        $(HOME)/.local/share/locale/$$lang/LC_MESSAGES/fcitx5-macishtype.mo; \
	done
	@for t in AssociatedDictionary.zh-Hant.txt WordFrequency.zh-Hant.txt \
	    SymbolNames.zh-Hant.txt McBopomofo.LICENSE.txt CLDR.LICENSE.txt; do \
	    install -D -m 644 ../tables/$$t $(USER_SHARE)/macishtype/tables/$$t; \
	done

# Reverses dev-install but keeps user data (the engines folder). Run this
# before switching to `make install`: user-dir files shadow the system
# install, so a stale dev copy would keep winning. The FCITX_ADDON_DIRS
# entry in ~/.config/environment.d is not an install artifact and stays.
dev-uninstall:
	rm -f $(USER_LIB)/libmacishtype.so
	rm -f $(USER_SHARE)/addon/macishtype.conf
	rm -f $(USER_SHARE)/macishtype/runtime.js
	rm -f $(USER_SHARE)/macishtype/hostglue.js
	rm -rf $(USER_SHARE)/macishtype/tables
	rm -f $(HOME)/.local/share/locale/*/LC_MESSAGES/fcitx5-macishtype.mo
	$(MAKE) remove-icon-links
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
	@journalctl --user -f -o cat $(LOG_MATCH) | $(LOG_SCOPE) | $(LOG_SIMPLIFY)

# JS-originated lines only: engine console.* arrives via the host's log
# bridge, prefixed with the engine id in brackets.
log-js:
	@journalctl --user -f -o cat $(LOG_MATCH) | $(LOG_SCOPE_JS) \
	    | $(LOG_SIMPLIFY) | sed -u -E 's/ [A-Za-z0-9_]+\.cpp:[0-9]+//'

log-history:
	@journalctl --user --since "-$(LOG_SHOW_LAST)" -o cat $(LOG_MATCH) \
	    | $(LOG_SCOPE) | $(LOG_SIMPLIFY) || true

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
	@sudo rmdir /usr/share/fcitx5/macishtype/tables \
	    /usr/share/fcitx5/macishtype 2> /dev/null || true
	$(MAKE) remove-icon-links
	$(MAKE) restart

# The addon links engine icons into the user's icon theme at runtime, so they
# are in no install manifest and its own startup sweep can no longer reach them
# once it is uninstalled; both uninstall paths call this. Only symlinks are
# removed, matching that sweep.
#
# Never run this against a live install: the addon serves panels the theme
# NAME, so deleting the links makes every panel show a missing icon — worse
# than before, and the next reload recreates them anyway. To go back to
# path-served icons, stop the addon from serving names first (uninstall, or
# revert and restart), then clean up here.
remove-icon-links:
	@find $(ICON_LINK_DIR) -maxdepth 3 -mindepth 3 -type l \
	    -name 'macishtype-*' -delete 2> /dev/null || true

# Acceptance suite against an isolated fcitx5; safe to run any time.
test: build
	test/acceptance.sh
	test/navigation.sh
	test/reload.sh
	test/storage.sh
	test/settings.sh
	test/orientation.sh
	test/segmenter.sh
	test/datetime.sh
	test/number.sh
	test/plural.sh
	test/collator.sh
	test/errorstack.sh
	test/fullwidth.sh
	test/compositionend.sh
	test/associated.sh
	test/contract.sh
	test/asyncfetch.sh
	test/toggle.sh
	test/discovery.sh
	test/textcodec.sh
	test/reverselookup.sh
	test/modules.sh
	test/icontheme.sh

clean:
	rm -rf $(BUILD_DIR)
