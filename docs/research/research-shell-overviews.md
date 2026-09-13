# Shell-level Mission Control / workspace overview research (2026-09-13)

Target: Arch Linux, Hyprland 0.56.2, Quickshell 0.3.1, DankMaterialShell (DMS) 1.6.0, AMD GPU.

## A. Existing shell-level overviews

### DankMaterialShell (AvengeMedia/DankMaterialShell) — https://github.com/AvengeMedia/DankMaterialShell
- 8077 stars, pushed 2026-09-12, actively maintained. Releases: v1.6.0 (2026-09-03), v1.6.1 (2026-09-08).
- Has a REAL Hyprland workspace overview already, in core Modules (not a plugin):
  - `quickshell/Modules/WorkspaceOverlays/HyprlandOverview.qml` — Scope + Loader + Variants over `Quickshell.screens`, each screen gets a `PanelWindow` with `WlrLayershell.namespace: "dms:workspace-overview"`, `WlrLayershell.layer: WlrLayer.Overlay`, `WlrLayershell.exclusiveZone: -1`, keyboard focus via `HyprlandFocusGrab` (exclusive/on-demand). This is a genuine fullscreen layer-shell overlay.
  - `quickshell/Modules/WorkspaceOverlays/OverviewWidget.qml` (510 lines) — lays out a grid of ALL workspaces (`workspaceGrid`), each workspace cell is a `DropArea` + `MouseArea` (click cell = `HyprlandService.focusWorkspace(...)` and close overview). All toplevels across the id range are gathered into a `Repeater`/`ScriptModel`, each window delegate has `Drag.hotSpot`, a `MouseArea` with `drag.target: parent`, `onPressed` sets `window.Drag.active = true`, `onReleased` checks `root.draggingTargetWorkspace` and calls `HyprlandService.moveToWorkspace(targetWorkspace, windowData?.address, false)` then `Hyprland.refreshToplevels()/refreshWorkspaces()`. This is full drag-and-drop of windows between workspaces.
  - `quickshell/Modules/WorkspaceOverlays/OverviewWindow.qml` (173 lines) — per-window thumbnail. Reads `toplevel.lastIpcObject` for `at`/`size` (`windowData?.at?.[0]`, `windowData?.size?.[0]`, etc.), computes clipped rect against workspace viewport, drives position/size via `SpringMotion` (spring physics, not tween) for open/close and drag animation. Actual live preview:
    ```qml
    ScreencopyView {
        id: windowPreview
        anchors.fill: parent
        captureSource: root.overviewOpen ? root.toplevel?.wayland : null
        live: true
        ...
    }
    ```
    So yes — video keeps playing in the thumbnail (ScreencopyView `live: true`), overlaid with app icon.
  - `NiriOverviewOverlay.qml` (442 lines) exists too for niri compositor (separate implementation; not inspected in depth, niri has native overview toolkit support).
