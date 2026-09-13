# Hyprland 0.56.2 core research: Mission Control style overview building blocks

Sources: GitHub releases (github.com/hyprwm/Hyprland/releases), Hyprland source tree via
raw.githubusercontent.com / gh api (main branch, checked 2026-09-13), hyprland-plugins repo,
wiki.hypr.land (partial — see caveat).

Caveat: wiki.hypr.land pages (Lua utilities, Dispatchers) are served by a JS-hydrated docs
site; `curl` only returns the shell/meta tags for most pages, not body text. WebFetch's
extraction was also partial/summarized. Where the wiki could not be confirmed verbatim, this
report relies on the Hyprland C++ source instead (also primary) and says so explicitly.

## 1. Release notes 0.50-0.56.x

Releases in range: v0.51.1 (2025-09-22) through v0.56.2 (2026-08-05). No v0.50 tag exists on
the releases page (list starts effectively at 0.51.x for the window checked).

No release in this range adds a native overview/exposé/workspace-preview feature, and none
mentions "hyprexpo" moving into core. There is no evidence of Mission-Control-style
functionality being merged into Hyprland core at any point 0.51-0.56.

Screencopy / capture protocol changes found:
- v0.54.0: `protocols: implement image-capture-source-v1 and image-copy-capture-v1 (#11709)`
  https://github.com/hyprwm/Hyprland/releases/tag/v0.54.0
  also: `protocols/toplevelExport: Support transparency in toplevel export (#12824)`
- v0.56.0: `protocols/toplevelExport: null-check pixel format (#15203)`,
  `screencopy: fix screenshare copyfb pending frames (#14837)`
  https://github.com/hyprwm/Hyprland/releases/tag/v0.56.0
- v0.52.0: minor screencopy format/color-management fixes only (no protocol additions).
- v0.53.0: `screencopy: fix possible crash in renderMon()` (bugfix only).

Gesture system:
- v0.55.0: `gestures: add live pinch cursor zoom (#14049)`, `gestures: add scroll_move (#14063)`
  https://github.com/hyprwm/Hyprland/releases/tag/v0.55.0
- v0.56.0: `config/lua: add lua-driven custom live gestures (#15393)` — this is the "new
  gesture config" moment: gestures become definable from Lua (`hl.gesture`), not a new
  touchpad-swipe conf keyword in the classic sense.
  https://github.com/hyprwm/Hyprland/releases/tag/v0.56.0
- v0.54.0: `gestures: add cursor zoom (#13033)`, `keybinds: add inhibiting gestures under
  shortcut inhibitors (#12692)`.

Animation tree:
- v0.55.0: `animations: add springs (#14171)`, `config/workspacerule: add animation style
  (#13380)`.
- v0.56.0: `renderer: add a motion blur option to windows (#14911)`.
- v0.53.0: internal-only (`animation: migrate PHLANIMVAR from SP to UP`, multi-refresh-rate
  fix) — no new config surface.

Drag-and-drop:
- v0.56.0: `input/dnd: fix touch-driven drag-and-drop (#15077)`,
  `protocols/xdg-shell: add support for xdg interactive drags (#15343)` — this is Wayland
  drag-and-drop protocol support (files/data between clients), not window-to-workspace
  dragging in an overview.
- v0.52.0: `protocols/core: round dnd drop surface box`, `xwm: attempt to guess mime in
  sendData for DnD` — same category, unrelated to window management.
- No release adds a dispatcher or input mode for dragging a *window* between workspaces by
  mouse in an overview; that remains a plugin-space concern (hyprexpo's own gesture/click
  picker did this internally, not exposed as a general API).

Lua API additions relevant to an overview tool (from CHANGELOG grep of v0.55.0/v0.56.0):
`config/lua: init lua config manager (#13817)` (0.55.0, introduces the runtime),
`config/lua: add change_id workspace API (#15298)`, `config/lua: add get_loaded_plugins
(#14582)`, `config/lua: add is_key_down and a key event (#14779)`, `lua/monitor: add set_
functions for raw workspace management (#14875)` (all 0.56.0).

