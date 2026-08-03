#!/bin/sh
# Prints the system fcitx5 addon directory: the Debian multiarch shape first,
# then the RPM-family lib64 and plain-lib shapes. Falls back to the multiarch
# path so a bare environment still gets a plausible default.
multiarch="/usr/lib/$(gcc -dumpmachine 2> /dev/null || echo x86_64-linux-gnu)/fcitx5"
for candidate in "$multiarch" /usr/lib64/fcitx5 /usr/lib/fcitx5; do
    if [ -d "$candidate" ]; then
        printf '%s\n' "$candidate"
        exit 0
    fi
done
printf '%s\n' "$multiarch"
