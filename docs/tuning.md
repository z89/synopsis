# tuning log

results of the experiments and measurements in the plan, newest at the bottom. every entry says how it was measured.

## 2026-09-13 phase 0 test 1: video on an inactive workspace

- setup: youtube in chromium, floating, on workspace 1; overview opened from workspace 2 with `dms ipc call hypr toggleOverview`. run by the user, observed by eye (this test is a yes/no on motion, so eye is enough)
- first open: no motion in the workspace 1 tile
- later opens, after the user had taken screenshots of both workspaces: the video played in the tile
- verdict: provisional pass. hyprland does deliver frames for a toplevel export of a window on an inactive workspace, at least for chromium, which keeps its own frame clock when wayland frame callbacks stop. the shell route stays the plan; no compositor plugin for now
- to close out: repeat with mpv, which paces strictly on frame callbacks, and note whether the first open is stale until the window has been visible once. the "started working" trigger is not understood yet. if mpv freezes while chromium plays, the frame-tick question comes back only for callback-paced clients

## 2026-09-13 dms overview stacking bug

- the workspace 1 tile drew the floating chromium window underneath the two terminals, while on screen it was on top
- cause: the dms tile draws windows in the order of quickshell's `Hyprland.toplevels` model, which is creation order, not stacking order
- consequence for synopsis: draw in hyprland's real z-order, read from `j/clients` over the request socket (plan, "data" and phase 0 check 8)

## 2026-09-13 phase 0 checks 3 and 7: qs cli, ipc, headless hyprland

