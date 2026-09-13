# plan

how synopsis gets built and proven. written 2026-09-13 after the brief, before any code. the order is: prove the risky assumptions, build a proof of concept with every main feature, harden it until it is boring, then make it beautiful. the ui foundations (tokens, animation driver, state machine) are laid in the proof of concept so the polish phase changes data and components, not architecture.

## shape

one long-running quickshell process, `qs -c synopsis`, separate from dms. it owns one overlay layer per monitor, keeps them hidden while idle, and wakes on a hyprland event. nothing of it renders while closed, so the idle cost is one sleeping process.

```
hyprland.lua ── hl.bind / hl.gesture ──► hl.dsp.event("synopsis", "toggle")
                                                │  socket2 custom event, no process spawn
                                                ▼
synopsis (qs -c synopsis) ── Hyprland.rawEvent ──► Overview state machine
      │                                                  │
      │  Hyprland.refreshToplevels / rawEvent            │  dispatch: focuswindow, workspace,
      │  (window rects, workspaces, monitors)            │  movetoworkspacesilent, alterzorder
      ▼                                                  ▼
one PanelWindow per screen (WlrLayer.Overlay, namespace "synopsis")
      strip of workspace tiles ─ each tile composes wallpaper + one ScreencopyView per window
      exposé of the current workspace ─ one ScreencopyView per window, row packed
      scrim, drag layer, hover chrome
```

why this shape and not the alternatives is in the brief and in docs/research/research-feasibility.md. the short version: hyprland has no native overview, the compositor plugin route breaks on every release, and dms already proves that live per-window capture from a layer surface works on this stack.

## the parts

### process and install

- the quickshell config lives in `shell/` in this repo. install is a symlink `~/.config/quickshell/synopsis -> <repo>/shell`, the same way ember is installed, so edits are live
- `systemd/synopsis.service` (user unit, `WantedBy=graphical-session.target`, `Restart=on-failure`, `RestartSec=1`) runs `qs -c synopsis`. a crash costs one second of downtime and never touches the bar
- `hypr/synopsis.lua` is loaded from hyprland.lua the same `io.open` + `load` way the colour files are. it holds the bind, the gesture and the layer rule. hyprland does not autoreload it, which is what we want
- `bin/synopsis` wraps `qs -c synopsis ipc call overview <toggle|open|close>` for scripts and for people without the lua config

### trigger

- `hl.dsp.event(...)` exists in the 0.56.2 lua api (`/usr/share/hypr/stubs/hl.meta.lua:872`) and emits a `custom>>` line on the event socket. synopsis already listens to that socket through `Hyprland.rawEvent`, so a keypress reaches the overlay with no process spawn and no ipc round trip. this is the primary trigger. the ipc handler stays as the scripted fallback
- keybind: proposed `Super + Grave` for toggle. it is free in hyprland.lua; `Super + Tab`, `Super + W`, `Super + Up` and `Super + Space` are all taken (hyprland.lua:318-351)
- gesture: `hl.gesture` takes `fingers`, `direction`, `mods` and an `action` that may be a lua function (hl.meta.lua:460-470). proposed 4-finger swipe up opens, swipe down closes. only one gesture is bound today (3-finger horizontal workspace swipe, hyprland.lua:288)
- close: the same bind, escape, a click on empty scrim, or any action that resolves (click window, click workspace, drop)
- layer rule `hl.layer_rule({ name = "synopsis-noanim", match = { namespace = "synopsis" }, no_anim = true })`, mirroring the `dms` rule at hyprland.lua:473, so hyprland never fades the layer in or out under our own animation. `no_screen_share = true` on the same rule as belt and braces even though we never capture the output

### state machine

one qml singleton, `Overview`, owns the state. every window, tile and animation binds to it. nothing else holds a copy of "open", which is the exact bug that broke the dms overlay (HyprlandOverview.qml:211).

```
closed ──open()──► preparing ──ready──► opening ──done──► open
   ▲                                                       │
   └── hidden ◄── closing ◄── resolve(action) ◄────────────┘
```

