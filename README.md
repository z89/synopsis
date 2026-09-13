<h1 align="center">synopsis</h1>

<p align="center">mission control for <a href="https://hypr.land">hyprland</a></p>

<p align="center">
  <a href="https://github.com/z89/synopsis/stargazers"><img src="https://img.shields.io/github/stars/z89/synopsis?style=flat-square&color=4fc3c9&labelColor=1b1a20" alt="stars"></a>
  <a href="https://github.com/z89/synopsis/commits/main"><img src="https://img.shields.io/github/last-commit/z89/synopsis?style=flat-square&color=4fc3c9&labelColor=1b1a20" alt="last commit"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/z89/synopsis?style=flat-square&color=4fc3c9&labelColor=1b1a20" alt="license"></a>
  <img src="https://img.shields.io/badge/hyprland-0.56%2B-4fc3c9?style=flat-square&labelColor=1b1a20" alt="hyprland 0.56+">
  <img src="https://img.shields.io/badge/quickshell-0.3%2B-4fc3c9?style=flat-square&labelColor=1b1a20" alt="quickshell 0.3+">
</p>

every workspace live in a strip along the top, every window on the current workspace spread out so none overlap, and windows fly from where they are into the layout instead of cutting. click a window to raise it, click a space to go there, drag a window onto a space to move it.

## how it works

a quickshell process of its own, not a shell plugin, so a crash takes the overview down and nothing else. one overlay layer per monitor. each window is captured live through hyprland's toplevel export and laid out in qml. colours come from the dankmaterialshell palette when it is there. the compositor stays untouched apart from a standing `render_unfocused` window rule, which keeps hidden windows painting instead of a plugin.

## install

symlink the shell into quickshell's config dir, the same way ember is installed:

```
bin/synopsis install
```

that links `~/.config/quickshell/synopsis` to `shell/` in this repo, so edits are live, and prints the remaining steps below.

systemd user unit, so a crash costs one second of downtime and never touches the bar:

```
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

run it by hand, in the foreground, for development:

```
bin/synopsis run
```

## docs

- [docs/brief.md](docs/brief.md): what it must do and the decisions taken so far
- [docs/plan.md](docs/plan.md): how it gets built and proven, phase by phase
- [docs/phase0.md](docs/phase0.md): the manual checklist for the experiments that need the desktop
- [docs/tuning.md](docs/tuning.md): what the experiments and measurements showed
- [docs/research/report.html](docs/research/report.html): the survey of everything that already exists
- [docs/research/](docs/research/): the raw notes behind the survey

## needs

hyprland 0.56 or newer, quickshell 0.3 or newer, node 22 for the tests. dankmaterialshell is optional and only supplies colours.

## licence

mit
