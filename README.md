<h1 align="center">synopsis</h1>

<p align="center">mission control for <a href="https://hypr.land">hyprland</a>: every workspace live along the top, every window of the current one spread out below, in one quickshell process of its own</p>

<p align="center">
  <a href="https://github.com/z89/synopsis/stargazers"><img src="https://img.shields.io/github/stars/z89/synopsis?style=flat-square&color=8fd3ff&labelColor=1b1a20" alt="stars"></a>
  <a href="https://github.com/z89/synopsis/commits/main"><img src="https://img.shields.io/github/last-commit/z89/synopsis?style=flat-square&color=8fd3ff&labelColor=1b1a20" alt="last commit"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/z89/synopsis?style=flat-square&color=8fd3ff&labelColor=1b1a20" alt="license"></a>
  <img src="https://img.shields.io/badge/hyprland-0.56%2B-8fd3ff?style=flat-square&labelColor=1b1a20" alt="hyprland 0.56+">
  <img src="https://img.shields.io/badge/quickshell-0.3%2B-8fd3ff?style=flat-square&labelColor=1b1a20" alt="quickshell 0.3+">
</p>

every workspace live in a strip along the top, every window on the current workspace spread out so none overlap, and windows fly from where they are into the layout instead of cutting. click a window to raise it, click a space to go there, drag a window onto a space to move it.

> built and tested on arch linux with hyprland 0.56.2, quickshell 0.3.1 and dankmaterialshell 1.6.0, on an amd rx 6600 driving one 5120x1440 120hz monitor. other versions and other setups are untested.

## ✨ highlights

- 🪟 **live workspaces**: every workspace is a real thumbnail with its windows composed on the wallpaper, and video keeps playing in them through hyprland's own `render_unfocused` rule.
- 🧩 **non-overlapping exposé**: the current workspace's windows are packed by gnome shell's row strategy at one uniform scale, aspect kept, so every window stays readable.
- ✈️ **continuous open**: thumbnails start at the windows' real rects and fly into the layout off one animation value, so there is no cut and no blank frame. closing runs it backwards.
- 🖱️ **click and drag**: click a window to focus and raise it, click a tile to switch, drag a window onto a tile to move it there silently.
- 🧱 **its own process**: a separate quickshell instance, not a shell plugin, so a capture crash takes the overview down and leaves the bar alone. a systemd user unit restarts it in one second.
- 🎨 **theming in lockstep**: colours, fonts, radius and durations come from dankmaterialshell when it is there, and from built-in defaults when it is not.
- 🧪 **measured, not guessed**: a frame log, a gpu sampler and a headless simulator back every timing number in the tuning log.

## 🏗️ how it works

a keybind sends a hyprland custom event, the shell hears it on the event socket, and one overlay layer per monitor wakes up. each window is captured live through hyprland's toplevel export and laid out in qml, so the client never copies pixels. the compositor stays untouched apart from a standing `render_unfocused` window rule, which keeps hidden windows painting instead of a plugin.

```
hyprland.lua ── bind ──► custom event ──► synopsis ──► overlay layer per monitor
                                                          strip of workspace tiles
                                                          exposé of the current workspace
```

the full shape, the state machine and the capture budget are in [docs/plan.md](docs/plan.md).

## 📦 install

symlink the shell into quickshell's config dir, the same way ember is installed:

```sh
bin/synopsis install
```

that links `~/.config/quickshell/synopsis` to `shell/` in this repo, so edits are live, and prints the remaining steps below.

systemd user unit, so a crash costs one second of downtime and never touches the bar:

```sh
mkdir -p ~/.config/systemd/user
ln -sf <repo>/systemd/synopsis.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now synopsis.service
```

hyprland.lua loader, the same io.open + load pattern as the colour files, bound to `Super + Grave`:

```lua
local synopsis = load(io.open(os.getenv("HOME") .. "/.config/hypr/synopsis.lua"):read("a"))()
synopsis.setup({ mod = mainMod })
```

`hypr/synopsis.lua` also carries the standing `render_unfocused` window rule: hyprland only sends frame callbacks to the active workspace, so this rule enrols every window at map time and synopsis raises the rate while the overview is open.

## 🖥️ cli

`bin/synopsis` talks to the running instance over quickshell ipc.

| command | what it does |
|---|---|
| `synopsis toggle` | toggle the overview |
| `synopsis open` / `synopsis close` | open or close it |
| `synopsis stats` | capture counts, live counts and last open latency |
| `synopsis ping` | check the shell is alive |
| `synopsis log` | follow the journal for `synopsis.service` |
| `synopsis run` | run it in the foreground, for development |
| `synopsis install` | symlink the shell and print the remaining steps |

## ⚙️ configuration

`~/.config/synopsis/config.json`, watched, every key optional. the defaults live in `shell/Core/Config.qml`.

| key | default | what it does |
|---|---|---|
| `hiddenFps` | `60` | frame rate given to hidden windows while the overview is open |
| `restFps` | `1` | frame rate they fall back to when it closes |
| `stripHeightFraction` | `0.14` | height of the workspace strip, as a fraction of the monitor |
| `exposeSpacing` | `24` | gap between windows in the exposé |
| `exposeMaxScale` | `0.95` | how large a single window may be drawn |
| `flightMs` / `flightEasing` | `260` / `OutCubic` | the open and close flight |
| `switchMs` / `switchEasing` | `450` / `InOutCubic` | the workspace slide |
| `scrimOpacity` | `0.55` | darkening behind the overview |
| `idleCaptureHz` | `12` | refresh rate of tiles that are not live |
| `showSpecialWorkspaces` | `false` | whether scratchpads appear in the strip |
| `followDms` | `true` | take colours and fonts from dankmaterialshell |
| `frameLog` | `false` | log per-frame timings to the journal |

## ✅ requirements

| what | version | why |
|---|---|---|
| hyprland | 0.56 or newer | the lua config runtime, custom events and `render_unfocused` |
| quickshell | 0.3 or newer | the overlay layers and toplevel capture |
| node | 22 | the layout tests only |
| dankmaterialshell | 1.6 or newer | optional, supplies colours and fonts |

## 📚 documentation

- [brief](docs/brief.md): what it must do and the decisions taken so far.
- [plan](docs/plan.md): how it gets built and proven, phase by phase.
- [phase 0](docs/phase0.md): the manual checklist for the experiments that need the desktop.
- [tuning log](docs/tuning.md): what the experiments and measurements showed.
- [research report](docs/research/report.html): the survey of everything that already exists.
- [research notes](docs/research/): the raw notes behind the survey.
- [simulator](tools/sim/README.md): the headless hyprland harness and the recording analyzer.

## 📄 license

mit