## 2. Lua config runtime (hl.*)

Introduced v0.55.0 (`config/lua: init lua config manager, use lua if available`, #13817);
Lua is now the default config format if no `hyprland.conf` is present. Doc page:
https://wiki.hypr.land/configuring/core/advanced-configuration/lua-utilities/ (partial
verbatim access only — see caveat). Ground truth used instead: Hyprland's own stub
generator `meta/generateLuaStubs.py`, which emits `meta/hl.meta.lua` from the actual C++
bindings in `src/config/lua/**` — this is as authoritative as documentation gets, being
generated directly from the binding source.

Full top-level `hl.*` function surface (from `meta/generateLuaStubs.py`, lines ~522-564):
`hl.on`, `hl.bind`, `hl.dispatch`, `hl.define_submap`, `hl.timer`, `hl.config`,
`hl.get_config`, `hl.device`, `hl.monitor`, `hl.window_rule`, `hl.layer_rule`,
`hl.workspace_rule`, `hl.permission`, `hl.gesture`, `hl.get_windows`, `hl.get_window`,
`hl.get_active_window`, `hl.get_urgent_window`, `hl.get_workspaces`, `hl.get_workspace`,
`hl.get_active_workspace`, `hl.get_active_special_workspace`, `hl.get_monitors`,
`hl.get_monitor`, `hl.get_active_monitor`, `hl.get_monitor_at`, `hl.get_monitor_at_cursor`,
`hl.get_layers`, `hl.get_workspace_windows`, `hl.get_cursor_pos`, `hl.get_last_window`,
`hl.get_last_workspace`, `hl.get_current_submap`, `hl.notification.create`,
`hl.notification.get`, `hl.layout.register`, `hl.exec_cmd`, `hl.get_loaded_plugins`,
`hl.is_key_down`, `hl.version`, `hl.clear_crashed_lockscreen`,
`hl.exec_scheduled_prop_refresh_immediately`, `hl.unbind`.

`hl.dsp.*` dispatcher namespace (from `src/config/lua/bindings/LuaBindingsDispatchers.cpp`,
function `hlWindowMove` etc. registered under `lua_setfield(L, -2, "window")` /
`"workspace"` / `"cursor"` / `"group"`):
- `hl.dsp.cursor.move`, `hl.dsp.cursor.move_to_corner`
- `hl.dsp.group.move_window`
- `hl.dsp.window.close`, `.kill`, `.signal`, `.float`, `.fullscreen`, `.fullscreen_state`,
  `.pseudo`, `.move`, `.swap`, `.center`, `.cycle_next`, `.tag`, `.clear_tags`,
  `.toggle_swallow`, `.pin`, `.bring_to_top`, `.alter_zorder`, `.set_prop`,
  `.deny_from_group`, `.drag`, `.resize`
- `hl.dsp.workspace.rename`, `.change_id`, `.move`, `.swap_monitors`, `.toggle_special`

`hl.window.move({x=.., y=.., relative=bool})` supports absolute or relative pixel
coordinates (verified in `hlWindowMove`, which builds a `dsp_move` closure taking x, y,
relative). `hl.window.resize(...)` exists as a sibling dispatcher (`hlWindowResize`).
`hl.window.set_prop({prop=.., value=..})` maps to the same underlying prop system as the
classic `setprop` dispatcher, whose settable window-rule props include `noanim` (confirmed
in `src/desktop/rule/windowRule/WindowRuleApplicator.cpp` and `.hpp`).

`hl.on` events — full documented list, extracted from `EVENTS` set in
`src/config/lua/LuaEventHandler.cpp`: `window.open`, `window.open_early`, `window.close`,
`window.destroy`, `window.kill`, `window.active`, `window.urgent`, `window.title`,
`window.class`, `window.pin`, `window.fullscreen`, `window.update_rules`,
`window.move_to_workspace`, `window.bell`, `window.minimize`, `layer.opened`,
`layer.closed`, `monitor.added`, `monitor.removed`, `monitor.focused`,
`monitor.layout_changed`, `workspace.active`, `workspace.special_active`,
`workspace.created`, `workspace.removed`, `workspace.move_to_monitor`, `config.reloaded`,
`config.props_refreshed`, `config.unload`, `keybinds.submap`, `screenshare.state`,
`hyprland.start`, `hyprland.shutdown`, `input.keyboard.key` (plus any plugin-registered
custom events). **There is no pointer/mouse/drag event in this set** — no
`pointer.move`, `mouse.button`, or drag-related event exists.

