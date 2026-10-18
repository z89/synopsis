<h1 align="center">synopsis simulator</h1>

<p align="center">
  <img src="https://img.shields.io/badge/hyprland-0.56.2-8fd3ff?style=flat-square&labelColor=1b1a20" alt="hyprland 0.56.2">
  <img src="https://img.shields.io/badge/quickshell-0.3.1-8fd3ff?style=flat-square&labelColor=1b1a20" alt="quickshell 0.3.1">
  <img src="https://img.shields.io/badge/python-3-8fd3ff?style=flat-square&labelColor=1b1a20" alt="python 3">
  <a href="../../LICENSE"><img src="https://img.shields.io/badge/license-MIT-8fd3ff?style=flat-square&labelColor=1b1a20" alt="license MIT"></a>
</p>

the simulator tests synopsis without touching your desktop. it starts a hidden hyprland session, opens a fixed set of windows, runs the overview through scripted scenarios and records the screen.

it then reports every glitch it can measure (flashes, sudden cuts, frames that never arrive, slow settles) and saves the frames worth looking at.

## ⌨️ usage

```sh
tools/sim/run.sh                        # every scenario, cage, 1280x720
tools/sim/run.sh --scenario open_close  # one scenario
tools/sim/run.sh --scenario fuzz --seed 7
tools/sim/run.sh --parent weston --w 2560 --h 720
tools/sim/run.sh --keep                 # leave the nested session up afterwards
python3 tools/sim/driver.py --scenario all --dry-run   # print the plan only
python3 tools/sim/analyze.py --out tools/sim/out/<ts>  # re-analyze a run
python3 tools/sim/analyze.py --self-test               # prove the detectors fire
python3 tools/sim/analyze.py --live ~/synopsis-recordings/<ts>       # a desktop recording
python3 tools/sim/analyze.py --live DIR --live-window 20 40          # only 20-40 s of it
```

`SIM_COVER=1` (the default) makes the stand-in wallpaper answer cover requests, so the cover path gets tested. `SIM_COVER=0` makes it a plain background, so the overview paints its own backdrop.

each run lands in `tools/sim/out/<timestamp>/`.

```text
report.md  report.json            the verdict
<scenario>.mkv                    the recording
<scenario>.actions.json           actions (ms from recorder start) + final state
<scenario>.events.json            hyprland socket2 events, same time base
<scenario>.qs.log                 the quickshell log slice for that scenario
frames/<scenario>-<index>.png     full-resolution frames around each flagged event
qs.log  hyprland.log  parent.log  raw logs
env                               the nested environment the driver reused
```

### scenarios

| name | what it tests |
|---|---|
| `open_close` | a plain open and close |
| `keybind_switch` | switching workspace while open |
| `keybind_interrupt` | switches cutting each other off mid-slide |
| `rapid_switch` | six switches in 600ms, back and forth, with no reversals |
| `spam_switch_light` | five switches 200ms apart, ending on ws2 |
| `spam_switch_heavy` | twelve switches 110ms apart across every workspace, ending on ws3 |
| `spam_toggle_keys` | six fast toggles, a switch and a close, ending closed on ws3 |
| `spam_click` | three clicks 60ms apart, where the last one (a window on ws2) wins |
| `tile_click` | clicking a workspace tile |
| `tile_click_interrupt` | a second tile clicked while closing |
| `new_workspace` | two plus clicks, which neither switch nor close |
| `new_workspace_from_empty` | plus, open the new tile, reopen and plus again. ws4 is kept and the unused ws6 is dropped on close |
| `window_click_behind` | clicking a window hidden behind another, which ends on top and focused |
| `toggle_spam` | eight toggles 30 to 400ms apart, too fast for anything to paint, ending closed |
| `toggle_spam_slow` | toggles far enough apart that each flight is cut off mid-air |
| `keybind_close_switch` | switch to ws3 while open, then close, which stays on ws3 |
| `switch_while_preparing` | workspace keybinds landing before the flight starts |
| `switch_then_close_midslide` | closing while a slide is still running |
| `move_window` | moving a window to another workspace |
| `keybind_enter` | Enter lands on the workspace shown |
| `fuzz` | 25 random steps, which must leave the shell alive and closed |

every scenario starts on workspace 1 with the overview closed. actions are sent as hyprland custom events (`synopsis:toggle`, `synopsis:activate-workspace:2` and so on), which run the same code a click does.

### reading a report

`report.md` opens with one row per scenario.

```text
| scenario | frames | flashes | reversals | cuts | spikes | stale | stalls | settle ms | budget | verdict |
```

- **flashes** are frames where the screen jumps and comes straight back. usually a placeholder or a layer showing for one frame.
- **reversals** look like flashes but line up with a flight being reversed on purpose. they do not fail.
- **cuts** are whole-screen changes outside any animation that nobody asked for.
- **spikes** are unusual jumps inside an animation. worth a look, but they do not fail.
- **stale** means no new frame for over 250ms while something should have been moving.
- **stalls** are flights with a gap over 80ms between frames. reported, but they do not fail yet.
- **settle ms** is the time from the last action until the screen goes quiet, checked against a budget from `shell/Core/Config.qml`. a workspace with a constantly moving window is judged against its own steady state instead.

under the table each scenario gets a few extra lines, all read from the shell's own log.

- **flights** give the frame count, length and worst frame gap of each animation, with any gap over 50ms listed next to the log lines inside it.
- **slides** count slides and the most leaving rows on screen at once.
- **switch latency** is the worst delay from a workspace event to its slide. over 60ms gets a note.
- **prepare** and **drags** summarise the prepare timings and the drag and drop lines.

