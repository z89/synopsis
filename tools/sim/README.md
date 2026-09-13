# tools/sim — headless simulator for the synopsis overview

An autonomous test harness. It starts a throwaway Hyprland session that nobody
can see, builds a fixed set of windows in it, drives the overview through
scripted scenarios, records the screen, and reports every visual glitch it can
measure (flashes, unexplained hard cuts, frames that never arrive, slow
settles) together with the frames to look at.

It never touches the live session.

## why it nests

aquamarine 0.15 (Hyprland's backend library) always needs a DRM or Wayland
parent for its GPU allocator, so a purely headless Hyprland aborts with
"no allocator available". The harness therefore runs a **headless parent
compositor** and nests Hyprland inside it as an ordinary Wayland client:

- **cage** (default): `WLR_BACKENDS=headless WLR_RENDERER=gles2
  WLR_SCENE_DISABLE_DIRECT_SCANOUT=1 WLR_RENDER_DRM_DEVICE=/dev/dri/renderD128
  WLR_LIBINPUT_NO_DEVICES=1 cage -- Hyprland -c tools/sim/hyprland.lua`. cage
  runs exactly one client and hands it its own `WAYLAND_DISPLAY`. Its headless
  output is fixed at **1280x720**. The binary is a patched build
  (`tools/sim/build-cage.sh` applies `tools/sim/cage.patch`, see below).
- **weston** (`--parent weston`, untested since the cage patches): `weston
  --backend=headless --renderer=gl --width=$SIM_W --height=$SIM_H
  --shell=kiosk-shell.so --socket=synopsis-sim-parent`.

The nested Hyprland's monitor is `WAYLAND-1`; it creates its own `WAYLAND_DISPLAY`
and instance signature. `run.sh` snapshots `$XDG_RUNTIME_DIR` before the launch
and discovers both as the new `hypr/<sig>/.socket.sock` and the new `wayland-N`
socket that is neither the live one nor the parent's. `hyprland.lua` sets
`debug.disable_logs = false` so the nested instance log is complete (Hyprland
0.56 truncates it by default).

### the cage patch

Stock cage 0.3.1 cannot host aquamarine 0.15:

- it creates `xdg_wm_base` at version 5 while aquamarine binds version 6;
- aquamarine only flushes its Wayland request queue when the parent socket
  becomes readable, so a silent headless parent deadlocks it before the first
  configure, and a headless output only commits when something is damaged, so
  the nested compositor stops getting frame callbacks and stops rendering.

`cage.patch` bumps the version and adds an 8 ms tick that renames the seat (an
event every client receives, which wakes aquamarine's dispatch), schedules an
output frame and damages one transparent pixel. Frames then arrive at ~120 Hz
regardless of nested activity.

### capture path

Recordings and stills are taken from the **parent** (cage) display, never from
inside the nested Hyprland: screencopy on the nested display hangs under the
headless stack, and the parent shows exactly what the nested compositor
presents. wf-recorder runs with `WAYLAND_DISPLAY=$PARENT_WL` and records the
cage output at 60 fps. `WLR_SCENE_DISABLE_DIRECT_SCANOUT=1` is required: with
direct scan-out cage presents the nested compositor's buffer straight to the
headless output and screencopy of that output returns a flat frame. The
driver takes one `grim` still (`<scenario>.mkv.pre.png`) before every
recording, and the analyzer reports `no-content` for a recording that never
changes, so a capture fault is never mistaken for a calm scene.

## requirements

| binary | needed for |
|---|---|
| `cage` (or `weston`) | the headless parent compositor |
| `Hyprland` | the nested session |
| `qs` (quickshell) | the shell under test |
| `kitty` | fixture windows running `pattern.py` |
| `wf-recorder` | the screen recording (optional; without it, only assertions run) |
| `ffmpeg`, `ffprobe` | decoding and frame extraction in the analyzer |
| `mpv` | the moving-video fixture window (optional) |
| `python3` | driver and analyzer (stdlib; numpy is used if present) |

## usage

```sh
tools/sim/run.sh                        # every scenario, cage, 1280x720
tools/sim/run.sh --scenario open_close  # one scenario
tools/sim/run.sh --scenario fuzz --seed 7
tools/sim/run.sh --parent weston --w 2560 --h 720
tools/sim/run.sh --keep                 # leave the nested session up afterwards
python3 tools/sim/driver.py --scenario all --dry-run   # print the plan only
python3 tools/sim/analyze.py --out tools/sim/out/<ts>  # re-analyze a run
python3 tools/sim/analyze.py --self-test               # prove the detectors fire
```

Output lands in `tools/sim/out/<timestamp>/`:

```
report.md  report.json            the verdict
<scenario>.mkv                    the recording
<scenario>.actions.json           actions (ms from recorder start) + final state
<scenario>.events.json            hyprland socket2 events, same time base
<scenario>.qs.log                 the quickshell log slice for that scenario
frames/<scenario>-<index>.png     full-resolution frames around each flagged event
qs.log  hyprland.log  parent.log  raw logs
env                               the nested environment the driver reused
```

## scenarios

| name | what it exercises |
|---|---|
| `open_close` | the plain open and close flight |
| `keybind_switch` | switching workspaces while the overview is open |
| `keybind_interrupt` | switches interrupting each other mid-slide |
| `rapid_switch` | six switches in 600 ms, including back-and-forth: one row per window, no reversals |
| `tile_click` | activating a workspace tile (closes by itself) |
| `tile_click_interrupt` | a second tile activated mid-close |
| `window_click_behind` | activating a window that sits *behind* another; asserts it ends on top and focused |
| `toggle_spam` | eight toggles with 30–400 ms gaps, then must end closed. The gaps are shorter than `hasContentTimeoutMs`, so the overview legitimately never paints |
| `toggle_spam_slow` | toggles at 0, 500, 700, 1300, 1350, 2000 ms then a close: gaps long enough to reach `opening`/`open`, so each flight is interrupted mid-air |
| `keybind_close_switch` | switch to ws3 with the overview open, then close it; asserts the session stays on ws3 (bounce-back regression) |
| `switch_while_preparing` | workspace keybinds landing between the toggle and the first flight frame, while the backdrop is still transparent |
| `switch_then_close_midslide` | closing while a workspace slide is still running |
| `move_window` | dragging a window to another workspace via the event API; asserts it moved |
| `keybind_enter` | Enter confirms the workspace shown while the overview is open, same as clicking its tile |
| `fuzz` | 25 seeded random steps; asserts only that the shell survives and ends closed |

Each scenario starts on workspace 1 with the overview closed and the session
quiet. Actions are sent as Hyprland custom events (`synopsis:toggle`,
`synopsis:activate-workspace:2`, `synopsis:activate-window:<addr>`,
`synopsis:move-window:<addr>:<ws>`, `synopsis:confirm`), which take the same
code path a click takes. `synopsis:confirm` mirrors pressing Enter while the
overview is open: it closes and lands on whichever workspace is active, same
as clicking that workspace's tile.

## reading a report

`report.md` starts with one row per scenario:

```
| scenario | frames | flashes | reversals | cuts | spikes | stale | stalls | settle ms | budget | verdict |
```

- **flashes** — a spike in the frame-to-frame difference that reverts: the
  screen jumped and came straight back. Usually a placeholder painting over a
  live thumbnail, or a layer appearing for one frame.
- **reversals** — a flash-shaped jump that lands within flightMs of a logged
  opening<->closing state flip: the flight was reversed mid-way, so the jump
  is expected behaviour rather than a defect, and it does not fail the verdict.
- **cuts** — a whole-screen change with no action within the grace window, i.e.
  something moved that nobody asked for. Only counted *outside* an animation
  window: the qs log says when a flight (flightMs + settleMs + 100 ms) or a
  slide (switchMs + 100 ms) was running, and mid-flight the whole screen is
  meant to change.
- **spikes** — the same frame seen *inside* an animation window: flagged only
  when it stands out from its own neighbourhood (d > 25 and more than 2.5x the
  median of the eight frames around it). A lead, not a failure: spikes do not
  fail the verdict.
- **stale** — no frame written for more than 250 ms while an animation should
  have been running. wf-recorder only writes damaged frames, so this means the
  shell stopped painting mid-flight.
- **stalls** — flights whose worst frame-to-frame gap exceeded 80 ms (see the
  `flights` line below). Reported, does not fail the verdict yet.
- **settle ms** — from the last action to the first run of 8 quiet frames.
  The budget is `switchMs 450 + settleMs 60 + flightMs 260 + 150` slack
  (`shell/Core/Config.qml`). A workspace whose fixture window ticks a
  full-screen pattern (workspace 3's `sim-t4`) never produces a quiet frame,
  so "quiet" there is measured against the recording's own steady-state
  tail instead of raw zero: the peak frame diff over the last 30 frames (or
  the last third of a shorter recording), plus a tolerance, replaces
  `T_quiet` as the ceiling for that scenario. A scenario section shows
  `steady tail: baseline N.N (animating window)` when that baseline is in
  effect; otherwise settle uses the plain `T_quiet` threshold.

A scenario section also carries `- switch latency: max N ms (n switches)`: the
worst gap between a `workspacev2` event and the `slide` line it caused (skipping
switches with no slide within 400 ms, i.e. the overview was not interactive).
Above 60 ms it is annotated as a note, never a failure.

Each scenario section starts with its frame cadence, taken from the shell's own
`[synopsis] frame` lines rather than from the video:

```
- flights: open 12 frames / 457 ms (max gap 103 ms); close 12 / 302 (48)
```

One entry per animation the qs log announces (`open` and `close` from the state
lines, `slide` from the slide lines), in order: frame count, duration, and the
worst gap between two consecutive frames. Gaps over 50 ms are listed under it
with the log lines that fall inside them, so a mid-flight stall can be read off
without opening the video.

A recording with no motion at all is normally a capture fault (`no-content`).
It is not one when the shell agrees nothing was drawn: if the log never reaches
`state … opening`, the verdict is `pass` with the note `nothing painted:
overview never reached opening (N prepare/close cycles)`. That is the correct
result for `toggle_spam`.

Every flagged event is listed underneath with its time, its metric and the PNGs
for the flagged frame and its neighbours, so it can be eyeballed directly.
Thresholds live in the `THRESHOLDS` dict at the top of `analyze.py` and are
printed at the end of every report.

## safety rules

- The harness only ever talks to the **nested** instance. `run.sh` and
  `driver.py` both refuse to continue if the discovered instance signature (or
  `WAYLAND_DISPLAY`) equals the live session's, and `run.sh` additionally
  verifies that the nested session presents exactly one monitor named `WAYLAND-1`.
- The nested Hyprland runs with `HYPRLAND_NO_SD_VARS=1`. Without it, Hyprland
  pushes `WAYLAND_DISPLAY` and `HYPRLAND_INSTANCE_SIGNATURE` into the user's
  systemd/dbus activation environment at startup, which would repoint the live
  session's newly launched apps at the throwaway one.
- Cleanup kills only the process groups the harness started (parent compositor,
  nested Hyprland, qs, fixture apps, recorder). Nothing else is signalled.
- `qs` is started as `qs -p <repo>/shell` (path form) so it is a distinct
  instance from the live `qs -c synopsis`. Override with `QS_ARGS` if needed.

## recording a live bug

When a glitch only shows up on the real desktop, `tools/record.sh [--output NAME]
[--seconds N] [--dir DIR] [--region "X,Y WxH"] [--shell|--no-shell]` captures
it the same way the simulator does: it writes `meta.json` (t0/t_stop epoch ms,
`hyprctl version -j`, `qs --version`), tails Hyprland's socket2 into
`events.log` with an epoch-ms prefix on every line, and records the focused
monitor with `wf-recorder` into `desktop.mkv` (`libx264 crf=14
tune=zerolatency`, rate rounded to the nearest integer and capped at 120) into
a directory under `~/synopsis-recordings/<timestamp>` by default. `--region
"1280,0 2560x1440"` restricts capture to part of the monitor (passed straight
through as wf-recorder's `-g`), useful on very large or high-refresh displays.
By default (`--shell`) the script manages the shell for you: if
`synopsis.service` is active it leaves it running and warns if
`~/.config/synopsis/config.json` lacks `"frameLog": true`; otherwise it stops
any hand-started `qs -c synopsis` and launches a fresh one with
`SYNOPSIS_FRAMELOG=1`, logging to `shell.log`, and leaves it running when the
recording ends. Pass `--no-shell` to leave shell management to yourself. Run
the script, reproduce the bug, press Enter (or let `--seconds` expire) to
stop, and send the whole recording directory: `meta.json`, `events.log`,
`desktop.mkv`, and `shell.log`.

Analyse it with `python3 tools/sim/analyze.py --live DIR` (add `--all-frames`
to also dump every frame at 640px wide into `frames-all/` for manual
scrubbing). It fabricates a synthetic scenario named `live` from the
`workspacev2` switches and `synopsis:` custom events in `events.log`, anchors
the video clock the same way a simulator run does, and runs the same flash/
cut/spike/stale/settle/flight-cadence/switch-latency detectors, writing
`report.md`, `report.json`, flagged frames under `frames/`, and (when
ImageMagick's `magick` is installed) a `sheets/<flag>-<frame>.png` contact
sheet of frames every 2 apart around each flag for a quick visual scan without
opening the video. When you hand off a recording, include the directory path
plus roughly when the glitch happens in the clip; `record.sh` prints that
reminder at the end alongside the exact analyze command.

## known limits

- **No pointer input.** There is no seat with a pointer in the nested session;
  clicks are simulated through the custom-event API, which enters the same
  handlers as a real click but does not test hit testing or cursor behaviour.
- **cage is 1280x720**, fixed. The fixture rectangles in `hyprland.lua` are
  fractions of `SIM_W`/`SIM_H`, so the layout keeps its shape at any size, but
  an ultrawide-shaped run needs weston.
- **Recordings are pts-based.** Every metric uses the pts of each frame, not
  the frame index; the cage tick keeps frames flowing at 60 fps but an idle
  stretch can still repeat frames.
- Thumbnail capture inside a nested software/headless GL stack can be slower
  than on real hardware, so absolute settle times are indicative; the flash,
  cut and stale detectors are what a regression shows up in.
- `mpv` may ignore `--wayland-app-id` on older builds; `hyprland.lua` therefore
  also has rules for the plain `mpv` class.
