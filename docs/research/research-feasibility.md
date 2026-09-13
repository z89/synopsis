# Mission Control on Hyprland 0.56.2 — architecture feasibility research

Date: 2026-09-13. Everything below was verified by reading source or by querying the GitHub
API today. Where I could not verify something, it says so explicitly.

Measured local target (`hyprctl -j monitors|clients`, `lspci`, `pacman -Q`, local DMS tree):

- Hyprland 0.56.2, commit `efb50993780079460b0cbed1363e2166a2de1d9f`, built 2026-08-05.
- One monitor **now**: DP-2, 5120x1440 @ 119.97 Hz, scale 1. User expects a second.
- GPU: **AMD Navi 23 / Radeon RX 6600** (`03:00.0`, `1002:73ff`), radeonsi.
- 14 mapped clients across 7 workspaces. Realistic worst case ~15-20 captures, not 30.
- quickshell 0.3.1-1, hyprland 0.56.2-3.
- **DankMaterialShell locally is v1.7-beta** (patched tree at
  `~/.local/share/dms-shell-patched`, stock cache `~/.cache/dms-shell-stock/c1f1da1`).

---

## 0. The finding that reorders everything

**DankMaterialShell already ships architecture B, working, on this machine.**

`~/.local/share/dms-shell-patched/Modules/WorkspaceOverlays/`
- `HyprlandOverview.qml` (301 lines)
- `OverviewWidget.qml` (510 lines)
- `OverviewWindow.qml` (173 lines)
- `NiriOverviewOverlay.qml` (442 lines)

It has: one `PanelWindow` per screen via `Variants { model: Quickshell.screens }`,
`WlrLayershell.layer: WlrLayer.Overlay`, namespace `"dms:workspace-overview"`,
`exclusiveZone: -1`, `HyprlandFocusGrab`, **live `ScreencopyView` per window**, spring
animations on x/y/width/height, drag-and-drop onto workspace tiles with `DropArea`
highlighting, click-to-focus, middle-click-to-close, and an icon rendered over the capture
as a fallback.

So the question is not "can architecture B be built". It is "what is missing from the thing
that already exists", and the answer is short:

1. **No exposé.** Windows are drawn at their real positions scaled into each workspace cell
   (`rawX = (windowData.at[0] - contentOriginX) * overviewScale`). Nothing spreads the
   current workspace's windows into a non-overlapping layout. That is the actual Mission
   Control feature and it does not exist here.
2. **No first-frame gating.** `grep hasContent` over the whole directory returns nothing.
   `captureSource: root.overviewOpen ? root.toplevel?.wayland : null; live: true` — the
   capture is requested at the same moment the overlay becomes visible. The one-frame flash
   risk is unmitigated.
3. **No continuous handoff.** The overlay fades (`Behavior on opacity`) while a dim layer
   goes to 0.5; thumbnails spring from their clipped grid positions, not from their real
   full-screen rects. There is no "windows fly out of the real desktop" illusion.

---

## 1. Decisive verified facts

1. **Hyprland renders only the monitor's active workspace.** A plugin wanting another
   workspace drawn must temporarily make it active. Proven by hyprtasking's code + comment.
2. **Frame callbacks go only to views on the active workspace**
   (`IHyprRenderer::sendFrameEventsToWorkspace`, called only for `m_activeWorkspace` /
   `m_activeSpecialWorkspace`). This is the biggest threat to "video keeps playing in every
   thumbnail".
3. **`hyprexpo` no longer exists.** Deleted from `hyprwm/hyprland-plugins` 2026-05-12,
   commit `3aa21f2e`, "all: drop unmaintained plugins (#663)", three days after Hyprland
   0.55.0. `raw.githubusercontent.com/.../main/hyprexpo/main.cpp` → **HTTP 404**. Maintainer
   in issue #672 (closed 2026-05-19): "it's been removed. It was unmaintained."
4. **`KZDKM/Hyprspace` has been broken on 0.56.x since 0.56.0 shipped** (2026-07-20). Open:
   #239, #240, #241. Last commit 2026-05-28.
5. **`raybbian/hyprtasking` works on 0.56.2** — `hyprpm.toml:5` pins our exact compositor
   commit. But that pin landed 2026-09-07/09: **33-35 days of the plugin being unusable**.
6. **There is no stable plugin ABI.** `src/plugins/PluginAPI.hpp:21` is still
   `#define HYPRLAND_API_VERSION "0.1"` — a constant, never bumped. Real compatibility is
   `hyprpm` matching the compositor's exact git commit + abiHash against a manifest pin.
7. **Quickshell 0.3.1 can capture only a `ShellScreen` or a `Toplevel`.** No workspace
   source. Per-window composition is the only route to a non-active-workspace thumbnail.
8. **`no_screen_share` is a real rule key** in 0.56.2's Lua config bindings, and monitor
   capture honours it — the feedback-loop fix, if output capture were ever used.
9. **No existing plugin does a macOS exposé.** hyprexpo / hyprtasking / Hyprspace are all
   workspace-grid zoom-out. The non-overlapping spread is new code in every architecture.
10. **A version-matched, reproducible crash exists for the live-capture approach:**
    quickshell-mirror/quickshell **#1123** (open), filed against Quickshell 0.3.1 +
    Hyprland 0.56.2.

---

## 2. Architecture A — C++ compositor plugin

### 2.1 How it actually renders (correcting the premise in the brief)

The brief assumed "renderWorkspace into a CFramebuffer, then blit scaled". That was old
hyprexpo. **hyprtasking on 0.56 uses no offscreen framebuffer for workspaces.** It renders
into the compositor's live render pass with a transform.