- `preparing`: `Hyprland.refreshToplevels()` and `refreshWorkspaces()`, wait for `lastIpcObject` to update, build the per-monitor models, set every capture source, wait until every capture on the current workspace has `hasContent` (watchdog 150ms so one slow client cannot hang the open). the layer is already mapped at this point with the scrim at 0 and every thumbnail at its real rect, so the first painted frame is indistinguishable from the desktop
- `opening`: the flight animation runs, progress 0 to 1
- `open`: input live. `rawEvent` keeps the models fresh: `openwindow`, `closewindow`, `movewindowv2`, `createworkspacev2`, `destroyworkspacev2`, `focusedmonv2`, `monitoradded`, `monitorremoved`. a window closed while the overview is open animates out of the layout; a new one animates in
- `resolve(action)`: keyboard focus drops to `None` first so the layer stops holding focus, then exactly one dispatch runs, then `closing`
- `closing`: the flight runs backwards to the real rects. when the target is on another workspace the thumbnails fade instead, since there is no real rect to fly to on this screen. the layer hides one frame after the last animation frame
- open and close are idempotent and interruptible. a toggle during `opening` reverses the same progress value. there is never a queue of pending toggles

### data

- monitors: `Hyprland.monitors` matched to `Quickshell.screens` by name through `Hyprland.monitorFor(screen)`
- workspaces per monitor: every `HyprlandWorkspace` whose monitor is this one, sorted by id. special workspaces are excluded in the proof of concept (open question in the brief)
- windows: `HyprlandToplevel` gives `address`, `wayland` (the capture source), `workspace`, `monitor`, and `lastIpcObject` with `at`, `size`, `floating`, `pinned`, `fullscreen`, `class`, `title`, `focusHistoryID`. `lastIpcObject` is a snapshot; it is refreshed on open and on every relevant `rawEvent`
- stacking: floating windows sort by `focusHistoryID` ascending on top of tiled ones, which is what hyprland draws
- filters: `mapped` only. windows with `fullscreen` take the workspace rect in the tile and their own slot in the exposé like any other window
- wallpaper for tiles: `wallpaperPath` from `~/.local/state/DankMaterialShell/session.json`, watched. tiles show the wallpaper with windows composed on top, since output capture cannot see an inactive workspace (research-feasibility.md 3.3)

### layout

`shell/Core/Layout.js` is pure javascript with no qml dependency: rects and an area in, rects out. it is a port of gnome shell's `UnalignedLayoutStrategy` (js/ui/workspace.js): try 1..n rows, pack windows into rows by vertical centre, one uniform scale capped at 0.95, score by scale weighted 1 and wasted space weighted 0.1, keep the best. aspect ratio is always preserved. spacing and the maximum scale are parameters.

because it is pure javascript it is unit tested with node against fixture sets (one window, two side by side, five mixed, twelve, a fullscreen one, a tiny floating one, extreme aspect ratios) and against the invariants: no overlap, inside the area, aspect preserved, deterministic.

the strip is a second, trivial layout: n tiles of the monitor's aspect at a fixed height, centred, with gaps. the exposé area is what remains below the strip minus margins.

### capture and performance

the whole point of the design is that thumbnails are gpu textures handed over by the compositor. the client never copies pixels. the risks are count and cadence, not bandwidth.

- one `ScreencopyView` per window. exposé views and the current workspace's tile views are `live: true`. views in other tiles are `live: false` and refreshed by `captureFrame()` on a shared 12hz timer while open. hovering a tile switches it to live. the numbers are config values; the measurement phase sets the defaults
- views are created staggered, a few per frame, never all at once. this is the mitigation for quickshell #1123 (concurrent live views racing the object id allocator and killing the process). even if it fires, it kills synopsis, not the bar, and the unit restarts it
- captures stop the moment the overlay is hidden: `captureSource` goes to null. nothing stays warm, so direct scanout is only blocked while the overview is on screen
- a 1px always-animating element lives while open. after the first frame a capture only advances when the output commits, and an idle overlay with no animation would otherwise stop every thumbnail (research-feasibility.md 3.4)
- one animation drives everything. `Overview.progress` is a single `NumberAnimation`; every thumbnail interpolates between its real rect and its layout rect from that value. n parallel animations with `Behavior` on geometry would re-evaluate every binding per tick, which is exactly what made the dms bar drop to 25fps during theme fades
- no `Behavior on color` anywhere, for the same reason. palette changes crossfade a snapshot (see theming)
- thumbnails are `ClippingRectangle` with a radius that scales with the thumbnail, so rounded corners match hyprland's `decoration.rounding` (16) at full size and stay proportional when small
- the overlay window is transparent, `exclusiveZone: -1`, no blur (blur is disabled in hyprland.lua anyway). the scrim is one rectangle
- budget at 5120x1440 at 120hz is 8.3ms per frame for everything. the feasibility estimate for 14 live captures is 2 to 6ms of extra gpu. the hardening phase measures it instead of trusting it