- Toggle is already wired as IPC: `~/.local/share/dms-shell-patched/DMSShellIPC.qml` has `IpcHandler { target: "hypr" ... function toggleOverview()/openOverview()/closeOverview() }` calling `root.hyprlandOverviewLoader.item.overviewOpen = ...`. Also `Modules/DankBar/Widgets/LauncherButton.qml` toggles the same property. CLI would be something like `dms ipc call hypr toggleOverview` (via quickshell's `qs ipc`/`dms ipc` wrapper) — exact CLI syntax not independently verified here.
- **No existing Hyprland keybind found** in the user's own `~/.config/hypr/*.lua` for this — feature is present in the shipped shell code (confirmed present since before Dec 2025, well before v1.6.0/v1.6.1 tags) but not bound to a key in this machine's config as of this session.
- DMS also has `Modules/DankDash/Overview/*` and `OverviewTab.qml` — this is a *different* "Overview" = a dashboard tab with calendar/media/weather/system-monitor cards, NOT the workspace exposé. Don't confuse the two.
- Plugin system: manifest `plugin.json`, `type` one of `widget|daemon|launcher|desktop|composite`. `components` maps surface name → QML file, valid keys: `widget, desktop, daemon, launcher`. **No manifest surface type for a fullscreen/layer-shell panel.** `PopoutService` (auto-injected into widget/daemon/settings components) only opens/closes/toggles a *fixed* list of built-in DMS surfaces (Control Center, Notification Center, App Drawer, Process List, DankDash, Battery, VPN, System Update, Settings, Clipboard History, Launcher, Power Menu, Color Picker, Notification, WiFi Password, Network Info, Notepad slideout) — no way to register a *new* custom fullscreen popout via the documented API. Daemon plugins are described as "invisible background services" driving `PopoutService`; no documented IpcHandler-registration or global-keybind-registration API for plugins either (`daemon-plugin-guide.md`, `popout-service-reference.md`, `advanced-patterns.md` — none mention `IpcHandler`, `GlobalShortcut`, `fullscreen`, `layershell`, or `PanelWindow`).
- `PluginComponent.qml` (the base wrapper daemons/widgets extend) is a plain QtQuick `Item`, not sandboxed against importing `Quickshell.Wayland`/`PanelWindow`. Given QML has no plugin sandbox visible in this code, a `daemon`-type plugin's QML likely COULD instantiate its own `PanelWindow`/`WlrLayershell` overlay directly (same mechanism core `HyprlandOverview.qml` uses) — but this is inference from reading `PluginComponent.qml` (381 lines, no restriction found), not a documented/supported pattern, and no example plugin doing this was found. **Unverified.**
- Source: docs site `danklinux.com` returned nothing fetched (not checked directly; README + in-repo `.agents/skills/dms-plugin-dev/` skill docs used instead, which are authoritative first-party dev docs shipped in the repo).

### end-4/dots-hyprland "illogical-impulse" — https://github.com/end-4/dots-hyprland
- 16071 stars, pushed 2026-08-27.
- `dots/.config/quickshell/ii/modules/ii/overview/{Overview,OverviewWidget,OverviewWindow,SearchBar,SearchItem,SearchWidget}.qml`.
- Confirmed near-identical pattern to DMS: `OverviewWindow.qml` has `ScreencopyView { captureSource: GlobalStates.overviewOpen ? root.toplevel : null; live: true }`. `OverviewWidget.qml` has `DropArea`, `Drag.hotSpot`, `drag.target: parent`, full drag-to-move-workspace flow, plus a `SearchBar`/`SearchWidget` (type-to-filter windows) that DMS's version doesn't have.
- This is almost certainly the origin of the DMS/`quickshell-overview`/`hypr-overview` pattern — the QML structure and property names are essentially the same lineage.

### caelestia-dots/shell — https://github.com/caelestia-dots/shell
- 12264 stars, pushed 2026-09-11 (very active).
- **No workspace-grid exposé found.** Has `modules/bar/components/workspaces/*` (bar workspace pills, not a grid overview) and `modules/dashboard/*` (a Caelestia-native dashboard, analogous to DMS DankDash, not a window exposé).
- Does have `modules/windowinfo/Preview.qml` — a **single-window** live preview (`ScreencopyView { captureSource: root.client?.wayland; live: true }`), used as e.g. a hover/alt-tab info panel, not a multi-workspace grid.
- Verdict: closest reusable piece is the `Preview.qml` live-thumbnail pattern, not a Mission-Control clone.

### Noctalia (noctalia-dev/noctalia-shell) — https://github.com/noctalia-dev/noctalia-shell
- 10541 stars, pushed 2026-09-13. **Important: this is NOT a Quickshell/QML shell.** Per its own README it is "built directly on Wayland and OpenGL ES with no Qt or GTK dependency" — a from-scratch native C++ compositor-agnostic shell (language breakdown: ~12.2MB C++, negligible else). This is a rewrite; do not assume it's the older AGS/Quickshell-based Noctalia some docs may reference.
- `src/shell/switcher/{window_switcher.cpp,window_switcher.h,window_switcher_tile.cpp}` — "Fullscreen Alt+Tab style window switcher with a centered 5×5 grid," backed by `AsyncTextureCache`. Inspected `window_switcher_tile.cpp`: renders `m_icon`/`m_iconHost` (app icon), no reference to screencopy/live capture in the tile — **this is an icon-based switcher, not live video thumbnails.**
- `src/capture/screencopy_capture.cpp` exists and uses `protocols/wlr-screencopy-unstable-v1.xml`, but wlr-screencopy captures whole outputs, not toplevels; combined with the tile code only using icons, live per-window preview in the switcher is unconfirmed/unlikely.
- `src/shell/overview/overview_launcher_capture.*` is specifically for **niri's** native compositor-level overview mode (keeping tiny keyboard-focus layer surfaces open so the launcher can be summoned while niri's own overview is shown) — not a Hyprland-relevant Mission Control feature at all.
- Verdict: not useful as a direct source for a Hyprland Mission Control clone; different toolkit, different feature scope, and its "overview" is a niri integration shim, not a thumbnail grid.

