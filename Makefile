# Thin entry points over CMake, mirroring the macOS repo's workflow. The
# real build system is CMake; see README.md.

BUILD_DIR := build
MACHINE := $(shell gcc -dumpmachine 2> /dev/null || echo x86_64-linux-gnu)
USER_LIB := $(HOME)/.local/lib/fcitx5
USER_SHARE := $(HOME)/.local/share/fcitx5
# FCITX_ADDON_DIRS replaces fcitx5's default addon search path, so the
# system directory must stay listed.
ADDON_DIRS := $(USER_LIB):/usr/lib/$(MACHINE)/fcitx5

.PHONY: build prepare debug dev-install dev-uninstall install restart test \
	clean

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
	$(MAKE) prepare
	cmake -B $(BUILD_DIR) -G Ninja -DCMAKE_INSTALL_PREFIX=/usr
	cmake --build $(BUILD_DIR) -j
	sudo cmake --install $(BUILD_DIR)

# Restarts the LIVE fcitx5 with the user-dir addon visible — interrupts
# typing, so run it yourself. The daemon inherits this terminal's stderr;
# discard it by default, or set MACISHTYPE_LOG=1 to keep a log file
# (truncated each restart). A session-autostarted fcitx5 logs to the
# journal instead.
restart:
	@log_file=/dev/null; \
	if [ -n "$$MACISHTYPE_LOG" ]; then \
	    log_file="$${XDG_STATE_HOME:-$$HOME/.local/state}/fcitx5-macishtype/fcitx5.log"; \
	    mkdir -p "$$(dirname "$$log_file")"; \
	    echo "fcitx5 log: $$log_file"; \
	fi; \
	FCITX_ADDON_DIRS="$(ADDON_DIRS)" fcitx5 -rd > "$$log_file" 2>&1

# Acceptance suite against an isolated fcitx5; safe to run any time.
test: build
	test/acceptance.sh
	test/reload.sh

clean:
	rm -rf $(BUILD_DIR)