`hl.timer(callback, opts)` exists (`src/config/lua/objects/LuaTimer.cpp`) and can be
combined with `hl.window.move`/`hl.window.resize`/`hl.window.set_prop({prop="noanim",
value="1"})` to animate-free-move/resize a window on a schedule.

**Direct answers:**
- Can Lua move/resize windows on a timer with animation disabled? **Yes.**
  `hl.timer` + `hl.dispatch(hl.dsp.window.move({...}))` /
  `hl.dispatch(hl.dsp.window.resize({...}))`, with `hl.dispatch(hl.dsp.window.set_prop({prop
  = "noanim", value = "1"}))` to kill per-window animation first.
- Can Lua render anything or draw overlays? **No.** No `hl.render`, `hl.draw`, `hl.canvas`,
  or similar exists anywhere in the stub generator's function list or the bindings source
  tree (`src/config/lua/bindings/*`, `src/config/lua/objects/*`).
- Can Lua receive pointer/drag events? **No.** Confirmed absent from the `EVENTS` set above;
  only `input.keyboard.key` exists for input, and it is keyboard-only.
- `hl.animation` / `hl.curve` / `hl.plugin.load`: **not documented / do not exist.** Not
  present in the generated stub function list. Only `hl.get_loaded_plugins` (read-only query)
  exists; there is no Lua-side plugin loader.

## 3. C++ plugin API (0.56)

Not stable across minor (or even patch) versions — plugins must be rebuilt per Hyprland
build. Evidence:
- `src/plugins/PluginAPI.hpp:21`: `#define HYPRLAND_API_VERSION "0.1"` — a hand-set string,
  unchanged for a long time; `src/plugins/PluginSystem.cpp:100` rejects a plugin only if this
  string differs (`if (PLUGINAPIVER != HYPRLAND_API_VERSION)`), which is a coarse check, not
  real ABI verification.
- The real compatibility gate is in `hyprpm` (`hyprpm/src/core/PluginManager.cpp`), which
  queries Hyprland over its IPC socket for `commit`, `abiHash`, `commit_date`, `commits`
  (`hlcommit`, `abiHash`, `hldate`, `hlcommits`), matches manifest **commit pins**
  (`pManifest->m_repository.commitPins`, keyed by exact commit hash `HLVER.hash`), and runs
  `headersValid()` against locally-cloned/checked-out Hyprland headers before building.
  This is a per-commit source match, not a stable ABI.
- Headers are installed to `${CMAKE_INSTALL_INCLUDEDIR}/hyprland`, i.e. `/usr/include/hyprland`
  (top-level `CMakeLists.txt` lines 693/701).
- Corroborating real-world evidence: hyprland-plugins' commit history is dominated by
  recurring `chase hyprland` commits (e.g. `borders/bars/focus: chase hyprland (#699)`,
  `hyprbars: chase hyprland (#702)`, dated through Sept 2026), and by explicit per-release
  pin commits (`hyprpm: add pin for 0.56.2`, `hyprpm: add pins for 0.56.0 and .1`).

Rendering hooks pattern (from hyprexpo, the canonical example — see caveat below on its
removal): plugins call `HyprlandAPI::findFunctionsByName(PHANDLE, "renderWorkspace")` to
locate and hook the internal `CHyprRenderer::renderWorkspace` function by name (not a stable
vtable/interface), then render each workspace off-screen into their own framebuffer using
`Render::GL::g_pHyprOpenGL` (`g_pHyprOpenGL->makeEGLCurrent()`,
`g_pHyprRenderer->renderWorkspace(PMONITOR, PWORKSPACE, now, monbox)` into a
plugin-owned FBO built in `ensureFramebuffer()`), and composite the result into the live
scene through a custom `IPassElement` added to the render pass
(`g_pHyprRenderer->m_renderPass.add(makeUnique<COverviewPassElement>())`, which then calls
`Render::GL::g_pHyprOpenGL->renderTextureInternal(image.fb->getTexture(), ...)`).

