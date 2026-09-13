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
