#!/usr/bin/env bash
# Build a patched cage into tools/sim/.cache/cage/cage.
#
# Stock cage 0.3.1 cannot host Hyprland's Wayland backend (aquamarine 0.15):
#   - it creates xdg_wm_base at version 5 and aquamarine binds version 6, so
#     the nested Hyprland dies with "invalid version for global xdg_wm_base";
#   - aquamarine only flushes its request queue when the parent socket becomes
#     readable, so a silent headless cage deadlocks it before the first
#     configure; cage.patch adds an 8 ms tick that renames the seat (a harmless
#     event every client receives), schedules an output frame and damages one
#     transparent pixel, so the nested compositor keeps getting frame callbacks.
# Both changes live in cage.patch. wlroots 0.20 supports xdg_wm_base v6.
set -euo pipefail
SIM="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE="$SIM/.cache/cage"
mkdir -p "$CACHE"
SRC="$CACHE/src"
if [[ ! -d "$SRC" ]]; then
    git clone -q --depth 1 -b v0.3.1 https://github.com/cage-kiosk/cage "$SRC"
fi
if ! git -C "$SRC" apply --check --reverse "$SIM/cage.patch" >/dev/null 2>&1; then
    git -C "$SRC" checkout -q -- cage.c
    git -C "$SRC" apply "$SIM/cage.patch"
fi
grep -q 'wlr_xdg_shell_create(server.wl_display, 6)' "$SRC/cage.c"
grep -q 'kick_clients' "$SRC/cage.c"
if [[ ! -f "$SRC/build/build.ninja" ]]; then
    meson setup "$SRC/build" "$SRC" -Dman-pages=disabled >/dev/null
fi
ninja -C "$SRC/build" >/dev/null
# the running binary may be busy: replace it atomically
cp "$SRC/build/cage" "$CACHE/cage.new"
mv -f "$CACHE/cage.new" "$CACHE/cage"
echo "built $CACHE/cage"