**hyprexpo status: it no longer exists in hyprwm/hyprland-plugins.** It was removed on
2026-05-12 in commit `3aa21f2e0ca72412f1b434c3126f8f1fec3c716c` / PR #663
(https://github.com/hyprwm/hyprland-plugins/pull/663), titled "all: drop unmaintained
plugins", with the maintainer's stated reason: "I am doing a shit job at maintaining them
and no longer wish to do so." hyprwinwrap was dropped in the same commit. Confirmed by
issues #670 ("what happened to hyprexpo",
https://github.com/hyprwm/hyprland-plugins/issues/670) and #672 ("Hyprexpo missing from
repository?"). The current top-level plugin list in hyprwm/hyprland-plugins main is only:
`borders-plus-plus`, `csgo-vulkan-fix`, `hyprbars`, `hyprfocus`. Community forks have taken
over maintenance: `colonelpanic8/hyprexpo` ("standalone maintained fork"),
`sandwichfarm/hyprexpo` ("the original hyprexpo fork"), and separate reimplementations
`btijs/hyprspace` / `KZDKM/Hyprspace` ("Workspace overview plugin for Hyprland"). Source
citations above are taken from the last pre-removal commit
(`eaf18d55d51cef00818c5a4fdd4170f8cc2de4dc`) at paths `hyprexpo/main.cpp`,
`hyprexpo/overview.cpp`, `hyprexpo/overview.hpp`, `hyprexpo/OverviewPassElement.cpp/.hpp`,
`hyprexpo/ExpoGesture.cpp/.hpp`, `hyprexpo/globals.hpp` — i.e. it does NOT currently build
against 0.56 as an hyprwm-maintained artifact; whether the community forks track 0.56 was
not separately verified in this pass.

## 4. Screen capture protocols for live thumbnails (0.56)

All present in `src/protocols/` on main: `Screencopy.cpp/.hpp` (wlr-screencopy-unstable-v1,
XML at `protocols/wlr-screencopy-unstable-v1.xml`), `ToplevelExport.cpp/.hpp`
(hyprland-toplevel-export-v1 — **still present, not deprecated**; handles both
`setCaptureToplevel` and a wlr-foreign-toplevel-handle variant), `ImageCopyCapture.cpp/.hpp`
(ext-image-copy-capture-v1) and `ImageCaptureSource.cpp/.hpp` (ext-image-capture-source-v1,
including `CToplevelImageCaptureSourceProtocol` /
`ext_foreign_toplevel_image_capture_source_manager_v1_interface` — the "foreign toplevel
image capture source" building on `ext-foreign-toplevel-list-v1`, implemented in
`ImageCaptureSource.cpp`, `#include "ForeignToplevel.hpp"`). image-capture-source-v1 and
image-copy-capture-v1 were added in v0.54.0 (PR #11709); no evidence either is being phased
out.

**Hidden/inactive-workspace windows are still rendered for export.** The capture path is
`src/managers/screenshare/ScreenshareFrame.cpp`, function `CScreenshareFrame::renderWindow()`
(line ~320), which calls:
```
g_pHyprRenderer->renderWindow(PWINDOW, PMONITOR, NOW, false, Render::RENDER_PASS_ALL, true, true);
```
The `renderWindow` signature (`src/render/Renderer.hpp:273`) is:
```
void renderWindow(PHLWINDOW, PHLMONITOR, const Time::steady_tp&, bool, eRenderPassMode, bool ignorePosition = false, bool standalone = false);
```
The last two `true, true` arguments are `ignorePosition=true, standalone=true` — this
renders the window's contents directly into an off-screen target regardless of whether it
would normally be visible on screen. The code only calls `shouldRenderWindow()` to decide
whether to *block surface feedback* (`m_bBlockSurfaceFeedback`, to avoid double frame
callbacks when the window is also visibly on-screen) — it does not gate whether the capture
happens. So a window on a non-active workspace is captured. A window fully obscured behind a
fullscreen window on the *same* visible workspace is also captured this way, since
`standalone` rendering bypasses normal stacking/visibility entirely; the code does add a
special case for `Fullscreen::controller()->isFullscreen(w, FSMODE_FULLSCREEN)` when drawing
window-share "black box" occlusion for privacy (`noScreenShare` rule masking), which is
unrelated to whether the frame itself is produced.

## 5. Dispatchers/props/JSON for an overlay-based approach

Confirmed to exist in current source (`hyprctl/hyprctl.usage`, generated from Hyprland's own
dispatcher table): `movetoworkspacesilent` — "Move window doesn't switch to the workspace";
`focuswindow` — "Focus the first window matching"; `pin` (emits an IPC `pin` event per
`src/ipc/s1/Commands.cpp:280`); `setprop` (underlies `hl.window.set_prop` in Lua).

`hyprctl clients -j` fields, confirmed directly in the JSON-emitting format strings in
`src/ipc/s1/Commands.cpp` (~lines 398-420): `address`, `hidden`, `at` (`[x, y]`), `size`
(`[w, h]`), `workspace` (`{address, ...}`), `floating`, `class`, `title`, `pinned`,
`fullscreen`. All of the fields the task asked about (`at`, `size`, `workspace`, `floating`,
`fullscreen`, `hidden`) are confirmed present.

Layer rule properties, confirmed in `src/desktop/rule/layerRule/LayerRuleApplicator.hpp`
(`DEFINE_PROP` list, lines 50-62): `noanim`, `blur`, `blurPopups`, `dimAround`, `xray`,
`noScreenShare`, `order` (int), `aboveLock` (int), `ignoreAlpha` (float), `animationStyle`
(string). **`ignorezero` is not documented and was not found anywhere in the Hyprland
source** (`gh` code search for the literal string returned zero hits in hyprwm/Hyprland) —
treat it as not existing; the properties relevant to a fullscreen overlay layer are
`noanim`, `blur`, `xray`, and `animationStyle`, not `ignorezero`.

`special:` workspace handling touches `src/config/shared/workspace/WorkspaceRuleManager.cpp`,
`src/state/workspace/Resolver.cpp`, and `src/state/workspace/State.cpp` (present, not
further inspected verbatim in this pass — see unverified list).

`hyprctl -j workspaces` / `-j monitors`: not independently field-verified in this pass (ran
out of scope) — see unverified list.

## Unverified

- Exact wiki.hypr.land prose for Dispatchers and Lua-utilities pages (movetoworkspacesilent,
  focuswindow, pin, setprop wording; full hl.* prose descriptions/parameter tables) — the
  live site did not yield body text to `curl` (JS-hydrated) or to WebFetch (partial/summarized
  extraction only). Substituted with direct C++ source citations instead, which are equally
  primary but not the wiki text itself.
- Whether community forks (`colonelpanic8/hyprexpo`, `sandwichfarm/hyprexpo`,
  `KZDKM/Hyprspace`, `btijs/hyprspace`) currently build cleanly against Hyprland 0.56.2 —
  not checked.
- Exact field list returned by `hyprctl -j workspaces` and `hyprctl -j monitors` — files
  identified (`src/ipc/s1/Commands.cpp`) but fields not individually grepped/quoted.
- `special:` workspace dispatcher/behavior details beyond confirming the relevant source
  files exist.
- Whether `hyprland-toplevel-export-v1` carries any deprecation notice in its own protocol
  XML header comment (file path not located in this pass; wayland.app listing describes it
  as current, no deprecation language found in search results).
- No v0.50.x release tag was found on the GitHub releases list (it starts at v0.51.1 in the
  fetched window); whether an 0.50.0 exists further back was not separately checked.
