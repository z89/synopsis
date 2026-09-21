# phase 0 checklist

the experiments from the plan that need a hand on the desktop. run each one, paste the output or say what you saw, and the result goes into tuning.md. every command is safe to run on the live session; the only things that appear are what the command says.

## 0. install the hello shell

```
ln -sfn <repo>/shell ~/.config/quickshell/synopsis
qs --version
qs -c synopsis
```

leave it running in that terminal. it shows nothing; it prints one "up" line, then a line for every custom hyprland event and every ipc call. `Control + C` stops it.

## 1. qs cli and ipc

in a second terminal:

```
qs list
qs -c synopsis ipc call overview ping
qs -c synopsis ipc call overview toggle
qs ipc -c synopsis call overview ping
```

wanted: which of the two ipc forms works, and "pong" back. the first terminal should print an "ipc toggle" line.

## 2. the custom event trigger

add this line to hyprland.lua next to the other binds (for example after the keybind cheatsheet line, hyprland.lua:321), then press `Super + Shift + R` to reload:

```
hl.bind(mainMod .. " + grave", hl.dsp.event("synopsis:toggle"), { desc = "Synopsis" })
```

then press `Super + Grave` a few times. wanted: a "socket2 custom >> synopsis:toggle" line per press in the first terminal. if nothing arrives, run this and paste what the hello shell prints:

```
socat -u UNIX-CONNECT:$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock - | grep -i custom
```

and press `Super + Grave` again while it runs.

for latency, run this and compare the printed millisecond time with the timestamp in the hello shell's line:

```
date +%s%3N; hyprctl dispatch 'hl.dsp.event("synopsis:toggle")'
```

## 3. video on an inactive workspace, with mpv

```
mpv --loop --no-audio /path/to/any/video.mp4
```

leave it on workspace 1, go to workspace 2, open the dms overview:

```
dms ipc call hypr toggleOverview
```

wanted: does the mpv tile move on the first open, and on a second open? chromium played (2026-09-13); mpv is the strict case. if the video path is not handy, `mpv --loop --no-audio av://lavfi:testsrc=size=1280x720:rate=30` gives a moving test pattern.

## 4. occluded window on the active workspace

same mpv, but open the dms overview on the workspace mpv is on. wanted: does the tile for the current workspace keep moving while the overlay covers it?

## 5. xwayland windows

```
hyprctl -j clients | jq -r '.[] | select(.xwayland) | "\(.class) ws \(.workspace.id) at \(.at) size \(.size)"'
```

if that lists anything, open the dms overview from another workspace and check the listed window shows its content in its tile. discord and steam are the usual xwayland apps. an empty list means no xwayland app is running; say so and skip.

## 6. stacking order

on one workspace have two floating windows overlapping. click the one underneath so it comes to the top. then:

```
hyprctl -j clients | jq -r '.[] | select(.floating) | "\(.class)  \(.title)"'
```

wanted: the window you just raised is listed last. repeat by raising the other one and check the order flips.

## 7. headless hyprland

first attempt, no display at all. this either starts silently or exits with a message; it cannot touch the real session:

```
cd <repo>
env -u WAYLAND_DISPLAY -u DISPLAY AQ_DRM_DEVICES= Hyprland -c tools/phase0/headless.lua
```

if it stays running, in another terminal:

```
hyprctl -j instances
```

and stop it with `Control + C`. paste the first 20 lines it printed either way.

second attempt only if the first exits: nested, which opens a window on your desktop:

```
Hyprland -c tools/phase0/headless.lua
```

`Super + M` inside that window exits it. wanted: whether either form runs, and whether `hyprctl -j instances` lists two instances while it is up.
