# Thin entry points over CMake and scripts/, mirroring the macOS repo's
# workflow. The real build system is CMake; see README.md.

BUILD_DIR := build

.PHONY: build prepare debug install restart test clean

build:
	cmake -B $(BUILD_DIR)
	cmake --build $(BUILD_DIR) -j

# Module data tables (wordFrequency / symbolNames). Set MACISHTYPE_REPO to a
# MacishType checkout to overlay its hand-curated symbol names.
prepare:
	scripts/prepare-data.sh

# Development install into ~/.local plus a fcitx5 restart. Restarting
# interrupts typing in the current session — run this yourself.
debug: build
	scripts/dev-install.sh
	scripts/dev-restart.sh

# Production install (addon .so, confs, shared runtime, and any prepared
# module data). Run `make prepare` first if the data tables should be
# included. The distro fcitx5 only loads addons from /usr, so the install
# prefix must be /usr — /usr/local would be ignored.
install:
	cmake -B $(BUILD_DIR) -DCMAKE_INSTALL_PREFIX=/usr
	cmake --build $(BUILD_DIR) -j
	sudo cmake --install $(BUILD_DIR)

restart:
	scripts/dev-restart.sh

# Acceptance suite against an isolated fcitx5; safe to run any time.
test: build
	test/acceptance.sh

clean:
	rm -rf $(BUILD_DIR)