`raw.githubusercontent.com/raybbian/hyprtasking/main/src/render.cpp`:

    void render_workspace_at_box(PHLMONITOR monitor, PHLWORKSPACE workspace,
                                 const Time::steady_tp& time, CBox box) {
        const float ws_scale = box.w / monitor->m_transformedSize.x;
        CBox render_box = {box.pos() / ws_scale, box.size()};
        if (monitor->m_transform % 2 == 1) std::swap(render_box.w, render_box.h);

        // Hyprland only fully renders the monitor's active workspace, so make this one
        // active+visible while we render it. The caller restores the original active ws.
        if (workspace != nullptr) {
            monitor->m_activeWorkspace = workspace;
            Animation::Workspace::startAnimation(workspace, ANIMATION_TYPE_IN, false, true);
            workspace->m_visible = true;
        }
        ((render_workspace_t)(render_workspace_hook->m_original))(
            g_pHyprRenderer.get(), monitor, workspace, time, render_box);
        ...
    }

and for the single dragged window:

    void render_window_at_box(PHLWINDOW window, PHLMONITOR monitor,
                              const Time::steady_tp& time, CBox box) {
        const float scale = box.w / window->sizeAnimation()->value().x;
        const Vector2D transform = (monitor->m_position - window->positionAnimation()->value()
                                    + box.pos() / scale) * monitor->m_scale;
        SRenderModifData data{};
        data.modifs.push_back({RMOD_TYPE_TRANSLATE, transform});
        data.modifs.push_back({RMOD_TYPE_SCALE, scale});
        g_pHyprRenderer->m_renderPass.add(makeUnique<CRendererHintsPassElement>(...));
        g_pHyprRenderer->damageWindow(window);
        ((render_window_t)render_window)(g_pHyprRenderer.get(), window, monitor, time, true,
                                         RENDER_PASS_MAIN, false, true);
    }

Consequence: **genuinely live**, no copy, no dmabuf round trip, no client latency. Because
the workspace is momentarily active while rendered, `sendFrameEventsToWorkspace` delivers
frame callbacks to its windows, so video keeps playing. **This is architecture A's one hard
advantage and B cannot replicate it.**

`src/layout/grid.cpp:508` `HTLayoutGrid::render()` — background rect, one
`render_workspace_at_box` per grid cell, one `render_window_at_box` for the dragged window.
No `CFramebuffer` allocation for workspaces anywhere in the repo.

### 2.2 Animation

`src/layout/grid.cpp:36-48` — two `CAnimatedVariable`s on Hyprland's animation manager,
reusing the user's `workspaces` animation config:

    Animation::mgr()->createAnimation({0,0}, offset,
        anim_tree->getAnimationPropertyConfig("workspaces"), AVARDAMAGE_NONE);
    Animation::mgr()->createAnimation(1.f, scale,
        anim_tree->getAnimationPropertyConfig("workspaces"), AVARDAMAGE_NONE);

A single pan+zoom of a workspace grid. Not a per-window exposé.

### 2.3 Input / drag-drop

`src/input.cpp` does not implement its own drag. It hijacks Hyprland's internal drag
controller and warps the pointer:

- `start_window_drag()`: `cursor_monitor->changeWorkspace(cursor_workspace, true)`, then
  `Pointer::mgr()->warpTo(workspace_coords)`, then reads
  `g_layoutManager->dragController()->target()` and remaps the window's `positionAnimation()`
  value and goal to undo scale-around-mouse.
- `end_window_drag()`: resolves the workspace under the cursor, creates it if empty
  (`State::workspaceState()->create(...)`), then
  `Desktop::globalWindowController()->moveWindowToWorkspace(dragged_window, cursor_workspace)`.

All private internal APIs. This is the source of the breakage churn.

### 2.4 Hook surface = fragility, counted

`src/main.cpp:595-690` installs **seven** hooks by mangled-symbol lookup
(`HyprlandAPI::findFunctionsByName` + `createFunctionHook`): `renderWorkspace`,
`renderTexture`, `renderBorder`, `renderBorder` (2-gradient overload), the
blur-optimizations predicate, `shouldRenderWindow`, `isSolitaryBlocked`. Any signature
change → `fail_exit("Failed initializing hooks")`. That exact failure is hyprtasking #128,
"Failed initializing hooks on Hyprland 0.56.2".

`src/hyprland-version-compat.hpp.in` + `meson.build` regenerate a compat header from the
**live pkg-config versions** of aquamarine / hyprutils / hyprlang / hyprcursor /
hyprgraphics, because the plugin ABI hash must match what the compositor was built against.
**A bump of aquamarine alone, with no Hyprland release at all, breaks the plugin.** That is
hyprtasking #127 and hyprland-plugins #705 (2026-09-09, "stale Aquamarine header cache
causes version mismatch for all plugins").

### 2.5 Measured lag behind Hyprland releases

Release dates from `api.github.com/repos/hyprwm/Hyprland/releases`.

| Hyprland | released | hyprtasking fix | lag | Hyprspace | hyprexpo |
|---|---|---|---|---|---|
| 0.54.0 | 2026-02-27 | `9d716263` 2026-03-02 | 3 d | 3 d, full PR +33 d | prep 2026-02-23 |
| 0.55.0 | 2026-05-09 | #114 closed 2026-05-11 | 2 d | 2 d, crash follow-ups to 05-15 | **deleted 2026-05-12** |
| 0.56.0 | 2026-07-20 | `d3c77cd4` same day | 0 d | **never — #239 open 55 d** | n/a |
| 0.56.1 | 2026-07-27 | #124 closed 2026-07-29 | 2 d | never | n/a |
| 0.56.2 | 2026-08-05 | pin `4d3c3951` 2026-09-07/09 | **33-35 d** | **never — #240/#241 open** | n/a |

Open crash issues: Hyprspace #227 (crashes immediately after enabling), #206, #176, #218
(crash on gesture). hyprland-plugins #504 (hyprexpo crash with many terminals, open since
2025-10-07), #639 (hyprexpo multi-monitor crash, closed). hyprtasking #91, #26, #32 (closed).

A plugin crash is a compositor crash: every window on the machine dies.

### 2.6 Multi-monitor

