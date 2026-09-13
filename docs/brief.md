# brief

what synopsis has to do, and what has been decided so far. written 2026-09-13 before any code.

## the target

macos tahoe mission control, on hyprland workspaces instead of spaces.

- a keyboard shortcut opens it; the same shortcut, escape, or a click closes it. this is a desktop: no trackpad, no gestures, no touch
- every workspace shows as a live thumbnail in a strip along the top. video keeps playing in the thumbnails
- the windows of the current workspace spread out below so none overlap and every one is readable
- opening animates continuously: each window flies from its real position into its place in the layout. no cut, no blank frame. closing runs it backwards
- click a window: go to its workspace, focus it, raise it above the others
- click a workspace thumbnail: go there
- drag a window onto a workspace thumbnail: move it there
- hover highlights; keyboard navigation later
- one overview per monitor, the way macos does it with displays have separate spaces
- the shortcut is `Super + Grave` (the backtick key, above tab and left of 1): the top-left corner of the workspace number row already in use, one key above the window cycle on `Super + Tab`. decided 2026-09-13
- normal workspaces only for now. special workspaces (hyprland scratchpads) stay out of the strip, but nothing may assume they do not exist: the model, the layout and the actions treat "which workspaces are shown" as a filter, so adding them later is a filter change and a tile variant, not a rewrite. decided 2026-09-13

## the machine

- arch, hyprland 0.56.2 with the lua config runtime, quickshell 0.3.1, dankmaterialshell 1.6.0
- amd rx 6600, one 5120x1440 120hz monitor, a second monitor sometimes
- hyprland has no native overview and the maintainer keeps it plugin territory. the official hyprexpo plugin was deleted in may 2026

## decisions

- own quickshell process, not a dms plugin and not a dms patch. dms plugins have no fullscreen surface type, and a known quickshell crash with many concurrent live captures should take down the overview, not the bar
- salvage dms plumbing, rewrite the layout. dms ships a workspace overview (Modules/WorkspaceOverlays) with the per-screen overlay, focus grab, live per-window capture and drag-drop already working. its grid layout is the wrong shape and gets replaced. check the dms licence before copying code
- exposé layout follows gnome shell's row packing (js/ui/workspace.js, UnalignedLayoutStrategy): rows packed by original vertical position, one uniform scale, aspect kept
- open animation follows omarchy-mission-control: thumbnails start full size over the real windows, then shrink into the layout; about 260ms with an ease-out curve to start, tuned by frame logs not by eye
- strip and exposé are shown together, the way gloview does it
- colours read from ~/.cache/DankMaterialShell/dms-colors.json when present

## what the dms overview taught us

tried on 2026-09-13. it works but looks rough and misbehaves:

- clicking a workspace or a window does not close it. the overlay hands overviewOpen into the grid widget as a one-way binding (HyprlandOverview.qml:211), the click sets the widget's own copy, and the overlay that owns the layer and keyboard grab never hears about it
- a click on a floating window only switches workspace. the keyboard grab is still alive after the click and steals focus back, so the window is never raised
- no gaps or borders between workspace tiles, empty workspaces drawn as large numbers, monitor name on every tile
- windows are drawn at their real relative positions inside each tile. nothing spreads them

## the one experiment before building

done 2026-09-13. hyprland renders a hidden window for capture but only sends frame callbacks to the active workspace, so mpv froze in its thumbnail while chromium, which keeps its own clock, played. hyprland's `render_unfocused` window rule sends callbacks to hidden windows at `misc:render_unfocused_fps`, and with it mpv moved too. the shell route covers everything; no compositor plugin. results and the mechanism in plan.md and tuning.md.

## open

- how the second monitor behaves when attached
- fullscreen and pinned windows in the exposé
- app grouping in the exposé, like macos "group windows by application"
