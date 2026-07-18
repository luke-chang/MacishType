#!/bin/sh
# Restarts the LIVE fcitx5 with the user-dir addon install visible. Run it
# yourself when you want to try the addon in real applications — it briefly
# interrupts typing. Automated tests never need this; they use
# test/isolated.sh, which leaves the live fcitx5 alone.
#
# After restarting, add the input method in fcitx5-configtool (the engines
# under ~/.local/share/fcitx5/macishtype/engines/ each appear as
# "macishtype-<name>").
#
# The FCITX_ADDON_DIRS set here only lives for this fcitx5 process. To make
# it permanent, put the export into ~/.config/environment.d/ and re-login.
set -e

machine="$(gcc -dumpmachine 2> /dev/null || echo x86_64-linux-gnu)"
export FCITX_ADDON_DIRS="$HOME/.local/lib/fcitx5:/usr/lib/$machine/fcitx5"
exec fcitx5 -rd