hyprtasking is per-monitor by construction: `HTView(MONITORID)`, one view per monitor in
`HTManager`, `get_monitor()` by id, grid filters `w->monitorID() != view_id`. Known-good
pattern. Also the source of hyprland-plugins #639.

### 2.7 UI chrome

A plugin draws with `CRectPassElement`, `CTexPassElement`, `CBorderPassElement`. No text
layout, no font stack, no theming, no Material palette. hyprtasking's "jump labels" are
`label_color` / `label_background` / `label_size` config ints — that is the ceiling.
**A plugin cannot host DMS-quality chrome.** Getting DMS styling means rendering chrome in
Quickshell anyway, i.e. architecture C.

---

## 3. Architecture B — Quickshell/DMS layer-shell overlay

### 3.1 Does Hyprland render an occluded / off-workspace toplevel for export?

**Yes, the pixels are produced on demand.** `src/managers/screenshare/ScreenshareFrame.cpp:316-333`
(v0.56.2 — note ToplevelExport.cpp was refactored in 0.56 to delegate to `ScreenshareManager`):

    void CScreenshareFrame::renderWindow() {
        ...
        g_pHyprRenderer->m_renderData.fbSize = m_bufferSize;
        g_pHyprRenderer->setProjectionType(Render::RPT_EXPORT);
        g_pHyprRenderer->setViewport(0, 0, m_bufferSize.x, m_bufferSize.y);
        // block the feedback to avoid spamming the surface if it's visible
        g_pHyprRenderer->m_bBlockSurfaceFeedback = g_pHyprRenderer->shouldRenderWindow(PWINDOW);
        g_pHyprRenderer->renderWindow(PWINDOW, PMONITOR, NOW, false, Render::RENDER_PASS_ALL, true, true);
        g_pHyprRenderer->m_bBlockSurfaceFeedback = false;
    }

with `copyDmabuf()` doing `beginRender(monitor, damage, RENDER_MODE_TO_BUFFER, m_buffer, nullptr, true)`
→ `render()` → `endRender(...)` (line 397). **No visibility or occlusion early-out in the
SHARE_WINDOW path.** `shouldRenderWindow` is used only to decide feedback blocking.
Hyprland discussion #13332 states the same design intent: toplevel-export "cleanly captures a
specific toplevel window regardless of overlap or visibility".

**But that only re-renders the client's last committed buffer.** It does not make the client
draw anything new.

### 3.2 The real problem: frame callbacks

`src/render/Renderer.cpp:2205-2209`:

    } else if (!pMonitor->isMirror()) {
        if (pMonitor->m_activeWorkspace)        sendFrameEventsToWorkspace(pMonitor, pMonitor->m_activeWorkspace, NOW);
        if (pMonitor->m_activeSpecialWorkspace) sendFrameEventsToWorkspace(pMonitor, pMonitor->m_activeSpecialWorkspace, NOW);
    }

`src/render/Renderer.cpp:2511-2518`:

    void IHyprRenderer::sendFrameEventsToWorkspace(PHLMONITOR pMonitor, PHLWORKSPACE pWorkspace, const Time::steady_tp& now) {
        for (const auto& view : Desktop::View::getViewsForWorkspace(pWorkspace)) {
            if (!view->aliveAndVisible()) continue;
            view->wlSurface()->resource()->frame(now);
        }
    }

The other unblocked path is `CSurfacePassElement::discard()`
(`src/render/pass/SurfacePassElement.cpp:181-186`), which calls
`presentFeedback(..., discarded=true)`, and `presentFeedback` calls `frame(when)`
(`src/protocols/core/Compositor.cpp:795-797`; `frame()` at `:369-378` sends the
`wl_callback`s). But `discard()` runs **only for pass elements the pass culled**
(`src/render/pass/Pass.cpp:187-191`), not for elements that were drawn.

**Code-verified conclusion (not empirically tested):** a window on an inactive workspace
captured via `hyprland-toplevel-export-v1` yields a correctly-rendered but **stale** image.
A client that paces on frame callbacks (mpv, Firefox, Chromium, most GTK/Qt apps) will not
advance; the thumbnail freezes on its last frame. Clients that render on their own timer may
keep moving.

For windows on the **active** workspace under the overlay, the export path blocks feedback
(`shouldRenderWindow` true) but `sendFrameEventsToWorkspace` still fires normally, so they
keep painting. Likely observed behaviour: **current workspace live, other workspaces frozen.**

A subagent trawl found **no** issue on quickshell or Hyprland explicitly confirming or
denying continued frame delivery for a non-focused-workspace window. Unresolved either way in
the field. My code reading says frozen. Treat as the #1 prototype question.

### 3.3 Whole-workspace thumbnails for non-active workspaces

Not available. `src/wayland/screencopy/manager.cpp:27-57` accepts exactly two source types:

- `QuickshellScreenInfo` (a `ShellScreen`) → ext-image-copy-capture, else wlr-screencopy.
  Captures the output **as currently composited** — active workspace only, and it would
  include the overlay itself.
- `toplevel::Toplevel` → `HyprlandScreencopyManager::captureToplevel(handle, paintCursors)`
  → `hyprland-toplevel-export-v1`.

`CScreenshareFrame::renderMonitor()` iterates windows with
`if (!g_pHyprRenderer->shouldRenderWindow(w, PMONITOR)) continue;` — confirming output
capture can never show an inactive workspace.

**Workaround (the only one), already implemented in DMS:** compose each workspace thumbnail
in QML. One `Item` per workspace at the monitor's aspect ratio, one `ScreencopyView` per
`Toplevel` on it, positioned from `HyprlandToplevel.lastIpcObject.at/size`. DMS's
`OverviewWindow.qml`:

    readonly property real rawX: ((windowData?.at?.[0] ?? 0) - contentOriginX) * overviewScale
    readonly property real rawY: ((windowData?.at?.[1] ?? 0) - contentOriginY) * overviewScale
    readonly property real rawWidth:  (windowData?.size?.[0] ?? 100) * overviewScale
    readonly property real rawHeight: (windowData?.size?.[1] ?? 100) * overviewScale

