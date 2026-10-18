<h1 align="center">synopsis</h1>

<p align="center">
  <img src="https://img.shields.io/badge/arch%20linux-rolling-8fd3ff?style=flat-square&labelColor=1b1a20" alt="arch linux">
  <img src="https://img.shields.io/badge/hyprland-0.56.2-8fd3ff?style=flat-square&labelColor=1b1a20" alt="hyprland 0.56.2">
  <img src="https://img.shields.io/badge/quickshell-0.3.1-8fd3ff?style=flat-square&labelColor=1b1a20" alt="quickshell 0.3.1">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-8fd3ff?style=flat-square&labelColor=1b1a20" alt="license MIT"></a>
</p>

synopsis is a workspace overview for [hyprland](https://hypr.land), modelled on macOS Tahoe Mission Control. press one shortcut and every workspace shows up as a live tile along the top, while the windows of the current workspace spread out below so you can see all of them.

opening is one smooth motion. each window flies from where it really is into its spot in the layout, and closing plays it backwards. click a window to focus it, click a tile to jump to that workspace, or drag a window onto a tile to move it there. it runs as its own quickshell process, so a crash only takes down the overview and systemd restarts it within a second.

> tested on arch linux with hyprland 0.56.2 (lua config), quickshell 0.3.1 and DankMaterialShell (DMS) 1.6.0, on an AMD RX 6600 with one 5120x1440 120Hz monitor. multiple monitors, other GPUs and other distributions are untested.

## ✨ highlights

- 🪟 **exposé of the current workspace** lays windows out in rows at one shared scale, keeps their shape and draws them in hyprland's real stacking order.
- 🗂️ **live workspace strip** gives every workspace a fixed-size tile, with a plus button for a new empty workspace and scrolling past seven tiles.
- 🛫 **flight from the real windows** starts each thumbnail exactly on top of its window, so the first frame looks just like the desktop.
- 🎞️ **video wallpapers in the tiles** play a small cached copy of the clip, in step with the desktop.
- ⚡ **wallpaper cover** lets a supporting live wallpaper cover the desktop itself, which cut the time to open from a median 377.5ms to 81ms on the test machine.
- 🖐️ **drag and drop** shrinks a dragged window toward the strip, drops it where you let go and flies it back if you miss.
- ⌨️ **keyboard first** opens from a hyprland keybind with no process spawn, closes on Escape and lands on the shown workspace with Enter.
- 🎨 **in step with DMS** uses its palette, fonts, corner radius and wallpaper, with built-in defaults on plain hyprland.
- 🧪 **headless simulator** runs scripted scenarios in a hidden hyprland and reports every flash, cut and stall it finds.

## 📦 install

there is no build step. link the shell, the systemd unit and the hyprland snippet into place.

```sh
bin/synopsis install
mkdir -p ~/.config/systemd/user
ln -sf "$PWD/systemd/synopsis.service" ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now synopsis.service
ln -sf "$PWD/hypr/synopsis.lua" ~/.config/hypr/synopsis.lua
```

`bin/synopsis install` links `~/.config/quickshell/synopsis` to `shell/`, so your edits are live. the unit runs `qs -c synopsis` and restarts it a second after a crash. when it stops it also deletes leftover `eco-cover-*.json` request files, so a crash never leaves the desktop covered.

then load the snippet from `~/.config/hypr/hyprland.lua`.

```lua
local synopsis = load(io.open(os.getenv("HOME") .. "/.config/hypr/synopsis.lua"):read("a"))()
synopsis.setup({ mod = mainMod })
```

`setup` takes `mod` (default `SUPER`) and `key` (default `grave`). it adds the keybind, three `no_anim` layer rules (`synopsis`, `synopsis-backdrop`, and `synopsis-cover` for `^eco:wallpaper$`) and a wildcard `render_unfocused` window rule. the window rule keeps windows on hidden workspaces drawing so their tiles stay live. it rests at 1fps and synopsis raises the rate while the overview is open.

window rules only apply as windows open, so anything already open before the first load stays frozen in its tile until you reopen it or reload the config.

`plugin/` is an optional DMS bar widget. clicking it toggles the overview.

```sh
ln -s "$PWD/plugin" ~/.config/DankMaterialShell/plugins/synopsis
dms ipc call plugins enable synopsis
```

then add `synopsis` to a bar under settings, bar, widgets.

## ⌨️ usage

| input | what it does |
|---|---|
| `Super + Grave` | open or close, and a press mid-flight reverses it |
| `Escape` | close |
| `Enter` | close and land on the workspace shown |
| click a window | go to its workspace, focus it and raise it |
| click a workspace tile | switch to it and close |
| click the empty background | close |
| click the plus button | add an empty workspace, which is dropped on close if unused |
| drag a window onto a tile | move it there, and a floating window keeps the spot you dropped it |
| `Shift + Scroll` | scroll the strip when it overflows |
| your workspace keybinds | switch while open, and the exposé slides along |

the grave key is the backtick key above Tab. holding the shortcut does not flicker the overview, since key repeat is ignored.

`bin/synopsis` controls the running instance from a shell.

| command | what it does |
|---|---|
| `synopsis toggle`, `open`, `close` | the same as the keybind |
| `synopsis stats` | capture counts and the last open time |
| `synopsis ping` | check the shell is alive |
| `synopsis log` | follow the journal |
| `synopsis run` | run in the foreground, for development |
| `synopsis install` | link `shell/` into quickshell's config directory |

### video wallpapers and the cover

with a video wallpaper, the tiles play a small copy of the clip (1280px wide, 30fps) built in the background by `shell/Scripts/wallpaper-proxy.sh` and cached in `~/.cache/synopsis/wallpaper/`. it starts at the wallpaper's own playhead, so tiles and desktop show the same moment. until the copy is ready, or without ffmpeg and ffprobe, the tiles show a still.

a live wallpaper that supports it can also lift its own window above everything while the overview is open, so synopsis has no backdrop to paint. the two sides talk through two small files per monitor in `$XDG_RUNTIME_DIR`.

| file | written by | content |
|---|---|---|
| `eco-cover-<monitor>.json` | synopsis | the request, `{cover, at, pid}` |
| `eco-cover-state-<monitor>.json` | the wallpaper | the answer, `{top, at, seq, pid}` |

if the wallpaper does not answer within 70ms, that monitor falls back to the still. without a supporting wallpaper nothing changes. `liveWallpaper` and `coverViaWallpaper` turn each part off.

## ⚙️ settings

settings live in `~/.config/synopsis/config.json`, which is watched, and every key is optional. defaults are in `shell/Core/Config.qml`. keybinds stay in hyprland.

| key | default | what it controls |
|---|---|---|
| `hiddenFps` | `60` | frame rate of hidden windows while open |
| `restFps` | `1` | the rate restored on close |
| `flightMs`, `flightEasing` | `260`, `OutCubic` | the open and close flight |
| `followHyprWorkspaceCurve` | `true` | use hyprland's own workspace animation curve |
| `hyprWorkspaceCurve` | `null` | override that curve with a spring or bezier |
| `switchMs`, `switchEasing` | `450`, `InOutCubic` | slides when the hyprland curve is off |
| `tileSwitchMs` | `420` | the tile click slide when the hyprland curve is off |
| `exposeSpacing`, `exposeMaxScale` | `24`, `0.95` | exposé gaps and the largest window scale |
| `scrimOpacity` | `0.55` | how much the desktop dims |
| `idleCaptureHz` | `12` | refresh rate of tiles that are not live |
| `stripMaxVisible` | `7` | tiles shown before the strip scrolls |
| `dragReturnMs` | `450` | the flight back after a missed drop |
| `showSpecialWorkspaces` | `false` | reserved for scratchpad tiles, not built yet |
| `liveWallpaper` | `true` | play a video wallpaper in the tiles |
| `coverViaWallpaper` | `true` | use the wallpaper cover when offered |
| `followDms` | `true` | read palette and fonts from DMS |
| `frameLog` | `false` | log frame timing to the journal (also `SYNOPSIS_FRAMELOG=1`) |

the rest are in `shell/Core/Config.qml`, and the [tuning log](docs/tuning.md) says what each value was tuned against.

## ✅ requirements

- hyprland 0.56 or newer, with the lua config.
- quickshell 0.3 or newer.
- node 22, for the layout tests.
- DMS, optional, for colours, fonts, wallpaper and the bar widget.
- ffmpeg and ffprobe, optional, for video wallpapers in the tiles.
- a live wallpaper that supports the cover files, optional.
- the simulator needs a few more tools, listed in [its readme](tools/sim/README.md).

## 🩺 troubleshooting

if the shortcut does nothing, run `systemctl --user status synopsis.service` and `synopsis ping`. `synopsis log` shows the journal.

if tiles for other workspaces are frozen, those windows opened before the `render_unfocused` rule existed. reopen them or reload the hyprland config.

if one app (say a gtk4 monitor) freezes in its tile, it is pausing itself on a hidden workspace. that is expected. terminals, mpv and browser video keep moving.

if the tiles show a still instead of the video, the copy is still being built, ffmpeg is missing, or `liveWallpaper` is off.

if the wallpaper stays on top after a crash, restart `synopsis.service`.

to see how long each open takes, turn `frameLog` on and feed the log to `tools/open-latency.py`.

```sh
synopsis log > open.log   # open it a few times, then stop
python3 tools/open-latency.py open.log
```

## 🧪 tests

```sh
npm test                                # layout engine
tools/sim/run.sh                        # every simulator scenario
tools/sim/run.sh --scenario open_close  # one scenario
```

the [simulator](tools/sim/README.md) runs hyprland hidden inside cage, drives the overview through scripted scenarios, records the screen and reports any glitches. it never touches your session. for a glitch that only shows on the real desktop, record it with `tools/record.sh` and score it with `python3 tools/sim/analyze.py --live DIR`.

the tag `stable-2026-09-14` is the last state checked by hand with no known bugs. if something breaks later, compare against it first.

```sh
git diff stable-2026-09-14 -- shell
```

## 🏗️ architecture

<p align="center"><img src="docs/img/architecture.svg" alt="architecture" width="820"></p>

one quickshell process keeps an overlay and a backdrop window per monitor, both hidden until needed. a keypress arrives as an event on hyprland's socket and starts the state machine.

- **Overview** is the one place that knows whether the overview is open. it runs the states and handles clicks, drops and focus.
- **HyprState** talks to hyprland. it reads monitors, workspaces and windows, follows events, and checks that every focus change actually landed.
- **Layout.js** is plain javascript that places the exposé and the strip, tested with node.
- **Wallpaper** finds the wallpaper, its still and the tile video.
- **the backdrop window** paints the wallpaper behind the exposé so the real windows never show through. with a supporting wallpaper it asks the wallpaper to do it instead.
- **the overlay window** holds the strip, the exposé and the thumbnails. each thumbnail shows the window's own buffer, so nothing is copied.
- **Config and Theme** watch `config.json` and the DMS files.

the full picture is in [architecture](docs/ARCHITECTURE.md).

## 📚 docs

- [architecture](docs/ARCHITECTURE.md) explains how each part works.
- [research](docs/research/) covers the macOS target, existing overviews and why synopsis is built this way.
- [tuning log](docs/tuning.md) lists every experiment and measurement.
- [simulator](tools/sim/README.md) covers the test harness and how to record a live bug.
- [changelog](CHANGELOG.md) lists what changed.

## 📄 license

MIT
