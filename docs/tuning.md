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
