# Thin entry points over CMake, mirroring the macOS repo's workflow. The
# real build system is CMake; see README.md.

BUILD_DIR := build
# Build parallelism; empty lets ninja decide. Low-memory machines want
# JOBS=2 — full parallelism can starve the compiler into a crash.
JOBS ?=
# Passed on every configure: CMake's own default only applies to an empty
# cache, so a build dir configured once as Debug would keep that type for
# every later build. BUILD_TYPE=Debug gives an unoptimized build on purpose.
BUILD_TYPE ?= RelWithDebInfo
# Engine folders from ../engines to install alongside the addon, space- or
# comma-separated, or `all` for every folder with a manifest
# (`make install PRELOAD_ENGINES="array30 example"`, and the same for
# `make pkg`). Empty ships the addon alone. Passed on every configure for the reason above: a build dir
# that once carried engines would keep installing them.
PRELOAD_ENGINES ?=
USER_LIB := $(HOME)/.local/lib/fcitx5
USER_SHARE := $(HOME)/.local/share/fcitx5
# Where the addon links engine icons at runtime (XDG data home, not fcitx's
# own data directory).
ICON_LINK_DIR := $(if $(XDG_DATA_HOME),$(XDG_DATA_HOME),$(HOME)/.local/share)/icons/hicolor
# FCITX_ADDON_DIRS replaces fcitx5's default addon search path, so the
# system directory must stay listed.
ADDON_DIRS := $(USER_LIB):$(shell test/SystemAddonDir.sh)
# Build stamp for `make pkg`, computed by scripts/VersionStamp.sh (date plus
# commit, `.dirty.<HHMM>` when the tree carries uncommitted changes). Handed
# to the build as an environment variable so the binary and the package share
# one value; other builds compute their own at build time. Override
# VERSION_STAMP to change or omit it.
VERSION_STAMP ?= $(shell scripts/VersionStamp.sh)

