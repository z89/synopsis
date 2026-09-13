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

nothing runs yet. this is the research and the brief; the code comes next.

## how it will work

a quickshell process of its own, not a shell plugin, so a crash takes the overview down and nothing else. one overlay layer per monitor. each window is captured live through hyprland's toplevel export and laid out in qml. colours come from the dankmaterialshell palette when it is there. the compositor stays untouched unless a video on an inactive workspace stops moving, in which case a tiny plugin ticks its frames.

## docs

- [docs/brief.md](docs/brief.md): what it must do and the decisions taken so far
- [docs/plan.md](docs/plan.md): how it gets built and proven, phase by phase
- [docs/tuning.md](docs/tuning.md): what the experiments and measurements showed
- [docs/research/report.html](docs/research/report.html): the survey of everything that already exists
- [docs/research/](docs/research/): the raw notes behind the survey

## needs

hyprland 0.56 or newer, quickshell 0.3 or newer. dankmaterialshell is optional and only supplies colours.

## licence

mit