every flagged moment is listed with its time, its numbers and the PNGs around it. thresholds live in `THRESHOLDS` at the top of `analyze.py` and are printed at the end of each report.

two warnings mean the recording is bad, not the shell.

- **overlay not captured** means the overview showed up black in the video. those frames are left out of the checks.
- **recorder dropped frames** (`CAPTURE-FAIL`) means fewer than half the expected frames were real. the visual checks are skipped and the log based lines still print. record again before reading anything else.

a recording with no motion at all is reported as `no-content`, unless the log shows the overview never opened. then it passes with a note, which is the right result for `toggle_spam`.

analysis decodes a small 320px gray copy in one pass, so a long 5120x1440 desktop recording takes about a minute. `--no-frames` skips saving PNGs.

### recording a live bug

when a glitch only shows on the real desktop, record it with `tools/record.sh`.

```sh
tools/record.sh                              # record until Enter
tools/record.sh --seconds 30                 # or for a fixed time
tools/record.sh --region "1280,0 2560x1440"  # only part of the monitor
```

reproduce the bug, press Enter to stop, and send the whole recording directory (`meta.json`, `events.log`, `desktop.mkv` and `shell.log`). it lands in `~/synopsis-recordings/<timestamp>` unless you pass `--dir`. mention roughly when in the clip the glitch happens.

the script records the focused monitor with wf-recorder and logs hyprland's events with timestamps beside it. if `synopsis.service` is running it leaves it alone and warns when `frameLog` is off. otherwise it starts a fresh shell with frame logging. `--no-shell` skips that.

- **encoder.** it picks a working hardware encoder by itself (VAAPI, or NVENC on NVIDIA). very wide captures need HEVC, since H.264 on an RX 6600 stops at 4096px. if none works it falls back to x264 and warns, since software encoding a big screen drops most frames. `--codec` forces one, `--qp` sets quality, and `--pixfmt yuv420p` or `--no-dmabuf` help when a hardware capture comes out green or glitchy.
- **frame rate.** the video only gets a frame when the screen changes, so anything reading it must use frame timestamps, not frame numbers. `--fps N` forces a fixed rate at the cost of padded frames.
- **quality check.** when recording stops it counts the real frames and prints either `capture looks usable` or `capture is padded/dropped, re-record`. it takes about 40s on a long recording, and `--no-quality-check` skips it.
- **screen sharing.** the overview is capturable as it is, so nothing special is needed.

then analyse it.

```sh
python3 tools/sim/analyze.py --live DIR
```

this turns the logged workspace switches and synopsis events into a scenario called `live` and runs the same checks. `--live-window START END` looks at just part of the clip, and `--all-frames` saves every frame for scrubbing. with imagemagick installed it also builds a contact sheet around each flagged moment. `record.sh` prints the exact command when it finishes.

## ✅ requirements

| binary | needed for |
|---|---|
| `cage` (or `weston`) | the hidden parent compositor |
| `Hyprland` | the nested session |
| `qs` (quickshell) | the shell under test |
| `kitty` | test windows running `pattern.py` |
| `wf-recorder` | recording, optional, without it only the assertions run |
| `ffmpeg`, `ffprobe` | decoding in the analyzer |
| `mpv` | the video test window, optional |
| `python3` | the driver and analyzer (standard library, numpy used if present) |

## 🛡️ safety rules

- the harness only talks to the **nested** session. `run.sh` and `driver.py` stop if the instance they found matches your live one, and `run.sh` checks the nested session has exactly one monitor called `WAYLAND-1`.
- the nested hyprland runs with `HYPRLAND_NO_SD_VARS=1`, so it cannot point your newly launched apps at the hidden session.
- cleanup only kills processes the harness started.
- `qs` runs as `qs -p <repo>/shell`, a separate instance from your live `qs -c synopsis`. `QS_ARGS` overrides it.

## 🏗️ architecture

### why it nests

hyprland's backend needs a real display or a wayland parent, so it cannot run fully headless. the harness starts a hidden parent compositor and runs hyprland inside it as a normal window.

- **cage** is the default, with a fixed 1280x720 output. it is a patched build (`tools/sim/build-cage.sh` applies `tools/sim/cage.patch`).
- **weston** works with `--parent weston` but has not been tested since the cage patches.

the nested hyprland gets its own monitor (`WAYLAND-1`), display and instance signature. `run.sh` finds them by looking for the new sockets in `$XDG_RUNTIME_DIR`. `hyprland.lua` turns full logging on, since hyprland 0.56 cuts its log short by default.

#### the cage patch

stock cage 0.3.1 cannot host hyprland's backend. it offers an older `xdg_wm_base` version, and a quiet headless output stops sending frames, so the nested hyprland freezes. `cage.patch` bumps the version and adds an 8ms tick that keeps events and frames flowing, at about 120Hz.

#### capture path

recordings come from the **parent** display, which shows exactly what the nested hyprland draws. capturing inside the nested session hangs. `WLR_SCENE_DISABLE_DIRECT_SCANOUT=1` is required, otherwise the capture comes out flat. a still is taken before each recording, and a recording that never changes is reported as `no-content`, so a broken capture is never mistaken for a calm screen.

### known limits

- **no pointer.** the nested session has no mouse. clicks go through custom events, which run the same handlers but skip hit testing and the cursor.
- **cage is 1280x720.** the test windows scale with the screen, but an ultrawide shaped run needs weston.
- **timestamps, not frame numbers.** every metric uses frame timestamps, since quiet stretches can repeat frames.
- **settle times are rough.** capture in a nested software stack is slower than real hardware. flashes, cuts and stale frames are where regressions show.
- **mpv.** older builds may ignore `--wayland-app-id`, so `hyprland.lua` also matches the plain `mpv` class.

## 📄 license

MIT