### interactions

- click a window: `resolve` with `focuswindow address:0x..` followed by `alterzorder top,address:0x..` when the window floats. `focuswindow` switches workspace if it has to. the exposé thumbnail flies back to its real rect under the layer, so the handoff is seamless when the window is on the current workspace
- click a workspace tile: `workspace <id>` on that tile's monitor
- drag a window: the thumbnail itself becomes the drag item and follows the pointer; every tile is a `DropArea` and highlights while hovered. on drop: `movetoworkspacesilent <id>,address:0x..`, then the models refresh and the thumbnail animates into the tile. dropping on the current workspace's tile or on empty space animates it back. drags stay within one monitor in the proof of concept; cross-monitor drag needs a shared drag state across two layer windows and is deferred
- hover: outline on the hovered thumbnail, title label. keyboard navigation (arrows, enter, digits for workspaces) is a polish item but the state machine exposes a `selected` index from day one so it drops in
- escape and click on scrim close

### theming in lockstep with dms

everything visible reads from `shell/Core/Theme.qml`, one singleton with the same token names dms uses: `primary`, `primaryContainer`, `secondary`, `surface`, `surfaceContainer`, `surfaceVariant`, `surfaceText`, `surfaceTextMedium`, `outline`, `error`, `cornerRadius`, `shortDuration`, `mediumDuration`, `longDuration`, `standardEasing`, `emphasizedEasing`, `fontFamily`, `monoFontFamily`, `fontSizeSmall..XLarge`, `spacingXXS..XL`. no component contains a literal colour, duration or font. the polish phase changes tokens and components, never plumbing.

sources, all watched with `FileView { watchChanges: true }`:

- `~/.cache/DankMaterialShell/dms-colors.json`: `mode` and `colors.dark` / `colors.light`, exactly the file dms's own `Theme.qml` watches. derived tokens (`primaryContainer` as a blend, `surfaceTextMedium` at 0.7 alpha) use the same formulas as dms so nothing looks a shade off
- `~/.config/DankMaterialShell/settings.json`: `fontFamily`, `monoFontFamily`, `cornerRadius` (default 12), `animationSpeed` (index into the same 75/150/250ms table), `popupTransparency`, `currentThemeName`, `matugenSmartMode`
- `~/.local/state/DankMaterialShell/session.json`: `isLightMode` and `wallpaperPath`
- `~/.cache/DankMaterialShell/palette-applied.stamp`: written by the patched dms bar from its first presented frame after a palette flip (DankBarWindow.qml, `Window.window.frameSwapped`). synopsis parses the new palette when the json lands but flips its tokens when the stamp changes. that puts the flip on the same frame family as the bar, the lock screen and kitty, which is what lockstep means here
- when the overview is visible during a flip it does what the bar does: `ShaderEffectSource` snapshot of its chrome, flip the tokens, fade the snapshot out over 500ms with `OutCubic`. thumbnails are not in the snapshot; they keep moving
- with no dms present every source has a built-in default (a dark material palette, inter, 12px radius) so the project runs on a plain hyprland

### config

`~/.config/synopsis/config.json`, watched, every key optional, defaults in `shell/Core/Config.qml`: `stripHeightFraction`, `exposeSpacing`, `exposeMaxScale`, `flightMs`, `flightEasing`, `scrimOpacity`, `idleCaptureHz`, `showSpecialWorkspaces`, `followDms`, `frameLog`. keybinds stay in hyprland.