`lastIpcObject` is **not live** — Quickshell's own header warns: "This is *not* updated
unless the toplevel object is fetched again from Hyprland … run `Hyprland.refreshToplevels()`
and wait for this property to update"
(`src/wayland/hyprland/ipc/hyprland_toplevel.hpp:40-45`). So one refresh on open; the layout
is a snapshot. Missing from the composition: wallpaper, layer-shell bars, shadows, rounded
corners, blur, borders. Fake the wallpaper (already available), skip the rest.

Toplevel ↔ Hyprland address linking is supported: `HyprlandToplevel` is an attached object
of `Quickshell.Wayland.Toplevel` (`address`, `handle`, `wayland`, `workspace`, `monitor`),
backed by `hyprland-toplevel-mapping-v1`
(`src/wayland/hyprland/ipc/toplevel_mapping.cpp`).

### 3.4 Cost of 10-30 simultaneous live captures

Mechanism, verified: `CScreenshareManager::onOutputCommit(monitor)` is called from
`src/output/Monitor.cpp:131` on every output commit. For each pending frame whose session
monitor matches, `frame->copy()` runs — for SHARE_WINDOW a full re-render of that window into
its own dmabuf **at the window's full pixel size**. There is no scaled-capture request in
`hyprland-toplevel-export-v1`: `m_resource->sendBuffer(fmt, bufSize.x, bufSize.y, stride)`.
Quickshell swaps (`mSwapchain.swapBuffers()`, `hyprland_screencopy.cpp:126`) and QML scales
down.

On this box, worst case per frame at 120 Hz: ~14 window re-renders totalling roughly 1-3x the
5120x1440 screen area, plus 14 dmabuf swaps and 14 QSG nodes. Plausibly 2-6 ms extra GPU per
frame on an RX 6600 — probably inside the 8.3 ms budget, **but this is an estimate, not a
measurement.** Two large monitors roughly doubles it. **No AMD-specific numbers were found in
the field — NOT VERIFIED.**

Mitigations: `live: false` + `captureFrame()` on a 10-15 Hz `Timer` for non-hovered
thumbnails; `live: true` only for hovered/animating ones. The loop is client-driven
(`hyprland_toplevel_export_frame_v1_ready` → `frameCaptured()` → re-request), so it is
throttleable. DMS currently sets `live: true` unconditionally for every window in the overview.

Additional gotcha: `g_pHyprRenderer->m_directScanoutBlocked = true` whenever any frame is
pending (`ScreenshareSession::nextFrame`, `:170-180`). Fine for a transient overview; bad if
captures are kept warm.

**Cadence gotcha:** only the **first** frame of a session calls `scheduleFrame` +
`damageMonitor` (`m_isFirst = !m_sharing`, `ScreenshareFrame.cpp:120-135`). After that, the
capture rate is exactly the output commit rate. If the overview sits open and idle with no
animation, nothing damages the output, the monitor stops committing, and every thumbnail
freezes. Fix: keep a 1px always-animating element alive for the lifetime of the overview.

### 3.5 paintCursor

