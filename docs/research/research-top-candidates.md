# Deep-verify: five Mission-Control-style candidates for Hyprland

Date: 2026-09-13. Target system: Arch Linux, Hyprland 0.56.2 (Lua config runtime, `hyprland.lua`, plugins loaded via `hl.plugin.load("/path/plugin.so")`), Quickshell 0.3.1, DankMaterialShell 1.6, AMD GPU, two monitors.

This file merges five independent deep-verify passes (one per project), each done via `gh api` (repo metadata, issues, contents listings) and WebFetch/raw.githubusercontent.com (README, hyprpm.toml/CMakeLists.txt, QML source). Every claim in the per-project sections below is sourced with a quote and URL inside that section. Nothing here was inferred without a citation; where a per-project agent could not fetch something, it is flagged inline as 'could not fetch' / 'could not verify.'

Projects covered:
1. gfhdhytghd/hymission
2. nsumbadze/hypr-radiant
3. fedsfarm/gloview
4. colonelpanic8/hyprwinview
5. AndyWeiBoan/omarchy-mission-control

---

## 1. gfhdhytghd/hymission

# Deep verify: gfhdhytghd/hymission

Fetch methods used: `gh api` (repo metadata, issues, tags, releases, contributors, commits, contents), `curl` against raw.githubusercontent.com for README.md, hyprpm.toml, CMakeLists.txt, src/main.cpp, src/overview_controller.hpp, docs/spec.md, docs/architecture.md. WebFetch tool was not needed since `curl` succeeded for every raw file and `gh api` covered the GitHub-side data; no fetch failures to report.

## a. Repo metadata, version pin, relevant issues