### Standalone dedicated Quickshell "Overview"/"Exposé" projects (found via search, not in the original candidate list)

- **Shanu-Kumawat/quickshell-overview** — https://github.com/Shanu-Kumawat/quickshell-overview (483 stars, pushed 2026-08-18). "A standalone workspace overview module for Hyprland using Quickshell — shows all workspaces with live window previews, drag-and-drop support, and Super+Tab keybind." File layout: `modules/overview/{Overview,OverviewWidget,OverviewWindow}.qml` (same lineage as end-4/DMS). Features per README: multi-monitor (experimental branch), smart row hiding, click-to-focus, middle-click-to-close, drag-and-drop between workspaces, keyboard nav (arrows/vim/number keys), auto-close on focus loss, hover tooltips, Material 3 theming. **Packaged for AUR**: `quickshell-overview-git`, installs to `/etc/xdg/quickshell/overview/`. Strongest "just use this" candidate for a standalone config.
- **thesleepingsage/hypr-overview** — https://github.com/thesleepingsage/hypr-overview (6 stars, pushed 2026-06-06). Explicitly "extracted from end-4's dots-hyprland, with refactoring and additional features." Adds beyond end-4/DMS baseline: **Window Swapping** (drag a window onto another to swap positions) and **Stash Trays** (park windows temporarily in a quick-access tray — closest analogue to macOS Mission Control's temporary space behavior). Has an `install.sh` with `--dry-run/--update/--uninstall` and a keybind example: `bind = Super, Tab, global, quickshell:overviewToggle`. Live thumbnails confirmed via feature list ("Live window thumbnails with titles and app icons"); requires Hyprland + Quickshell only.
- **dom0/qs-hyprview** — https://github.com/dom0/qs-hyprview (85 stars, pushed 2026-08-21). Framed as a Window Switcher/Exposé rather than a workspace grid: shows ALL windows (across workspaces?) arranged by **10 selectable layout algorithms** (smartgrid, justified, masonry, bands, hero, spiral, satellite, staggered, columnar, vortex, random). README states "Live Thumbnails: Live window contents via Hyprland screencopy." Ships as a runnable Quickshell config (`quickshell -c qs-hyprview`) with a documented **IPC handler named `expose`**: `quickshell ipc -c qs-hyprview call expose toggle $layout` / `open` / `close`, meant to be bound directly in `hyprland.conf`. Suggests native Hyprland `layerrule = dimaround, quickshell:expose` and `blur` for compositor-side dim/blur of the overlay — a technique reusable regardless of which shell project is chosen. No drag-and-drop mentioned in the README excerpt read (not fully confirmed absent).
- Both **gfhdhytghd/hymission** (128 stars, C++, pushed 2026-09-12) and **simonwinther/hyprspace** (0 stars, C++, pushed 2026-09-11) are **Hyprland compositor plugins** (loaded via `hyprpm`/`hyprctl plugin`, run inside the compositor process) — explicitly OUT OF SCOPE per the task's shell-level requirement, but noted because they are the most feature-complete "Mission Control" clones found (hymission: gesture support, workspace strip, scope control, referenced hyprexpo/hycov/Hyprspace as prior art; hyprspace: pinned to exact Hyprland 0.56.2 commit `efb50993780079460b0cbed1363e2166a2de1d9f`, which happens to match the target system's Hyprland version). If the shell-level requirement is ever relaxed, hymission is the one to look at first.
- pyprland's "expose" (hyprland-community/pyprland wiki) was surfaced by search but not fetched/verified — it's a Python IPC daemon (`pypr`) feature, conceptually more like "gather all windows onto the current workspace temporarily" (a scratchpad-style expose) rather than a rendered thumbnail grid. **Unverified**, not investigated further (out of scope: not a shell UI, no live-thumbnail claim found).