`ScreencopyView.paintCursor` exists (`src/wayland/screencopy/view.hpp`), default false, maps
to the protocol's `overlay_cursor`. Hyprland's SHARE_WINDOW path draws the cursor only if the
pointer surface intersects the window **and** the window is focused
(`ScreenshareFrame.cpp:344-356`; cf. Hyprland #9042). Leave it false.

### 3.6 Feedback loop

Only a risk for `ShellScreen` capture, which this design does not use. `renderMonitor()`
skips a layer surface only when `l->m_ruleApplicator->noScreenShare()`
(`ScreenshareFrame.cpp` layer loop). **`no_screen_share` is a real rule key** — verified as a
string literal in `src/config/lua/bindings/LuaBindingsConfigRules.cpp`, alongside
`layer_rule`, `window_rule`, `xray`, `no_anim`, `blur`, `screencopy`, `permission`. Belt and
braces: put a `no_screen_share` layer rule on `dms:workspace-overview`.

### 3.7 Real windows underneath, focus, keyboard grab

Keep them; just cover them. DMS already does this correctly: `WlrLayer.Overlay`,
`exclusiveZone: -1`, `keyboardFocus` switched conditionally, and `HyprlandFocusGrab` when
`CompositorService.useHyprlandFocusGrab`. `WlrKeyboardFocus.Exclusive` is documented as
"Exclusive access to the keyboard, locking out all other windows"; `OnDemand` carries a
warning that it "may cause the shell window to never lose focus"
(`src/wayland/wlr_layershell/wlr_layershell.hpp:47-69`). Use `Exclusive`, drop to `None` on
close, and explicitly refocus on exit.

### 3.8 Input and gesture trigger

Hover/click/drag are ordinary QML — this is where B wins outright. DMS's `OverviewWidget.qml`
already has `Drag`/`DropArea` with `draggingFromWorkspace` / `draggingTargetWorkspace`,
hover highlighting (`hoveredWhileDragging`), and on drop:

    HyprlandService.moveToWorkspace(targetWorkspace, windowData?.address, false);
    Qt.callLater(() => { Hyprland.refreshToplevels(); Hyprland.refreshWorkspaces(); ... });

end-4/dots-hyprland dispatches the Lua form directly:
`Hyprland.dispatch("hl.dsp.window.move({ workspace = N, follow = false, window = \"address:0x…\" })")`.

Touchpad trigger: Hyprland 0.56's Lua config has first-class gestures — `gesture`, `fingers`,
`direction`, `disable_inhibit`, `mods` all appear in the `LuaBindingsConfigRules` string
table. Bind a 4-finger swipe to a dispatcher and signal the shell over IPC, or expose
`hl.plugin.<ns>.<fn>` from a plugin (see 4.1).

### 3.9 Handoff illusion

`hasContent` is exactly the right gate: "If true, the view has content ready to display.
Content is not always immediately available, and this property can be used to avoid
displaying it until ready." `sourceSize` is valid only when `hasContent`. **DMS does not use
it at all.**

Correct open sequence:
1. `Hyprland.refreshToplevels()`; await the `lastIpcObject` update (IPC round trip, ~ms).
2. Create the overlay at `opacity: 0`, transparent, every `ScreencopyView` positioned at its
   real full-screen rect, `live: true`.
3. Wait until every visible-workspace view has `hasContent === true` (a count binding plus a
   ~150 ms watchdog so one slow client can't hang it).
4. Only then raise overlay opacity and start the exposé animation.

Residual seam risks, all real:
- Between step 3 and the compositor presenting the overlay, the underlying window may have
  repainted — the thumbnail is one frame stale. ~8 ms at 120 Hz; invisible for static
  content, visible as a hitch over playing video.
- The overlay's commit and the capture's ready are not synchronised, and there is no
  cross-surface atomic commit available to a layer-shell client. **The seam cannot be fully
  eliminated from the client side.** A plugin can, being inside the same render pass.
- Close is easier: animate back to real rects, then fade out over 1-2 frames.

### 3.10 Prior art and the crash that matters

- **end-4/dots-hyprland** — `.config/quickshell/ii/modules/ii/overview/`. **Icon-based, not
  live**: `OverviewWindow.qml` renders a `Rectangle` + `Image` from
  `Quickshell.iconPath(AppSearch.guessIcon(windowData?.class))`. No `ScreencopyView` in the
  module. Full drag-and-drop via `hl.dsp.window.move`. The conservative design.
- **DankMaterialShell** — live, as above. The aggressive design.
- **Shanu-Kumawat/quickshell-overview** — end-4's module with a `ScreencopyView` bolted on.
- **caelestia-dots/shell** — `modules/windowinfo/Preview.qml`, a single live
  `ScreencopyView { captureSource: root.client?.wayland; live: true }` for the active client
  only. No grid.
- **quickshell-mirror/quickshell #1123 (open)** — filed against **Quickshell 0.3.1 +
  Hyprland 0.56.2**, i.e. exactly this stack. A third-party overview with many concurrent
  `ScreencopyView{live:true}` triggers a race in Quickshell's client-side Wayland object-id
  allocator: an id is reused before the compositor confirms release, the compositor rejects
  with a fatal `wl_display` `invalid object` error, and **Qt's Wayland backend calls
  `_exit()` — the entire shell process dies**, not just the overview. Needs 4+ windows and
  repeated open/close. Non-deterministic.
- **hyprwm/Hyprland discussion #13324** — a different Quickshell overview crashes **Hyprland
  itself** when dragging a toplevel. Independent of #1123.
- Other `ScreencopyView` crashes: quickshell #679 (PRIME offload), #839 (NVIDIA
  `eglCreateImage EGL_BAD_MATCH` + null deref), #897 (segfault at session lock), #876 /
  #1094 (SIGSEGV toggling PanelWindow+ScreencopyView on niri), #193. All hybrid-GPU or
  lifecycle; **none AMD-specific**.

---

## 4. Architecture C — hybrid, and the Lua route

### 4.1 A plugin can expose itself to Lua — verified

`src/plugins/PluginAPI.hpp:357`:

    APICALL bool addLuaFunction(HANDLE handle, const std::string& namespace_,
                                const std::string& name, PLUGIN_LUA_FN fn);
    // "Unregister a plugin-owned Lua C callback from hl.plugin.<namespace>.<name>."

hyprtasking already uses it: `HyprlandAPI::addLuaFunction(PHANDLE, "hyprtasking", #name, lua_##name);`
(`src/main.cpp:719`). So a minimal plugin can be called straight from `hyprland.lua`, with
chrome left in DMS.

Problem with the **full** hybrid (plugin renders thumbnails, shell draws chrome): there is no
protocol for handing a compositor-side texture to a Quickshell client cheaply. You would
either have two compositing layers that must stay pixel-aligned and frame-synchronised (the
seam moves rather than disappears), or write a new protocol. Not worth it.

**C-lite is worth it.** A tiny plugin whose only job is to send frame callbacks to windows on
inactive workspaces while the overview is open. Roughly:

    // per compositor frame, for each workspace with an active capture session:
    for (const auto& view : Desktop::View::getViewsForWorkspace(ws))
        if (view->aliveAndVisible()) view->wlSurface()->resource()->frame(now);

No hooks — a per-frame tick callback plus one public-ish call. It fixes the single defect
(3.2) that makes B's thumbnails freeze. Small enough to re-fix in an hour when Hyprland
breaks it, and if it fails to load the overview degrades to static thumbnails rather than
dying.

### 4.2 Real exposé by physically moving windows (`hl.dsp.window.move/resize`)

Verified present. `src/config/lua/bindings/LuaBindingsDispatchers.cpp` string table contains
`dsp`, `window`, `move`, `resize`, `set_prop`, `float`, `floating`, `pin`, `alter_zorder`,
`bring_to_top`, `center`, `relative`, `keep_aspect_ratio`, `x`, `y`, `prop`, `value`.
`src/config/lua/objects/LuaWindow.cpp` exposes `at`, `size`, `x`, `y`, `width`, `floating`,
`fullscreen`, `pinned`, `workspace`, `monitor`, `address`, `hidden`, `mapped`, `visible`,
`perc_master`, `perc_size`. `no_anim` is a real rule key. Same machinery as carry.lua.

What breaks:

- **Tiled windows.** Every tiled window must be floated, moved, then restored. Hyprland's
  layout engine re-tiles the remainder each time one is floated, so restore is not a simple
  inverse — you fight `onWindowRemovedTiling` / `onWindowCreatedTiling` on every toggle.
  Dwindle split ratios and master percentages are not restored by float/unfloat. **Expect
  the tiling layout to be subtly destroyed.**
- **Clients get real `xdg_toplevel.configure` events.** Terminals reflow, browsers
  re-layout, Electron stutters, some apps lose scroll position. Not an animation — a
  relayout storm, at 120 Hz if driven on `hl.timer`. carry.lua gets away with it for **one**
  window; 14 at once is a different class of load.
- **Fullscreen windows** must be un- and re-fullscreened; video players often re-init decoders.
- **Other workspaces stay invisible.** This is an exposé of the current workspace only. The
  workspace strip still needs A or B.

Verdict: a usable *fallback* for the current workspace if thumbnails prove unworkable. Not
the primary mechanism.

### 4.3 Lua layout provider — underexplored

`src/config/lua/layout/LuaLayoutProvider.cpp` exists with `register`, `layout`,
`recalculate`, `layout_msg`. A custom Lua layout could own the exposé positions properly —
the layout engine stops fighting you because you *are* the layout engine. I have not read
enough of it to say whether it can animate. Flagged as an open question.

---

## 5. Ranking

**1. B, built as an extension of DMS's existing `Modules/WorkspaceOverlays/`.**
**2. C-lite (B + a ~50-line frame-callback plugin), only if the prototype shows frozen
   thumbnails and that turns out to matter.**
**3. A (full C++ plugin) — do not.**

Reasons in order of weight:

- **~70% of B already exists on this machine and works.** Per-monitor overlay, focus grab,
  live captures, drag-drop to workspaces, spring animation, DMS theming. The remaining work
  is an exposé layout function, a `hasContent` gate, and a real-rect open/close animation.
  Nothing in architecture A gives a comparable head start — and critically, **no plugin
  implements the exposé spread either**, so A starts from zero on the actual hard requirement.
- Everything except "live video on inactive workspaces" is easy in B and hard in A.
  Drag-and-drop with hit testing, drop targets, spring-back, DMS chrome, fonts, Material
  palette, rounded corners — free in QML. In a plugin, drag means hijacking Hyprland's
  internal drag controller and warping the pointer: ~500 lines of the most fragile code in
  hyprtasking.
- The maintenance arithmetic is decisive. hyprexpo is deleted. Hyprspace has been broken for
  55 days. hyprtasking, the healthiest and actively maintained, still went 33 days unusable
  after 0.56.2, and its own #127 shows a *dependency* bump alone breaks the ABI. A
  self-maintained plugin means the overview breaks on every `pacman -Syu` that touches
  hyprland or aquamarine — and when it breaks wrong, the compositor dies with every window.
- A's one genuine win is real: it is the only architecture where all workspaces are truly
  live, and the only one that can make open/close seamless, being inside the render pass.
- B is not risk-free either: quickshell #1123 is a version-matched crash that kills the whole
  shell under exactly this workload. But losing the shell is recoverable (DMS restarts);
  losing the compositor is not.

Likely outcome of B: the current workspace's windows animate live and correct (they are on
the active workspace, they keep getting frame callbacks); other workspaces show crisp but
static thumbnails of their last painted frame. For an overview open for ~2 seconds, that is
close enough to macOS in practice.