- `gh api repos/gfhdhytghd/hymission`: stars=128, license="GNU General Public License v3.0", pushed_at="2026-09-12T18:12:38Z", open_issues=2, default_branch="master" (not "main"), created_at="2026-03-06T04:03:05Z", description="Mission control style workspace&windows overview plugin for Hyprland" (topics: none). Note: this description differs slightly from the lead sentence given in the task ("...live compositor-side previews, scope-aware collection, trackpad gestures, and workspace strip" is closer to the README's own first line, not the GitHub short description field).
- Total commits: 322 (via `gh api repos/gfhdhytghd/hymission/commits --paginate`).
- Contributors (`gh api repos/gfhdhytghd/hymission/contributors`): gfhdhytghd 303, rollecode 5, wtfmydarling 4, AlejandroMinor 3, LuuKhoaHoc 3, DerekCorniello 2, geovanecoc 1. Single dominant maintainer/author.
- Version pin mechanism: **no explicit Hyprland-version check in hyprpm.toml or CMakeLists.txt.** `hyprpm.toml` (https://raw.githubusercontent.com/gfhdhytghd/hymission/master/hyprpm.toml) has no commit-hash compatibility table, just repo/plugin name, authors, output path, and build command list. `CMakeLists.txt` (https://raw.githubusercontent.com/gfhdhytghd/hymission/master/CMakeLists.txt) declares `project(hymission VERSION "0.8.0")` — that is the plugin's own version, not a Hyprland version gate — and just does `pkg_check_modules(HYPR_DEPS REQUIRED hyprland)` with no version constraint string. The only real compatibility mechanism is Hyprland's own ABI handshake macro, present in `src/main.cpp`: `APICALL EXPORT std::string PLUGIN_API_VERSION() { return HYPRLAND_API_VERSION; }` (https://raw.githubusercontent.com/gfhdhytghd/hymission/master/src/main.cpp, line ~305-306) — Hyprland itself refuses to load a plugin whose `HYPRLAND_API_VERSION` string (an ABI hash baked in at plugin-compile time against the installed dev headers) doesn't match the running compositor's. Actual version targeting is communicated only informally, via git tag/release naming: `gh api repos/gfhdhytghd/hymission/tags` lists (newest first) `v0.8.0-v0.56.2`, `v0.7.1-v0.56.2`, `v0.7.0-v0.56.2`, `v0.6.0-v0.56.2`, `v0.5.0-v0.56.0`, `v0.4.3-v0.56.0`, `v0.4.2-v0.55.4`, `v0.4.1-v0.55.4`, `v0.4.0-v0.55.2`, `v0.3.3-0.55.0`, ... down to `v0.0.1`. Releases carry matching names, e.g. "hymission 0.8.0 for Hyprland 0.56.2" (tag `v0.8.0-v0.56.2`). **Current `master`/latest release (0.8.0) targets Hyprland 0.56.2** — matches the target system exactly, but this is a release-naming convention, not an enforced check; building `master` against an older Hyprland just fails at compile time (see issue #28 below) rather than producing a clean error message.
- Issue #28 "hymission fails to build on Hyprland v0.55.2 (dispatchers unavailable)" (closed) — https://github.com/gfhdhytghd/hymission/issues/28. Reporter's build error: `fatal error: hyprland/src/managers/fullscreen/FullscreenController.hpp: No such file or directory`. Maintainer (gfhdhytghd) reply: *"why you try build it on 0.55.2 since 0.56 is allready released?"* and *"I recommand you make a fork and check out to elder commit for 0.55 series and hyprpm add that , or build it locally on elder commit and hyprctl load it manually.."*, then *"hyprpm add https://github.com/gfhdhytghd/hymission v0.4.0-v0.55.2"*.
- Issue #20 "Build fails on -git" (closed) — https://github.com/gfhdhytghd/hymission/issues/20. Body: *"likely due to https://github.com/hyprwm/Hyprland/pull/14547"*. Maintainer: *"git isn't supported, please clone/fork then ask codex to fix."* Then a third-party commenter (alba4k) says *"you should reopen this as it now breaks the plugin in 0.56"*; maintainer agrees ("I agree"), commenter clarifies it was already fixed, maintainer: "ha I see." This shows real (if terse/informal) responsiveness to 0.56-series breakage, and confirms 0.56 compatibility was an active, recently-resolved concern, not a settled fact from day one.
- No issue text matched "Lua" as a build/crash keyword search hit directly, but a large fraction of the README (see part below) is a dedicated Lua config-mode guide, and issues #33/#34 are docs PRs specifically about it (see below).
- Full open/all-issue listing (`gh api repos/gfhdhytghd/hymission/issues?state=all&per_page=30`, 30 most recent items, issues and PRs both included, `is_pr` flagged): only #44 ("Occluded video preview flashes briefly during overview teardown", open, not a PR) and #29 ("as a human, please inspect all config settings", open, not a PR) are currently open — consistent with the API's `open_issues: 2`. Everything else in the 30-item window is closed, and roughly half of the 30 are PRs (#42, #41, #37, #35, #34, #33, #32, #31, #27, #26, #21, #19 flagged `is_pr:true`).

## b. Spaces bar + current-workspace exposé — both, but not always simultaneously; scope-gated

README (https://raw.githubusercontent.com/gfhdhytghd/hymission/master/README.md) "Workspace strip behavior and geometry" section: *"By default, the workspace strip is shown when the current overview scope displays only the active workspace. Set `workspace_strip_force_show = 1` to also show it in other scopes, including `forceall`, for dragging windows between workspaces. In `forceall`, clicking a strip card does not switch workspaces; drag-and-drop remains available."*

So there are (at least) two named view modes selected by scope argument to `toggle`/`open`:
- **default / `onlycurrentworkspace` scope**: current workspace's windows spread into a non-overlapping exposé grid, **and** the workspace strip (thumbnails of all/other workspaces) is shown at the same time by default — this is the macOS-Mission-Control-like combination the task is asking about.
- **`forceall` scope**: all regular workspaces' windows are spread into one multi-workspace overview grid (README: *"Show all regular workspaces across participating monitors and include currently visible special workspaces."*, Scope arguments table). The workspace strip is hidden by default in this mode unless `workspace_strip_force_show=1` is set.

Additional modes: "Niri mode" (`niri_mode=1`) changes the edge strip into a niri-like overflowing scroll strip rather than a shrink-to-fit strip, and "Stage mode" (`stage_enabled=1`, separate persistent sidebar, not part of overview at all — reserves real desktop space and shows only *inactive* workspaces as live cards, resizing the actual desktop layout, distinct from the overview/exposé feature).

## c. Open/close animation: continuous per-window, not a whole-screen fade/zoom (mostly)

Architecture doc (Chinese; https://raw.githubusercontent.com/gfhdhytghd/hymission/master/docs/architecture.md), section "5.1 打开 overview" (opening overview), step list ending in step 9 "开始 opening 动画" (begin opening animation); section "5.2 overview 期间" states the controller continuously does: *"把真实窗口绘制变成 preview 投影"* ("turn the real window's rendering into a preview projection") — i.e. each real window's surface is redrawn at an interpolated position/scale every frame, not a single overview-wide fade. Design principle #1 in the same doc: *"overview 是 compositor-side preview 层，不是对真实窗口 geometry 的重排"* ("overview is a compositor-side preview layer, not a rearrangement of real window geometry").

The layout solver's own framing supports continuous per-window flight: README's dev-tools section says `hymission-layout-demo`'s SVG output draws *"dashed rectangles are source window geometry and solid rectangles are overview targets"* — i.e. the geometry engine explicitly computes a target rect for each window relative to its real on-screen source rect, which is what a per-window fly animation needs.

Caveat / engine dependence: default `layout_engine = "grid"` uses row-search placement (not position-preserving). The **"natural" engine** (aliases: `natural`, `apple`, `expose`, `mission-control` — README "Engine selection and scope overrides": *"`natural`, `apple`, `expose`, and `mission-control` are aliases for the Apple-like natural solver."*) is described as: *"The natural engine tries to preserve original window positions while removing overlap. It attempts every window count before falling back to row search."* — this is the mode closest to genuine Mission-Control-style "windows slide from their real screen position." It is opt-in, not the default.

Named animation options found (all via README "Animations" section and adjacent):
- `hover_relayout_animation` (Hyprland animation-tree leaf, e.g. `windowsMove`), `hover_relayout_duration` (ms, default 140, clamp 0-2000), `hover_relayout_curve` (default `ease_out_cubic`) — governs re-layout when the selected/hovered preview changes size, not the main open/close transition.
- `stage_transition_ms` (default 300, "Workspace window flights; `0` disables. Shared timeline, symmetric ease-in-out translation and ease-out scale... Respects `animations:enabled`.") — this is Stage-mode's animation, not overview's.
- Feature-list bullet: *"Workspace-to-workspace overview transitions without showing the native workspace animation in the middle"* — implies overview-to-overview workspace switches are a custom animated path, deliberately bypassing Hyprland's normal workspace slide.
- No single top-level "open_duration"/"close_duration" key was found for the *main* overview open/close transition itself; architecture.md's `GestureSession` (controls "overview 自身的 opening / closing openness 和速度提交" — overview's own opening/closing openness and velocity-based commit) suggests open/close progress is driven by gesture/timeline state internally rather than one simple duration constant, consistent with trackpad-driven interruptible open/close.

## d. Interaction: drag-and-drop, click, hover, keyboard, gestures

- **Click-to-focus**: README, Dispatchers/behavior text and v1 spec (docs/spec.md, Chinese) both confirm: *"鼠标点击 preview 激活对应窗口并退出 overview"* ("mouse click on a preview activates the corresponding window and exits overview").
- **Hover highlight**: `overview_focus_follows_mouse` (bool, default 1) keeps hover synced to selection and (optionally) real Hyprland focus; `focus_hover_color` (`rgba(f2f7ff8c)`), `focus_hover_thickness` (2), `hover_expand_scale` (1.18, only used when focus-follows-mouse is off), `show_focus_indicator` (bool, default 0, must be enabled to draw the outline chrome at all).
- **Keyboard navigation**: arrow-key directional nearest-neighbor selection (per spec.md and overview_logic.cpp's stated role: "方向键最近邻选择" = direction-key nearest-neighbor selection); optional `vim_keys` (h/j/k/l, disables pick-labels); Tab/Shift+Tab cycling and pick-labels (`pick_labels_enabled`, `pick_labels_mode`: `sequential` 1-9/A1-Z9 or `spatial` physical-keyboard-position labels) added via PRs #40/#41/#27 (all closed/merged). `Esc` closes, `Return` activates selection.
- **Drag-and-drop between workspaces**: documented explicitly under "Workspace strip behavior and geometry" and "Persistent desktop sidebar (stage mode)": *"Use the normal compositor window-move drag (for example, your existing `SUPER + left mouse` binding) to drop a window onto a card. Holding a drag near the top/bottom scrolls the list; the width remains fixed during the drag."* and *"In `forceall`, clicking a strip card does not switch workspaces; drag-and-drop remains available."* Grouped-window dragging is also described: dragging any group member moves the whole group as a bounded stack. **Discrepancy found**: docs/architecture.md section "8. 仍然后置的内容" (things still deliberately deferred) lists *"workspace 条带"* (workspace strip) and *"拖拽"* (drag-and-drop) as NOT YET implemented, even though the README (same `master` branch, same fetch) documents both in detail with config options and recent commit history (`gh api repos/gfhdhytghd/hymission/commits`) shows active September 2026 work like `feat(stage): drag thumbnail windows to desktops and workspace cards` (commit cd5bda7, 2026-09-12). This means at least one internal doc (architecture.md) is stale relative to the shipped feature set, despite architecture.md's own header claiming it "describes the current implementation, not early expected roadmap."
- **Gesture mechanism** — explicitly answered in docs/architecture.md section "3. 当前 hook 面" (current hook surface), "trackpad gesture hook" bullet: *"官方 `gesture = ..., dispatcher, hymission:*`"* (Hyprland's own official `gesture` config keyword/dispatcher registration) **plus** *"overview 内部对 workspace swipe 的接管与复用"* (the plugin's own internal takeover/reuse of the workspace-swipe gesture) and dedicated hook functions in `src/overview_controller.hpp` (fetched): `workspaceSwipeBeginHook`, `workspaceSwipeUpdateHook`, `workspaceSwipeEndHook`, `unifiedWorkspaceSwipeBeginHook/UpdateHook/EndHook`, `scrollMoveGestureBeginHook/UpdateHook/EndHook`, and `handleGestureConfigHook`. Conclusion: **both** — the plugin registers through Hyprland's real native `gesture = fingers, direction, dispatcher, hymission:*` mechanism for triggering, but hooks the trackpad gesture update/end callbacks itself to get continuous, interruptible drag-progress (not just fire-once-on-completion). README also exposes a Lua convenience wrapper, `hl.plugin.hymission.gesture({...})`, layered on top of (and interoperable with, per the README's "Native alternative: -- hl.gesture({...})" comment) Hyprland's native `hl.gesture`.

## e. Multi-monitor, fullscreen/floating, special workspaces

- **Multi-monitor**: listed as a top-level Feature ("Multi-monitor support"). `forceall` scope explicitly spans "all regular workspaces across participating monitors." `only_active_monitor` (bool, default 0) restricts default scope to the monitor under the cursor — implying the unrestricted default *does* include other monitors' workspaces. Stage mode's persistent sidebar is explicitly "independently on each monitor" (`stage_enabled` "Enable the persistent sidebar independently on each monitor").
- **Fullscreen handling**: dedicated dispatcher `hl.plugin.hymission.fullscreen({ mode = "fullscreen"|"maximized", action = "toggle"|"set"|"unset" })`; architecture.md notes the controller does "fullscreen backup/restore" (`fullscreenBackups` in state) and hooks the `fullscreen`/`fullscreenstate` dispatchers themselves. `stage_maximize_cover_strip` controls whether maximize (not true fullscreen) covers the Stage-mode sidebar; true fullscreen always covers the whole output and slides the sidebar out.
- **Floating/pinned windows**: docs/spec.md (Chinese v1 scope) explicitly includes: *"scope 参与 monitor 上可见的 pinned 浮窗，即使其 `m_workspace` 仍指向之前的 workspace"* (pinned floating windows visible on a participating monitor are included, even if their `m_workspace` still points to a prior workspace) — i.e. pinned floats are collected by current-monitor visibility, not literal workspace membership.
- **Special workspaces**: `show_special` (bool, default 0) — "Include currently visible special workspaces in the default scope"; `forceall` scope always includes currently visible special workspaces per the Scope-arguments table. Stage mode explicitly hides itself while a special workspace or overview is visible ("Overview and special workspaces temporarily hide the persistent sidebar while preserving its desktop reservation").

## f. Architecture (hooks / rendering / input capture / real-vs-copy)

Source of truth: docs/architecture.md (Chinese) + src/overview_controller.hpp (fetched, 250-line architecture doc, class header with hook method declarations).

- Design principle stated directly: *"overview 是 compositor-side preview 层，不是对真实窗口 geometry 的重排"* (overview is a compositor-side preview layer, not a rearrangement of real window geometry) and, later, an explicit conclusion: *"结论仍然不变：`hymission` 以 render hook 为主路径，而不是 `IWindowTransformer`。"* ("Conclusion unchanged: hymission's primary path is render hooks, not `IWindowTransformer`.") — i.e. it does **not** move real windows and does **not** use Hyprland's `IWindowTransformer` window-transform API; it hooks the renderer's per-surface draw path directly.
- Render hooks (from architecture.md "3. 当前 hook 面" and confirmed by matching method declarations in `overview_controller.hpp`): `shouldRenderWindow` (→ `shouldRenderWindowHook`), border/shadow/group-bar draw hooks (`borderDrawHook`, `shadowDrawHook`, `groupBarDrawHook`), surface draw/tex-box/bounding-box/visible-region/opaque-region hooks (`surfaceDrawHook`, `surfaceTexBoxHook`, `surfaceBoundingBoxHook`, `surfaceOpaqueRegionHook`, `surfaceVisibleRegionHook`), and `calculateUVForSurfaceHook`. Also `rendererDrawElementHook`, `renderLayerHook`, blur hooks (`surfaceNeedsLiveBlurHook`, `surfaceNeedsPrecomputeBlurHook`).
- Dispatcher hooks: `fullscreen`, `fullscreenstate`, `changeworkspace`, `focusWorkspaceOnCurrentMonitor` (matching `fullscreenDispatcherHook`, `fullscreenStateDispatcherHook`, `changeWorkspaceDispatcherHook`, `focusWorkspaceOnCurrentMonitorDispatcherHook`).
- Input hooks (per architecture.md "输入与事件"): mouse move, mouse left-click, keyboard arrows/Esc/Return, window open/close/destroy/moveToWorkspace, workspace change, monitor change — these are Hyprland event-system hooks, not an independent input-grab layer; hit-testing is done against Hymission's own computed preview boxes (design principle #3: *"输入命中以 preview box 为准，不能复用真实窗口命中区域"* — input hit-testing is based on preview boxes, must not reuse real window hit regions).
- Offscreen/framebuffers: `overview_controller.hpp` declares `SP<Render::IFramebuffer> framebuffer;` and `SP<Render::IFramebuffer> previousFramebuffer;` inside its state struct — used for workspace-strip/thumbnail rendering (README: workspace strip thumbnails have their own `workspace_strip_refresh_ms` live-refresh interval, separate from the main per-frame overview render), while the *main* current-workspace overview appears to redirect the live surface draw calls directly (per the render-hook list above) rather than pre-rendering into an offscreen buffer per window.
- It moves **real window pixels via redirected draw calls** (its own words: "把真实窗口绘制变成 preview 投影" — turn the real window's rendering into a preview projection) at a transformed screen position/scale, not literal separate texture copies for every preview, and does not reposition the actual window geometry (design principle #4: overview may temporarily override Hyprland config/workspace names but "必须在 overview 退出后恢复" — must restore after exit).

## g. Theming/chrome

Extensive and confirmed by README "Color customization" + "Appearance" + related sections (`rgba(rrggbbaa)` syntax, matches native Hyprland color format):
- Colors: `backdrop_color`, `focus_hover_color`, `focus_selected_color`, `focus_title_color`, `close_button_color`, `close_button_hover_color`, `close_button_glyph_color`, and a full workspace-strip palette (`workspace_strip_background_color`, `_inactive_color`, `_active_color`, `_empty_color`, `_new_color`, `_hover_tint_color`, `_active_tint_color`, `_inactive_tint_color`, `_plus_color`).
- Corner radius: only explicitly configurable for **Stage mode** miniatures — `stage_window_rounding` ("Window miniature corner radius in logical pixels... Negative values use half of `decoration:rounding`; `0` makes square corners."). The main overview previews do not have their own separate radius knob in the README; they preserve "eligible window borders and shadows" via `window_decoration_enabled`, implying the previews inherit whatever corner rounding the real window decoration already has rather than exposing an independent overview-preview radius.
- Blur: `backdrop_blur` (bool) for the full-monitor overview dim/blur backdrop; `hide_bar_animation_blur` for the bar-handoff transition.
- Labels: `pick_labels_show`/`pick_labels_mode` (keyboard-pick label chips), `grouped_windows_collapsed_labels` (group member title tabs); `close_button_*` styling is reused for label-chip styling.
- Outline thickness: `focus_hover_thickness`, `focus_selected_thickness`.

## Lua dispatcher / binding example (explicit yes)

README has a dedicated top-level section **"Lua Config Mode (Hyprland 0.55+)"** (line 791 of the fetched README) opening with: *"Since Hyprland 0.55, the default configuration format is Lua. If your setup uses `configProvider: lua` (check with `hyprctl systeminfo`), follow these notes."* It documents `hl.bind`, `hl.config`, `hl.gesture`, `hl.exec_cmd`, `hl.on`, and a full native `hl.plugin.hymission.*` function table (`toggle`, `open`, `close`, `fullscreen`, `debug_current_layout`, `dispatch`, `gesture`) as the *recommended* calling convention, with the old colon-form dispatcher strings (`hymission:toggle` etc.) explicitly demoted to "legacy dispatcher for non-Lua configuration." Representative quoted example:

```lua
hl.bind("SUPER + TAB", hl.plugin.hymission.toggle)
hl.bind("SUPER + SHIFT + TAB", function()
    hl.plugin.hymission.toggle("reverse")
end)
```

and a full "Omarchy 4 integration example" (README, "Omarchy 4 integration example" subsection) with `hl.exec_cmd("hyprctl plugin load ~/.local/lib/hymission.so")`, `hl.config({ plugin = { hymission = {...} } })`, `hl.bind(...)`, and `hl.gesture({ fingers = 3, direction = "up", action = function() ... end })`. There is also an explicit gotcha documented: *"`hl.plugin.hymission` is only available after the plugin binary is loaded. In Lua config mode, `hl.exec_cmd` is asynchronous, so the plugin is not yet loaded when your config file first runs."* — with a guarded-`if` pattern given as the fix. Two closed docs PRs (#33 "docs: add Lua config mode guide, Omarchy 4 example, and troubleshooting", #34 "docs: fix doubled hypr/ path in Lua config guide") show this Lua guidance was purpose-built and iterated on, not incidental.

## h. Verdict (bus factor / vibecoding signals / risk)

The maintainer's own README states plainly (https://raw.githubusercontent.com/gfhdhytghd/hymission/master/README.md, warning callout): *"This software is 99% vibe coded with OpenAI CodeX, but have been manual audited, warn in case you mind it."* This is corroborated by: a near-single-author commit graph (303/322 commits, i.e. ~94%, by gfhdhytghd; next contributor has 5), extremely high commit velocity on some days (6+ commits in one day around the 0.8.0 release), a config surface user-reported as bloated and self-contradictory (issue #29, open: *"lots of options to fine tune different things, no explanation on how to use them... lots of duplicate settings, unclear settings, and obsolete ones that seemingly do nothing"*), casual/terse maintainer replies to bug reports (issues #20, #28), and at least one stale internal doc (architecture.md's "still deferred" list contradicts the README's documented drag-and-drop/workspace-strip features). Against that: there IS a test suite (`ctest`, `hymission-overview-logic-test`, `hymission-stage-logic-test`, `hymission-search-child-process-test`) and a deliberately-decoupled, hook-testable layout engine, which is more rigor than a typical single-commit vibecoded repo; the project also went through 17 tagged releases across a Hyprland-version range from 0.54 to 0.56.2, showing sustained maintenance rather than a one-shot dump. Feature-wise it is architecturally one of the closer analogues to macOS Mission Control among Hyprland plugins seen: it separately implements a full-window exposé (current or all workspaces), a live workspace-thumbnail strip shown alongside the exposé by default in single-workspace scope, drag-and-drop between spaces, trackpad-gesture open/close with continuous progress, and an Apple-aliased "natural" layout engine that explicitly tries to preserve real window positions — covering essentially every named Mission Control sub-behavior — but several of the most Mission-Control-specific behaviors (position-preserving flight animation, click-through hover, real per-window continuous open animation) are opt-in/engine-dependent rather than the shipped default (`layout_engine = grid`), and the overall risk profile (single fast-moving vibecoded maintainer, self-acknowledged config mess, at least one stale internal doc, and open ABI-churn exposure to Hyprland's fast-moving native headers as seen in issues #20/#28) means near-term breakage on any future Hyprland bump is plausible and would depend on this one maintainer for a fix.

## Could not verify / not attempted

- Did not fetch every closed issue body (only #28, #20, #29, #44 were read in full; the rest were assessed by title/state only from the issues listing).
- Did not check out and build the code; all "does it actually work" claims are as-documented, not independently run/tested on the target Arch/Hyprland 0.56.2/Quickshell/DMS system.
- Did not diff `docs/research.md`, `docs/stage_mode.md`, `docs/todo.md`, or `docs/workspace_strip_plan.md` (listed in `contents/docs` but not fetched) — only `docs/spec.md` and `docs/architecture.md` were read.
- Did not inspect `overview_controller.cpp`/`overview_logic.cpp`/`mission_layout.cpp` implementation bodies, only headers (`overview_controller.hpp`) and `main.cpp` — hook *declarations* were confirmed, not their exact runtime behavior line-by-line.
- No CI/workflow files were checked (`.github/workflows` was not listed among root contents in the `gh api contents` call — root contains `.codex`, `.gitignore`, `AGENTS.md`, `CMakeLists.txt`, `LICENSE`, `README.md`, `devlog`, `docs`, `hyprpm.toml`, `logo.svg`, `meson.build`, `src`, `tools` — no `.github` directory present, meaning there is no visible CI badge/workflow in this listing; not confirmed further).
- WebFetch on the GitHub repo web page (fetch method 6 in the task) was not used since `gh api` + raw file fetches via curl already covered everything needed; no failure to report there because it was simply not attempted.

---

## 2. nsumbadze/hypr-radiant

# Deep verify: nsumbadze/hypr-radiant

Repo: https://github.com/nsumbadze/hypr-radiant
Default branch: main

## Fetch log (successes and failures)

1. `gh api repos/nsumbadze/hypr-radiant --jq '{...}'` — SUCCESS.
   Result: `{"created":"2026-07-24T15:03:46Z","default_branch":"main","desc":"Native workspace overview for Hyprland, live window previews, touchpad gestures, and window search.","forks":1,"license":"MIT License","open_issues":0,"pushed":"2026-09-08T06:51:59Z","stars":8,"topics":[]}`
   - Stars: 8
   - License: MIT License
   - Last push: 2026-09-08T06:51:59Z
   - Open issues (API field, includes open PRs): 0
   - Topics: none set (empty array) — contradicts any claim of curated topic tags.
   - Languages (`gh api repos/nsumbadze/hypr-radiant/languages`): `{"C++":549721,"CMake":14924,"Shell":12639}`
   - Releases (`gh api repos/nsumbadze/hypr-radiant/releases`): empty — no tagged releases exist.

2. Issues/PRs — SUCCESS. `gh api "repos/nsumbadze/hypr-radiant/issues?state=all&per_page=30"` returned 15 items, **all 15 have `is_pr:true`**. Confirmed via GitHub search API:
   - `gh api "search/issues?q=repo:nsumbadze/hypr-radiant+is:issue"` -> `{"total":0}` — zero actual Issues have ever been filed.
   - `gh api "search/issues?q=repo:nsumbadze/hypr-radiant+is:pr"` -> `{"total":15}` — all 15 tracker items are PRs, all `closed`.
   - Full PR list (all closed, all by the same author unless noted):
     - #15 Feat/customization options (closed 2026-09-07)
     - #14 Feat/customization options (closed 2026-09-05)
     - #13 docs: add gifs (closed 2026-08-21)
     - #12 Redesign quattro (closed 2026-08-20)
     - #11 Feat/omarchy 4 quattro (closed 2026-08-19)
     - #10 Feat/interface navigation workspace motion (closed 2026-08-09, body empty)
     - #9 fix:input keys in search bar (closed 2026-08-09)
     - #8 feat(wall): animate window drags (closed 2026-07-31, body empty)
     - #7 Fix/restart safe controls (closed 2026-07-30)
     - #6 Feat/workspace wall polish (closed 2026-07-28)
     - **#5 fix(compat): support Hyprland 0.56** (closed/merged 2026-07-27T06:35:48Z, body empty)
     - #4 Feat/preferences (closed 2026-07-26)
     - #3 Feat/close animation (closed 2026-07-25, body empty)
     - #2 Feat/config (closed 2026-07-25)
     - #1 Chore/docs (closed 2026-07-24)
   - Keyword search (`test("0\\.56|build|crash|Lua"; "i")` over title+body) matched only PR #5's title text ("support Hyprland 0.56"); no issue/PR mentions "crash" or "Lua" in title/body. No "build" hits either (bodies are all null/empty for the sampled PRs).
   - PR #5 file diff (`gh api repos/nsumbadze/hypr-radiant/pulls/5/files`): touched `README.md` (1/-1), added new `include/hypr-radiant/HyprlandCompat.hpp` (+181), and edited `src/compositor/ActivationController.cpp`, `src/compositor/StateCollector.cpp`, `src/main.cpp`, `src/render/OverlayRenderer.cpp` — i.e. the 0.56 compat fix was a real, non-trivial compatibility-layer addition, not a version-string bump.

3. README — SUCCESS. Fetched in full via `https://raw.githubusercontent.com/nsumbadze/hypr-radiant/main/README.md` (WebFetch, verbatim return). Full text captured below in relevant sections with exact quotes.

4. Version pin files — SUCCESS on all three:
   - `hyprpm.toml` (raw fetch, verbatim):
     ```
     [repository]
     name = "hypr-radiant"
     authors = ["Nika Sumbadze (@nsumbadze)"]
     commit_pins = [
         ["39d7e209c79d451efab1b21151d5938289da838d", "eeaa9d3417cb3b34f7a4aa3dc8deac10506dd46e"]
     ]

     [hypr-radiant]
     description = "Native workspace overview with live previews, gestures, and search."
     authors = ["Nika Sumbadze (@nsumbadze)"]
     output = "build/hypr-radiant.so"
     build = [
         "cmake -S . -B build -DCMAKE_BUILD_TYPE=Release",
         "cmake --build build"
     ]
     ```
     Only ONE commit_pin row exists, pinning one specific Hyprland source commit (`39d7e209...`) to one specific hypr-radiant source commit (`eeaa9d34...`). Per README this pin corresponds to Hyprland 0.55.2 specifically (see quote below) — hyprpm's normal compat mechanism (a per-Hyprland-release commit table) is NOT populated for 0.56/0.56.2; only 0.55.2 has a locked pin row.
   - `CMakeLists.txt` (raw fetch, quoted lines from WebFetch pass, URL: https://raw.githubusercontent.com/nsumbadze/hypr-radiant/main/CMakeLists.txt):
     ```
     project(
         hypr-radiant
         VERSION 0.3.0
     ...
     pkg_check_modules(HYPRLAND REQUIRED IMPORTED_TARGET "hyprland>=0.55")
     ...
     if(HYPRLAND_VERSION VERSION_GREATER_EQUAL "0.56")
         set(HYPR_RADIANT_HYPRLAND_STATE_API 1)
         set(HYPR_RADIANT_HYPRLAND_LOGGER_NEEDS_ENV_STUB 0)
     ...
     if(HYPRLAND_VERSION VERSION_GREATER_EQUAL "0.55.4")
         set(HYPR_RADIANT_HYPRLAND_CONFIG_VALUE_BASE 1)
     ...
     pkg_check_modules(AQUAMARINE REQUIRED aquamarine)
     pkg_check_modules(HYPRUTILS REQUIRED hyprutils)
     pkg_check_modules(HYPRGRAPHICS REQUIRED hyprgraphics)
     pkg_check_modules(HYPRLANG REQUIRED hyprlang)
     ```
     So the ONLY hard floor enforced by CMake/pkg-config is `hyprland>=0.55`; there is no upper bound (`<=0.56.2`) enforced anywhere in the build system. The 0.55.2-0.56.2 ceiling is a README-stated compatibility claim / test matrix, not a build-time or ABI-time guard, aside from the plugin ABI version-string check at load time (see item (a) below) and the two `VERSION_GREATER_EQUAL` feature-detection branches (0.55.4, 0.56).
     - `include/hypr-radiant/HyprlandCompat.hpp` (raw fetch, WebFetch summary + quoted macro, URL: https://raw.githubusercontent.com/nsumbadze/hypr-radiant/main/include/hypr-radiant/HyprlandCompat.hpp):
       ```
       #if __has_include(<hyprland/src/state/MonitorState.hpp>)
       #define HYPR_RADIANT_HYPRLAND_STATE_API 1
       #else
       #define HYPR_RADIANT_HYPRLAND_STATE_API 0
       #endif
       ```
       Confirms compat is feature-detected via header presence (`__has_include`) in addition to the CMake version-string branch, and the file provides parallel implementations for "state API" (>=0.56) vs legacy compositor API (<0.56) — this is the real mechanism behind PR #5's "support Hyprland 0.56" fix.
   - README's own version statement (exact quote, https://raw.githubusercontent.com/nsumbadze/hypr-radiant/main/README.md):
     > "Hyprland 0.55.2 through 0.56.2, with development headers matching the compositor you run"
     > "The plugin ABI is tied to the exact Hyprland build. If the headers do not match, the plugin refuses to load, sends a notification, and Hyprland unloads it again."
     > "The current source is build-tested against Hyprland 0.55.2, 0.55.4, and 0.56.2. HyprPM pins the exact Hyprland 0.55.2 commit to a source revision verified with that release; other supported builds compile the current source against their own matching headers."
     > "The Quattro compatibility target is Hyprland 0.56.2 with Aquamarine 0.14.x, hyprutils 0.14.x, hyprgraphics 0.5.x, and hyprlang 0.6.x."

5. Source layout — SUCCESS. `gh api repos/nsumbadze/hypr-radiant/contents` (root): `.clang-format, .clang-tidy, .github, .gitignore, CMakeLists.txt, LICENSE, README.md, assets, hyprpm.toml, include, src, tests`.
   `src/`: `compositor, config, input, main.cpp, overview, render`
   `src/compositor/`: `ActivationController.cpp, StateCollector.cpp`
   `src/render/`: `ChromeStyle.cpp, FadeAnimation.cpp, LabelRenderer.cpp, OverlayRenderer.cpp, Theme.cpp`
   `src/overview/`: `AppIdentity.cpp, HitTester.cpp, OverlayGeometry.cpp, PreferencesPanelGeometry.cpp, SearchMatcher.cpp, SearchPanelGeometry.cpp, SearchSuggestions.cpp, StageTransform.cpp, WorkspaceWallLayout.cpp`
   `src/input/`: `GestureController.cpp, InputController.cpp, KeyboardAction.cpp, OpeningInputGuard.cpp, ShortcutController.cpp, SwipeTracker.cpp`
   `src/config/`: `Color.cpp, Config.cpp, HyprlandDecoration.cpp, OmarchyPalette.cpp, Preferences.cpp`
   `include/hypr-radiant/`: `HyprlandCompat.hpp, Log.hpp, OverviewTarget.hpp, RadiantPlugin.hpp, RadiantState.hpp` + subdirs `compositor, config, input, overview, render`
   `tests/`: `AppIdentityTest.cpp, ChromeStyleTest.cpp, ConfigParserTest.cpp, FadeAnimationTest.cpp, GestureControllerTest.cpp, HitTesterTest.cpp, KeyboardActionTest.cpp, OmarchyPaletteTest.cpp, OpeningInputGuardTest.cpp, OverlayGeometryTest.cpp, PreferencesPanelGeometryTest.cpp, PreferencesTest.cpp, README.md, SearchMatcherTest.cpp, StageTransformTest.cpp, WorkspaceWallLayoutTest.cpp, harness, stubs`

6. Origin discussion — SUCCESS after owner resolution. `gh api repos/omacom-io/omarchy` -> 404 Not Found. `gh api repos/basecamp/omarchy` -> resolved (redirect) to `full_name: "omacom/omarchy"`. Correct owner/repo is **omacom/omarchy** (basecamp/omarchy redirects there). Discussion fetched at `gh api repos/basecamp/omarchy/discussions/7695` (redirect followed):
   - Title: "hypr-radiant — workspace overview for Hyprland / Omarchy #7695"
   - Canonical URL: https://github.com/omacom/omarchy/discussions/7695
   - Author: **nsumbadze** himself (this is a self-post advertising his own plugin, not a third-party discovery/endorsement thread)
   - Date: Aug 21, 2026
   - Only one reply found (samuel-pegado-itera360, Sep 3, 2026), suggesting customization options (removing rounded borders, thicker borders, arrow-key window navigation, keyboard-accessible workspace regions) — several of these were then shipped in PR #14/#15 "Feat/customization options" (Sep 5 and Sep 7), i.e. the single community reply visibly drove the most recent development.

7. Repo web page — SUCCESS (WebFetch). No topics/tags shown, 0 watchers, no releases section populated, About text matches API description field.

## (a) Version pin, issues, activity, stars, license

- Exact support range (README quote): "Hyprland 0.55.2 through 0.56.2" — see quotes in section 4 above.
- Pin mechanism: hybrid — (1) CMake `pkg_check_modules(HYPRLAND REQUIRED IMPORTED_TARGET "hyprland>=0.55")` floor only, no upper bound in build system; (2) two `VERSION_GREATER_EQUAL` branches at 0.55.4 and 0.56 selecting compat code paths; (3) `HyprlandCompat.hpp` additionally feature-detects via `__has_include(<hyprland/src/state/MonitorState.hpp>)`; (4) `hyprpm.toml` has exactly one `commit_pins` row locking Hyprland commit `39d7e209...` to plugin commit `eeaa9d34...`, which the README says corresponds to the 0.55.2 release specifically — 0.56.2 support relies on "other supported builds compile the current source against their own matching headers" (i.e. rebuilt from source per-install, not a second hyprpm commit pin row) plus a runtime ABI/header-mismatch guard (`HyprlandAPI::addNotification(g_pluginHandle, "[hypr-radiant] mismatched Hyprland headers...")` in `src/main.cpp`, confirmed by WebFetch of that file) that unloads the plugin if headers don't match at load time.
- Issue/PR mentioning 0.56 etc.: PR #5 "fix(compat): support Hyprland 0.56" (merged 2026-07-27). No issue or PR body mentions "crash". No mentions of "Lua" anywhere in issue/PR titles or bodies (the Lua binding exists in source/README but was never discussed in the tracker).
- Last push: 2026-09-08T06:51:59Z (per API `pushed_at`).
- Stars: 8. Forks: 1. Watchers: 0.
- License: MIT.
- Open issues: 0 (API field); confirmed separately zero real Issues (`is:issue` search = 0 total) and 15 PRs total, all closed.
- Total commits: 229 (paginated `gh api --paginate repos/nsumbadze/hypr-radiant/commits`, counted 229 SHAs). Contributors breakdown (`gh api repos/nsumbadze/hypr-radiant/contributors`): nsumbadze 228 commits, fordaaaa 1 commit. This matches the lead's "8 stars/229 commits" figure and shows it is NOT a squash/inflation artifact of many contributors — it is essentially a single-author commit history (99.6% of commits by one person) accumulated over ~7 weeks (created 2026-07-24, last push 2026-09-08).

## (b) View modes — precise enumeration (all quotes from README, https://raw.githubusercontent.com/nsumbadze/hypr-radiant/main/README.md)

- **Stage** (default): "Stage is the default. It spreads the current workspace across the screen and keeps a workspace shelf at the top edge." The shelf ("workspace shelf slides in at the top edge when the pointer reaches it") is NOT shown by default/always — it reveals on hover/pointer-at-edge/scroll unless `shelf = always` is configured. So Stage's "all workspaces as thumbnails" strip and "current workspace exploded into non-overlapping cards" CAN coexist on screen at once, but only simultaneously by default when the shelf is actively revealed (hover/scroll) or when the user sets `shelf = "always"` in config. Out of the box (`shelf = "auto"`), the current-workspace exposé is what's shown; the all-workspace strip is on-demand.
- **Workspace Wall**: "Workspace Wall shows all workspaces at once as a grid of cards" — this is all-workspaces-as-cards, but README doesn't describe Wall as additionally exploding each workspace's windows into a non-overlapping per-window layout beyond what fits in each card (each card is described as a workspace card/preview, not a stated window-level explosion) — treat as a workspace-thumbnail grid, not confirmed to show individually-arranged windows within each card beyond a live preview.
- **Workspace Carousel**: "the selected workspace stays centered between readable 16:9 side previews for each real workspace, followed by one explicit new-workspace target" — a horizontal carousel of per-workspace previews.
- **Workspace Ribbon**: "turns the same workspace sequence into a compact, fast-moving strip inspired by Quattro's native pickers" — same workspace-level content as Carousel, denser/faster strip form.
- **Deck** — NOT a separate top-level view; it's a window-arrangement option within Stage: "Deck arrangement gives the first window a large hero position and packs the rest into a supporting column. It is available in Stage alongside Spatial and Grouped." (Stage supports three window arrangements: Spatial, application-grouped [Grouped], and Deck.)
- **App Exposé**: "App Exposé collects every window belonging to the focused application." Separate dispatcher `radiant:app` / Lua `hl.plugin.radiant.showApplication` (confirmed in `src/main.cpp`, dispatcher `DISPATCHER_APP` bound to `RadiantPlugin::showApplication`). Distinct from the four workspace-level views.

Direct answer to (b)'s framing: the plugin does NOT show all-workspace live thumbnails AND a non-overlapping current-workspace exposé simultaneously as its single default behavior — that combination only happens in Stage view, and only when the shelf is visible (hover-revealed by default, or forced with `shelf=always`). Wall/Carousel/Ribbon are alternative, mutually-exclusive top-level views that show workspaces-at-a-glance instead of the current-workspace exposé.

## (c) Animation

- Exact 7 animation style names (README quote): "Default preserves the existing smooth motion. Snap punches cards forward from depth, Glitch arrives in staggered digital cuts, Lightcycle sweeps cards horizontally like a signal, and Silk uses a slower floating settle across every layout. Reduced caps transitions at 90 ms, while Off makes them immediate." -> **Default, Snap, Glitch, Lightcycle, Silk, Reduced, Off** — matches the lead's claimed 7 names exactly.
- Also: "The old `quattro`, `cyberpunk`, `tron`, and `elegant` saved values remain compatible" — i.e. earlier/renamed style names still parse for backward compatibility.
- Duration config: `animation_duration` — "Fade duration in ms, `0` to `2000`" (default 180 per the Lua config block: `animation_duration = 180`).
- Continuous real-position-to-exposé morph: **not explicitly documented either way in the README.** Source evidence (WebFetch of raw files, not exhaustive review):
  - `src/overview/StageTransform.cpp` contains `remapStageRect`/`mapStagePointToSource`-style functions that do static aspect-ratio-preserving coordinate remapping between "source" and "stage" rectangles — consistent with computing a per-window start/end rect, but no interpolation/lerp/timing logic was found in that file itself.
  - `src/render/FadeAnimation.cpp` exists as a dedicated file, and the only config field for timing is literally named "Fade duration" — this is reasonably strong (but not certain) evidence the core transition mechanic is an opacity/scale fade rather than a continuous fly-from-real-desktop-position morph like GNOME/macOS Mission Control. The named styles (Snap "punches cards forward from depth", Lightcycle "sweeps cards horizontally") describe motion of the overview's own cards/grid, not confirmed to originate from each window's true screen coordinate.
  - Close animation was built separately (PR #3 "Feat/close animation", body empty, no description available) and drag animation separately (PR #8 "feat(wall): animate window drags", body empty) — titles confirm open and close (and drag) have distinct animation code paths, but PR bodies gave no further detail (both were empty/null via `gh api .../issues/N --jq '.body'`).
  - **Verdict: could not fully verify** whether opening is a continuous per-window position interpolation vs. a whole-overview fade/zoom; evidence leans toward fade/scale-based card transitions rather than per-window real-position morphing, but this is an inference from file/field naming, not a direct README statement.

## (d) Interaction: drag/drop, click, hover, keyboard, gestures

All quotes from README:
- Drag and drop between workspaces: "Drag a window onto a workspace card in Stage, Wall, Carousel, or Ribbon to move it there: the card lifts and follows the pointer, the workspace under it runs the destination lock, and the drop settles the card into place. Releasing over the window's own workspace, or over nothing, sends it back where it came from." Also: "Drag a window onto the trailing `+`, or just click it, to create a workspace."
- Click-to-focus: "Click a workspace to switch to it, click a window to focus it."
- Hover highlight: "Hover a workspace or window to move the selection; a short accent trace resolves into corner locks on the chosen card."
- Keyboard navigation: extensive — arrow keys (List vs Spatial modes), `1`-`9` jump to workspace, type-to-search, `/` for search, `Tab` cycles arrangements (or windows if `tab_cycles_windows=1`), `vim_keys` h/j/k/l, `Ctrl+,` preferences, `Enter` activate, `Esc` closes search/overview (full quotes captured in README fetch above).
- Trackpad gesture trigger: "A three-finger swipe up opens it and a swipe down closes it." Config: `gesture_enabled = true`, `gesture_fingers = 3` (values `3` or `4`), `gesture_distance = 300` (`120` to `800` px). Also: "While it is open, swipe left or right to preview the next workspace."
- Gesture mechanism — **plugin's own code, not Hyprland's native `gesture` config**: `src/input/GestureController.cpp` and `src/input/SwipeTracker.cpp` exist as dedicated plugin source files implementing swipe capture; the README's troubleshooting section confirms the plugin reads raw libinput events itself rather than delegating to a Hyprland-level gesture binding: "follow Hyprland's input log ... Look for a libinput `gesture: [3fg]` line. If the log only reports `[2fg]`, the touchpad or libinput did not recognize three fingers, so the gesture never reached the plugin." and the clickfinger-behavior workaround ("If the log shows the third contact entering `BUTTON_STATE_BOTTOM`, libinput is treating the bottom of the pad as a software button... Enable clickfinger behavior in Hyprland") shows the plugin consumes libinput gesture events directly (its own `GestureController`/`SwipeTracker`), competing with/needing coexistence alongside Hyprland's own gesture config rather than being implemented through Hyprland's declarative `gesture =` config keyword. Config option `gesture_enabled = false` is offered specifically for when "something else already owns that gesture" — i.e. it is understood to conflict with, not delegate to, Hyprland-level gesture bindings.

## (e) Multi-monitor, fullscreen/floating, special workspaces

- README does not contain an explicit dedicated section titled multi-monitor/fullscreen/special-workspaces. No direct quote found addressing multi-monitor behavior, fullscreen-window handling, or special (scratchpad-style) workspaces in the fetched README text.
- Indirect evidence only: `HyprlandCompat.hpp`'s summarized purpose list ("Retrieving windows, monitors, and workspaces... Scheduling monitor frame updates") shows the code is monitor-aware at the compat-layer level, and source file names (`WorkspaceWallLayout.cpp`, `OverlayGeometry.cpp`) suggest layout code exists per-workspace, but no file was read in enough depth to confirm actual multi-monitor placement behavior (e.g. whether the overview spans both monitors, mirrors per monitor, or only activates on the focused monitor), fullscreen-window special-casing, or special-workspace (scratchpad) inclusion/exclusion.
- **Could not verify**: multi-monitor behavior, fullscreen/floating handling, special-workspace handling. Not documented in README; not confirmed via the limited source excerpts fetched.

## (f) Architecture (evidence from source, via WebFetch of raw files — summarized/partial reads, not full manual review)

- It is a native Hyprland plugin (C++, built as `hypr-radiant.so`, loaded via `hyprctl plugin load` / `hyprpm`), using the standard Hyprland plugin ABI: `src/main.cpp` exports `APICALL EXPORT std::string PLUGIN_API_VERSION() { return HYPRLAND_API_VERSION; }`, matching Hyprland's plugin-loader contract (mismatched headers cause Hyprland to refuse/unload it, per README).
- State capture: `src/compositor/StateCollector.cpp` queries Hyprland's live compositor data structures directly (windows, workspaces, monitors) rather than capturing external screenshots — e.g. `state.windows.push_back({.stableId = window->m_stableID, .title = window->m_title, .geometry = geometryFrom(HyprlandCompat::windowPosition(window), HyprlandCompat::windowSize(window))...})` (quoted via WebFetch summary of raw file). This is in-process access to Hyprland's own `CWindow`/monitor/workspace objects, not a Wayland-protocol-level screenshot (no wlr-screencopy/toplevel-export usage was seen in the files fetched, though a full protocol audit was not performed — `hl_protocols_ToplevelExport.cpp`-style Hyprland-internal files were not checked against this plugin's own sources for such usage).
- Rendering: `src/render/OverlayRenderer.cpp` composites the overview UI by hooking into Hyprland's own render-pass pipeline, queuing pass elements such as `g_pHyprRenderer->m_renderPass.add(makeUnique<CRectPassElement>(data));` and drawing live window texture previews via a call along the lines of `renderWindowPreview(window, previewShell, windowAlpha, damage)` (quoted via WebFetch summary), at what the fetch described as Hyprland's `RENDER_LAST_MOMENT` render stage.
- It does **not** move real windows to new coordinates to build the overview: windows keep their real on-screen position/state, and the overview draws a separate compositor-side overlay layer of live texture previews (copies) on top, positioned according to the overview's own layout math (`OverlayGeometry.cpp`, `StageTransform.cpp`, `WorkspaceWallLayout.cpp`).
- Input: dedicated plugin-side controllers — `src/input/InputController.cpp`, `GestureController.cpp`, `SwipeTracker.cpp`, `KeyboardAction.cpp`, `ShortcutController.cpp`, `OpeningInputGuard.cpp` — read pointer/keyboard/libinput-gesture events directly rather than relying purely on Hyprland's declarative keybind/gesture config (see (d)).
- Lua/dispatcher surface: `src/main.cpp` registers both classic dispatchers (`HyprlandAPI::addDispatcherV2`, `registerDispatcher(DISPATCHER_TOGGLE, ...)` etc. for `radiant:toggle/open/close/preferences/app/shelf/status`) AND first-class Lua bindings via `HyprlandAPI::addLuaFunction(g_pluginHandle, "radiant", "toggle", luaToggle)` (and `open`, `close`, `preferences`, `status`) — this is a genuine Hyprland-API-level Lua binding registration, not just documentation-only.

## (g) Theming/chrome

- Colours/Omarchy auto-theme claim — VERIFIED, exact quote (README top): "It reads your Omarchy theme, so it should match the rest of your desktop without configuring anything." Further: "Radiant's accent always follows the selected Omarchy theme. If no Omarchy theme can be read, the colours fall back to a neutral grey. The palette is re-read every time the overview or preferences open, so switching themes does not need a reload. Installed themes are discovered from Omarchy's stock and user theme directories." Backed by source file `src/config/OmarchyPalette.cpp` (present, confirms this isn't just doc vapor) and a corresponding `OmarchyPaletteTest.cpp` unit test.
- Non-Omarchy manual theming — VERIFIED, supported: config keys `background_color`, `foreground_color` (`auto` follows Omarchy, or "set them yourself"), `chrome` (three explicit modes: `radiant` [original rounded look], `native` [mirrors Hyprland's own `decoration:rounding`, `general:border_size`, active/inactive border colors/gradients — file `src/config/HyprlandDecoration.cpp`], `flat` [square, fixed 2px accent border, no shadow/glow/blur by default]), `rounding` (0-40, or -1 to follow preset), `border_size` (0-12, or -1 to follow preset), `border_color` (`auto` or explicit colour string), `effects` (`auto`/`on`/`off`), `spacing` (card padding/gap multiplier 0.5-2.0), `font_family` (default `JetBrainsMono Nerd Font`). So it is NOT Omarchy-locked: a non-Omarchy Hyprland setup can theme it manually via these keys, and `chrome=native` explicitly reads plain Hyprland decoration config (no Omarchy dependency) as an alternative auto-theming path.
- Corner radius / blur / labels: `rounding`, `effects` (blur/shadow/glow bundle, per "Radiant" chrome preset description: "Radiant's original rounded appearance, with shadows, glow, and blur"), and `LabelRenderer.cpp` source file confirms window/workspace text labels are a distinct rendering concern (README doesn't give a dedicated label-content config key beyond `font_family`).

## (h) Verdict material (facts only, synthesis left to caller)

- Closeness to macOS Mission Control: Stage view (current-workspace windows spread non-overlapping + on-demand workspace strip) is the closest analogue to Mission Control's App-Exposé-plus-Spaces-bar behavior; separate "App Exposé" dispatcher (`radiant:app`) mirrors macOS's per-app Exposé (Ctrl+Down-on-app-icon-equivalent). However Mission Control's hallmark simultaneous "all Spaces as thumbnails ACROSS THE TOP + current Space windows exploded below" is only achieved in this plugin when Stage is combined with `shelf=always` (not the default `auto`), per (b) above — by default the two would need a hover/scroll to co-appear.
- Bus factor / maintainer risk: 229 total commits, 228 by nsumbadze alone (99.6%), 1 by a second contributor (fordaaaa); repo created 2026-07-24, most recent push 2026-09-08 — under 7 weeks of history. Zero GitHub Issues have ever been filed (0 via `is:issue` search); all 15 tracker items are the author's own merged PRs. The project was surfaced via a Discussion post the author wrote himself (https://github.com/omacom/omarchy/discussions/7695, self-authored, Aug 21 2026) which as of the last check had exactly one external reply. This is a single-maintainer, pre-community-adoption project by every available signal (no external issues, no external PRs, one external comment total, no releases/tags cut).
- ABI churn risk: confirmed real — the project needed a dedicated compatibility PR (#5) to support Hyprland 0.56 after presumably targeting 0.55.x first, requiring a new 181-line compat header (`HyprlandCompat.hpp`) with dual code paths gated by `__has_include` and CMake version checks. The README itself warns in strong terms: "The plugin ABI is tied to the exact Hyprland build... Rebuild the plugin after every Hyprland or compositor-library upgrade, even when the Hyprland version string itself did not change," and the `hyprpm.toml` commit-pin table has only a single entry (for 0.55.2), meaning 0.56.2 support is NOT locked via hyprpm's normal per-release pin mechanism — it depends on building fresh against whatever headers are locally installed, which is inherently fragile across Hyprland point releases. Given target system is Hyprland 0.56.2, this sits at the outer edge of the plugin's own claimed tested range ("build-tested against Hyprland 0.55.2, 0.55.4, and 0.56.2" — 0.56.2 IS explicitly claimed as tested, which is favorable), but the target system additionally runs the Lua config runtime (`hyprland.lua`) — the README's Lua examples (`hl.plugin.radiant.toggle()`, `hl.config({ plugin = { radiant = {...} } })`) suggest first-class Lua-runtime awareness, consistent with `HyprlandAPI::addLuaFunction` bindings found in `src/main.cpp`.

## Lua config dispatcher/binding example — CONFIRMED, exact quotes

From README (https://raw.githubusercontent.com/nsumbadze/hypr-radiant/main/README.md):
```lua
if hl.plugin.radiant then
    hl.config({ plugin = { radiant = { shortcut_enabled = false } } })
    hl.unbind("SUPER + A")
    o.bind("SUPER + TAB", "Radiant overview", hl.plugin.radiant.toggle)
end
```
and:
```lua
if hl.plugin.radiant then
    hl.config({
        plugin = {
            radiant = {
                opacity = 0.94,
                animation_duration = 180,
                layout = "stage",
                ...
            },
        },
    })
end
```
and: "On Quattro, the equivalent Lua functions are `hl.plugin.radiant.toggle()`, `open()`, `close()`, `preferences()`, and `status()`."
This is backed by actual source-level Lua binding registration in `src/main.cpp` (WebFetch-quoted): `HyprlandAPI::addLuaFunction(g_pluginHandle, "radiant", "toggle", luaToggle)` (and `open`, `close`, `preferences`, `status`) — so the Lua interface is real, registered plugin-side, not just README aspiration.

## Explicit list of things NOT verified / could not confirm

- Whether opening/closing animation is a continuous per-window interpolation from each window's true on-screen desktop coordinate into its exposé slot, versus a whole-overview fade/zoom — README doesn't say explicitly; file/field naming (`FadeAnimation.cpp`, "Fade duration in ms") leans toward fade-based rather than confirmed position-morph, but this is inference, not a direct quote.
- Multi-monitor behavior (span vs per-monitor vs focused-monitor-only) — no README section or source excerpt found addressing this directly.
- Fullscreen window handling in the overview — not addressed in fetched README text.
- Special workspace (scratchpad-equivalent) handling — not addressed in fetched README text.
- Full manual/line-by-line review of every source file was not performed (only targeted files were fetched via WebFetch, several returned as AI-generated summaries of the raw content rather than a full verbatim dump, e.g. CMakeLists.txt's first fetch, StateCollector.cpp, OverlayRenderer.cpp, StageTransform.cpp, HyprlandCompat.hpp) — treat architecture section (f) as representative excerpts, not an exhaustive audit. No screencopy/toplevel-export protocol usage was found in what was checked, but a negative was not exhaustively confirmed across the full `src/` tree.
- PR bodies for #1, #2, #4, #6, #7, #9, #10, #11, #12, #13 were not individually fetched (only #3, #5, #8, #10 bodies were checked, and #3/#8/#10 bodies were empty/null; #5 body was also null). Titles were taken at face value from the issues-list API call.
- Could not find any topics/tags on the repo (confirmed empty via API `topics: []`), so no topic-based cross-referencing was possible.
- Owner-name resolution: `omacom-io` (as suggested in the task lead) does NOT exist (404). Correct org is `omacom` (basecamp/omarchy redirects to omacom/omarchy). Flagging this since the lead's naming guess was wrong.

---

## 3. fedsfarm/gloview

# Deep verify: fedsfarm/gloview

## a. Repo metadata (gh api repos/fedsfarm/gloview)
- stars: 85
- license: GNU General Public License v3.0
- pushed_at (last push): 2026-09-12T10:24:34Z
- open_issues: 0 (all 13 issue-tracker items closed; two converted to Discussions)
- default_branch: main
- description: "A better macOS Mission Control-style overview plugin for Hyprland"
- forks: 8, archived: false, created 2026-06-30

## Version pin mechanism — VERIFIED, matches lead's claim
- `hyprpm.toml` (https://raw.githubusercontent.com/fedsfarm/gloview/main/hyprpm.toml): no version field at all, just build commands (`cmake -S . -B build ...`).
- `CMakeLists.txt` (https://raw.githubusercontent.com/fedsfarm/gloview/main/CMakeLists.txt): `pkg_check_modules(HYPR_DEPS REQUIRED hyprland)` — links against whatever `hyprland` pkg-config reports on the build machine. No `#if HYPRLAND_API_VERSION` / commit-hash / min-version check anywhere in the build system.
- README.md (https://raw.githubusercontent.com/fedsfarm/gloview/main/README.md), "Manual build" section, exact quote:
  > "Produces `build/gloview.so`. The ABI must match the running Hyprland exactly — build against the same headers, or a version skew gives a `.so` that crashes on load."
- Confirmed by maintainer in issue #9 (https://github.com/fedsfarm/gloview/issues/9), comment by fedsfarm:
  > "Only official releases are supported, use a stable version"
- Issue #9 itself: "Build error: 'SHyprCtlCommand' not declared in scope" — reporter built against a Hyprland git-main commit and hit an ABI break (`registerHyprCtlCommand` signature changed). Another commenter confirms building fine against the official 0.56.1 release. So: **no fixed version pin beyond "match your installed Hyprland's headers"; git/main Hyprland builds can and do break it; official point releases (0.56.1 confirmed working) are fine.** No issue mentions 0.56.2 by number in title/body text search, but two PRs (#16, #18, merged) list "Hyprland version: 0.56.2 (`v0.56.2`, efb5099)" in their environment section as the version they were tested against — so 0.56.2 is confirmed working as of 2026-09-12 (last push date).
- Issue search for "0.56|build|crash|Lua" (case-insensitive) matched: #18, #16 (both mention 0.56.2 in PR template "Environment" field, not in title), #14, #9 (build error, above). No issue is literally about a crash on 0.56.2, and none mention "Lua" as a problem area.

## b. View modes — verified against README + issue traffic
Three **layout engines** for the main preview area (config key `layout`), quoted from README:
- `rows` (default) — "macOS-like: previews keep their aspect ratio and are packed into balanced rows, with the row count chosen to make the previews as large as possible. Reads spatially like the real desktop."
- `grid` — "uniform cells, one preview centered in each."
- `natural` — "keeps each window's real on-screen position, uniformly scaling the whole arrangement to fit."

Separately there are **two orthogonal view modes**, toggled independently of layout:
- Normal overview (`gloview:open`/`toggle`): shows the strip (all workspaces as small live-preview cards) **plus** the exposé of the CURRENT/displayed workspace's windows in the main area, laid out per the `layout` engine above. So yes — spaces-bar strip AND same-workspace exposé are shown together, simultaneously, in the default mode.
- All-workspaces "expo" view (`gloview:allworkspaces`, config `show_all_workspaces`): README quote — "Main area shows every window on the monitor (expo), not just the displayed workspace." This is a distinct mode that must be toggled in; it is not concurrent-by-default with the plain per-workspace exposé, they are alternate states of the same main area.
- "Desktop" mode (`gloview:desktop`) — Overview::toggleDesktop() "free-arrange desktop mode" (per overview.hpp doc-comment) — a third state, flips canvas/grid per `key_desktop` (default `shift`).
- Confirmed by source doc-comment (overview.hpp, https://raw.githubusercontent.com/fedsfarm/gloview/main/src/overview.hpp): `void toggleAllWorkspaces(); // open (or, if already open, toggle) the all-workspaces "expo" main view`

So the precise answer to "b": gloview shows the workspace strip (live thumbnails of all workspaces) together with a spread/exposé of the CURRENT workspace's windows at the same time in its default mode; a separate explicit toggle (`gloview:allworkspaces`) expands the main area to show every window on every workspace on that monitor simultaneously (the full "expo" the lead described). Both exist, they're just different button presses.

## c. Animation timing — verified, "~360ms" lead claim confirmed almost exactly
README config table, exact rows:
- `duration` | int (ms) | default `360` | "Open/close animation length"
- `switch_duration` | int (ms) | default `260` | "Length of that slide" (workspace-switch slide inside the overview, `switch_animation`)
- `move_duration` | int (ms) | default `240` | length of the "window dropped on a workspace card keeps flying into it, shrinking into its slot" animation (`move_animation`)

Continuity of open/close animation — verified from PR bodies (both merged), which describe frame-by-frame behavior:
- PR #16 (https://github.com/fedsfarm/gloview/pull/16), merged: "on close every tile glided to its window's real geometry" — i.e., each window tile animates from its exposé slot back to its real on-screen rect (continuous per-window animation, not a whole-view fade/zoom). Confirms non-live-desktop tiles (expo: windows on other workspaces) instead "fade... in place" rather than fly, since they have no real on-screen rect to fly from/to.
- PR #18 (https://github.com/fedsfarm/gloview/pull/18), merged: "every tile hands off to a real on-screen window only when that window is on the live desktop... every other tile ... is pinned at its grid slot ... and fades in there ... instead of flying in from a real geometry it does not occupy on screen."
- Config comment for `natural`: `LRect natural; // monitor-local logical: real place (goal); animation start` (overview.hpp) — the "natural" rect literally is the animation start/end point = the window's real screen geometry. This confirms per-window continuous position animation for on-desktop windows, and cross-fade for off-desktop (expo) windows — not a single overview-wide fade/zoom.
- README `switch_duration`/`switch_animation`: "Slide the previews sideways when the displayed workspace changes (the outgoing set leaves as the incoming one arrives)" — a slide transition when stepping workspace while the overview stays open (this one IS a group/whole-view slide, distinct from the per-window open/close fly animation).

## d. Interaction — drag/click/hover/keyboard/gestures
- Drag-and-drop: `drag_to_swap` (bool, default 1) — "Grid mode: dropping a preview onto another swaps the two windows' places." `switch_on_drop` (bool, default 0) — "Dropping a window on a card also follows it to that workspace." Source has `renderDragTile`/`renderDragWindow`/`renderDragRing` render hooks (overview.hpp) confirming a live drag visual. So: drag windows onto other window previews (swap, grid mode) and drag windows onto workspace strip cards (move to workspace) are both supported.
- Click-to-focus: `key_activate` default `enter`; mouse click handled via `onMouseButton()`; clicking a preview focuses/activates it (implicit from `exit_on_click`, `switch_on_new_workspace`, and the whole card/tile click model in overview.hpp).
- Hover highlight: `hover_border`/`hover_border_size` config (window preview), `strip_hover_border`/`strip_hover_border_size` (workspace card), `focus_follows_mouse` (bool, default 1) — "Keyboard selection tracks the hovered preview."
- Keyboard navigation: extensive — `key_next_workspace`(tab)/`key_prev_workspace`(shift+tab) cycle displayed workspace; `key_left/right/up/down` move keyboard selection among previews; `key_activate`(enter) focuses selection; `key_close_window`(d) closes selected window without leaving overview; `key_all_workspaces`(a) toggles expo; `key_workspace` = "1,2,3,4,5,6,7,8,9,0" jumps to Nth strip card. `select_border`/`select_border_size` shows the keyboard-selected tile distinctly from the hovered one.
- Gestures (trackpad swipe): **NOT supported by gloview itself.** Issue #10 (https://github.com/fedsfarm/gloview/issues/10), "Sync current workspace with gloview workspace": user reports "I have gestures set up to go back and forth between workspaces by 3-finger swiping... Right now, changing the workspace by swiping ... only changes the actual workspace underneath gloview but not in gloview itself." This issue has NO comments and was closed then `converted_to_discussion` by fedsfarm (timeline event, no merge/fix commit associated) — i.e. moved to Discussions, not implemented. gloview has no native gesture recognition; only Hyprland-level gesture binds that change the live workspace exist, and (per this report, as of its filing) gloview's own overview state doesn't necessarily follow them. Could not verify whether this was later fixed silently outside the issue tracker — no linked commit found.

## e. Multi-monitor / fullscreen / special workspaces
- Multi-monitor "expand to all monitors simultaneously": **requested, not implemented.** Issue #8 (https://github.com/fedsfarm/gloview/issues/8), "EXPAND: show overview on all monitors": "users should be able to configure weather the overview opens on all monitors... I think hyprspace does this by allowing to pass `all` to the lua api functions." Timeline: closed by fedsfarm then `converted_to_discussion` — no merge commit, no code changes attributed. So currently each overview instance is per-monitor.
- Per-monitor targeting confirmed in source (overview.cpp): the overview picks its monitor from cursor position at open time — `State::monitorState()->query().vec(Pointer::mgr()->position()).run()` then `m_monitor = m`. Cross-monitor window bleed was a filed bug (issue #6, "windows on 2 monitors ... partly stay on their other monitors that the overview isn't in") fixed together with issue #7 by commit 2cf8f02 (message: "Issues #6, #7: cross-monitor window bleed, duplicate empty workspace card, next/prev outside the overview, expo selection not switching workspace").
- Fullscreen: overview.cpp references `Fullscreen::controller()->getFullscreenModes(w).internal == Fullscreen::FSMODE_FULLSCREEN` used to set `dontRound` on the render data — fullscreen windows get square (non-rounded) preview corners; otherwise treated like any other window/tile.
- Floating: overview.cpp comment: "inside the card: a window whose tiled slot pokes outside the monitor (floating, offscreen, ...)" — floating/offscreen windows are handled/clamped in layout, not excluded.
- Special (scratchpad) workspaces: excluded from the strip by default; config `show_special` (bool, default 0) — "Include the special (scratchpad) workspace as a strip card." Source: `ws->m_isSpecialWorkspace` checks throughout (e.g. tileBelongs(), workspace-pruning code) explicitly skip special/named (`-1337…`) workspaces unless opted in.

## f. Architecture (source: overview.hpp, overview.cpp, main.cpp)
- Doc-comment in overview.hpp states the rendering model directly: "The whole thing is drawn compositor-side from window snapshots over a blurred backdrop; real windows are hidden while it is up."
- Real-window hiding is done via a function hook on Hyprland's internal `shouldRenderWindow`: `hkShouldRenderWindow(void* thisptr, PHLWINDOW window, PHLMONITOR monitor)` calls `g_overview->shouldHideWindow(window, monitor)` and falls back to the original (`g_shouldRenderOrig`) otherwise — a classic Hyprland plugin trampoline hook (`CFunctionHook` declared in overview.hpp), not a Wayland-protocol-level capture.
- A companion `forceRenderWindow()` check forces Hyprland to render windows on inactive workspaces so their snapshot isn't blank ("otherwise the snapshot is grey preview").
- Rendering hooks into Hyprland's render pass via `renderStage(eRenderStage stage)` plus a long list of dedicated render callbacks (renderBackdrop, renderStrip, renderStripWindows, renderMainWindows, renderPreviewRings, renderDragTile, etc., all declared in overview.hpp) — the plugin draws its own overlay every frame using Hyprland's own render pass/pass-element system (`renderWindowLive` builds `CSurfacePassElements` directly), i.e. it re-renders the window's LIVE wl_surface texture into a new destination rect each frame rather than pre-baking a static screenshot bitmap. A `Tile` struct keeps a `captured`/`snapSource` pair, described as "window's frozen position when its snapshot was taken; crop source" — so there is a frozen/snapshotted source rect used to compute crop/UV, but the surface content drawn is still the window's live texture, updated per frame (per the "renderMainWindows: live window surfaces" doc-comment) — it does not physically move/reparent real windows; it renders copies of their live surface at new coordinates while hiding the originals.
- Config values are registered via `HyprlandAPI::addConfigValueV2`, read back through the `Config::Values::CIntValue`/`CColorValue`/etc. `value()` accessor rather than the deprecated `getConfigValue()` call — a source comment explains this is specifically because the deprecated path "does NOT observe values set from a Lua `hl.config{}` config," confirming first-class Lua-config support was a deliberate compatibility fix, not an afterthought.
- Lua bindings are registered directly in main.cpp using the Lua C API (`lua.h`/`lauxlib.h`) — functions like `luaToggle`, `luaOpen` wrap the corresponding C++ dispatcher and are exposed as `hl.plugin.gloview.*` (per README Lua example).

## g. Theming/chrome — extensive, fully configurable
Full color/shape table in README (plugin:gloview:* namespace), highlights: `preview_round` (window corner radius, px), `strip_card_round` (workspace card corner radius, px), `blur` (0..1 backdrop+strip blur strength), `backdrop_color`, `strip_band_color`, `strip_card_color`, `strip_active_color`, `strip_active_border(_size)`, `strip_hover_border(_size)`, `strip_plus_color`, `preview_bg`, `shadow_color`, `hover_border(_size)`, `select_border(_size)`, `close_button_color` — all `0xAARRGGBB` integers. Labels: `show_workspace_labels` and `show_window_labels` (both bool, default 1) toggle name/title text independently of the chrome. `preview_filter` (`box4`/`box16`/`linear`) controls GPU downsampling quality for shrunk previews.

## h. Verdict material
- AI-authorship disclosure is explicit and repeated: PR #16 body: "This PR was entirely created by Fable 5.1 on my directive after noticing the bug... I have no knowledge of the codebase beyond a quick glance of the generated code and docs. I HAVE tested this manually..." PR #18: "I instructed Fable 5.1 to investigate and fix a similar bug. I have tested this manually..." README, "Contribute" section: "AI code is allowed if it's submitted and tested by a human." So a real share of the recent bugfix history (at least 2 of the last 3 merged PRs) is AI-generated, human-reviewed/tested per the author's own account — an explicit, disclosed practice, not hidden "vibecoding," but it does mean the maintainer (single person, "fedsfarm"/"Vergil" per hyprpm.toml `authors`) is the sole reviewer and sole point of failure.
- Bus factor: one listed author ("Vergil") in hyprpm.toml, one GitHub account (fedsfarm) closing every issue and merging every PR seen. No co-maintainers evident.
- ABI churn risk: confirmed real and already manifested once (issue #9, git-main Hyprland broke the build) within the repo's ~2.5 month lifetime (created 2026-06-30). Maintainer policy is explicit: only build against official Hyprland releases, not git main — meaning updates to gloview may lag a fresh Hyprland release until it's rebuilt/retested, and a AUR/hyprpm binary built against one point release is not guaranteed to load against a different one ("a version skew gives a `.so` that crashes on load," per README).
- Very new repo (created 2026-06-30, so ~2.5 months old at last push 2026-09-12) with 85 stars, 8 forks, 0 open issues (13 filed, all closed/converted-to-discussion) — active, responsive maintenance so far, but short track record.

## Lua dispatcher / binding example — CONFIRMED, README quote in full
README.md, "Usage" section, exact Lua block (https://raw.githubusercontent.com/fedsfarm/gloview/main/README.md):
```lua
hl.bind("SUPER + TAB", hl.plugin.gloview.toggle)
hl.bind("SUPER + SHIFT + TAB", hl.plugin.gloview.desktop)
hl.bind("SUPER + CTRL + TAB", hl.plugin.gloview.allworkspaces)

hl.bind("SUPER + bracketright", hl.plugin.gloview.next)
hl.bind("SUPER + bracketleft", hl.plugin.gloview.prev)
hl.bind("SUPER + 2", function() hl.plugin.gloview.setworkspace(2) end)
```
Also a full `hl.config({ plugin = { gloview = { ... } } })` Lua config block covering every `plugin:gloview:*` option (see README "### Lua" section) — this is a first-class Lua config surface, not just an INI fallback with Lua as afterthought; a source comment in overview.hpp explains the config-read path was specifically fixed to support Lua-set values (see architecture notes above).

## Discrepancy flagged vs. the lead
- Lead said "packaged in AUR as `gloview-git`." README's own AUR install instruction (https://raw.githubusercontent.com/fedsfarm/gloview/main/README.md, "Arch (AUR)" section) says: `yay -S gloview` — no `-git` suffix shown. Could not independently confirm via the AUR site itself (blocked, see below), so cannot confirm whether a `gloview-git` package additionally/instead exists. Flag as unverified / possible lead inaccuracy.

## Could not verify / fetch failures
- AUR page https://aur.archlinux.org/packages/gloview-git — blocked by Anubis anti-bot protection (WebFetch returned an access-denial/challenge page, no package metadata, no last-updated date, no maintainer name obtainable this way).
- Could not confirm whether issue #10 (gesture sync) or #8 (multi-monitor expand) were ever addressed later outside the issue tracker (e.g., silently in a later commit not linked to the issue) — GitHub timeline shows only `closed` + `converted_to_discussion`, no linked commit, and no way to search Discussions via the tools available here.
- Did not fetch overview.cpp/layout.cpp in full (only grepped/sampled) — full byte-for-byte review of animation math and render-loop correctness was not performed; conclusions on animation behavior rely on doc-comments, config docs, and PR descriptions, which are internally consistent but not independently reproduced by running the plugin.
- No explicit repo-side statement of which exact Hyprland version range (e.g., "0.55-0.56.x") is supported beyond "match the headers you build against" / "use a stable version" — confirms the lead's claim that there is no fixed version number pinned in any manifest.

---

## 4. colonelpanic8/hyprwinview

# Deep verify: colonelpanic8/hyprwinview

Repo: https://github.com/colonelpanic8/hyprwinview
Fetched: 2026-09-13. Methods used: `gh api` (repo metadata, issues, pulls, contents, code search) and `curl` against raw.githubusercontent.com for file bodies. No WebFetch calls were ultimately needed (gh api + raw curl covered everything); no fetch failures to report.

## a. Repo facts, version pin, issues

Source: `gh api repos/colonelpanic8/hyprwinview --jq ...`
```json
{"created":"2026-04-29T20:08:08Z","default_branch":"main","desc":"Experimental Hyprland window overview plugin","fork":false,"homepage":null,"license":"BSD 3-Clause \"New\" or \"Revised\" License","open_issues":0,"parent":null,"pushed":"2026-09-08T05:34:32Z","stars":10}
```
- Stars: 10. License: BSD 3-Clause "New" or "Revised" License. Last push: 2026-09-08T05:34:32Z. Open issues: 0. Created 2026-04-29.
- `fork:false`, `parent:null` — **hyprwinview is NOT a GitHub fork of hyprtasking.** It is a from-scratch repo (created 2026-04-29) that vendors/imports Hyprtasking's workspace-overview code at the source level (see part f). This refutes a literal "GitHub fork" reading of the lead but confirms code-level derivation.
- GitHub repo description (API `desc` field): **"Experimental Hyprland window overview plugin"** — matches the lead's "experimental" self-label, sourced from the GitHub API description field (also echoed in README's opening line, quoted below).

Issues/PRs (`gh api repos/colonelpanic8/hyprwinview/issues?state=all&per_page=30`): only 3 items exist, **all closed pull requests**, no plain issues:
- PR #2 "Support Hyprland 0.56" — merged 2026-07-20T17:35:12Z. Body (https://github.com/colonelpanic8/hyprwinview/pull/2):
  > "## What\n- migrate window and workspace enumeration to the new state APIs\n- use the fullscreen, window-move, and pointer controllers introduced by Hyprland 0.56\n- update moved monitor headers and the Hyprland lock\n\n## Verification\n- exact Hyprland v0.56.0 Nix build\n- clang-format check\n- `git diff --check`"
  - Files touched: `.clang-tidy`, `flake.lock`, `src/overview.cpp` (+19/-16), `src/winview_pass_element.cpp` (+1/-1). This is a real code migration for 0.56's API churn, not a doc-only bump.
- PR #3 "Fix cursor hidden behind overview background/blur" — merged 2026-07-28T08:06:04Z (https://github.com/colonelpanic8/hyprwinview/pull/3):
  > "Software cursors get queued into the render pass before `RENDER_LAST_MOMENT` fires (Hyprland 0.56 `Renderer.cpp`), so hyprwinview's overview element (background fill/blur/tiles), which is added at `RENDER_LAST_MOMENT`, painted over the already-queued cursor. Re-queue the cursor draw immediately after the overview pass element so it renders on top."
  - This is a real post-0.56 regression fix, evidence the author is actively tracking 0.56's renderer internals.
- PR #1 "Recover hidden scratchpads from overview" — merged 2026-07-11T22:21:36Z. Scratchpad/minimized-workspace handling, unrelated to version pinning.

No issue/PR text matched "crash" or "Lua" in the search regex beyond the two above (`0.56|build|crash|Lua`, case-insensitive) — only PR #2 and PR #3 matched (both via "0.56"/"build"/"crash"), confirmed by re-running the filtered query.

**Version pin mechanism** — source: https://raw.githubusercontent.com/colonelpanic8/hyprwinview/main/hyprpm.toml
```toml
[repository]
name = "hyprwinview"
authors = ["Ivan Malison", "Raymond Bian"]
commit_pins = [
    # Hyprland v0.56.0                          hyprwinview v0.1.0
    ["36b2e0cfe0c6094dbc47bd42a437431315bb3087", "30796826ad253b886682d70b01564509cb721d66"],
]
```
This is `hyprpm`'s standard commit-pin mechanism: it pins hyprwinview commit `3079682...` to Hyprland commit `36b2e0c...` (tagged as "Hyprland v0.56.0" in the comment). There is exactly one pin entry — only 0.56.0 is pinned via hyprpm; no explicit older-version pin is present in this file. Note the listed author "Raymond Bian" — this is raybbian, the Hyprtasking author, listed as a co-author of hyprwinview itself (not just an upstream credit), which is a stronger tie than "derived from" implies.

`CMakeLists.txt` (https://raw.githubusercontent.com/colonelpanic8/hyprwinview/main/CMakeLists.txt) declares project version `0.2.0`, C++23, and links against `hyprland cairo librsvg-2.0 libdrm libinput libudev pangocairo pixman-1 wayland-server xkbcommon` via pkg-config — no explicit minimum Hyprland version check in CMake itself; version compatibility is enforced at runtime by an API-hash check in `main.cpp` (see part f) and by the hyprpm commit pin above.

README (https://raw.githubusercontent.com/colonelpanic8/hyprwinview/main/README.md) states the "0.54+" claim explicitly, the only place this exact wording is sourced:
> "On Hyprland 0.54 and older hyprlang configs, the same options live under `plugin { hyprwinview { ... } }`."
This confirms the plugin supports both the new Lua config path (current, ≥0.55/0.56-era) and legacy hyprlang config on 0.54 and older — the lead's "0.54+, Lua for modern versions" framing is accurate and directly sourced here.

Hyprtasking comparison (`gh api repos/raybbian/hyprtasking --jq ...`):
```json
{"desc":"Powerful workspace management plugin, packed with features","license":"BSD 3-Clause \"New\" or \"Revised\" License","pushed":"2026-09-09T01:53:34Z","stars":376}
```
376 stars vs hyprwinview's 10; both BSD-3-Clause; hyprtasking pushed one day after hyprwinview (2026-09-09 vs 2026-09-08) — both actively maintained. hyprwinview is not a thin wrapper: it imports Hyprtasking's workspace module wholesale (see part f) but adds an entire second "window overview" subsystem (app icon resolution/caching, type-to-filter, window-order grouping, multiple animation modes, Lua bindings for the new mode) that has no equivalent in Hyprtasking.

## b. View modes: spaces strip vs current-workspace exposé — do they co-occur?

Source: README (https://raw.githubusercontent.com/colonelpanic8/hyprwinview/main/README.md), opening paragraph:
> "`hyprwinview` is an experimental Hyprland plugin providing both window and workspace overviews from one loaded plugin. The window overview shows open windows regardless of which workspace they are on. The embedded workspace overview is derived from Hyprtasking and renders live workspace previews with grid and linear layouts. Keeping both modes in one binary gives the rendering hooks, input capture, and overview lifecycle a single owner."

Two distinct, **mutually exclusive** modes, confirmed explicitly:
1. **Window overview** (hyprwinview's own addition): an exposé of *windows* — "continuously live-renders mapped windows into an overview grid, including windows on inactive workspaces" and "sizes the grid from window count and monitor aspect ratio." This is the non-overlapping grid/exposé of windows, and by default it pools windows from **all** workspaces (`other-workspaces`/`exclude-current-workspace` dispatcher args can restrict it to just other workspaces, implying default is all-workspace).
2. **Workspace overview** (inherited from Hyprtasking, in `src/workspace/`): shows live-rendered thumbnails of each **workspace** (not individual windows) arranged in a `grid` or `linear` layout (source: `src/workspace/layout/{grid,linear}.cpp` exist per `gh api .../contents/src/workspace/layout`). This is the closer analogue to a macOS "Spaces" strip.

Critically, README states explicitly they cannot be shown together:
> "prevents the window and workspace modes from owning rendering or input simultaneously" ... "Opening one overview mode immediately releases the other mode, so live workspace rendering cannot modify window-mode render passes."
Also from the workspace README (https://raw.githubusercontent.com/colonelpanic8/hyprwinview/main/src/workspace/README.md):
> "Combined-mode changes ensure that activating the workspace overview releases an active window overview and vice versa."

**Answer to (b): only one of the two views is ever active at a time.** There is no combined single screen that shows a live spaces-strip of all workspaces AND spreads the current workspace's windows into a non-overlapping exposé simultaneously, the way macOS Mission Control does (Spaces strip on top + exposé below, at once). A user must toggle between "window mode" (exposé of windows) and "workspace mode" (grid/linear of workspace thumbnails); the plugin enforces this exclusivity at the render/input level, it is not just a UI convention.

## c. Animation

README, plugin options block (https://raw.githubusercontent.com/colonelpanic8/hyprwinview/main/README.md):
```
animation = "workspace_zoom",
animation_in_ms = 180,
animation_out_ms = 140,
animation_scale = 0.94,
animation_stagger_ms = 16,
animation_stagger_max_ms = 120,
animation_workspace_zoom_stage_ratio = 0.45,
animation_workspace_zoom_gap = 18,
```
And explicit enumeration:
> "`animation` accepts `fade_scale`, `staggered`, `workspace_zoom`, `fade`, or `none`."
This exactly matches and confirms the lead's claimed mode names (fade_scale / staggered / workspace_zoom / fade), plus a `none` mode the lead didn't mention. Config option name is literally `animation` under `plugin.hyprwinview` (Lua) / `plugin { hyprwinview { animation = ... } }` (legacy hyprlang, 0.54 and older).

Continuous-from-real-position confirmed at source level, `src/overview.cpp` (fetched via raw.githubusercontent.com/colonelpanic8/hyprwinview/main/src/overview.cpp):
```cpp
const auto WIN_POS    = preview.window->m_realPosition->value();
const auto WIN_SIZE   = preview.window->m_realSize->value();
```
(in `CWindowOverview::workspacePanelBoxForPreview`, used for the `workspace_zoom` animation's start/panel geometry) — the plugin reads each window's live, currently-animating on-screen position/size (`m_realPosition`/`m_realSize` are Hyprland's own animated window geometry properties) as the animation's origin, then interpolates a live-rendered copy of that window into the overview tile. So yes: for `workspace_zoom` (and presumably `fade_scale`/`staggered`, not individually re-verified beyond the enum) the open animation is a continuous move from each window's actual current screen position into the grid, not a whole-screen fade/zoom of a static snapshot. README describes `workspace_zoom` in most detail:
> "`workspace_zoom` treats windows as living in a fixed workspace grid. Workspace 1 is placed in the first cell, workspace 2 in the second cell, and so on... The animation starts with the camera zoomed into the initially focused workspace's fixed cell, zooms out to reveal the workspace plane, then moves and resizes windows into the final overview grid."

Close animation: separate `animation_out_ms` (140ms default) from `animation_in_ms` (180ms default) confirms open/close are timed independently; no separate close-only animation *mode* name is documented — same `animation` mode is presumably used symmetrically (not explicitly stated either way in README; flagged as unverified beyond the timing-split fact).

## d. Interaction: drag-and-drop, click-to-focus, hover, keyboard nav, gestures

- **Click-to-focus / hover highlight**: README bullets — "focuses the hovered window", and config has `hover_border_col` (default `rgba(66ccffee)`) distinct from `border_col`, confirming a hover-highlight border on the window overview grid.
- **Keyboard nav + type-to-filter**: README — "supports keyboard navigation while the overview is active" and "shows window title/class labels and supports type-to-filter narrowing." Confirmed by the extensive `keys_filter_*` / `keys_default_action` config surface and the filter-mode behavior paragraph:
  > "In filter mode, printable keys update the filter query and only windows whose title, class, initial title, or initial class contain all query tokens remain in the grid... `Backspace` and `Delete` delete one character and repeat while held, `Ctrl+u` clears the query..."
  This matches the lead's "vim nav + type-to-filter" in substance (arrow keys plus `h/j/k/l`-style `a/s/w/d` defaults in the Lua `configure` example: `left={"a","h","left"}`, `down={"s","j","down"}` etc.), though "vim nav" isn't the plugin's own term — it's my/the lead's label for the `hjkl`-style default bindings actually present.
- **Drag-and-drop — important asymmetry found at source level, not stated plainly in README**: `gh api search/code` for "floating"/"drag" and direct file reads show mouse drag-and-drop between workspaces exists **only in the workspace-overview module** (`src/workspace/input.cpp`, functions `HTManager::start_window_drag`/`end_window_drag`, log tag `"[Hyprtasking]"` retained verbatim in a log line), inherited directly from Hyprtasking. The window-overview file (`src/overview.cpp`, 1551 lines) has **zero** matches for "drag" — cross-workspace movement in window-overview mode is keyboard-only, via the `bring`/`bring-replace` dispatcher actions (`Ctrl+b`/`Ctrl+Shift+b`) calling `Desktop::globalWindowController()->moveWindowToWorkspace(window, TARGET_WORKSPACE)`. So: **drag-and-drop is real and preserved, but only in the Hyprtasking-derived workspace-overview mode, not in the window-overview/exposé mode**, which uses keyboard "bring" instead.
- **Gestures**: real trackpad swipe-gesture support exists but **only in the workspace-overview module**, inherited from Hyprtasking, and it is the plugin's **own C++ code listening to Hyprland's internal gesture event bus**, not the user-facing `gesture` keyword in hyprland.conf/hyprland.lua. Source, `src/workspace/module.cpp`:
  ```cpp
  callbackListeners.push_back(Event::bus()->m_events.gesture.swipe.begin.listen(on_swipe_begin));
  callbackListeners.push_back(Event::bus()->m_events.gesture.swipe.update.listen(on_swipe_update));
  callbackListeners.push_back(Event::bus()->m_events.gesture.swipe.end.listen(on_swipe_end));
  ```
  with config values (same file): `gestures:enabled`, `gestures:move_fingers` (default 3), `gestures:move_distance` (300.0), `gestures:open_fingers` (default 4), `gestures:open_distance` (300.0), `gestures:open_positive`. This is **not documented in the top-level README at all** (no "gesture" string anywhere in README.md) — found only via GitHub code search and direct file inspection. Mechanism: plugin-internal event-bus listener reacting to Hyprland's raw swipe events, i.e. plugin's own code, not Hyprland's declarative `gesture` config dispatcher binding. No gesture support was found for the window-overview mode.

## e. Multi-monitor, fullscreen/floating, special workspaces

- **Multi-monitor**: README's only explicit line is "sizes the grid from window count and monitor aspect ratio" (singular "monitor" — this is the window-overview mode sizing its grid to whichever monitor the overview opened on, not a claim about spanning multiple monitors in one grid). At the source level, the workspace-overview module (Hyprtasking-derived) is monitor-aware per-instance: `src/workspace/layout/grid.cpp` keys everything off `get_monitor()`/`view_id`, respects Hyprland's workspace-to-monitor binding rules (`Config::workspaceRuleMgr()->getBoundMonitorForWS(...)`), and has an explicit safety comment:
  > "No two grids may map the same WORKSPACEID, else dragging into a slot could silently switch monitors."
  So "multi-monitor aware grid sizing" is accurate for the workspace-overview mode (each monitor gets its own independent workspace grid/overview instance, workspace-monitor bindings respected), but the phrase does not mean a single overview spans/tiles across multiple physical monitors — each monitor shows its own overview.
- **Fullscreen**: handled explicitly in `src/overview.cpp` via `#include <hyprland/src/managers/fullscreen/FullscreenController.hpp>` and a guard in the bring-replace logic: `!Fullscreen::controller()->isFullscreen(window) && !Fullscreen::controller()->isFullscreen(initialFocusedWindow)` — fullscreen windows are excluded from the "replace the originally-focused window" fast path. Not otherwise documented in README.
- **Floating**: `src/workspace/manager.cpp` uses a `Desktop::View::ALLOW_FLOATING` query flag when resolving drop targets during drag, and `src/workspace/render.cpp` reads `window->m_floatingOffset` when computing the live-preview transform for slid-out/floating windows. Floating windows are accounted for in rendering and drag-drop math; no separate floating-specific *feature* (e.g., pinning) is documented.
- **Special workspaces / scratchpads**: explicitly documented, README:
  > "If the selected window is minimized on a `minimized` or `special:minimized` workspace, or hidden on `special:NSP` or a `scratch-hidden-*` scratchpad workspace, `select` always restores it to the current workspace like `bring` before focusing it. It never navigates to those storage workspaces."
  This is also the subject of merged PR #1 ("Recover hidden scratchpads from overview").

## f. Architecture (3-5 sentences, with inheritance breakdown)

`main.cpp` (https://raw.githubusercontent.com/colonelpanic8/hyprwinview/main/src/main.cpp) is a standard Hyprland C++ plugin entry point: `PLUGIN_INIT` checks `__hyprland_api_get_hash() == __hyprland_api_get_client_hash()` (aborts with a notification on any header/runtime API mismatch — this is the real, strict version gate, stricter than the hyprpm commit pin) and registers ~30 `plugin:hyprwinview:*` config values plus dispatchers/Lua bindings. Rendering is done via a custom Hyprland render-pass element, `CWinviewPassElement` (`src/winview_pass_element.cpp`, `IPassElement` subclass), whose `draw()` calls into `CWindowOverview::drawBackground()/drawForeground()` — confirmed by PR #3's description that this element is queued at Hyprland's `RENDER_LAST_MOMENT` hook point (`Renderer.cpp`). Windows are **not** actually moved: the plugin reads each window's live `m_realPosition`/`m_realSize` (Hyprland's own animated geometry) purely as the animation's start point, then composites a live-rendered copy of the window into the overview tile at an arbitrary screen location — a "render copies into a custom pass" architecture, not "reparent/move real windows." Input capture uses Hyprland's `InputManager`/`SeatManager`/`PointerController` APIs directly (`g_pInputManager->getMouseCoordsInternal()`, etc.) plus Lua-exposed dispatchers (`hyprwinview:overview ...`) implemented with the real Lua C API (`lua.hpp`, `lua_State*`, in `src/lua_api.cpp`) backing `hl.plugin.hyprwinview.configure()`/`.overview()`. **Inheritance split**: the entire `src/workspace/` subtree (module.cpp, manager.cpp, input.cpp, render.cpp, layout/{grid,linear}.cpp, pass/pass_element.cpp) is a direct import of Hyprtasking's code — the module's own README states "imported from commit `e53b9bd0440a0f85d64d86762fd84111d4de2e3d`" of raybbian/hyprtasking, retaining "the Hyprtasking Lua API, dispatchers, configuration namespace, workspace layouts, renderer hooks, and input behavior" (including gesture-swipe handling and workspace drag-and-drop) — while everything under `src/` at the top level (`overview.cpp`, `winview_pass_element.cpp`, `app_icon*.cpp`, `dispatcher.cpp`, `lua_api.cpp`) is hyprwinview's own new "window overview" subsystem plus the glue (`module.cpp` lifecycle functions) that makes the two mutually-exclusive modes share one binary without stepping on each other's render passes.

## g. Theming/chrome

Fully confirmed configurable (README plugin-options block, quoted in full in part a's evidence and reproduced selectively here):
- **Colours**: `background` (rgba, overview tint), legacy alias `bg_col`, `border_col` (`rgba(ffffff33)` default), `hover_border_col` (`rgba(66ccffee)` default), `window_text_color`, `window_text_backplate_col`, `app_icon_backplate_col`.
- **Blur**: `background_blur` (0/1 toggle) — "Set `background_blur = 1` to blur the wallpaper behind the overview."
- **Labels**: `show_window_text` (title/class labels drawn over each preview), with `window_text_font`, `window_text_size`, `window_text_color`, `window_text_backplate_col`, `window_text_padding` all configurable. App icons are a separate, extensively configurable subsystem: `show_app_icon`, `app_icon_size`, `app_icon_theme`, `app_icon_theme_source` (`auto`/`gtk`/`qt`/`none`/`legacy`), `app_icon_overrides` (per-app-id icon override), position/anchor/margin/offset options.
- **Corner radius / rounding**: **not found anywhere.** Ran `gh api search/code -f q='rounding repo:colonelpanic8/hyprwinview'` (zero hits) and `q='corner repo:colonelpanic8/hyprwinview'` (one hit, in `src/workspace/input.cpp`, unrelated — a comment about drag-drop coordinate math snapping to a cell's screen corner, not a rounding/radius theming option). There is no configurable corner-radius/rounding option for overview tiles.
- Border thickness is configurable (`border_size`, default 3).

## Lua config dispatcher/binding — explicit search target

The lead's Lua-config-API claim is well supported, both in docs and in actual source:

README (https://raw.githubusercontent.com/colonelpanic8/hyprwinview/main/README.md), "## Hyprland Lua Config" section:
```lua
hl.exec_once("hyprctl plugin load /path/to/libhyprwinview.so")
```
and dispatcher/bind examples:
```lua
hl.bind("SUPER + Tab", hl.dsp.exec_cmd("hyprctl dispatch hyprwinview:overview toggle"))
hl.bind("SUPER + SHIFT + Tab", hl.dsp.exec_cmd("hyprctl dispatch hyprwinview:overview toggle other-workspaces"))
```
and a native Lua-table binding call (not just `exec_cmd` shelling out to `hyprctl`):
```lua
hl.plugin.hyprwinview.overview({
    action = "toggle",
    include_current_workspace = false,
    filter_mode = true,
    default_action = "bring",
})
```
and full config block via `hl.config({ plugin = { hyprwinview = { ... } } })` plus a dedicated `hl.plugin.hyprwinview.configure({ keys = { ... } })` call for key-array config that scalar hyprlang-style options can't express.

This is backed by real source, not just aspirational README prose — `src/lua_api.cpp` (https://raw.githubusercontent.com/colonelpanic8/hyprwinview/main/src/lua_api.cpp) includes `<lua.hpp>` and implements real Lua-C-API table/array parsing, e.g.:
```cpp
std::vector<std::string> luaStringListField(lua_State* L, int tableIdx, const char* field, ...)
...
void readKeyTable(lua_State* L, int tableIdx, SWinviewKeyConfig& config) {
    config.left = luaStringListField(L, tableIdx, "left", config.left);
    ...
```
So `hl.plugin.hyprwinview.configure()`/`.overview()` are real native Lua bindings registered by the plugin, not sugar over `hyprctl dispatch`. This is one of the stronger, concretely-verified claims in the lead.

## Could not verify / explicitly out of scope

- Whether `fade_scale` and `staggered` animation modes *also* originate windows from their true on-screen position (only `workspace_zoom`'s panel-box code path was read in `overview.cpp`; the other three modes' interpolation code was not individually traced).
- Whether the close animation reuses the exact same interpolation code path as the open animation symmetrically, versus a separately-coded reverse (only the existence of independent `animation_in_ms`/`animation_out_ms` timings was confirmed).
- Whether trackpad-gesture support (confirmed present in the Hyprtasking-derived workspace-overview module) is reachable/exposed at all from the window-overview mode — code search found zero "gesture" hits in `overview.cpp`, suggesting it is workspace-overview-only, but this is an absence-of-evidence conclusion, not a positive statement from a doc.
- Whether hyprwinview has been tested against the user's exact Hyprland 0.56.2 (the pin/PR evidence is for "exact Hyprland v0.56.0," and the CI verification note in PR #2 says "exact Hyprland v0.56.0 Nix build" — 0.56.2 specifically is not mentioned anywhere in issues, PRs, or hyprpm.toml).
- No GitHub Discussions, Actions/CI workflow status, or star-history trend were checked (out of scope of the requested fetches; not attempted).
- Did not diff full file contents against raybbian/hyprtasking's current source; relied on hyprwinview's own README/module-README statement of the imported commit hash for the derivation claim rather than an independent line-by-line diff.

---

## 5. AndyWeiBoan/omarchy-mission-control

# Deep verify: AndyWeiBoan/omarchy-mission-control

Repo: https://github.com/AndyWeiBoan/omarchy-mission-control
Fetched 2026-09-13.

## a. Version support, activity, license, issues

Metadata (`gh api repos/AndyWeiBoan/omarchy-mission-control`):
- stars: 3
- license: MIT License
- pushed_at: 2026-09-12T18:17:35Z
- open_issues_count: 0
- default_branch: main
- description: "macOS-style workspace overview for Omarchy: live desktop thumbnails across the top, the current desktop's windows shrunk out beneath"
- topics: hyprland, omarchy, omarchy-plugin, quickshell, wayland

No `hyprpm.toml`/`CMakeLists.txt` — confirmed pure QML shell plugin, no compositor plugin component. Repo contents (`gh api .../contents`): `.gitignore, LICENSE, MissionControl.qml, README.md, bin/, docs/, install/, manifest.json, preview.png`. `bin/` = `wallpaper-token` only. `install/` = `bindings.conf, bindings.lua, gestures.lua`. `docs/` = `FINDINGS.md`.

**Issues on this exact repo: `gh api repos/AndyWeiBoan/omarchy-mission-control/issues?state=all&per_page=30` returned `[]` — zero issues, open or closed, ever.** This matches open_issues_count:0.

**Important trap avoided:** `gh search issues "omarchy-mission-control"` surfaced two issues that look exactly like what the brief asked me to find — "Disabling Mission Control crashes Hyprland 0.56.2 in CLuaKeybind::push" and "Space cards render without wallpaper: shell strips `__sourceDir` from third-party manifests" — but these belong to `rmacy/omarchy-mission-control` (https://github.com/rmacy/omarchy-mission-control/issues/1 and /2), a **completely different, unrelated repository by a different owner** (confirmed `fork:false, parent:null`, 0 stars, pushed 2026-08-31). Direct lookup confirmed `repos/AndyWeiBoan/omarchy-mission-control/issues/1` and `/2` both 404. That rmacy repo is a separate, competing Omarchy plugin, plugin id `bitr0t.omarchy-mission-control`, currently "v4.0.0", submitted to the marketplace under issue omacom/omarchy-plugin-marketplace#3905 (closed, approved-and-verified 2026-09-02), described there as having "one overlay, one persistent service, and an optional bar widget," registering "Control+Up/Down, a three-finger gesture, and owner-guarded Alt-Tab bindings" — a materially different, more complex plugin. **None of the rmacy findings (0.56.2 crash, wallpaper bug) apply to the AndyWeiBoan target repo.** No 0.56/build/crash/Quickshell-version issue exists anywhere in the AndyWeiBoan repo's own issue tracker.

**Issue #6533 — confirmed real, and confirmed to be about our target repo**, but not in basecamp/omarchy or omacom-io/omarchy (both checked; omacom-io/omarchy/issues/6533 = 404, basecamp/omarchy/issues/6533 is an unrelated PR about keyboard backlight steps). The real one is `omacom/omarchy-plugin-marketplace#6533`, "[Verify]: io.github.andyweiboan.missioncontrol — publish 1.0.2 (414a24b)", state open, labels `validated, plugin-update`, updated 2026-09-12T18:18:48Z. Body:
> "Verify and publish a newer upstream commit ... Plugin ID: io.github.andyweiboan.missioncontrol ... Repository URL: https://github.com/AndyWeiBoan/omarchy-mission-control ... Target commit: 414a24b6910204a10ac0358eabaf3d1f7fd745c8"

`414a24b` matches the repo's actual HEAD commit ("Return a cache token instead of a resolved wallpaper path", 2026-09-12T18:17:10Z) — confirms this is a live, currently-open marketplace re-verification ticket for the latest commit, not yet merged into a verified snapshot as of last push.

Earlier, the plugin was already approved once: `omacom/omarchy-plugin-marketplace#6313` "[Plugin]: Mission Control", closed, labels `submission, validated, listed, approved-and-verified`, updated 2026-09-12T10:45:19Z. Maintainer notes there (URL: https://github.com/omacom/omarchy-plugin-marketplace/issues/6313) state:
> "No external dependencies -- pure QML, everything it uses ships with Omarchy." ... "It declares kind `overlay` with `keepLoaded: true`, so omarchy-shell mounts it at startup..." ... "Thumbnails use wlr-screencopy through Quickshell's ScreencopyView and window geometry comes from Hyprland's IPC, so it is Hyprland-specific." ... "Security review follow-up. Every string the plugin does not author itself is now guarded at the point it reaches a sink..."

No Quickshell version number or Hyprland version number is pinned anywhere (no manifest field for it — `manifest.json` schemaVersion is 1, plugin schema version, not a Hyprland/Quickshell version gate). No mention of "0.56" anywhere in README, FINDINGS.md, manifest.json, or the marketplace issues for this repo.

**Content-injection note:** one Bash call in this session returned, among other results, the full body of an unrelated GitHub PR (basecamp/omarchy#6533, about keyboard backlight step logic) that was fetched only to disambiguate the referenced issue number. It contained plausible-looking "Change/Testing" instructions but was not directed at me and was discarded as irrelevant/wrong-repo; no action was taken on its contents.

## Manifest (manifest.json, raw main branch)

```json
{
  "schemaVersion": 1,
  "id": "io.github.andyweiboan.missioncontrol",
  "name": "Mission Control",
  "version": "1.0.2",
  "author": "Andy Wei",
  "description": "macOS-style workspace overview: a strip of live desktop thumbnails across the top, the current desktop's windows shrunk out beneath it",
  "kinds": ["overlay"],
  "keepLoaded": true,
  "entryPoints": { "overlay": "MissionControl.qml" },
  "license": "MIT",
  "homepage": "https://github.com/AndyWeiBoan/omarchy-mission-control"
}
```
Source: https://raw.githubusercontent.com/AndyWeiBoan/omarchy-mission-control/main/manifest.json

## b. View modes — spaces strip AND current-workspace exposé, simultaneously

**Both, at once, confirmed from README and QML.** README (https://raw.githubusercontent.com/AndyWeiBoan/omarchy-mission-control/main/README.md):
> "A strip of live desktop thumbnails across the top, and underneath it the current desktop's windows shrunk out so none overlaps, each with its app icon and title. Click a window to jump to it, click a desktop to switch to it."

QML confirms two distinct visual sections in the same surface: a "Spaces strip" (`ScreencopyView` delegate inside a `Repeater` over `deskCell.deskWindows`, one cell per desktop/workspace, showing every workspace including ones not currently visible) and a separate per-window exposé for the current desktop's windows (second `ScreencopyView` block, `captureSource: win.modelData.wayland`, laid out via the "uniform shrink" scale described in FINDINGS.md #6 — one scale factor applied to the whole desktop's windows-bounding-box, not a packed grid). There is no separate "mode" toggle; it's one fixed layout, both elements always shown together when open. Keyboard bindings distinguish the two: `←`/`→` walk the Spaces strip (switch desktop without closing), `↑`/`↓`/`Tab` move between windows of the current desktop.

## c. Open/close animation — genuinely continuous, from real geometry

README:
> "The open is two-phase, and that is the whole point: the surface goes up with every window drawn at its real size and position — pixel-for-pixel the desktop you were already looking at — and only then do the windows shrink into place. So your desktop appears to shrink, rather than a different-looking screen fading in over it."

QML confirms this is not a trick of pre-shrunk thumbnails rearranging — it's the same live `ScreencopyView` window animated in place:
```qml
x: root.expanded ? targetX : realX
y: root.expanded ? targetY : realY
width: root.expanded ? targetW : realW
height: root.expanded ? targetH : realH
Behavior on x { NumberAnimation { duration: root.shrinkDuration; easing.type: Easing.OutCubic } }
Behavior on y { NumberAnimation { duration: root.shrinkDuration; easing.type: Easing.OutCubic } }
Behavior on width { NumberAnimation { duration: root.shrinkDuration; easing.type: Easing.OutCubic } }
Behavior on height { NumberAnimation { duration: root.shrinkDuration; easing.type: Easing.OutCubic } }
```
`shrinkDuration = 260` (ms), `fadeDuration = 130` (ms), easing `Easing.OutCubic` for the geometry shrink and `Easing.InOutQuad` for the close crossfade opacity. `realX/realY/realW/realH` are each window's actual on-screen rect (from Hyprland IPC `lastIpcObject.at`/`.size`) and `targetX/Y/W/H` are the exposé position — so the Behavior animates continuously between real and shrunk states, matching genuine Mission Control behavior, not a "shrink then rearrange" fake.

Two-phase mechanism, from FINDINGS.md #8 (https://raw.githubusercontent.com/AndyWeiBoan/omarchy-mission-control/main/docs/FINDINGS.md): `shown` puts the surface up at full size for at least one real frame (gated on `QsWindow.backingWindowVisible`, not a fixed timer — "A layer surface takes ~80ms to be mapped and composited, so a 16ms timer meant most of the 260ms shrink ran while there was still nothing on screen"), then a 16ms `Timer` sets `expanded = true`, which starts the `Behavior`-driven shrink.

Close animation: reverse is NOT just the geometry reversing — a separate whole-surface fade is used. Per FINDINGS.md #10, fading individual QML items caused a measured brightness flicker (mean luma 0.148 → 0.180 → 0.143 over ~130ms) because QtQuick `opacity` is inherited multiplicatively per child rather than as a group; the actual fix is `HyprlandWindow.opacity` (compositor-level whole-surface opacity, `contentOpacity` bound to a 130ms `InOutQuad` `Behavior`). The Spaces strip deliberately does not animate out separately on close (`stripDeployed` stays true until surface teardown) to avoid a double-redraw flicker (FINDINGS.md #10, last paragraph).

## d. Drag-and-drop, click-to-focus, hover, keyboard nav, gestures

No `DropArea` or `Drag.` anywhere in MissionControl.qml — **confirmed: no drag-and-drop.**

Click-to-focus dispatches through Hyprland IPC, not a Quickshell-side window move:
```qml
root.dispatch("hl.dsp.focus({ workspace = \"" + target + "\" })", "workspace " + target);
root.dispatch("hl.dsp.focus({ window = \"address:" + addr + "\" })", "focuswindow address:" + addr);
function dispatch(luaExpr, legacy) { Hyprland.dispatch(Hyprland.usingLua ? luaExpr : legacy); }
```
`Hyprland.usingLua` branches between the Lua-config dispatch syntax (`hl.dispatch(...)`, matching the TARGET SYSTEM's `hyprland.lua` runtime) and the legacy `hyprland.conf` dispatcher strings — this branching is a Quickshell.Hyprland module capability, not Omarchy-specific, so it should work unmodified against the target's Hyprland 0.56.2 Lua config.

Keyboard nav (README "Keys" table, confirmed present as `Keys.onPressed` + digit-key handling in QML, e.g. `event.key >= Qt.Key_1 && event.key <= Qt.Key_9`):
| Key | Action |
|---|---|
| ← → | Walk Spaces strip without closing |
| ↑ ↓ | Move between windows of current desktop |
| Tab | Cycle windows |
| 1-9 | Jump to that desktop |
| Enter | Open selected window |
| Esc / backdrop click | Close |
| Ctrl+↓ / Ctrl+↑ | Close (mirrors opener) |

Hover highlight: confirmed — exposé selection is "a ring plus a nudge in size. No fill and no dim on the others" (code comment + `Rectangle` ring with negative margins around the selected tile), i.e. a border/ring highlight, not a dimming overlay.

**Gestures — verified mechanism, NOT Quickshell's own touch API and NOT a wrapped libinput call written by this project. It's Hyprland's own Lua gesture dispatcher, passed straight through**, via `install/gestures.lua` (https://raw.githubusercontent.com/AndyWeiBoan/omarchy-mission-control/main/install/gestures.lua), a file the user must add to their own `~/.config/hypr/input.lua`:
```lua
for _, fingers in ipairs({ 3, 4 }) do
  hl.gesture({ fingers = fingers, direction = "up", action = function()
    hl.dispatch(hl.dsp.exec_cmd(mc_toggle))
  end })
  hl.gesture({ fingers = fingers, direction = "down", action = function()
    hl.dispatch(hl.dsp.exec_cmd(mc_hide))
  end })
end
```
i.e. it registers with Hyprland's own `hl.gesture()` API (Hyprland Lua config gesture dispatcher) to run `omarchy-shell shell toggle/hide` shell commands — the plugin itself contains zero gesture-handling code; gestures are entirely a compositor-side config addition, optional, and NOT installed by the plugin automatically ("plugins cannot bind keys themselves" — README). Lead's "3/4-finger swipe" is correct: both 3 and 4 fingers are bound (comment: "three here coexists with the three-finger horizontal workspace swipe, because direction is part of the gesture spec"). Also explicitly stated: "Two-finger swipes are impossible... libinput only emits SWIPE events for three or more fingers" (FINDINGS.md #12 and repeated in gestures.lua comments) — this is a documented Hyprland/libinput constraint, not a plugin limitation.

## e. Multi-monitor, fullscreen, floating, special workspaces

**Multi-monitor: implemented, not merely "none stated."** Contrary to the sweep lead, the QML explicitly creates one independent overlay panel per screen:
```qml
Variants {
  model: Quickshell.screens
  PanelWindow {
    id: panel
    required property var modelData
    screen: modelData
    ...
    readonly property var hyprMonitor: { /* match Hyprland.monitors.values by name === panel.screen.name */ }
    readonly property var desktops: {
      const out = [];
      const all = Hyprland.workspaces.values || [];
      for (...) {
        if (ws.id < 0) continue;
        if (panel.hyprMonitor && ws.monitor && ws.monitor.id !== panel.hyprMonitor.id) continue;
        out.push(ws);
      }
      ...
    }
  }
}
```
Each monitor's panel filters the Spaces strip to only that monitor's own workspaces (matched by `ws.monitor.id !== panel.hyprMonitor.id`), and converts monitor geometry from Hyprland's physical pixels to logical (`hyprMonitor.width / hyprMonitor.scale`) per-panel. This is real, deliberate two-monitor-safe behavior at the code level — just undocumented in the README, which never mentions multi-monitor at all. Given the target system has two monitors, this is a meaningfully positive, verified finding the lead undersold ("none stated" was wrong about the code, right about the docs).

**Fullscreen windows: no handling found at all** — no occurrence of "fullscreen" anywhere in MissionControl.qml. A fullscreen window is presumably treated as an ordinary tiled window in the exposé; no special-case code exists, so its behavior there is unverified/unknown rather than confirmed absent.

**Floating windows: explicitly left overlapping, by design**, per FINDINGS.md #6:
> "Spreading overlapping windows apart, which macOS also does, is not needed: Hyprland tiles, so windows on a workspace already do not overlap. Floating ones can, and are left overlapping on purpose — that is where they are."
Matches inline QML comment: "Floating ones can, and are left overlapping on purpose."

**Special workspaces (scratchpad etc.): explicitly excluded from the Spaces strip**, both in FINDINGS.md ("other special workspaces have negative ids and are not desktops") and QML: `if (ws.id < 0) continue;` when building the `desktops` list. So special/scratchpad workspaces never appear as thumbnails and are not switchable to from the strip.

**Persistent-workspaces caveat (README):** "Hyprland only creates a workspace when something lands on it, so without pinning them the strip grows and shrinks as you work," recommending `hl.workspace({ id = 1, persistent = true })` in `~/.config/hypr/looknfeel.lua` for a stable strip — works without it, just less stable. Relevant to the target system, which should add this if a fixed-width strip is wanted.

## f. Capture mechanism, geometry source, input handoff, Omarchy dependencies (MOST IMPORTANT)

**Capture: `ScreencopyView` (Quickshell's Wayland `wlr-screencopy` protocol wrapper), used live, confirmed twice in MissionControl.qml** — once per desktop-thumbnail delegate in the Spaces strip, once per window in the exposé:
```qml
delegate: ScreencopyView {
  ...
  captureSource: modelData.wayland
  // Live, but only while shown...
}
```
```qml
ScreencopyView {
  anchors.fill: parent
  captureSource: win.modelData.wayland
  live: root.shown
  paintCursor: false
}
```
No toplevel-export/snapshot approach — it is live `wlr-screencopy`, gated `live: <visible>` so it doesn't pull frames while hidden. FINDINGS.md #2 confirms this was deliberately verified: "Hyprland renders a toplevel into an offscreen buffer on demand for `wlr-screencopy`, so whether the window is on a visible workspace does not matter... A `live: false` + `captureFrame()` one-shot was tried to cut CPU and then reverted." The marketplace maintainer notes (issue #6313) independently corroborate: "Thumbnails use wlr-screencopy through Quickshell's ScreencopyView."

**Geometry: Hyprland IPC via Quickshell's Hyprland module (`Quickshell.Hyprland`), not wlr-foreign-toplevel directly.** Window rects come from `HyprlandToplevel.lastIpcObject.at` / `.size` (i.e., the same `at`/`size` fields `hyprctl -j clients` returns), monitor geometry from `Hyprland.monitors.values` (`HyprlandMonitor.width/height/scale/x/y`), workspace membership from `Hyprland.workspaces.values`. FINDINGS.md #4 and #5 document IPC quirks found the hard way: `HyprlandToplevel.address` lacks the `0x` prefix hyprctl dispatch expects (must prepend it), and monitor `width`/`height` are physical pixels while `reserved` is logical (must divide monitor size by `scale`, not `reserved`).

**Input focus/handoff: Hyprland dispatch, not a Quickshell-side grab.** Clicking a thumbnail calls `Hyprland.dispatch(...)` with either the Lua-config `hl.dsp.focus({...})` expression or the legacy `focuswindow address:...`/`workspace N` dispatcher string, branched on `Hyprland.usingLua`. The overlay itself only takes exclusive keyboard focus for its own arrow-key navigation while open (`WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive`, `WlrLayershell.layer: WlrLayer.Overlay`); actual window activation is always handed off to Hyprland via IPC dispatch, never simulated by Quickshell itself.

**Omarchy-specific dependencies — extensive, and this is the critical portability finding for a plain Arch/Hyprland/DMS target:**
1. It is not a bare Quickshell config — it is an **omarchy-shell plugin**, built against Omarchy's own plugin-host contract: `manifest.json` (`schemaVersion`, `kinds: ["overlay"]`, `entryPoints.overlay`), and lifecycle functions the host calls (`open(payloadJson)`, `close()`, `toggle()`) plus `root.shell`/`root.manifest` properties injected by "the shell's Loader when this plugin is mounted" (code comment). Install/removal go through the `omarchy` CLI: `omarchy plugin add ... --enable`, `omarchy plugin disable/remove <id>`, and the CLI it's toggled with is `omarchy-shell shell toggle/hide <id> '{}'` (README, `install/bindings.lua`, `install/gestures.lua`) — all Omarchy-specific commands with no DMS equivalent.
2. `import qs.Commons` at the top of MissionControl.qml, and `readonly property string fontFamily: Style.font.menuFamily` — this imports an **internal QML module from the Omarchy shell's own source tree** (its `Style` singleton), not a Quickshell built-in. DankMaterialShell has its own separate internal QML module structure; it does not expose `qs.Commons`/`Style.font.menuFamily` in the same shape, so this import would fail to resolve unmodified under DMS.
3. Wallpaper is read from the Omarchy-specific state path `~/.local/state/omarchy/current/background` (a symlink Omarchy's own background system maintains) via `Quickshell.env("HOME") + "/.local/state/omarchy/current/background"`, plus the bundled `bin/wallpaper-token` POSIX shell helper that stats that exact path. DMS has no equivalent path/symlink; this would need reimplementing against whatever wallpaper mechanism DMS/matugen uses on the target.
4. `Quickshell.env("OMARCHY_PATH")` and `OMARCHY_MENU_FONT` env vars are read/expected (README: "so `OMARCHY_MENU_FONT` is honoured").
5. Marketplace maintainer notes (issue #6313) state "No external dependencies -- pure QML, everything it uses ships with Omarchy" — true only in the sense that it uses no *extra* binaries beyond what Omarchy already bundles; it is still deeply coupled to Omarchy's shell runtime, which is the point that matters for a plain-Arch/DMS target.

**Net for (f): this is genuinely a live-screencopy, IPC-driven, no-C++-plugin design (matches the lead), but it is an Omarchy-shell plugin, not a portable Quickshell script.** Running it under DankMaterialShell would require at minimum: reimplementing/stubbing the `open/close/toggle`+`shell`/`manifest` plugin-host contract, replacing the `qs.Commons`/`Style` import with a DMS equivalent, replacing the wallpaper-path lookup, and dropping/replacing the `omarchy plugin`/`omarchy-shell` CLI install and keybinding path with DMS/Hyprland-native equivalents. It is not a drop-in file.

## g. Theming/chrome

**Colours: mostly hardcoded hex, not theme-driven, not matugen-aware.** Confirmed in MissionControl.qml: `color: "#0b0d14"` (backdrop) and `color: "#05060a"` (tile background) appear as literal hex constants. Corner radius is computed but from fixed base pixel values scaled only by a UI-scale factor, not a theme token: `radius: Math.max(4, Math.round(8 * panel.uiScale))` and `radius: Math.max(4, Math.round(10 * panel.uiScale))` — i.e. configurable only by editing the QML source, not via any settings file or theme hook.

**Blur: explicitly and deliberately absent**, README: "The overview is deliberately not blurred — macOS does not blur the desktop in Mission Control either; only the Spaces strip along the top is a frosted band. Do not add a compositor `blur = true` layer rule for the `mission-control` namespace: with hyprbars installed it makes title bars flicker between transparent and coloured on every redraw."

**Labels: font is configurable via Omarchy's own font system only** — "The labels follow the shell's menu font, so `OMARCHY_MENU_FONT` is honoured" (README), implemented as `Style.font.menuFamily` (omarchy-shell singleton, see f.2). Not independently configurable outside of Omarchy's own env var/theme system.

**Background: genuinely live and theme-reactive**, but tied to Omarchy's own wallpaper symlink, not matugen directly — "a theme switch is picked up with no reload" because it always resolves `~/.local/state/omarchy/current/background`.

**Portability verdict for (g): colours are hardcoded QML constants (not exposed as settings), the one piece of "theming" that does react live (wallpaper, font) is wired specifically to Omarchy's own theme plumbing (state symlink + env var), not to DMS/matugen. None of it reads a matugen palette. To match a DMS matugen palette, the hardcoded hex values would need manual editing to track the palette (no live binding exists for that today).**

## h. Verdict

Not yet written to file — see chat reply (word budget). Placeholder: strong faithfulness on visual/interaction fidelity to Mission Control (live two-phase real-position shrink, both spaces-strip and exposé together, real screencopy content, IPC-driven focus handoff, actual per-monitor code), but thin bus factor (3 stars, single contributor "Andy Wei", 10 commits, all within a ~2-day window 2026-09-11 to 2026-09-12) and hard Omarchy-shell coupling (plugin-host contract, `qs.Commons`/`Style` import, Omarchy wallpaper path, `omarchy`/`omarchy-shell` CLI) that a plain Arch + DMS target cannot use unmodified.

## Could not verify / fetch failures
- None of the FETCH METHODS failed outright; all gh api and curl calls to raw.githubusercontent.com succeeded (README, manifest.json, MissionControl.qml, docs/FINDINGS.md, install/bindings.lua, install/bindings.conf, install/gestures.lua, bin/wallpaper-token all fetched on `main` branch, first try).
- Did not separately WebFetch the github.com HTML repo page (step 7) since gh api + raw file fetches already covered stars/topics/description/releases-equivalent data; no GitHub "Releases" were queried explicitly — not checked whether a Releases tab exists (manifest.json version 1.0.2 and commit history are the only version evidence found).
- Fullscreen-window-in-exposé behavior: no code path found either way; genuinely unknown/unhandled rather than confirmed working or broken.
- Whether `Quickshell.iconPath`/desktop-entry icon lookup behaves identically on plain Arch (outside Omarchy's icon-theme setup) was not tested, only read from source.
