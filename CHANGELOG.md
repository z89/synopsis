# changelog

## unreleased

- video wallpapers play in the tiles from a small cached copy of the clip (1280px, 30fps), started at the wallpaper's own playhead so tiles and desktop match. without ffmpeg the tiles show the still
- a live wallpaper that supports it can cover the desktop while the overview is open, so synopsis paints no backdrop. it falls back to the still if the wallpaper does not answer within 70ms
- with the cover, the time from the toggle to the start of the flight fell from a median 377.5ms to 81ms on one 5120x1440 monitor
- the cover sits beneath the DankMaterialShell (DMS) bar, and stopping `synopsis.service` clears leftover requests so a crash cannot leave the desktop covered
- new settings `liveWallpaper` and `coverViaWallpaper`, both on by default
- the opening flight waits for the backdrop's first frame, with a 100ms limit
- focusing a window raises it to the top
- `tools/open-latency.py` prints how long each open took, and the simulator takes `SIM_COVER=1|0`
- an optional DMS bar widget in `plugin/`, an architecture doc and diagram, and simpler readmes
- workspace slides travel far enough to clear the screen, so the old workspace always leaves fully on wide monitors
- drag and drop follows the cursor, shrinks the window so the strip stays visible, and flies back on a miss
- faster open and close that hold up to key spam. toggles while preparing cancel at once, key repeat is ignored, clicks work mid-flight and focus lands after the keyboard handoff
- slides run during opening, a close finishes any running slide, and slide distance follows the content
- fast switching shows at most two workspaces at once and shortens slides, with normal switching unchanged
- leaving thumbnails stop live capture and sit beneath arriving ones
- `tools/record.sh` records a live bug in one command, with frame logging and timestamped hyprland events
- the analyzer scores live desktop recordings, builds contact sheets, flags black or padded captures and no longer hangs on long recordings
- the recorder uses hardware encoding, checks its arguments first and reports capture quality
- four spam scenarios in the simulator and heavier fuzzing

## stable checkpoint 2026-09-14 (tag `stable-2026-09-14`)

checked by hand on the live desktop with no known bugs in toggling, keybind switching (fast reversals too), tile clicks, Enter, Escape or scratchpad focus. all 15 simulator scenarios pass. if a glitch comes back, compare against this tag first with `git diff stable-2026-09-14 -- shell`.

what made it stable.

- the overlay's keyboard focus goes from exclusive to on-demand, never to none, and every close confirms where focus lands
- the backdrop stays opaque through the whole close, and thumbnails blank out if the workspace changes while preparing
- each exposé row slides on its own, so there are no duplicates and no reversals
- the active workspace comes from hyprland events, and a refresh cannot overwrite a newer event
- one state snapshot per refresh, and no refresh during a close
- workspace switches start their slide within a frame

## groundwork 2026-09-13

- a survey of every existing overview for hyprland, the brief and the repo scaffold
- the build plan covering architecture, layout, capture cost, theming with DMS and testing
- install pieces (hyprland snippet, systemd unit, CLI wrapper and tools)
