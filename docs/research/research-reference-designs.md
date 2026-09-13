# Reference Design Research — Mission Control Clone for Hyprland

Compiled 2026-09-13. Sources are cited inline as full URLs. Anything not confirmed by
a source is flagged "unverified" rather than guessed.

---

## PART 1 — macOS Tahoe (macOS 26, 26.6.x) Mission Control Spec

### 1. Trigger and exit methods

**Open:**
- Keyboard: F3 (dedicated Mission Control key on Apple keyboards), or Control+Up Arrow.
  (https://support.apple.com/en-gw/guide/mac-help/mh35798/mac)
- Trackpad: three-finger swipe up (documented default); four-finger swipe up available as
  an alternative via System Settings > Trackpad > More Gestures.
  (https://www.getspacejump.com/guides/mission-control-shortcuts)
- Magic Mouse: double-tap with two fingers on the mouse surface.
  (https://support.apple.com/en-gw/guide/mac-help/mh35798/mac)
- Hot corners: System Settings > Desktop & Dock > Hot Corners, any of the four screen
  corners, optionally gated behind a modifier key (Cmd/Shift/Option/Control). Disabled
  (no corner assigned) by default.
  (https://support.apple.com/en-tj/guide/mac-help/mchlp3000/mac,
  https://www.macrumors.com/how-to/macos-set-up-hot-corners-modifier-keys/)
- Dock: click the Mission Control icon if added to the Dock.
  (https://www.idownloadblog.com/2019/11/28/mac-mission-control-basics/)
- All bindings above are user-remappable.

**Exit:**
- Trigger the same gesture/key again (toggle behavior).
- Esc cancels without changing focus. (https://www.getspacejump.com/guides/mission-control-shortcuts)
- Click a window (focuses it and exits) or click empty desktop area (exits, stays put).
  (https://macmost.com/31-mission-control-tips.html)

**Related, distinct mode:** Cmd+F3 / four-finger spread = "Show Desktop" (pushes all
windows to screen edges), NOT the same as the All-Windows spread.
(https://en.wikipedia.org/wiki/Mission_Control_(macOS))

**Slow-motion easter egg:** holding Shift while triggering plays the transition in slow
motion (callback to the 2003 Exposé WWDC demo).
(https://en.wikipedia.org/wiki/Mission_Control_(macOS))

### 2. Spaces bar (top of screen)

- Shows one thumbnail per custom desktop Space AND per fullscreen/Split View app.
  Regular windows on the current desktop do NOT get their own top-bar entry — only the
  main Exposé grid shows them. (https://support.apple.com/en-gw/guide/mac-help/mh35798/mac)
- **Live vs static — UNVERIFIED both ways.** No source confirms continuous live-video
  refresh of off-screen Spaces' thumbnails while Mission Control stays open. What is
  established: thumbnails are essentially snapshots captured at/near open time, other
  Spaces' full thumbnails only render once the pointer moves into the bar, and Apple
  removed always-on all-space thumbnails after Sierra.
  (https://forums.macrumors.com/threads/new-mission-control-desktop-thumbnails.1924424/)
  Do not assume live GPU-composited previews here as fact — this differs from niri/GNOME
  which ARE confirmed live (see Part 2). Treat macOS behavior as unconfirmed and design
  defensively (either is a reasonable implementation target).
- Collapsed labels: inactive Space entries collapse to small text/label form when the
  cursor is away from the top edge; moving into the bar expands them to full thumbnails.
  (https://support.apple.com/en-gw/guide/mac-help/mh35798/mac)
- Reordering: dragging Space thumbnails left/right to reorder is long-standing, widely
  reported behavior, but not found spelled out verbatim in Apple's current help copy —
  treat as commonly-documented-but-not-Apple-primary-quoted.
- "+" add-space button appears on hover at the right edge of the bar; click creates a new
  Space (cap of 16 total); dragging a window onto it creates a new Space pre-populated
  with that window.
  (https://support.apple.com/guide/mac-help/work-in-multiple-spaces-mh14112/mac,
  https://flaviocopes.com/courses/macos-basics/mission-control-and-spaces/)
- Closing a Space: hover reveals an X on the thumbnail; clicking removes it and its
  windows relocate to another Space.
  (https://support.apple.com/guide/mac-help/work-in-multiple-spaces-mh14112/mac)
- Per-display Spaces ("Displays have separate Spaces", System Settings > Desktop & Dock >
  Mission Control): ON by default — each display keeps its own independent Space stack
  and menu bar, Dock follows pointer to active display. OFF makes Spaces unified across
  all displays (a window can straddle two screens); toggling requires logout/login.
  (https://macos-defaults.com/mission-control/spans-displays.html)
  Apple's help text: "If you enter Mission Control on a second display, only the open
  windows and spaces you're working with on that display are shown" — i.e. invocation is
  effectively per-display, not one unified overlay spanning monitors.
  (https://support.apple.com/en-lamr/guide/mac-help/mh35798/mac)

### 3. Exposé window-spread area

- "Group windows by application" (System Settings > Desktop & Dock, Mission Control
  section): clusters an app's multiple windows together with its icon near the cluster,
  instead of interleaving windows from different apps. Default on/off state not confirmed.
  (https://macos-defaults.com/mission-control/expose-group-apps.html,
  https://9to5mac.com/2016/05/10/how-to-group-mission-control-windows-app-mac-os-x/)
- Layout algorithm: Apple's original Exposé patent (filed 2003) — US 8,127,248 "Computer
  interface having a virtual single-layer mode for viewing overlapping objects"
  (https://patents.google.com/patent/US8127248B2/en) — describes a force/vector
  relaxation approach: iteratively move each overlapping window pair apart proportional
  to their overlap (a moderating factor, e.g. 0.5 per pass, halving remaining overlap
  each iteration), then uniformly scale the whole arrangement down if it still exceeds
  display bounds, preserving relative size and aspect ratio, animating continuously from
  each window's real position/size to its computed target. This is a description of
  design intent from a patent filing, not a confirmed spec of the current shipped
  algorithm — treat iteration counts and the patent's own "2-5 second" animation example
  as illustrative only, not verified for Tahoe.
- Titles on hover: widely reported (multiple how-to guides) that hovering or the Quick
  Look mechanism reveals app/window titles; not found explicitly in Apple's own guide
  text — partially unverified for exact trigger.
  (https://eshop.macsales.com/blog/49131-tips-for-using-mission-control-on-a-mac/)
- Minimized windows: NOT shown in the main All-Windows grid. Long-standing, persistent
  behavior since OS X Lion. They only surface in App Exposé (Control+Down) for that
  specific app, and even then reliably only when another non-minimized window of the same
  app is also open.
  (https://forums.macrumors.com/threads/show-minimized-windows-in-mission-control.1132962/,
  https://discussions.apple.com/thread/3191931)
- Hidden windows (Cmd+H): excluded from the spread entirely.
  (https://en.wikipedia.org/wiki/Mission_Control_(macOS))
- Fullscreen/Split View windows: never appear in the Exposé grid; each is its own Space,
  represented only as a top-bar thumbnail. (https://support.apple.com/en-gw/guide/mac-help/mh35798/mac)

### 4. Interactions

- Click a window in the spread -> focuses/raises it, exits Mission Control.
- Click a Space thumbnail in the bar -> jumps to that Space, exits.
- Drag a window onto a Space thumbnail -> moves the window to that Space.
- Drag a window onto "+" -> creates a new Space containing that window.
- Keyboard: arrow keys move selection between windows/Spaces, Return/Enter activates
  selection, Esc cancels. (Community-documented consensus, not verbatim Apple text —
  https://www.getspacejump.com/guides/mission-control-shortcuts)
- Control+Left/Right Arrow: move one Space left/right (works outside Mission Control too).
  Control+1-9 direct space jump exists but is disabled by default.
- Space-bar "Quick Look" preview: hover a thumbnail, press spacebar for an enlarged
  preview via the same Quick Look mechanism used in Finder.
  (https://osxdaily.com/2017/07/03/see-large-preview-mission-control-thumbnail-mac/)
- App Exposé (Control+Down Arrow, or 3/4-finger swipe down): shows only the frontmost
  app's windows, same non-overlap/scale layout; Tab cycles to next app's windows;
  unavailable while that app is fullscreen.
  (https://macmost.com/using-the-application-windows-feature-expose-on-a-mac.html)

### 5. Animation details

- Duration: **no Apple-published figure**. A community-known `defaults write
  com.apple.dock expose-animation-duration -float <n>` key exists from pre-Sierra era;
  users guessed stock default was "probably ~0.2-0.25s" but this is an unverified
  community estimate and the key reportedly stopped reliably working after Sierra.
  (https://osxdaily.com/2012/02/14/speed-up-misson-control-animations-mac-os-x/)
- Easing curve: **not published anywhere found. Unverified.**
- Continuous interpolation, not a cut/fade: windows fly/scale continuously from real
  desktop position/size to computed grid position/size, per the Exposé patent and
  consistent with all qualitative reviewer descriptions since 2003.
  (https://patents.google.com/patent/US8127248B2/en,
  https://en.wikipedia.org/wiki/Mission_Control_(macOS))
- Wallpaper/background treatment has changed release to release historically: 10.6/10.7
  textured dark grey -> Mavericks plain dark grey -> Yosemite translucent (wallpaper
  faintly visible) -> El Capitan fully transparent background.
  (https://en.wikipedia.org/wiki/Mission_Control_(macOS))
  **Tahoe-specific:** reviewers report a new Liquid Glass flourish on the open gesture —
  "when you three-finger swipe up for Mission Control, a glass pane descends from the top
  and distorts the view of the wallpaper underneath" (described as a "kitschy" but "fun"
  effect). (https://oakcover.com/hands-on-with-macos-tahoe-26-liquid-glass-new-theme-options-and-spotlight/)
- Liquid Glass / Tahoe redesign: system-wide translucency/depth-aware materials apply to
  window chrome broadly (https://medium.com/@uiuxsatyam/macos-tahoe-and-liquid-glass-ui-apples-boldest-desktop-redesign-yet-65c4e484dc57).
  macOS 26.1 added a system-wide Clear/Tinted Liquid Glass intensity toggle.
  (https://www.inkl.com/news/macos-tahoe-26-1-brings-sleek-liquid-glass-redesign-airplay-upgrades-and-safer-child-settings)
  Beyond the opening glass-pane flourish, no source documents a structural redesign of
  the Spaces bar or Exposé grid itself in Tahoe.
- Point-release changes found:
  - **macOS 26.4** removed a drop shadow that had been present in the Mission Control
    view (per aggregated Reddit comment on Michael Tsai's blog: "the shadow in the
    mission control thing has been removed thank god").
    (https://mjtsai.com/blog/2026/03/25/macos-26-4/)
  - Various 26.0-26.1 user-forum bug reports (not intentional feature changes): windows
    rendering "microscopic" until reboot
    (https://discussions.apple.com/thread/256225069); all windows briefly vanishing on
    trigger (https://forums.macrumors.com/threads/mission-control-makes-everything-disappear-tahoe-26.2479853/);
    stuttering/framerate drops returning from Mission Control (MacRumors forum).
  - No official Apple release-notes entries name Mission Control across 26.0-26.6.x
    developer release notes
    (https://developer.apple.com/documentation/macos-release-notes/macos-26_6-release-notes,
    https://developer.apple.com/documentation/macos-release-notes/macos-26-release-notes).
- Apple HIG page exists at
  https://developer.apple.com/macos/human-interface-guidelines/system-capabilities/mission-control/
  but is a JS-rendered SPA whose content could not be extracted by automated fetch in
  this pass — **unverified, page exists but content not retrievable**.

### Part 1 — Unverified / not documented
- Exact animation open/close duration in milliseconds (only an unofficial ~0.2-0.25s
  guess for a pre-Sierra defaults key; no Tahoe-era figure found anywhere).
- Exact easing/timing curve — no source specifies one.
- Whether off-screen Spaces-bar thumbnails continuously live-refresh while Mission
  Control remains open, vs. being snapshots taken at open time.
- Default on/off state of "Group windows by application."
- Full HIG guidance text for Mission Control (page exists, JS-rendered, unreadable via
  fetch).
- Any Apple-official (not third-party/forum) changelog entries for Mission Control across
  26.0-26.6.x — only the 26.4 shadow-removal note and scattered bug reports found.
- Whether the Exposé grid or Spaces bar got any structural (non-cosmetic) redesign in
  Tahoe beyond the opening glass-pane flourish and 26.4 shadow removal.
- Exact hover-vs-click trigger for window title display in the spread.

---

## PART 2 — Native Linux Compositor Overview Implementations (Design References)

### 1. niri Overview

Shipped in niri v25.05 (May 2025), confirmed via
https://github.com/niri-wm/niri/discussions/1589 ("The big new thing in niri v25.05 is
the Overview"). Project moved from `github.com/YaLTeR/niri` to
**`github.com/niri-wm/niri`** (old URL redirects). Rendering is a genuine live zoom-out,
not screenshots: background/bottom layer-shell layers (wallpaper) scale down together
with workspaces, while top/overlay layers (status bars) stay fixed on top so panels
remain usable while zoomed out. Input is not gated on animation completion — a window can
be grabbed immediately on open, and closing returns focus immediately without waiting for
the zoom-in to finish. Interactions: left-click-drag moves windows, right-click-drag pans
workspaces, scroll switches workspaces; touch supports one-finger scroll to navigate and
one-finger long-press to drag a window. Windows can be dragged vertically between
workspaces, or dropped between two existing workspaces to create a new one there.
Triggers: `toggle-overview` keybind, a top-left hot corner, or a four-finger touchpad
swipe. Config lives in an `overview { }` block (`zoom` default 0.5, `backdrop-color`,
`workspace-shadow`).

- Wiki: https://github.com/niri-wm/niri/wiki/Overview
- Config docs: https://github.com/niri-wm/niri/wiki/Configuration:-Introduction
- Version-confirming discussion: https://github.com/niri-wm/niri/discussions/1589
- Config struct/defaults: `niri-config/src/misc.rs` (`struct Overview { zoom,
  backdrop_color, workspace_shadow }`, `OverviewPart`) —
  https://github.com/niri-wm/niri/blob/main/niri-config/src/misc.rs ; wired in
  `niri-config/src/lib.rs` (field ~L85, defaults ~L1700, `OverviewOpenCloseAnim` ~L1649) —
  https://github.com/niri-wm/niri/blob/main/niri-config/src/lib.rs
- Runtime state/zoom/gestures: `src/niri.rs` (`KeyboardFocus::Overview`,
  `is_overview_open()`, `mon.overview_zoom()`, `overview_scroll_swipe_gesture`) —
  https://github.com/niri-wm/niri/blob/main/src/niri.rs
- Touch drag handling: `src/input/touch_overview_grab.rs` —
  https://github.com/niri-wm/niri/blob/main/src/input/touch_overview_grab.rs
- **Note:** no dedicated `overview.rs` exists under `src/layout/` — that directory
  currently holds `mod.rs, monitor.rs, workspace.rs, scrolling.rs, floating.rs, tile.rs`
  etc. The zoom/render logic is distributed across `src/niri.rs` and
  `src/layout/monitor.rs`, not isolated in one file. Do not cite a specific
  `layout/overview.rs` path — it does not exist.

### 2. KWin Overview effect (KDE Plasma 6)

QML-based effect (introduced ~Plasma 5.24, intended to eventually replace Present
Windows): live per-desktop window heaps, drag-and-drop of windows between virtual
desktops, desktop create/remove, and a type-to-search filter over open windows. Confirmed
directory contents of `src/plugins/overview/`: `main.cpp`, `overvieweffect.cpp`/`.h`,
`metadata.json`, `overviewconfig.kcfg`/`.kcfgc`, a `kcm/` settings module, and `qml/`
containing `DesktopBar.qml`, `DesktopView.qml`, `Main.qml`. `Main.qml` exposes an
`effect.searchText` property feeding a search field/results list, F1-F9/1-9 keys to jump
directly to a desktop, arrow-key navigation between window heaps per desktop, and
desktop creation/removal shortcuts. `overvieweffect.cpp` mainly exposes `setSearchText()`
to QML; the actual window-heap thumbnail rendering is a shared `WindowHeap` QML component
also used by Present Windows and Desktop Grid — its exact file location was not traced.
Plasma 6 defaults the four-finger touchpad swipe to open it.

- Repo tree: https://invent.kde.org/plasma/kwin/-/tree/master/src/plugins/overview
- Main.qml: https://invent.kde.org/plasma/kwin/-/blob/master/src/plugins/overview/qml/Main.qml
- overvieweffect.cpp: https://invent.kde.org/plasma/kwin/-/blob/master/src/plugins/overview/overvieweffect.cpp
- Introducing merge request: https://invent.kde.org/plasma/kwin/-/merge_requests/1388
- QML-effect authoring background: https://blog.vladzahorodnii.com/2024/03/18/how-to-write-a-qml-effect-for-kwin/

### 3. GNOME Shell Activities Overview (`js/ui/workspace.js`)

Confirmed current path on `main` branch (1451 lines): `js/ui/workspace.js`. `class
LayoutStrategy` (L102) is an abstract base; `class UnalignedLayoutStrategy extends
LayoutStrategy` (L145) is the concrete row-based algorithm, with `computeLayout(windows,
layoutParams)` at L212. Given a target `numRows`, it sums scaled window widths to get
`idealRowWidth = totalWidth/numRows`, sorts windows by vertical center to minimize travel,
then greedily assigns windows to rows via `_keepSameRow()` (append to the current row if
that keeps the row's width closer to `idealRowWidth`, else start a new row), and sorts
each row horizontally in `_sortRow()`. `computeScaleAndSpace(layout, area)` derives one
uniform scale = `min(horizontalScale, verticalScale, WINDOW_PREVIEW_MAXIMUM_SCALE=0.95)`.
The caller iterates increasing row counts and stops once a candidate scores worse than the
previous one, weighted by `LAYOUT_SCALE_WEIGHT=1` and `LAYOUT_SPACE_WEIGHT=0.1` — this
weighting and the "Window Thumbnail Layout Algorithm" description are documented in a
comment block near the top of the file (~L20-45). Previews are not screenshots:
`WindowPreview` (from `./windowPreview.js`, instantiated at L1338) wraps the real
`Meta.WindowActor` via Clutter clone/GL machinery for a live GPU-composited thumbnail.

- File: https://github.com/GNOME/gnome-shell/blob/main/js/ui/workspace.js
  (mirror: https://gitlab.gnome.org/GNOME/gnome-shell/-/blob/main/js/ui/workspace.js)

### 4. COSMIC (System76)

COSMIC does have a workspace overview, implemented as a separate on-demand process,
`cosmic-workspaces-epoch` (part of the `pop-os/cosmic-epoch` super-repo), rather than
inside `cosmic-comp` itself. It talks to the compositor over Wayland
(screencopy-style protocols) for live captures and a toplevel-management protocol to
move/close windows. Confirmed tree: `src/backend/wayland/{capture.rs, screencopy.rs,
dmabuf.rs, gbm_devices.rs, vulkan.rs, toplevel.rs}` (GPU/DMA-BUF-backed live capture, not
static screenshots), `src/dnd.rs` (drag-and-drop between workspaces),
`src/widgets/workspace_bar.rs`, and pluggable layout strategies under
`src/widgets/toplevels/toplevel_layout/{row_col_toplevel_layout.rs,
axis_toplevel_layout.rs, two_row_col_toplevel_layout.rs}` — conceptually parallel to
GNOME's row-based approach. As of 2025/2026 it's actively developed but rougher: open
issues show known layout/rendering bugs.

- Repo: https://github.com/pop-os/cosmic-workspaces-epoch
- Layout strategies dir: https://github.com/pop-os/cosmic-workspaces-epoch/tree/master/src/widgets/toplevels/toplevel_layout
- Known issues: https://github.com/pop-os/cosmic-epoch/issues/3391 ,
  https://github.com/pop-os/cosmic-epoch/issues/505

### 5. Hyprland hyprexpo (brief — another agent covers plugins in depth)

Shows a zoomed grid of all workspaces with a zoom-in animation; config keys historically
include `columns`, `gap_size`, `bg_col`, `workspace_method`, gesture options. **It has
been removed from `hyprwm/hyprland-plugins`** — the current tree only has
`borders-plus-plus`, `csgo-vulkan-fix`, `hyprbars`, `hyprfocus`, no `hyprexpo/` — per
unresolved issue https://github.com/hyprwm/hyprland-plugins/issues/672 ("Hyprexpo missing
from repository?", May 2026). Community forks carry it forward:
`github.com/sandwichfarm/hyprexpo` (files `src/main.cpp`, `src/Overview.cpp`,
`src/OverviewRender.cpp`, `src/ExpoGesture.cpp`) and `github.com/colonelpanic8/hyprexpo`
(same layout). Do not cite `hyprwm/hyprland-plugins/hyprexpo/main.cpp` — it 404s.

- Fork tree: https://github.com/sandwichfarm/hyprexpo/tree/master/src
- Issue: https://github.com/hyprwm/hyprland-plugins/issues/672

### 6. General non-overlapping ("exposé"/"scale") layout algorithms

- **GNOME's row-based approach** — fully described in §3 above: iterative row-count
  search, greedy row-packing sorted by original position, single uniform scale to fit.
- **Compiz Scale** — the wiki page documents `speed`/`timestep`/`spacing` as
  spring-animation-into-place parameters rather than a placement-algorithm writeup
  (http://wiki.compiz.org/Plugins/Scale). Compiz upstream is defunct; no live current
  source repo/file path for the Scale plugin could be confirmed — flagged unconfirmed.
- **KWin Present Windows** — historically offered "Natural", "Regular Grid", and
  "Flexible Grid" modes sharing layout code with the Desktop Grid effect, per Martin
  Gräßlin's 2013 post "Hitting walls — a story of Present Windows 2"
  (https://blog.martin-graesslin.com/blog/2013/04/hitting-walls-a-story-of-present-windows-2/).
  Present Windows is superseded by the QML Overview effect in Plasma 6. A live KDE
  workboard item, "RFC: new ExpoLayout Algorithm"
  (https://invent.kde.org/plasma/kwin/-/work_items/189), and merge request
  "effects/overview: implement new layout algorithm"
  (https://invent.kde.org/plasma/kwin/-/merge_requests/4916), describe replacing the old
  "closest"/"natural" heuristics with a layered/strip layout that packs windows into rows
  or columns of similar width, minimizes per-window movement within a strip, and runs in
  roughly O(n log n).
- No peer-reviewed academic paper on Exposé-style layout was found by the research
  agent — only vendor blog posts, wiki pages, and thin patent filings (see Apple's own
  US 8,127,248 in Part 1 §3 as the closest thing to a formal description).

### Part 2 — Unverified / could not confirm
- Exact niri source file(s) implementing the Overview zoom/render pipeline beyond
  `src/niri.rs` and `src/input/touch_overview_grab.rs` — no `overview.rs` file exists.
- Current/live Compiz Scale plugin source repository and file path (project defunct).
- Exact shared `WindowHeap` QML component file path in KWin (referenced by Overview/
  Present Windows/Desktop Grid but not directly traced to a path).
- Precise current hyprexpo config option names — pulled from pre-removal knowledge/fork
  READMEs, not verified against a currently-live canonical doc.
- Any peer-reviewed academic source for grid/force-directed exposé layout algorithms —
  none found.