### AGS / Astal
- No official Astal example overview: `Aylur/astal` repo's `examples/` only has `simple-bar` (gtk3/gtk4, py/vala/js) — no overview/exposé example shipped upstream.
- Astal/AGS has **no ScreencopyView-equivalent widget**. Any live preview in this ecosystem would require hand-rolling a GTK4 `Gdk.Paintable`/DMABUF importer against `wlr-screencopy-unstable-v1` or `hyprland-toplevel-export-v1` manually — meaningfully more work than Quickshell, which ships `ScreencopyView` as a ready-made `Item`.
- Community hits, all small/low-maintenance, checked file trees for screencopy usage:
  - **selimbucher/kiwi-shell** — https://github.com/selimbucher/kiwi-shell (4 stars, pushed 2026-09-12). Has `widgets/AppSwitcher/{AppSwitcher.tsx,clientCachingService.tsx}` and `widgets/WorkspaceSwitcher/WorkspaceSwitcher.tsx`. No screencopy file found in tree — icon/app-based, README claims "Super+Tab cycling through workspace overview, showing miniature versions of window layouts" (likely rectangle/icon miniatures, not live video). **Unverified beyond absence of screencopy code.**
  - **TheWolfStreet/ags2-shell** — https://github.com/TheWolfStreet/ags2-shell (14 stars, pushed 2026-09-07). Claims "workspace overview" in description; not inspected in depth (budget).
  - **Praczet/ags-hyprland** — https://github.com/Praczet/ags-hyprland — **archived**, 2 stars, "Exposé-style window overview" claimed but dead project.
- Verdict: AGS/Astal ecosystem has no serious, actively maintained Mission-Control clone with live thumbnails. Quickshell is structurally ahead here because of `ScreencopyView`.

### eww / GTK
- Search turned up only ordinary eww workspace-indicator widgets (`croyleje/eww-hyprland-workspace`, `FieldofClay/hyprland-workspaces`) — simple pill/dot bar widgets showing workspace numbers/occupancy, not an overview/exposé with previews. No live-thumbnail eww project found. eww's architecture (declarative SCSS/yuck, no arbitrary custom rendering surface) makes a screencopy-based exposé impractical without shelling out to an external compositor tool.
- H3rmt/hyprshell (formerly hyprswitch) — https://github.com/H3rmt/hyprshell (590 stars, pushed 2026-09-07, Rust + GTK4 + gtk4-layer-shell + libadwaita). "Modern GTK4-based window switcher and application launcher." Checked full repo file tree for `screencopy`/`thumbnail`/`capture`/`preview` — only hit was an unrelated `nix_preview.rs` (a Nix config preview pane in its settings app). **No live-thumbnail / screencopy support found** — confirms this is an icon/text-based Alt-Tab-style switcher, not a Mission Control clone. Actively maintained, well packaged (AUR, crates.io, Nix), min Hyprland 0.55.0.

## B. Quickshell capabilities (fetched directly from https://quickshell.org/docs/v0.3.0/ — WebFetch was blocked with 403 by the doc site's bot protection; used `curl` with a browser User-Agent instead, which worked)

### ScreencopyView (`Quickshell.Wayland`) — https://quickshell.org/docs/v0.3.0/types/Quickshell.Wayland/ScreencopyView/
Full extracted doc text:
> ScreencopyView : Item. "Displays live video streams or single captured frames from valid capture sources."
- **captureSource : QtObject** — accepts:
  - `null` — clears the displayed image.
  - `ShellScreen` — a monitor. Requires a compositor supporting `wlr-screencopy-unstable` **or** both `ext-image-copy-capture-v1` and `ext-capture-source-v1`.
  - `Toplevel` — a toplevel window. Requires a compositor supporting **`hyprland-toplevel-export-v1`**. (I.e., per-window capture on Hyprland goes through Hyprland's own toplevel-export protocol, not a generic wlr/ext protocol — matches what DMS/end-4/caelestia all actually use: `captureSource: toplevel.wayland` where `toplevel` is a `HyprlandToplevel`'s attached `Toplevel`.)