- `qs --version`: Quickshell 0.3.1 (Arch). `qs -c synopsis` resolves `~/.config/quickshell/synopsis/shell.qml` through the symlink; `Quickshell.shellDir` is the symlink path, `Quickshell.watchFiles` is true by default, so edits hot-reload
- `qs list` without `-c` fails looking for a "default" config; use `qs list --all`
- ipc: both `qs -c synopsis ipc call overview fn` and `qs ipc -c synopsis call overview fn` reach the instance (three connections in the log). a function without a declared return type returns nothing on the cli; `function ping(): string` is required for a value. `/usr/bin/qmllint` is qt5's and rejects those annotations; lint with `/usr/lib/qt6/bin/qmllint -I /usr/lib/qt6/qml`
- `Connections` needs `import QtQuick` even in a shell with no visible items
- headless hyprland: `env -u WAYLAND_DISPLAY -u DISPLAY AQ_DRM_DEVICES= Hyprland -c tools/phase0/headless.lua` aborts during startup with `CBackend::create() failed!` (exit 134, crash report written to ~/.cache/hyprland/). 0.56.2 has no standalone headless backend; a test compositor has to run nested inside the live session as a window (`Hyprland -c tools/phase0/headless.lua` with the session's WAYLAND_DISPLAY). that is a visible desktop action, so behavioural tests stay user-triggered or approval-gated; the layout tests and everything pure stay headless in node

## 2026-09-13 phase 0 checks 1, 2, 5: ipc return values, trigger latency, xwayland

- `qs list --all` shows dms (`~/.local/share/dms-shell-patched/shell.qml`) and synopsis side by side on the same display; two quickshell instances coexist without fuss
- both ipc forms return "pong" once the function is typed
- the hot reload works: the "up" line appears again in the log after each edit of shell.qml
- trigger: `hyprctl dispatch 'hl.dsp.event("synopsis:toggle")'` replies `ok`; the classic `hyprctl dispatch event synopsis:toggle` is rejected under the lua config ("dispatch in lua is a shorthand for hl.dispatch(...)"). the hello shell receives it as `rawEvent` name `custom`, data `synopsis:toggle`
- latency: dispatch issued at 1789283192081 ms, received by the shell at 1789283192085 ms. 4 ms end to end, and that includes spawning hyprctl. from a keybind it will be less. the trigger path is settled
- xwayland: no xwayland client was running, check 5 skipped until one is (discord and steam are the candidates)
- `hyprctl -j instances` lists only the live compositor; the crashed headless attempts left empty instance dirs under $XDG_RUNTIME_DIR/hypr, harmless

## 2026-09-13 phase 0 test 1 closed: mpv on an inactive workspace

- mpv (`av://lavfi:testsrc`) on workspace 1, overview opened from workspace 2 with the dms overview: frozen on both opens. on the mpv workspace itself: moving. exactly the split the feasibility read predicted: hyprland sends frame callbacks only to the active workspace (Renderer.cpp:2207-2209, sendFrameEventsToWorkspace 2511-2517); chromium moved earlier only because it keeps its own clock
- fix, built into hyprland: the `render_unfocused` window rule plus `misc:render_unfocused_fps`. the renderer keeps a list of enrolled windows and a timer that calls `presentFeedback` on each hidden one at that rate (Renderer.cpp:184-217), which is a frame callback and nothing else: no rendering, no monitor damage
- applied live: `hyprctl eval 'hl.config({ misc = { render_unfocused_fps = 60 } })'` then `hyprctl eval 'hl.window_rule({ name = "synopsis-test", match = { class = "mpv" }, render_unfocused = true })'`, both `ok`. first try still froze because a rule registered at runtime is applied only to windows as they map (Engine.cpp registerRule appends only; enrolment happens from window.updateRules, emitted on map at Window.cpp:2497 or on a config reload via updateAllRules, Engine.cpp:33-46). after quitting and restarting mpv the tile moved on both opens, with no mouse movement needed
- why no keepalive was needed: captures are copied on real output commits (ScreenshareManager.cpp:14-44 from Monitor.cpp:124-131). each new captured frame repaints the overlay, which commits the output, which copies the next frame. the loop sustains itself once content changes. the keepalive in the plan stays as a guard for the fully static case
- facts that shape the design: the timer re-reads `misc:render_unfocused_fps` on every tick (Renderer.cpp:213-214), so raising it at runtime changes the cadence immediately; the config value is clamped to 1..120; a window stays enrolled until destroyed even if the rule flips off (only expired entries are erased, :210-211); `setprop render_unfocused` sets the flag but never enrols an already mapped window (ConfigActions.cpp:867-875); visible windows in the list are skipped at no cost (:199)
- verdict: no compositor plugin. synopsis ships a standing wildcard rule so every window is enrolled at map time and on reload, keeps the rate at 1 fps at rest (one callback per second per hidden window, negligible), and raises it while the overview is open

## 2026-09-13 wildcard render_unfocused, all windows live

- one-liner: `misc:render_unfocused_fps = 60` plus `hl.window_rule({ name = "synopsis-test-all", match = { class = ".*" }, render_unfocused = true })`, then mpv restarted, then a new terminal with `watch -n 0.1 date` and gnome Resources opened, then the overview from another workspace: mpv and the clock terminal both moved for the whole ten seconds. windows opened before the one-liner stayed frozen, as the source predicted (enrolment at map time only)
- btop aborted about ten seconds in: an unhandled c++ exception inside btop (coredumpctl, SIGABRT via std::terminate), nothing to do with capture or the shell; dms did not restart
- the gtk4 Resources window did not update its graphs while hidden even though enrolled. under investigation: suspected xdg_toplevel `suspended` state, which gtk4 honours by pausing its frame clock and which frame callbacks do not clear

## 2026-09-13 why gtk4 Resources froze while hidden: the xdg suspended state

- hyprland marks every mapped window whose workspace is not visible as suspended, unconditionally: `GlobalWindowController.cpp:26-31` sets `w->setSuspended(w->isHidden() || !w->m_workspace || !w->m_workspace->isVisible())` after every workspace switch (Monitor.cpp:1525, 1595, 1698). `Window.cpp:1178-1186` forwards it to the xdg toplevel, `XDGShell.cpp:424-438` sends `XDG_TOPLEVEL_STATE_SUSPENDED` (xdg-shell v6). x11 windows never get it. no window rule, no config option and nothing in `render_unfocused` clears it; the two mechanisms are independent
- gtk 4.12 and later map it to `GDK_TOPLEVEL_STATE_SUSPENDED` (gdktoplevel-wayland.c:774-775) and expose it as the `GtkWindow:suspended` property (gtkwindow.c:4847-4851). gdk itself does not freeze the frame clock or skip drawing. apps opt in: Resources watches the property and pauses its own graph refresh to save power. there is no gdk debug flag to switch it off; `GDK_DEBUG=events` shows the configure carrying "suspended" if anyone wants to watch it arrive
- mpv tracks the state too (wayland_common.c:1836-1877, `wl->hidden`, render gated by `--force-render`), yet it kept updating in the tests. not chased; the observation stands
- consequence: a hidden window that pauses itself on suspended shows its last frame in the tile, exactly as a self-pausing app does in macos mission control (occlusion state). not fixable from a shell, and only a compositor plugin could lie to the app. documented as a known limitation, not a bug. terminals, mpv and chromium video are unaffected

## silent move under the lua config (2026-09-13)

`hl.dsp.window.move({ workspace = N, window = "address:0x…" })` follows the window (classic `movetoworkspace`). The silent form is `follow = false`; there is no `silent` key. Source: src/config/lua/bindings/LuaBindingsDispatchers.cpp, `silent = follow.has_value() && !*follow`. The stubs type it as `fun(...)`, so this is not discoverable from hl.meta.lua.

## live config evals do not reload (2026-09-13)

`eval hl.config({ animations = { enabled = false } })` and the `misc.render_unfocused_fps` eval only set the one value: `hlConfig` walks the table, parses each key and schedules a property refresh from the value's refresh bits (LuaBindingsConfigRules.cpp ~1000). `animations:enabled` and `misc:render_unfocused_fps` carry no refresh bits, so nothing relayouts and no reload runs. While enabled is false the animation tick warps every running variable to its goal (AnimationManager.cpp tick, `warp = !*PANIMENABLED`), which is what makes the tile-click switch instant behind the backdrop. Any post-close smear therefore is not a config reload.

## layer order, socket parser, focus handoff (2026-09-13)

- layer rule `order = 1` on `^synopsis-backdrop$`: Renderer sorts layers descending by order and renders in vector order, so a higher order sits beneath the DMS bar on the same layer. That is how the wallpaper backdrop sits under the bar while the Overlay-layer scrim dims everything.
- request socket in quickshell: hyprland closes the peer after the reply and quickshell reports PeerClosedError without streamFinished. Use `SplitParser { splitMarker: "" }` to collect chunks and finish the request on disconnect.
- focus handoff: dispatches that focus or switch land wrong while the overlay holds exclusive keyboard focus. Superseded by the section below (waiting for a frame is not enough; the fix is ondemand plus confirmation).

## exclusive keyboard focus, the ondemand handoff and the retry (2026-09-13)

- `CFocusState::rawWindowFocus` refuses every window focus while `m_exclusiveLSes` is non-empty and logs `Refusing a keyboard focus to a window because of an exclusive ls`. The overview layer is `Exclusive` while `Overview.wantsFocus`, so a workspace switch made while it is open (our dispatch or the user's own keybind) moves the workspace but leaves the focused window on the old one.
- Dropping that layer straight to `None` is what bounced the switch back: `CLayerSurface`'s commit handler sees exclusive -> none with keyboard focus on us, calls `rawSurfaceFocus(nullptr)` and then `refocusLastWindow(monitor)`, which finds our layer under the cursor, sees it is not keyboard focusable and calls `fullWindowFocus(last window)` — and that switches the monitor back to the old window's workspace.
- Exclusive -> **OnDemand** does none of that: the handler only drops us out of `m_exclusiveLSes` and calls `simulateMouseMovement()`. Keyboard focus stays on our layer, nothing is refocused, and a window focus dispatched afterwards is accepted. A later OnDemand -> None or an unmap is harmless because a window holds focus by then. `shell/Ui/OverlayWindow.qml` therefore never uses `None` while it is mapped.
- The Wayland commit that carries the new interactivity and the IPC dispatch are not ordered against each other, so the first dispatch after a close can still be refused. Frame counting cannot fix that (`frameSwapped` comes from the render thread). `Overview.requestFocus()` instead confirms each dispatch against hyprland's own events — `activewindowv2` for a window, `workspacev2` for a workspace — and re-dispatches every `Config.focusRetryMs` (60) up to `Config.focusRetries` (6), logging `[synopsis] focus unconfirmed …` if it never lands. One refusal per close before the first retry is normal; more than one means the retry is not firing.
- A dispatch that asks for what hyprland already has (the tile of the active workspace, the already-focused window) emits no event at all, so `requestFocus` checks the live state first (`HyprState.focusedAddress`, `HyprState.activeWorkspaceId`, both fed from the event socket) and confirms immediately instead of burning six retries.
- Every close path decides what must hold focus once the overlay is gone: if a request is already pending (tile click) it is kept, otherwise `closeFocusTarget()` picks the lowest `focusHistoryID` client on the active workspace of the focused monitor when the focused window is not on it. That is what makes a workspace switched by an external keybind survive the close.

## the backdrop must stay opaque through closing (2026-09-13)

The wallpaper backdrop was visible only for `progress > 0 || opening || open`. After a tile click the return flight reaches progress 0 while the exposé slide (`Config.switchMs` 450) is still running, so the real windows reappeared under still-sliding thumbs — the "duplicated windows" seen in the frames. It is now `Overview.active && Overview.state !== "preparing"`: transparent only while preparing, when the thumbs sit exactly over the real windows, and opaque for the whole of closing until `finishClose()`.

## refresh cost: one property write, not three (2026-09-13)

`refreshAll` assigned `monitors`, `workspaces` and `clients` separately, so every binding that read all three rebuilt its model three times per refresh, twice of them on a half-updated world (measured with `SYNOPSIS_FRAMELOG=1`: `refresh took 89 ms (parse 0 apply 59 …)`, three `model …` lines per refresh). The lists are now published as one `HyprState.snapshot` object with a `version`, and the overlay binds `Overview.modelFor(name, HyprState.snapshot.version)`, so a refresh rebuilds each model exactly once (apply is 1-10 ms after the first). Anything a binding reads must come from the snapshot; `monitors`/`workspaces`/`clients` remain for imperative callers. Two other frame eaters went with it: `misc:render_unfocused_fps` is now lowered in `finishClose` rather than on the first frame of the close flight (the config eval can take 60-230 ms), and `modelsDirty` no longer schedules a refresh while the close flight runs.

## close-focus rules: special workspaces, live ids, vanished targets (2026-09-13)

- `closeFocusTarget()` reads the active workspace from `HyprState.activeWorkspaceId`, fed from `workspacev2`/`focusedmonv2` and repaired on every refresh. The snapshot alone is up to one refresh debounce stale, and a keybind switch followed straight by Escape lands inside exactly that window — picking a client from the stale list re-creates the bounce it exists to prevent.
- If the focused monitor has a special workspace open (`mon.specialWorkspace.id !== 0`), or the focused client's workspace id is negative, the close dispatches nothing: a scratchpad has to survive open-then-Escape, and any `focus window` would drop it.
- `closewindow` removes the address from the snapshot, so a focus request cannot retry forever against a window that is gone; `sendFocus()` re-resolves the target before each dispatch and recomputes the close target once before giving up. `finishClose()` cancels any request that is still pending (after one last dispatch), so no retry outlives the overlay.

## the open gate and the thumb placeholder are separate timeouts (2026-09-13)

`Config.gateTimeoutMs` (250) is how long the open flight waits for every gated thumb to report content before it flies anyway; `Config.hasContentTimeoutMs` (400) is how long a single thumb keeps showing its placeholder. They were one value, which meant lengthening the placeholder grace also delayed every open by the same amount.

## the world moving under a preparing overlay (2026-09-13)

While `preparing` the backdrop is transparent and every thumb sits exactly over its own real window, so anything that moves a window between the toggle and the first flight frame makes every row a lie. The real case is a workspace keybind pressed right after the toggle keybind: hyprland switches (instantly, animations are off), the desktop is now the new workspace, and the old workspace's thumbs paint over it as soon as their captures arrive — three frames of the wrong windows in `fuzz` seed 4 (frames 335-337 of `out/20260913-231021`). `Overview.prepareDirty` is set by `workspacev2`, `focusedmonv2`, `movewindowv2` and `activespecial` while preparing and cleared by the next `HyprState.refreshed`; the exposé rides at opacity 0 in between (opacity, not `visible`: a hidden subtree can stop feeding the captures the gate waits for). The refreshed sync then drops the old rows outright instead of diffing them and re-runs the gate for the new set.

A black rounded box in the same sequence (frame 334, 80 ms after the switch) is **not** ours: a thumb paints nothing until `hasContent` while preparing, and the workspace-5 capture only arrived later. It is the real window, revealed by the instant switch before it had committed a buffer since being mapped on a hidden workspace — the same "hidden windows only paint while render_unfocused_fps is high" limitation, seen at the moment of the reveal.

`HyprState.send` is asynchronous throughout (a `Socket` plus a callback; nothing waits), so a 50 ms `eval hl.config` is latency, not a blocked QML thread. `applyConfig()` still merges the two evals `finishClose` used to issue into one request, because each one is a separate hyprland config apply.

## per-row slide targets: why the phase model failed (2026-09-13)

The exposé used to handle a workspace switch by *phase*: every row on screen was frozen as phase `out`, the new workspace's windows were appended as fresh `in` rows, and all `out` rows shared one direction, `slideDir`, computed from the last two active ids. On a quick back-and-forth that model breaks three ways, all visible in `out/20260913-231809/keybind_interrupt.mkv` between 1.40 and 1.80 s (switches 1→2 at 1318 ms, 2→3 at 1439, 3→2 at 1499):

1. rows already leaving are re-frozen with the *new* `slideDir`, so workspace 1's thumbs, halfway off the left edge, reverse and cross the whole screen before leaving on the right;
2. the workspace being returned to still has rows on screen (now `out`, going left) and gets a *second* set appended as `in` rows entering from the left, so every one of its windows is drawn twice, moving in opposite directions, with two `ScreencopyView`s capturing the same toplevel;
3. every switch restarts `slide` from 0 with the full `switchMs`, so a burst moves the rows in slow ramps that never complete.

The model now is one row per address, never two. Each row carries `startOff`, `endOff` and the `wsId` it belongs to; phase is derived (`endOff !== 0` means leaving) and the delegate's offset is `startOff + (endOff - startOff) * slide` on the one shared eased value, so there are still no per-row animations. A switch to workspace N *retargets* the existing rows instead of re-phasing them: each row restarts from the offset it had actually reached (`rowOffset`, computed from row data, not from items), a row whose window is in the new set gets `endOff = 0` and comes back to the live geometry wherever it was going, and every other row leaves toward the side its own workspace sits on (`wsId < N` ⇒ leftward, flipped by `slideReverse`), which is a fixed direction no later switch can reverse. Leaving rows already a full `slideDistance` out are dropped. `appendRow` refuses an address that already has a row and logs `[synopsis] duplicate row <addr>`; the simulator fails any scenario whose log contains that line, and it has never fired.

The duration is scaled by the longest remaining travel, `switchMs * clamp(maxTravel / slideDistance, 0.45, 1)`: in `rapid_switch` the six switches log `dur=450, 450, 428, 203, 424, 450`, so a burst that barely moves anything lands promptly instead of ramping for 450 ms each time. `slidesRunning` / `noteWorkspaceSwitch` / `noteSlideFinished` are untouched, so the close path still waits for the slide.

### slide spam awareness (2026-09-14)

The live recording `~/synopsis-recordings/20260914-005728` showed why a fast burst still ghosts, and it is not the machine: switch latency 0 ms, slides rendering at ~110 fps. Two structural faults.

*Sets pile up.* Arriving rows always travel a full screen width, so `maxTravel / slideDistance` is 1 and every slide asked for the full 450 ms, while keypresses arrived every 130-250 ms. Three or four slides overlapped and the log reached `leaving=11`: eleven thumbs from a handful of different workspaces on screen at once, crossing each other and the arriving set. `retargetRows` now takes `prevId` as well and caps the picture at two workspace sets, like hyprland's own slide: the set that was live until this switch (`wsId === prevId`) becomes the leaving set, and any older leaving row is removed on the spot instead of finishing its journey. The one exception is the rule that was already there and comes first: a row whose window is in the new set is *retargeted* to arrive, keeping its row, its delegate and its capture, so a window that is both leaving and in N turns around rather than being dropped and re-appended (which would be a second row for one address, the thing `appendRow`'s `duplicate row` guard exists to catch). Rows a full `slideDistance` out are still dropped as before.

*Every slide is full length.* `startSlide` now records `lastSwitchAt` and computes `interval = now - lastSwitchAt`. When `interval >= switchMs` (a single switch, or an interrupt that had a full slide's worth of time) the duration is the old expression, unchanged to the millisecond: `round(switchMs * clamp(maxTravel / slideDistance, 0.45, 1))`. Only when the switches come faster than one slide does the other branch run: `paced = clamp(interval * switchSpamFactor, switchMinMs, switchMs)`, then `round(max(switchMinMs, paced * clamp(maxTravel / slideDistance, 0.45, 1)))`. So a slide during a burst lasts a little longer than the gap the user is actually leaving (factor 1.2) and never less than `switchMinMs`, and the last switch of a burst is on screen almost at once instead of arriving behind a queue of half-finished ramps. `lastSwitchAt` resets when the overview goes away, so a reopen never inherits the pace of the burst before it. Normal switching is untouched by construction: the adaptive branch cannot be reached unless a previous slide started less than `switchMs` ago.

Leaving rows also stop costing anything: `wantLive: false` (the `ScreencopyView` keeps its last frame, which is what a workspace on its way out should show anyway), `interactive: false` as before, `hovered` forced off when interactivity drops so a highlight cannot ride off the screen, and `demoted: true` pins them to `z: -1` so the arriving set always draws over them.

Keys, both with JSON overrides in `~/.config/synopsis/config.json`:

- `switchMinMs` (140): floor for a slide shortened by spam. The floor is capped at `switchMs`, so setting it above the full slide length cannot make a spam slide outlast a normal one. Below roughly 120 ms the eased motion reads as a jump; raise it if the burst feels snappy to the point of being abrupt.
- `switchSpamFactor` (1.2): how much of the gap between two switches a spam slide is allowed to take. 1.0 makes each slide finish exactly as the next arrives; above ~1.5 the overlap returns.

The `slide` log line now carries `interval=` (`-1` for the first slide of an overview) between `arrive=` and `dur=`.

## the active workspace comes from hyprland's events, not from the refresh (2026-09-14)

A workspace switch used to reach the exposé only through a full state refresh: `workspacev2` marked the models dirty, `Overview.refreshTimer` (60 ms) called `HyprState.refreshAll`, three request-socket round trips later the new snapshot was published, and only then did `mon.activeId` change and `Expose.sync()` start the slide. Measured in `out/20260913-234838/rapid_switch.qs.log` (six switches 80 ms apart), every slide started **56-69 ms** after the event that caused it, and each one was produced by a refresh that had been *requested before that keypress*: `j/monitors` answers with the active workspace as of the request, so under a slower refresh, or with a reply already in flight, the id it carries is the one from before the switch. During a burst those stale intermediates are replayed one refresh apart, after the user has stopped pressing keys, and the thumbs wobble.

`HyprState` now keeps hyprland's own answer instead of asking for it:

- `activeByMonitor`, monitor name -> workspace id, fed by `workspacev2` (the monitor is the one the snapshot gives for that workspace id, or the focused monitor for a workspace hyprland has only just created) and by `focusedmonv2` (the workspace name resolved against the snapshot, monitor-matched). The map is replaced rather than patched and only when a value really changes, and each change bumps `liveVersion`.
- `eventSeq` counts workspace events. `refreshAll` records it when the requests go out and republishes the map from `j/monitors` only if it is unchanged when the reply lands; otherwise the events that arrived meanwhile are newer than anything in that reply and keep their values. `activeWorkspaceId` (the focus-confirm id) is guarded the same way.
- `Overview.liveActiveId(monitor, liveVersion)` feeds `_buildModel`, so a switch rebuilds the per-monitor model inside the event handler. The window lists still come from the last snapshot; only `activeId` and the exposé set move, and the model cache keys on the signature, so an unchanged rebuild hands back the same object and `Expose.sync()` sees `switched` false.

Measured in `out/20260914-000101` with the new `switch latency` metric (`workspacev2` to the `slide` line it caused): **max 0 ms across all 17 measured switches** in `rapid_switch`, `keybind_switch`, `keybind_interrupt`, `keybind_close_switch`, `keybind_enter`, `tile_click`, `tile_click_interrupt` and `switch_then_close_midslide`. Zero because the whole chain - event, map write, model rebuild, `sync`, `startSlide` - runs synchronously inside the raw-event handler; for the same reason the `slide` line is printed two or three ms *before* `shell.qml` prints the `event` line it answers, which the analyzer allows for (`SWITCH_LOG_SKEW_MS`).

The close flight is the one place that must not follow the events: it draws the workspace the close started on, and a keybind landing inside it would swap every thumb mid-flight for a set the flight has no geometry for. `Overview.pinnedActive` holds the map from `beginClose` until the next `beginPrepare` (or until a close is reversed by `open()`), which is exactly what the old refresh-driven build did by accident, since `refreshTimer` is stopped while closing.