---

## 6. Risk table

| # | Risk | Arch | Severity | Mitigation |
|---|---|---|---|---|
| 1 | Inactive-workspace thumbnails freeze — `sendFrameEventsToWorkspace` covers active ws only | B | **High** | Prototype first. If it matters: C-lite plugin ticking `resource()->frame(now)` for views on captured inactive workspaces. Otherwise accept static thumbnails off-workspace, live on the current one. |
| 2 | quickshell #1123 — concurrent `ScreencopyView{live:true}` races the Wayland id allocator; Qt `_exit()`s the whole shell | B | **High** | Stagger capture creation (create views over several frames, not all in one); cap concurrent live views (`live:true` only for the current workspace + hovered, `captureFrame()` polling for the rest); destroy contexts on close; ensure DMS is supervised so it restarts. Track #1123. |
| 3 | Plugin ABI break on any Hyprland/aquamarine bump; plugin won't load or compositor dies | A, C | **High** | Only B avoids it. If a plugin is used, keep it tiny and hook-free, pin hyprland+aquamarine in pacman, and guard `hl.plugin.load` in `hyprland.lua` so a failed load degrades instead of breaking config. |
| 4 | Plugin bug = full compositor crash, every window lost | A, C | **High** | Same. cf. hyprtasking #128, Hyprspace #227, hyprland-plugins #504, Hyprland discussion #13324. |
| 5 | Exposé by moving real windows destroys the tiling layout and spams clients with configures | C (Lua route) | **High** | Don't use as primary. Restrict to floating windows, or investigate `LuaLayoutProvider` so the layout engine isn't fighting you. |
| 6 | GPU cost of 14-20 full-resolution captures per output commit at 5120x1440@120 on an RX 6600 | B | Medium | `live:false` + 10-15 Hz `captureFrame()` timer for non-hovered; `live:true` only hovered/animating. Measure with frame logs (as the DMS theme-sync work did) — never by eye. Re-measure with the second monitor. |
| 7 | One-frame flash / visible handoff at open (DMS has no `hasContent` gate today) | B | Medium | Gate overlay opacity on all `hasContent === true` with a ~150 ms watchdog; fade over 1-2 frames; animate close back to real rects before fading. Cannot be fully eliminated client-side. |
| 8 | Capture cadence dies when the overview is idle (only the first frame calls `scheduleFrame`) | B | Medium | Keep one 1px opacity-animating element alive while the overview is open so the output keeps committing. |
| 9 | `lastIpcObject` is stale — thumbnails land on wrong rects | B | Medium | `Hyprland.refreshToplevels()` and await the property update *before* showing; never bind geometry to a cached object. DMS already refreshes after a drop; also needed at open. |
| 10 | Second monitor: per-monitor overlay, per-monitor workspace sets, cursor crossing screens mid-drag | A, B | Medium | DMS's `Variants { model: Quickshell.screens }` already handles the overlay; cross-monitor drag is untested — forbid it in v1 or share drag state across variants. hyprtasking's `HTView(MONITORID)` is the plugin-side reference. |
| 11 | Layer-shell exclusive keyboard focus leaves the previous app de-highlighted or nothing focused on close | B | Low | Set `keyboardFocus: None` before hiding; explicitly refocus (`HyprlandService.focusWindow`) on close. `HyprlandFocusGrab` (already wired in DMS) is the alternative. |
| 12 | Overlay captured into its own thumbnails (feedback loop) | B | Low | Only affects `ShellScreen` capture, unused here. Belt and braces: `no_screen_share` layer rule on `dms:workspace-overview`. |
| 13 | XWayland windows: no toplevel-export handle, or geometry mismatch | B | Low-Med | `hyprctl clients` reports `xwayland: true`; test one. DMS already falls back to an app icon drawn over the capture — extend that to "never reached `hasContent`". |
| 14 | Direct scanout permanently disabled if captures are kept warm | B | Low | Create contexts on open, destroy on close; no warm pool. |
| 15 | `screencopy` permission prompt on first capture | B | Low | `screencopy` / `permission` keys exist in the Lua rules table; DMS already captures elsewhere (`Modals/DankLauncherV2/TileItem.qml`), so it is probably already permitted — confirm. |

