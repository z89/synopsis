# changelog

## unreleased

## stable checkpoint 2026-09-14 (tag `stable-2026-09-14`, commit 992464e)

user-verified on the live desktop: no reproducible bugs in toggle, keybind switching (including fast reversals), tile clicks, Enter to land, Escape, scratchpad focus. all 15 simulator scenarios pass (`tools/sim/out/20260914-000101`). if a later change brings the glitches back, diff against this tag first: `git diff stable-2026-09-14 -- shell`.

what makes it stable:
- overlay keyboard focus goes exclusive -> on-demand (never none) and every close dispatches a confirmed focus target with retries
- backdrop opaque through the whole closing state; thumbs blanked when the workspace changes while preparing
- one exposé row per window with its own slide start/end offset; no phases, no duplicates, no reversals
- active workspace fed from hyprland events, refreshes cannot overwrite a newer event
- one state snapshot per refresh, config writes merged, no refresh during closing


- survey of every existing overview for hyprland, the brief, and the repo scaffold
- the build plan: architecture, layout, capture budget, theming in lockstep with dms, and the test matrix
- install pieces: hyprland snippet, systemd unit, cli wrapper, tools