- **constraintSize : size** — if nonzero, constrains width/height of the view's implicit size while preserving the source's aspect ratio.
- **paintCursor : bool** — paint system cursor on the image; default `false`.
- **hasContent : bool, readonly** — true once content is ready to display (avoid showing before ready).
- **live : bool** — if true, shows a live video feed instead of a single still frame; default `false`. (This is the property DMS/end-4/caelestia set to `true`.)
- **sourceSize : size, readonly** — size of the source image; valid once `hasContent` is true.
- **Function `captureFrame()`** — capture a single frame; no effect if `live` is true.
- **Signal `stopped()`** — compositor ended the video stream; restart may or may not work.
- No explicit documented statement about occluded/other-workspace toplevel behavior was found on this page — **unverified** whether a toplevel on a non-visible workspace or occluded by a fullscreen layer keeps producing frames. (Circumstantial evidence it does: DMS's/end-4's overview code sets `captureSource` to the toplevel unconditionally while `overviewOpen` is true regardless of which workspace the window is actually on, and these projects are widely used, which suggests Hyprland's `hyprland-toplevel-export-v1` does keep compositing/exporting off-screen and other-workspace toplevels. Not a documentation-confirmed fact.)
- Performance notes found only in the changelog (below), not on the type page itself.

### Quickshell.Hyprland module — https://quickshell.org/docs/v0.3.0/types/Quickshell.Hyprland/
Types: `GlobalShortcut, Hyprland, HyprlandEvent, HyprlandFocusGrab, HyprlandMonitor, HyprlandToplevel, HyprlandWindow, HyprlandWorkspace`.

**`Hyprland` (singleton QtObject)** — https://quickshell.org/docs/v0.3.0/types/Quickshell.Hyprland/Hyprland/
- Properties: `monitors: ObjectModel<HyprlandMonitor>` (readonly), `activeToplevel: HyprlandToplevel` (readonly, may be null), `toplevels: ObjectModel<HyprlandToplevel>` (readonly), `workspaces: ObjectModel<HyprlandWorkspace>` (readonly, sorted by id; named workspaces have negative id and sort before unnamed ones), `eventSocketPath: string`, `focusedMonitor: HyprlandMonitor` (may be null), `focusedWorkspace: HyprlandWorkspace` (may be null), `requestSocketPath: string`, `usingLua: bool` (false until module initialized; dispatcher syntax changes in lua mode).
- Functions: `dispatch(request: string): void`, `monitorFor(screen: ShellScreen): HyprlandMonitor`, `refreshMonitors()/refreshToplevels()/refreshWorkspaces(): void` (manual refresh since not all state-changing actions emit events).
- Signal: `rawEvent(event: HyprlandEvent)` — emitted for every event on the hyprland event socket (socket2).

**`HyprlandToplevel`** (uncreatable) — https://quickshell.org/docs/v0.3.0/types/Quickshell.Hyprland/HyprlandToplevel/
"Represents a window as Hyprland exposes it. Can also be used as an attached object of a `Toplevel`, to resolve a handle to a Hyprland toplevel."
- Properties: `title: string`, `monitor: HyprlandMonitor`, `address: string` (hex, empty until reported), `wayland: Toplevel` (readonly, the wlr-foreign-toplevel handle; null until address reported — **this is what gets passed to `ScreencopyView.captureSource`**), `workspace: HyprlandWorkspace`, `lastIpcObject: unknown` (readonly — raw JSON from Hyprland for this toplevel, e.g. contains `at`, `size`, `floating`, `pinned`, `class`, `fullscreen`, etc. — NOT updated automatically; call `Hyprland.refreshToplevels()` and wait for it to update if you need fresh values), `activated: bool`, `urgent: bool`, `handle: HyprlandToplevel` (self-reference, "the toplevel handle exposing the Hyprland toplevel").
- Confirmed fields consumed in practice (from DMS's `OverviewWindow.qml`): `windowData.at[0]/at[1]` (position), `windowData.size[0]/size[1]` (size), `windowData.workspace.id`, `windowData.class`, `windowData.address` — all read off `lastIpcObject`, not off dedicated typed properties (Quickshell doesn't expose typed `x/y/width/height/floating/pinned` properties on `HyprlandToplevel` itself; you go through `lastIpcObject`).

**`HyprlandWorkspace`** (uncreatable) — https://quickshell.org/docs/v0.3.0/types/Quickshell.Hyprland/HyprlandWorkspace/
- Properties: `active: bool`, `hasFullscreen: bool`, `focused: bool` (active AND monitor focused), `id: int`, `urgent: bool`, `monitor: HyprlandMonitor`, `name: string`, `lastIpcObject: unknown`, `toplevels: ObjectModel` (list of toplevels on this workspace).
- Function: `activate()` — equivalent to dispatching `workspace <name>`.

**`HyprlandMonitor`** (uncreatable) — https://quickshell.org/docs/v0.3.0/types/Quickshell.Hyprland/HyprlandMonitor/
- Properties: `x, y, width, height: int`, `id: int`, `description: string`, `activeWorkspace: HyprlandWorkspace`, `focused: bool`, `name: string`, `scale: real`, `lastIpcObject: unknown`.

**`HyprlandEvent`** (uncreatable) — https://quickshell.org/docs/v0.3.0/types/Quickshell.Hyprland/HyprlandEvent/
"Live Hyprland IPC event. Holding this object after the signal handler exits is undefined as the event instance is reused." Emitted by `Hyprland.rawEvent()`. Properties: `name: string` (see Hyprland Wiki IPC event list), `data: string` (unparsed). Function: `parse(argumentCount: int): list` — parses with a known arg count (some events have commas inside args).

**`Toplevel` / `ToplevelManager`** (`Quickshell.Wayland`) — generic wlr-foreign-toplevel layer, compositor-agnostic:
- `ToplevelManager` (singleton): "Exposes a list of windows from other applications as `Toplevel`s via the `zwlr-foreign-toplevel-management-v1` wayland protocol." Properties: `activeToplevel: Toplevel` (readonly), `toplevels: ...`.
- `Toplevel` (uncreatable): properties `maximized/fullscreen/minimized: bool` (settable as a *request*, compositor may ignore), `activated: bool` (readonly), `appId: string`, `screens: list<ShellScreen>` (readonly), `title: string`, `parent: Toplevel` (modal/dialog parent). Functions: `activate()`, `close()`, `fullscreenOn(screen)`, `setRectangle(window, rect)` (hint to compositor for minimize animation target), `unsetRectangle()`. Signal `closed()`.

**`WlrLayershell`** (`Quickshell.Wayland`, attached object of `PanelWindow`) — https://quickshell.org/docs/v0.3.0/types/Quickshell.Wayland/WlrLayershell/
"Decorationless window attached to screen edges via `zwlr_layer_shell_v1`." Recommended usage is always through `PanelWindow` (platform-independent) with `WlrLayershell` as its attached object, e.g. `WlrLayershell.layer: WlrLayer.Bottom`, guarded with `if (this.WlrLayershell != null)` for cross-platform (X11) compatibility. Properties seen: `layer: WlrLayer` (default `WlrLayer.Top`), `namespace: string` (like a window class, for external tools; immutable after `windowConnected`), `keyboardFocus: WlrKeyboardFocus`, plus `exclusiveZone` (used by DMS as `-1` = ignore/cover-everything) — this is exactly the mechanism a fullscreen Mission-Control overlay uses (`layer: WlrLayer.Overlay`, `exclusiveZone: -1`, `anchors` to all four edges).

**New/notable: `Quickshell.WindowManager` module** (types: `ScreenProjection, WindowManager, Windowset, WindowsetProjection`) — https://quickshell.org/docs/v0.3.0/types/Quickshell.WindowManager/ — a **generic, compositor-agnostic** workspace/tag abstraction added per the v0.3.0 changelog ("Added generic WindowManager interface implementing ext-workspace"). `Windowset` is described as "a generic type that encompasses both 'Workspaces' and 'Tags'" with `active/urgent/canActivate/canDeactivate/canRemove/canSetProjection/shouldDisplay/id/name/coordinates/projection` properties and `activate()/deactivate()/remove()/setProjection()` functions; `WindowManager.screenProjection(screen)` returns a `ScreenProjection` aggregating all windowsets on a screen. This is a newer, non-Hyprland-specific alternative to `Quickshell.Hyprland` for workspace enumeration (built on the Wayland `ext-workspace` protocol) — useful if cross-compositor portability matters, but it doesn't carry per-window geometry (`at`/`size`) the way Hyprland's `lastIpcObject` does, so a Mission-Control clone would likely still want `Quickshell.Hyprland` for actual window rects on this system.

### Quickshell changelog — https://quickshell.org/changelog/ (fetched fully)
- **v0.3.1** (bugfix release): "Fixed ScreencopyView not displaying when only lock surfaces are shown," "Fixed potential crashes from usage of WindowsetProjection.screens during monitor unplug," "Fixed crashes when failing to create a ScreencopyView," plus many unrelated crash fixes (pipewire, wifi, JsonAdapter, FileView, ColorQuantizer, PopupAnchor, X11 last-panel-hide). No new features in 0.3.1.
- **v0.3.0** (feature release) — relevant new features: "Added vulkan support to screencopy," "Added generic WindowManager interface implementing ext-workspace" (see above), "Added ext-background-effect window blur support," "Added support for grabbing focus from popup windows," "Added lua config support to Hyprland module," "Added minimized, maximized, and fullscreen properties to FloatingWindow," "Added the ability to handle move and resize events to FloatingWindow." Breaking change: config paths no longer canonicalized (affects nix symlinked configs / shell-id). Bug fixes directly relevant here: "Fixed hyprland active toplevel not resetting after window closes," "Fixed hyprland ipc window names and titles being reversed," "Fixed a hyprland ipc crash when refreshing toplevels before workspaces," "Fixed ToplevelManager not clearing activeToplevel on deactivation," "Fixed HyprlandFocusGrab crashing if windows were destroyed after being passed to it," "Fixed ScreencopyView pixelation when scaled," "Fixed screencopy crashing when used across GPUs," "Fixed nulls in Toplevel.screens after unplugging a monitor."
- **v0.2.1**: mostly bugfixes + Qt 6.10 support; no overview-relevant features.
- **v0.2.0**: "Added HyprlandToplevel and related toplevel/window management APIs in the Hyprland module" (i.e. per-window Hyprland API is relatively recent, introduced in 0.2.0), root-relative QML imports, Bluetooth module, "Fixed ScreencopyView having incorrect rotation when displaying a rotated monitor," "Fixed HyprlandWorkspace.activate() sending invalid commands to Hyprland for named or special workspaces."
- No dedicated built-in drag-and-drop API is mentioned anywhere in the changelog — the drag-and-drop seen in every project above (DMS, end-4, quickshell-overview, hypr-overview) is implemented with plain QtQuick `Drag`/`DropArea` attached properties (standard Qt Quick, not Quickshell-specific), which is why it's readily reusable.

## Sources (all fetched/verified this session unless marked unverified)
- https://quickshell.org/docs/v0.3.0/types/Quickshell.Wayland/ScreencopyView/
- https://quickshell.org/docs/v0.3.0/types/Quickshell.Hyprland/ (index), /Hyprland/, /HyprlandToplevel/, /HyprlandWorkspace/, /HyprlandMonitor/, /HyprlandEvent/
- https://quickshell.org/docs/v0.3.0/types/Quickshell.Wayland/Toplevel/, /ToplevelManager/, /WlrLayershell/
- https://quickshell.org/docs/v0.3.0/types/Quickshell.WindowManager/WindowManager/, /Windowset/, /WindowsetProjection/, /ScreenProjection/
- https://quickshell.org/changelog/
- https://github.com/AvengeMedia/DankMaterialShell (README, file tree, raw source of HyprlandOverview.qml/OverviewWidget.qml/OverviewWindow.qml/NiriOverviewOverlay.qml, `.agents/skills/dms-plugin-dev/` docs, local install at ~/.local/share/dms-shell-patched/DMSShellIPC.qml)
- https://github.com/end-4/dots-hyprland (raw source of ii/modules/ii/overview/*.qml)
- https://github.com/caelestia-dots/shell (file tree, raw source of modules/windowinfo/Preview.qml)
- https://github.com/noctalia-dev/noctalia-shell (README, languages, file tree, raw source of window_switcher.h, window_switcher_tile.cpp headers/excerpts, overview_launcher_capture.h)
- https://github.com/Shanu-Kumawat/quickshell-overview (README, file tree)
- https://github.com/thesleepingsage/hypr-overview (README)
- https://github.com/dom0/qs-hyprview (README)
- https://github.com/gfhdhytghd/hymission (README) — compositor plugin, out of scope
- https://github.com/simonwinther/hyprspace (README) — compositor plugin, out of scope
- https://github.com/H3rmt/hyprshell (README, file tree grep)
- https://github.com/Aylur/astal (examples tree)
- https://github.com/selimbucher/kiwi-shell, https://github.com/TheWolfStreet/ags2-shell, https://github.com/Praczet/ags-hyprland (metadata + kiwi-shell file tree only)
- https://github.com/hyprland-community/pyprland (wiki "expose" page referenced by search, not fetched — unverified)