---

## 7. Verified facts, with paths

URLs are `https://raw.githubusercontent.com/<repo>/<ref>/<path>` unless noted.

**Hyprland `v0.56.2`:**
- `src/managers/screenshare/ScreenshareFrame.cpp:316-333` — `renderWindow()` re-renders a
  toplevel into a private buffer with `RPT_EXPORT`; no occlusion or workspace early-out;
  `m_bBlockSurfaceFeedback = shouldRenderWindow(PWINDOW)`.
- `…/ScreenshareFrame.cpp:397` — `beginRender(..., RENDER_MODE_TO_BUFFER, m_buffer, ...)`.
- `…/ScreenshareFrame.cpp:120-140` — only `m_isFirst` calls `scheduleFrame` + `damageMonitor`.
- `…/ScreenshareFrame.cpp` layer loop — skips a layer when `l->m_ruleApplicator->noScreenShare()`.
- `…/ScreenshareFrame.cpp` window loop — `if (!g_pHyprRenderer->shouldRenderWindow(w, PMONITOR)) continue;`
- `…/ScreenshareFrame.cpp:344-356` — cursor drawn only if pointer surface intersects **and** window is focused.
- `src/managers/screenshare/ScreenshareManager.cpp:14-45` — `onOutputCommit()` drives all pending frames.
- `src/managers/screenshare/ScreenshareSession.cpp:170-180` — `nextFrame()` sets `m_directScanoutBlocked = true`; `isFirst = !m_sharing`.
- `src/output/Monitor.cpp:131` — `Screenshare::mgr()->onOutputCommit(m_self.lock())`.
- `src/render/Renderer.cpp:2205-2209`, `:2511-2518` — frame callbacks only for active / active-special workspace, only `aliveAndVisible()` views.
- `src/render/pass/SurfacePassElement.cpp:181-186` — `discard()` → `presentFeedback()` when `!m_bBlockSurfaceFeedback`.
- `src/render/pass/Pass.cpp:187-191` — `discard()` runs only for culled elements.
- `src/protocols/core/Compositor.cpp:795-797`, `:369-378` — `presentFeedback()` calls `frame()`, which sends `wl_callback`s.
- `src/protocols/ToplevelExport.cpp:20-25` — both capture requests route to `Screenshare::mgr()->getManagedSession`.
- `src/plugins/PluginAPI.hpp:21` — `#define HYPRLAND_API_VERSION "0.1"` (constant).
- `src/plugins/PluginAPI.hpp:357` — `addLuaFunction(...)` → `hl.plugin.<ns>.<name>`.
- `src/config/lua/bindings/LuaBindingsConfigRules.cpp` — contains `"no_screen_share"`, `"layer_rule"`, `"window_rule"`, `"gesture"`, `"fingers"`, `"direction"`, `"disable_inhibit"`, `"no_anim"`, `"xray"`, `"screencopy"`, `"permission"`.
- `src/config/lua/bindings/LuaBindingsDispatchers.cpp` — `"dsp"`, `"window"`, `"move"`, `"resize"`, `"set_prop"`, `"float"`, `"pin"`, `"alter_zorder"`, `"bring_to_top"`, `"relative"`, `"keep_aspect_ratio"`.
- `src/config/lua/objects/LuaWindow.cpp` — `at`, `size`, `x`, `y`, `floating`, `fullscreen`, `pinned`, `hidden`, `visible`, `workspace`, `monitor`, `address`, `perc_master`, `perc_size`.
- `src/config/lua/layout/LuaLayoutProvider.cpp` — `register`, `layout`, `recalculate`, `layout_msg`.

**Quickshell `v0.3.1`:**
- `src/wayland/screencopy/view.hpp` — `captureSource` accepts only `ShellScreen` or `Quickshell.Wayland.Toplevel`; `paintCursor`, `live`, `hasContent`, `sourceSize`, `constraintSize`, `captureFrame()`, `stopped()`.
- `src/wayland/screencopy/manager.cpp:27-57` — dispatch to icc / wlr / hyprland-toplevel.
- `src/wayland/screencopy/view.cpp:120-131` — `onFrameCaptured()` sets `bHasContent = true`.
- `src/wayland/screencopy/hyprland_screencopy/hyprland_screencopy.cpp:116, :126` — `copy(buf, copiedFirstFrame ? 0 : 1)`; `mSwapchain.swapBuffers()`.
- `src/wayland/hyprland/ipc/hyprland_toplevel.hpp:26-49` — `address`, `handle`, `wayland`, `lastIpcObject` (**with the not-live warning**), `workspace`, `monitor`.
- `src/wayland/hyprland/ipc/toplevel_mapping.cpp` + `hyprland-toplevel-mapping-v1.xml`.
- `src/wayland/wlr_layershell/wlr_layershell.hpp:47-69, :108` — `WlrKeyboardFocus.Exclusive` / `OnDemand` (with its warning).
- `src/wayland/hyprland/focus_grab/` — `HyprlandFocusGrab` via `hyprland-focus-grab-v1`.
- Docs (all HTTP 200): `quickshell.org/docs/v0.3.1/types/Quickshell.Wayland/ScreencopyView/`,
  `…/Quickshell.Wayland/Toplevel/`, `…/Quickshell.Hyprland/HyprlandToplevel/`. **No documented
  performance warnings on ScreencopyView.**