### debug and measurement

- `SYNOPSIS_FRAMELOG=1` (or `frameLog` in config) makes each overlay window log `frameSwapped` timestamps and the animation progress per frame to the journal, the same technique used to tune the dms theme sync. frame gaps over 9ms during a flight are the failure signal, never a visual impression
- `bin/synopsis stats` prints capture counts, live counts and last open latency (time from event to first painted frame) over ipc
- gpu load during tests from `/sys/class/drm/card*/device/gpu_busy_percent` sampled at 10hz by a tiny script in `tools/`

## repo layout

```
shell/
  shell.qml                 ShellRoot, Variants over screens, ipc handler, event listener
  Core/  Overview.qml       state machine, per-monitor models, actions
         HyprState.qml      hyprland ipc glue, refresh + rawEvent handling
         Theme.qml          tokens, dms sources, defaults, snapshot crossfade
         Config.qml         config.json with defaults
         Layout.js          pure exposé layout
  Ui/    OverlayWindow.qml  one per screen: layer, focus, scrim, strip, exposé, drag layer
         WorkspaceStrip.qml WorkspaceTile.qml Expose.qml WindowThumb.qml Scrim.qml
  Debug/ FrameLog.qml
hypr/synopsis.lua           bind, gesture, layer rule
systemd/synopsis.service
bin/synopsis
tests/layout.test.js        node, fixtures + invariants
tools/                      gpu sampler, journal frame parser
docs/                       brief, plan, research, later a tuning log
```

## phases

### phase 0: the experiments (gate)

nothing gets built until these are answered. each is a short, recorded test; results go into `docs/tuning.md`.

1. **video on an inactive workspace.** mpv looping on one workspace, open the dms overview from another, watch the tile. the user runs this; no agent touches the desktop. moving means the shell route covers everything. frozen means either a tiny hook-free compositor plugin that ticks frame callbacks for windows being captured, or the whole project moves into a plugin. this one experiment decides the biggest fork in the plan
2. **occluded window on the active workspace keeps painting.** same video, same workspace, overview open on top
3. **quickshell cli and a hello shell.** `qs --help`, `qs -c synopsis` with a shell that shows nothing, `qs ipc call` syntax, whether file watching is on by default. running qs is a desktop action in this setup, so it is done with an approval or by the user
4. **custom event reaches the shell.** `hl.dsp.event` from a bind, `Hyprland.rawEvent` in the hello shell logs it. measures the latency of the primary trigger path
5. **xwayland captures.** a toplevel export of an xwayland window (discord, steam) produces frames, and its `at`/`size` match its real rect
6. **capture permission.** `ecosystem.enforce_permissions` is off in hyprland.lua (line 132, commented). confirm no prompt appears; note the `hl.permission("/usr/bin/quickshell", "screencopy", "allow")` line for people who enforce
7. **headless hyprland for tests.** whether hyprland 0.56.2 starts with only the aquamarine headless backend the way its own `hyprtester` does in ci. if it does, every later behavioural test runs in a throwaway compositor instead of on the user's desktop, and the desktop guard never has to be asked

### phase 1: proof of concept

every main feature, minimal chrome, tokens wired. exit criteria, each one a test:

- open and close from the keybind, from ipc, and from escape, 50 times in a row without a crash, a stuck layer, or a stuck focus
- every workspace of the monitor appears as a tile with its windows in place and the wallpaper behind; the current tile is marked
- every window of the current workspace appears in the exposé, none overlapping, all inside the area, aspect kept (layout test suite green, plus a screenshot check)
- open animation: no blank or black frame between the desktop and the first overlay frame (frame log plus a high-rate `grim` sample of the first frames), thumbnails start at the real rects
- click a tiled window on the current workspace: overlay gone, window focused, no focus left on the layer
- click a floating window on another workspace: workspace switched, window focused and on top
- click a tile: workspace switched, overlay gone
- drag a window to a tile: window moved silently, overlay still open, layout updated, thumbnail in the tile
- palette flips when the wallpaper changes (the overlay may be closed; check by opening after)
- with dms stopped, synopsis still opens with defaults

