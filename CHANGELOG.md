# changelog

## unreleased

- workspace slide distance is now the travel needed for both sets to clear the screen edge, so the previous workspace always animates fully out on wide monitors
- drag and drop fixed: the drop point follows the cursor, the dragged thumb shrinks so the strip stays visible, failed drops animate back
- faster and spam-aware open and close: startup requests run concurrently, window focus is dispatched after the keyboard-focus handoff, clicks work during the opening flight, toggles during preparing cancel instantly, key repeat is coalesced, pending switches retarget cleanly
- slide polish: switches animate during opening, a close finishes any running slide within the flight, slide distance follows the content so ultrawide sets stay continuous
- spam-aware workspace slides: at most two workspace sets on screen and shorter slides when switches arrive faster than one slide, normal switching unchanged
- leaving thumbs stop live capture and drop below arriving ones
- `tools/record.sh` records a live bug in one command: restarts the shell with frame logging, captures the focused monitor with timestamped hyprland events, and prints the analyze command
- the simulator analyzer scores a live desktop recording, builds contact sheets around flagged frames, flags black overview frames and padded captures, and no longer hangs on long recordings
- the recorder uses hardware encoding, validates arguments before touching the session, disables the overlay screen-share block during capture and restores it, and reports capture quality
- four spam simulator scenarios and heavier rapid-switch fuzz

## stable checkpoint 2026-09-14 (tag `stable-2026-09-14`)

user-verified on the live desktop: no reproducible bugs in toggle, keybind switching (including fast reversals), tile clicks, Enter to land, Escape, scratchpad focus. all 15 simulator scenarios pass. if a later change brings the glitches back, diff against this tag first: `git diff stable-2026-09-14 -- shell`.

what makes it stable:

- overlay keyboard focus goes exclusive -> on-demand (never none) and every close dispatches a confirmed focus target with retries
- backdrop opaque through the whole closing state; thumbs blanked when the workspace changes while preparing
- one exposé row per window with its own slide start/end offset; no phases, no duplicates, no reversals
- active workspace fed from hyprland events, refreshes cannot overwrite a newer event
- one state snapshot per refresh, config writes merged, no refresh during closing
- workspace switches reach the overview straight from hyprland events instead of waiting for a state refresh, so the slide starts within a frame

## groundwork 2026-09-13

- survey of every existing overview for hyprland, the brief, and the repo scaffold
- the build plan: architecture, layout, capture budget, theming in lockstep with dms, and the test matrix
- install pieces: hyprland snippet, systemd unit, cli wrapper, tools