**hyprtasking (`main`, HEAD 2026-09-09):**
- `src/render.cpp` — `render_workspace_at_box` / `render_window_at_box` as quoted, with the
  "Hyprland only fully renders the monitor's active workspace" comment.
- `src/layout/grid.cpp:36-48` — `Animation::mgr()->createAnimation(...)` on `offset`, `scale`.
- `src/layout/grid.cpp:508-610` — render loop.
- `src/input.cpp:18-160` — `start_window_drag` / `end_window_drag` via
  `g_layoutManager->dragController()`, `Pointer::mgr()->warpTo`,
  `Desktop::globalWindowController()->moveWindowToWorkspace`.
- `src/main.cpp:595-690` — seven `findFunctionsByName` + `createFunctionHook` pairs;
  `fail_exit("Failed initializing hooks")`.
- `src/main.cpp:718-741` — `addDispatcherV2` + `addLuaFunction(PHANDLE, "hyprtasking", ...)`.
- `src/hyprland-version-compat.hpp.in` — regenerates aquamarine/hyprutils/hyprlang/
  hyprcursor/hyprgraphics version macros at build time.
- `hyprpm.toml:5` — `["efb50993780079460b0cbed1363e2166a2de1d9f", "4d3c39511c3f38966abf1ec4393f5a7220ffb1a3"], #v0.56.2`.

**hyprland-plugins (`main`):** tree at HEAD contains only `borders-plus-plus`,
`csgo-vulkan-fix`, `hyprbars`, `hyprfocus`. `hyprexpo/main.cpp` → HTTP 404. Commit
`3aa21f2e` 2026-05-12 removed it. Issue #672 closed 2026-05-19. `hyprpm.toml` pins run to
`efb50993…` for the four survivors. Open: #705 (2026-09-09 hyprpm stale aquamarine header
cache), #697 (hyprbars render glitch on 0.56).

**KZDKM/Hyprspace:** last commit 2026-05-28. Open: #239, #240, #241, #227, #206, #176, #218.

**Local DankMaterialShell v1.7-beta** (`~/.local/share/dms-shell-patched/`):
- `Modules/WorkspaceOverlays/HyprlandOverview.qml:19-56` — `Variants{model: Quickshell.screens}`,
  `PanelWindow`, `WlrLayershell.namespace: "dms:workspace-overview"`, `WlrLayer.Overlay`,
  `exclusiveZone: -1`, conditional `keyboardFocus`, `HyprlandFocusGrab`.
- `Modules/WorkspaceOverlays/OverviewWindow.qml:23-62` — four `SpringMotion`s on x/y/w/h
  driven by `Theme.springPreset("expressive", …)`.
- `…/OverviewWindow.qml:69-79` — `rawX/rawY/rawWidth/rawHeight` from `lastIpcObject.at/size`.
- `…/OverviewWindow.qml:~112` — `ScreencopyView { captureSource: root.overviewOpen ? root.toplevel?.wayland : null; live: true }`.
- `Modules/WorkspaceOverlays/OverviewWidget.qml:289-336` — `DropArea` + `hoveredWhileDragging`.
- `…/OverviewWidget.qml:399-460` — `Drag` + `dragArea`, `HyprlandService.moveToWorkspace(...)`,
  click-to-focus, middle-click-close.
- `grep hasContent` over the directory → **no hits**.
- Also uses `ScreencopyView` at `Modals/DankLauncherV2/TileItem.qml`.

---

## 8. Open questions only a prototype can answer

1. **Does a video keep playing in a `ScreencopyView` of a toplevel on an inactive
   workspace?** Code says no frame callbacks reach it; the protocol's stated intent says
   capture works "regardless of visibility"; no field report settles it. Test: mpv looping on
   ws 5, overview open from ws 2, watch for motion. Repeat with Firefox and an XWayland app.
   **This decides B vs C-lite and is the single most important experiment.**
2. **Does a window fully occluded by the overlay on the *active* workspace keep painting?**
   Code path says yes, but occlusion culling may route it through `discard()` with feedback
   blocked. Same test method.
3. **What do 14-20 simultaneous live captures cost on the RX 6600 at 5120x1440@120?**
   Measure frame time with everything `live: true` vs `live: false` + 12 Hz timer. Repeat
   with the second monitor attached.
4. **Can quickshell #1123 be reproduced here**, and does staggering capture creation avoid
   it? This is the one bug that can kill the whole shell.
5. **How big is the open-handoff seam in practice?** Record at high frame rate or use
   Hyprland frame logs (as the DMS theme-sync work did) and count flashed frames between
   overlay-visible and first-capture-presented. Never judge by eye.
6. **Do XWayland toplevels produce toplevel-export frames at all**, and does
   `lastIpcObject.at/size` match their real rect under scaling?
7. **Is DMS's Quickshell instance already granted the `screencopy` permission**, or does a
   fresh capture pop a dialog?
8. **Can `LuaLayoutProvider` express an animated exposé layout** — is it called per frame,
   can it return animated targets, and can it be entered/left without destroying dwindle
   split ratios?
9. **Does making a workspace momentarily active (hyprtasking's trick) fire IPC workspace
   events** that the DMS bar reacts to, causing visible flicker? Relevant to any plugin route.
10. **Can a QML drag cross between two `PanelWindow`s on different screens** under
    layer-shell, or does it die at the screen edge?
11. **On close, does `movetoworkspacesilent` + workspace switch leave the correct window
    focused**, or does the layer's exclusive keyboard focus leave nothing focused?