.PHONY: help prepare update-resources build test debug restart dev-install \
	dev-uninstall install-engines install uninstall remove-icon-links pkg \
	clean clean-resources log log-js log-history
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
# The seam forwards each MACISHTYPE_* call site, so host and shared lines name
# their own file rather than the adapter's; all three source directories have
# to be in scope. sort drops the duplicate FontCoverage.cpp.
LOG_SOURCES = $(sort $(notdir $(wildcard src/*.cpp ../jshost/src/*.cpp \
                                         ../shared/src/*.cpp)))
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
	@echo "fcitx5-macishtype - Available Commands:"
	@echo ""
	@echo "  make prepare           - Sync external resources to lock state (incremental; auto-run by builds)"
	@echo "  make update-resources  - Bump pinned upstream SHAs in lock and re-prepare"
	@echo "  make build             - CMake configure + build (BUILD_TYPE=Debug for an unoptimized build)"
	@echo "  make test              - Acceptance suite against an isolated fcitx5"
	@echo "  make debug             - prepare + build + dev-install + restart"
	@echo "  make restart           - Restart the live fcitx5 (LOG_DEBUG=1 enables per-key Debug logging)"
	@echo "  make dev-install       - Install into ~/.local (no restart)"
	@echo "  make dev-uninstall     - Remove the ~/.local install (keeps engines)"
	@echo "  make install-engines   - Install engines from ../engines/ as copies or symlinks"
	@echo "  make install           - Production install into /usr (sudo) + restart"
	@echo "  make uninstall         - Remove the production install + restart"
	@echo "  make pkg               - Build a native package (deb/rpm); PRELOAD_ENGINES=\"array30\" or =all to preload engines"
	@echo "  make clean             - Clean build artifacts"
	@echo "  make clean-resources   - Remove downloaded external resources and cache/stamp"
	@echo "  make log               - Follow the addon's log (user journal)"
	@echo "  make log-js            - Follow engine console.* output only"
	@echo "  make log-history       - Recent addon log (default $(LOG_SHOW_LAST), use LOG_SHOW_LAST=24h to override)"
	@echo ""
	@echo "Quick Start:"
	@echo "  make debug"
	@echo "  make install-engines"
	@echo "  Then add the input methods in fcitx5-configtool"

# Module data tables (wordFrequency / symbolNames), pinned in the repo-level
# scripts/ExternalResources.lock and shared with the other platforms.
prepare:
	@../scripts/ExternalResources.py --prepare

update-resources:
	@../scripts/ExternalResources.py --update

build: prepare
	cmake -B $(BUILD_DIR) -G Ninja -DCMAKE_BUILD_TYPE=$(BUILD_TYPE) \
	    -DMACISHTYPE_PRELOAD_ENGINES="$(PRELOAD_ENGINES)"
	cmake --build $(BUILD_DIR) -j $(JOBS)

# Acceptance suite against an isolated fcitx5; safe to run any time.
test: build
	test/Acceptance.sh
	test/Navigation.sh
	test/Modifier.sh
	test/Reload.sh
	test/Storage.sh
	test/Settings.sh
	test/Orientation.sh
	test/Segmenter.sh
	test/DateTime.sh
	test/Number.sh
	test/Plural.sh
	test/Collator.sh
	test/ErrorStack.sh
	test/FullWidth.sh
	test/CompositionEnd.sh
	test/Associated.sh
	test/AssociatedKeys.sh
	test/Grapheme.sh
	test/Contract.sh
	test/AsyncFetch.sh
	test/Toggle.sh
	test/Menu.sh
	test/MenuBad.sh
	test/MenuUi.sh
	test/Discovery.sh
	test/TextCodec.sh
	test/ReverseLookup.sh
	test/Modules.sh
	test/IconTheme.sh
	test/Message.sh
	test/Beep.sh

# Development install into ~/.local plus a fcitx5 restart. Restarting
# interrupts typing in the current session — run this yourself.
debug:
	$(MAKE) build
	$(MAKE) dev-install
	$(MAKE) restart

# Restarts the LIVE fcitx5 with the user-dir addon visible — interrupts
# typing, so run it yourself. Output goes to the user journal (see `make
# log`), same as a session-autostarted fcitx5. Per-key Debug logging is
# off by default; enable with LOG_DEBUG=1.
restart:
	FCITX_ADDON_DIRS="$(ADDON_DIRS)" systemd-cat -t fcitx5 \
	    fcitx5 -rd $(if $(LOG_DEBUG),--verbose macishtype=5)

# User-dir install; no root needed. Engine folders go into
# ~/.local/share/fcitx5/macishtype/engines/<name>/. The freshness check keeps
# stale data tables from being copied silently (`make prepare` to sync).
dev-install:
	@../scripts/ExternalResources.py --check
	install -D -m 755 $(BUILD_DIR)/src/libmacishtype.so $(USER_LIB)/libmacishtype.so
	install -D -m 644 $(BUILD_DIR)/src/macishtype-addon.conf $(USER_SHARE)/addon/macishtype.conf
	install -D -m 644 ../shared/js/globals.js $(USER_SHARE)/macishtype/globals.js
	install -D -m 644 ../jshost/js/hostglue.js $(USER_SHARE)/macishtype/hostglue.js
	@rm -f $(USER_SHARE)/macishtype/runtime.js  # globals.js's name before 0.3
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
	rm -f $(USER_SHARE)/macishtype/globals.js
	rm -f $(USER_SHARE)/macishtype/hostglue.js
	# runtime.js was globals.js's name before 0.3; drop a stale dev copy.
	rm -f $(USER_SHARE)/macishtype/runtime.js
	rm -rf $(USER_SHARE)/macishtype/tables
	rm -f $(HOME)/.local/share/locale/*/LC_MESSAGES/fcitx5-macishtype.mo
	@rmdir $(USER_SHARE)/macishtype/engines $(USER_SHARE)/macishtype \
	    2> /dev/null || true

# Interactive engine installer: lists the engine folders in ../engines/ and
# installs the picked ones into the user engines directory, as copies or as
# symlinks. Independent of the addon build — engines are user data, installed
# and removed on their own.
install-engines:
	@scripts/InstallEngines.py

# Production install (addon .so, confs, shared runtime, and the prepared
# module data). The distro fcitx5 only loads addons from /usr, so the
# install prefix must be /usr — /usr/local would be ignored.
#
# The system engines directory is cleared first, so it ends up holding
# exactly what PRELOAD_ENGINES asked for: cmake's install only ever adds,
# while dpkg already drops files a new version no longer carries.
install:
	@if [ -f $(USER_LIB)/libmacishtype.so ] || \
	    [ -f $(USER_SHARE)/addon/macishtype.conf ]; then \
	    echo "A dev install exists in ~/.local and would shadow the" >&2; \
	    echo "system install. Run \`make dev-uninstall\` first (engine" >&2; \
	    echo "folders are kept)." >&2; \
	    exit 1; \
	fi
	$(MAKE) prepare
	cmake -B $(BUILD_DIR) -G Ninja -DCMAKE_BUILD_TYPE=$(BUILD_TYPE) \
	    -DCMAKE_INSTALL_PREFIX=/usr \
	    -DMACISHTYPE_PRELOAD_ENGINES="$(PRELOAD_ENGINES)"
	cmake --build $(BUILD_DIR) -j $(JOBS)
	sudo rm -rf /usr/share/fcitx5/macishtype/engines
	sudo cmake --install $(BUILD_DIR)
	$(MAKE) restart

# Removes a production install, using the manifest cmake wrote during the
# last `make install`, and restarts fcitx5 so the removal takes effect —
# fcitx5 then drops this addon's entries from the profile, which is
# the correct cleanup for a real removal. Switching to a dev install
# instead? Run `make debug` first so the addon never disappears and the
# profile keeps its entries.
#
# Preloaded engines are removed outright rather than through the manifest,
# which records only the last install: a package that once carried engines
# would otherwise leave them behind. The user-layer engines directory in
# ~/.local/share is never touched.
uninstall:
	@test -f $(BUILD_DIR)/install_manifest.txt || \
	    { echo "No install manifest; nothing recorded to uninstall." >&2; exit 1; }
	sudo xargs rm -f < $(BUILD_DIR)/install_manifest.txt
	sudo rm -rf /usr/share/fcitx5/macishtype/engines
	@sudo rmdir /usr/share/fcitx5/macishtype/tables \
	    /usr/share/fcitx5/macishtype 2> /dev/null || true
	$(MAKE) restart

# Crash backstop. The addon removes its own icon theme links when it shuts
# down after being uninstalled out from under a running fcitx5; this manual
# target covers the one gap — a crash/SIGKILL where that destructor never
# ran. Only symlinks are removed, matching the addon's own sweep rule.
#
# Never run this against a live install: the addon serves panels the theme
# NAME, so deleting the links makes every panel show a missing icon — worse
# than before, and the next reload recreates them anyway.
remove-icon-links:
	@find $(ICON_LINK_DIR) -maxdepth 3 -mindepth 3 -type l \
	    -name 'macishtype-*' -delete 2> /dev/null || true

# Native package for the current environment: deb on Debian-family, rpm on
# RPM-family (run inside a matching container to produce the other format).
pkg:
	$(MAKE) prepare
	cmake -B $(BUILD_DIR) -G Ninja -DCMAKE_BUILD_TYPE=$(BUILD_TYPE) \
	    -DCMAKE_INSTALL_PREFIX=/usr \
	    -DMACISHTYPE_PRELOAD_ENGINES="$(PRELOAD_ENGINES)"
	VERSION_STAMP="$(VERSION_STAMP)" cmake --build $(BUILD_DIR) -j $(JOBS)
	@gen=$$(. /etc/os-release 2> /dev/null; \
	    case "$$ID $$ID_LIKE" in \
	        *debian*) echo DEB ;; \
	        *fedora*|*rhel*|*suse*) echo RPM ;; \
	        *) echo TGZ ;; \
	    esac); \
	set -x; \
	cpack -G $$gen --config $(BUILD_DIR)/CPackConfig.cmake -B $(BUILD_DIR) \
	    || exit 1; \
	{ set +x; } 2> /dev/null; \
	case "$$gen" in \
	    DEB) glob='*.deb' ;; \
	    RPM) glob='*.rpm' ;; \
	    *) glob='*.tar.gz' ;; \
	esac; \
	pkg=$$(ls -t $(BUILD_DIR)/$$glob 2> /dev/null | head -1); \
	if [ -n "$(PRELOAD_ENGINES)" ] && [ -n "$$pkg" ]; then \
	    case "$$pkg" in \
	        *.tar.gz) marked="$${pkg%.tar.gz}.with-engines.tar.gz" ;; \
	        *) marked="$${pkg%.*}.with-engines.$${pkg##*.}" ;; \
	    esac; \
	    mv "$$pkg" "$$marked" && pkg="$$marked"; \
	fi; \
	echo; \
	echo "Package: $$pkg"; \
	echo "Engines: $(if $(PRELOAD_ENGINES),$(PRELOAD_ENGINES),none)"

clean:
	rm -rf $(BUILD_DIR)

clean-resources:
	@../scripts/ExternalResources.py --clean

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
