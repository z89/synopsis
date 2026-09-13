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