### phase 2: hardening and measurement

this phase ends when the thing is boring. tests, each with its pass bar:

| what | how | pass |
|---|---|---|
| open latency | event timestamp to first frame, frame log | under 50ms |
| flight smoothness | frame log during 30 opens with 15 windows | no gap over 9ms, no dropped presentation |
| gpu cost | gpu_busy_percent with overlay open and idle, then during flight, 1 and 2 monitors | headroom left at 120hz, numbers recorded |
| capture crash | 200 open/close cycles with 12 live windows, staggered vs unstaggered | zero exits; if unstaggered dies, stagger stays mandatory |
| windows churn while open | open, then close and spawn windows from a script | model and layout follow within one refresh, no orphan views |
| workspace churn while open | create and destroy workspaces while open | tiles appear and vanish, no crash |
| monitor hotplug | plug and unplug the second monitor, open on each | one overlay per monitor, tiles only for that monitor's workspaces |
| fullscreen, pinned, xwayland, special | one of each in the set | shown correctly or deliberately excluded, documented |
| focus after close | every close path | `activewindow` is the intended window, never nothing |
| dms restart | restart dms.service with synopsis open and closed | synopsis survives, palette rebinds |
| synopsis crash | kill the process while open | unit restarts within 1s, no stuck layer, no focus grab left behind |
| memory | rss after 500 cycles | flat |

crash resistance also means: capture sources set to null before the window hides, never destroy a view mid-frame, all dispatches issued once, timers stopped on close, and a watchdog that force-closes the overlay if `opening` has not reached `open` within 500ms.

### phase 3: the ui

only now does it get its look, because now the frame log says what a change costs.

- tahoe feel: the strip descends from the top with the scrim, thumbnails carry a soft shadow and a hover outline in `primary`, the current tile gets a `primary` ring, labels use `surfaceText` on a `surfaceContainer` pill, app icons on thumbnails
- curves tuned from the frame log: start at 260ms `OutCubic`, then try the `swift` spring parameters hyprland uses for workspaces so the overview and the workspace slide feel like one system
- light mode, high contrast and every palette dms can produce, checked by switching wallpapers
- keyboard navigation and a search-as-you-type filter
- the gesture with progress: swipe distance drives `Overview.progress` directly so the overview follows the fingers, then settles
- cross-monitor drag
- empty workspace tiles, the "plus" tile for a new workspace, app grouping toggle

## risks and their answers

| risk | answer |
|---|---|
| inactive workspace thumbnails freeze | phase 0 test 1; frame-tick plugin or plugin route |
| quickshell #1123 kills the process | own process, staggered captures, unit restart, 200-cycle test |
| gpu cost at 120hz | live only where it matters, 12hz elsewhere, measured not guessed |
| visible seam on open | layer mapped before anything moves, hasContent gate, frame-sampled |
| stale rects from ipc | refresh on open, rawEvent while open, models rebuilt not patched |
| focus stuck on the layer | keyboardFocus None before every dispatch, explicit focuswindow, tested per path |
| theme flip out of step with the bar | flip on the stamp, not on the json write |
| binding churn during animation | one progress value, no Behaviors |
| hyprland api drift | only ipc and lua, no compositor hooks; the lua snippet is ten lines |

## corrections to the research notes

- `hl.plugin.load`, `hl.animation` and `hl.curve` exist in 0.56.2 and are used in hyprland.lua; research-hyprland-core.md says otherwise. the stub file `/usr/share/hypr/stubs/hl.meta.lua` is the authoritative api list on this machine
- `hl.dsp.event` exists and is the trigger path; the research assumed a process spawn per keypress
- dms is mit since december 2025 (`LICENSE_CHANGE_12_11_2025.md`), so salvaging its qml into this mit repo needs only attribution
- `pseudo` is no longer a field in `hyprctl clients -j`

## what the user decides

- the keybind (`Super + Grave` proposed) and the gesture (4-finger swipe up proposed)
- whether special workspaces belong in the strip
- when to run phase 0 test 1, since it needs the desktop
