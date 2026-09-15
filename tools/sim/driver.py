#!/usr/bin/env python3
"""Scenario driver for the synopsis headless simulator.

Talks to the NESTED Hyprland instance only (never the live session), builds the
fixture windows, drives one scenario through Hyprland's own event socket, and
records a video of it with wf-recorder. Everything the analyzer needs is written
next to the video:

    <out>/<scenario>.mkv           screen recording (VFR: damage-driven)
    <out>/<scenario>.actions.json  actions with ms offsets from recorder start
    <out>/<scenario>.qs.log        the qs stdout/stderr slice for this scenario
    <out>/<scenario>.events.json   hyprland socket2 events, same time base

Python stdlib only.

Usage:
    driver.py --scenario open_close --out DIR [--env DIR/env] [--seed N]
    driver.py --scenario all --out DIR
    driver.py --scenario all --dry-run          # no sockets, prints the plan

Safety: the driver refuses to run if the nested instance signature equals the
live session's $HYPRLAND_INSTANCE_SIGNATURE, or if it is missing.
"""

import argparse
import json
import os
import random
import re
import signal
import socket
import subprocess
import sys
import threading
import time

REPO = os.environ.get("SYNOPSIS_REPO") or os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# how long the recorder keeps rolling after the last action of a scenario
TAIL_MS = 1500
# quiet window used to decide the session has settled before a scenario starts
QUIET_MS = 400


# --------------------------------------------------------------------------
# sockets
# --------------------------------------------------------------------------

class HyprSock:
    """Hyprland request socket: one request per connection, read to EOF."""

    def __init__(self, sig, runtime=None):
        self.sig = sig
        self.runtime = runtime or os.environ.get("XDG_RUNTIME_DIR", "/run/user/%d" % os.getuid())
        self.path = os.path.join(self.runtime, "hypr", sig, ".socket.sock")

    def alive(self):
        try:
            self.request("j/version", timeout=1.0)
            return True
        except OSError:
            return False

    def request(self, msg, timeout=3.0):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(timeout)
        try:
            s.connect(self.path)
            s.sendall(msg.encode())           # no trailing newline
            chunks = []
            while True:
                b = s.recv(65536)
                if not b:
                    break
                chunks.append(b)
            return b"".join(chunks).decode(errors="replace")
        finally:
            s.close()

    def j(self, what):
        raw = self.request("j/" + what)
        try:
            return json.loads(raw)
        except json.JSONDecodeError:
            raise RuntimeError("bad json for %s: %r" % (what, raw[:200]))

    def dispatch(self, expr):
        return self.request("dispatch " + expr).strip()

    def dispatch_any(self, exprs):
        """Try dispatcher spellings in order; return the first that answers ok."""
        last = ""
        for e in exprs:
            last = self.dispatch(e)
            if last.lower().startswith("ok"):
                return last
        return last


class HyprEvents(threading.Thread):
    """Reads .socket2.sock in a thread into a timestamped list."""

    def __init__(self, sig, runtime=None):
        super().__init__(daemon=True)
        runtime = runtime or os.environ.get("XDG_RUNTIME_DIR", "/run/user/%d" % os.getuid())
        self.path = os.path.join(runtime, "hypr", sig, ".socket2.sock")
        self.lock = threading.Lock()
        self.items = []           # (t_ms_epoch, name, data)
        self._stop = threading.Event()
        self.sock = None

    def start(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(1.0)
        self.sock.connect(self.path)
        super().start()
        return self

    def run(self):
        buf = b""
        while not self._stop.is_set():
            try:
                b = self.sock.recv(65536)
            except socket.timeout:
                continue
            except OSError:
                break
            if not b:
                break
            buf += b
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                text = line.decode(errors="replace")
                if ">>" not in text:
                    continue
                name, data = text.split(">>", 1)
                with self.lock:
                    self.items.append((now_ms(), name, data))

    def stop(self):
        self._stop.set()
        try:
            if self.sock:
                self.sock.close()
        except OSError:
            pass

    def snapshot(self):
        with self.lock:
            return list(self.items)

    def mark(self):
        with self.lock:
            return len(self.items)

    def since(self, mark):
        with self.lock:
            return list(self.items[mark:])

    def wait_for(self, pred, timeout=8.0, mark=None):
        """Wait for an event matching pred(name, data); returns it or None."""
        start = time.time()
        idx = self.mark() if mark is None else mark
        while time.time() - start < timeout:
            items = self.since(idx)
            for t, name, data in items:
                if pred(name, data):
                    return (t, name, data)
            idx += len(items)          # never skip events appended mid-scan
            time.sleep(0.02)
        return None

    def wait_quiet(self, quiet_ms=QUIET_MS, timeout=6.0):
        """Wait until no event has arrived for quiet_ms."""
        start = time.time()
        while time.time() - start < timeout:
            snap = self.snapshot()
            last = snap[-1][0] if snap else 0
            if now_ms() - last >= quiet_ms:
                return True
            time.sleep(0.05)
        return False


def now_ms():
    return int(time.time() * 1000)


def wait_until(pred, timeout):
    """Poll pred every 20 ms; True once it holds, False at the timeout."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        if pred():
            return True
        time.sleep(0.02)
    return False


# --------------------------------------------------------------------------
# the scenario plan (pure data, so --dry-run needs no sockets)
# --------------------------------------------------------------------------

class Step:
    __slots__ = ("verb", "arg", "wait")

    def __init__(self, verb, arg=None, wait=0):
        self.verb = verb      # toggle | open | close | focus_ws | event
        self.arg = arg        # workspace id, or the synopsis:<verb> payload
        self.wait = wait      # ms to sleep after the step

    def describe(self):
        return "%-14s %-28s wait %4d ms" % (self.verb, "" if self.arg is None else str(self.arg), self.wait)


def S(verb, arg=None, wait=0):
    return Step(verb, arg, wait)


def plan_open_close():
    return [S("toggle", wait=900), S("toggle")]


def plan_keybind_switch():
    return [S("toggle", wait=700), S("focus_ws", 2, 900), S("focus_ws", 1, 900), S("toggle")]


def plan_keybind_interrupt():
    return [S("toggle", wait=700), S("focus_ws", 2, 120), S("focus_ws", 3, 60),
            S("focus_ws", 2, 200), S("focus_ws", 5, 1200), S("toggle")]


def plan_rapid_switch():
    # a burst of back-and-forth switches with the overview open: each switch
    # retargets the rows already on screen, so no window may be drawn twice and
    # nothing may reverse across the screen.
    # switches at 700, 780, 860, 940, 1020, 1300 ms, close at 2400 ms.
    return [S("toggle", wait=700), S("focus_ws", 2, 80), S("focus_ws", 3, 80),
            S("focus_ws", 2, 80), S("focus_ws", 1, 80), S("focus_ws", 2, 280),
            S("focus_ws", 3, 1100), S("close", wait=0)]


def plan_spam_switch_light():
    # a light, evenly-paced back-and-forth: switches at 700, 900, 1100, 1300,
    # 1500 ms (200 ms apart), close at 2600 ms. Last switch lands on ws2.
    return [S("toggle", wait=700), S("focus_ws", 2, 200), S("focus_ws", 3, 200),
            S("focus_ws", 2, 200), S("focus_ws", 3, 200), S("focus_ws", 2, 1100),
            S("close", wait=0)]


def plan_spam_switch_heavy():
    # a fast sweep across every fixture workspace and back, 110 ms apart,
    # starting at 700 ms: 2,3,4,5,6,5,4,3,2,1,2,3, close at 2600 ms. ws4 and
    # ws6 carry no fixture windows but are valid empty workspaces to switch
    # through. Last switch lands on ws3.
    steps = [S("toggle", wait=700)]
    seq = [2, 3, 4, 5, 6, 5, 4, 3, 2, 1, 2, 3]
    for i, ws in enumerate(seq):
        wait = 110 if i < len(seq) - 1 else 690
        steps.append(S("focus_ws", ws, wait))
    steps.append(S("close", wait=0))
    return steps


def plan_spam_toggle_keys():
    # toggles at 0, 30, 60, 300, 330, 900 ms: raw gaps to the previous toggle
    # are 30, 30, 240, 30, 570. The two sub-50 ms gaps (30 ms, at the 2nd and
    # 5th toggles) are exactly the pairs a coalescing debounce (Track 2,
    # inputCoalesceMs=50) would drop, whether it rebaselines on the last
    # accepted toggle or not: either reading drops exactly 2 of the 6 raw
    # toggles. 6 raw or 4 accepted are both even, so the overview is closed
    # (its starting state) by t=900 regardless of which coalescing variant is
    # in place - the end state is not ambiguous. focus_ws at 1200 ms then
    # sets ws3 independently of overview state, and the close at 2000 ms is
    # a deliberate no-op safety net (overview already closed).
    return [S("toggle", wait=30), S("toggle", wait=30), S("toggle", wait=240),
            S("toggle", wait=30), S("toggle", wait=570), S("toggle", wait=300),
            S("focus_ws", 3, wait=800), S("close", wait=0)]


def plan_spam_click():
    # rapid-fire tile/window clicks while switches are still pending: each
    # new click must cancel the previous pending requestFocus (Track 2 point
    # 3). activate-workspace:2 (700), activate-workspace:3 (760, 60 ms
    # later) retargets away from ws2, then activate-window:@t1 (820, 60 ms
    # later) retargets again: @t1 is the first fixture window on ws2 (see
    # FIXTURE), so the driver resolves it to a real address the same way
    # window_click_behind resolves @f1, and the final click wins, landing
    # back on ws2.
    return [S("toggle", wait=700), S("event", "activate-workspace:2", 60),
            S("event", "activate-workspace:3", 60), S("event", "activate-window:@t1", 1380),
            S("close", wait=0)]


def plan_tile_click():
    # activating a workspace tile closes the overview by itself
    return [S("toggle", wait=700), S("event", "activate-workspace:2", 1500)]


def plan_tile_click_left():
    # the same click from ws3: ws2 lies to the left, so its rows arrive from
    # the left (negative start offset) while ws3's row leaves to the right
    return [S("focus_ws", 3, 600), S("toggle", wait=700),
            S("event", "activate-workspace:2", 1500)]


def plan_tile_click_interrupt():
    # the first click switches and starts the close at once (tileSwitchMs), so
    # the second one 150 ms later arrives while closing and is ignored: the
    # session must stay on ws2 and the close must not hang or time out
    return [S("toggle", wait=700), S("event", "activate-workspace:2", 150),
            S("event", "activate-workspace:3", 1500)]


def plan_new_workspace():
    # two plus clicks with the overview open must not switch or close it: they
    # only grow virtualWorkspaces. toggle@0, new-workspace@700, @900, checked
    # still open right before the toggle@1600 that finally closes it (the
    # 700 ms wait to it covers the "still open at 1500" window: nothing
    # happens between 1500 and 1600, so the state does not change either).
    return [S("toggle", wait=700), S("event", "new-workspace", wait=200),
            S("event", "new-workspace", wait=700), S("toggle")]


def plan_new_workspace_from_empty():
    # the first plus (700) adds a virtual tile at the first fixture-empty id
    # (ws4); activating it (1000, activate-workspace:<target>) makes it real
    # and closes the overview. reopened (1800) on that now-active, still
    # empty workspace, a second plus (2500) must skip it and add virtual ws6,
    # which is left unused: the close (2900) must discard it, logging
    # "virtual workspaces cleared (1)".
    fixture_ids = set(ws for _, _, ws, _ in FIXTURE)
    target = next(i for i in range(1, 11) if i not in fixture_ids)
    return [S("toggle", wait=700), S("event", "new-workspace", wait=300),
            S("event", "activate-workspace:%d" % target, wait=800),
            S("toggle", wait=700), S("event", "new-workspace", wait=400),
            S("toggle")]


def plan_strip_scroll():
    # twelve plus clicks 150 ms apart push the fixture's four tiles past
    # stripMaxVisible (7): "strip overflow on" at 8, the overview still open
    # before the close toggle (action 13). the close discards the twelve
    # virtual tiles ("strip overflow off"); a second open/close at the
    # fixture's count must not overflow. every "strip tile" and overflow line
    # must carry the same tile size, at 4 tiles and at 16
    steps = [S("toggle", wait=700)]
    steps += [S("event", "new-workspace", wait=150) for _ in range(11)]
    steps += [S("event", "new-workspace", wait=700),
              S("toggle", wait=1200), S("toggle", wait=900), S("toggle")]
    return steps


def plan_strip_autoscroll():
    # twelve plus clicks overflow the strip (16 tiles, the view revealed at the
    # right end). the keybind then switches to ws2 (off-screen left), to ws16
    # (the last tile, off-screen right) and back to ws1: each switch must scroll
    # its tile fully into view on the highlight's own move (strip move lines),
    # the right fade must be off at the right end and the left fade off at the
    # start. then, from ws1 at the start (action 16 on):
    #  (c) ws12 scrolls in and ws3 is emptied mid-move (@t4 to ws1), so its
    #      tile goes and the row shifts left under the move: the scroll is
    #      retargeted and ws12 ends clear of the right fade by revealPad
    #      (restore_fixture puts @t4 back for later scenarios)
    #  (a) ws2 scrolls in and a 3 px touchpad swipe lands mid-move, then ws1
    #      and a wheel notch mid-move: the user takes the scroll from where
    #      the view is, with no jump, and the highlight finishes its move
    #  (b) ws14 scrolls in and Escape closes mid-move: no scrolling frame
    #      after closing, no move frame after closed, and the reopen is at
    #      rest with the active tile in view. ws1 again, then the final close
    steps = [S("toggle", wait=700)]
    steps += [S("event", "new-workspace", wait=150) for _ in range(11)]
    steps += [S("event", "new-workspace", wait=900),
              S("focus_ws", 2, 1000), S("focus_ws", 16, 1000), S("focus_ws", 1, 1000)]
    steps += [S("focus_ws", 12, 100), S("event", "move-window:@t4:1", 1000)]
    steps += [S("focus_ws", 2, 120), S("event", "strip-scroll:pixel:3", 1000)]
    steps += [S("focus_ws", 1, 120), S("event", "strip-scroll:angle:120", 1000)]
    steps += [S("focus_ws", 14, 100), S("close", wait=1400), S("toggle", wait=1000),
              S("focus_ws", 1, 900), S("toggle")]
    return steps


def plan_window_click_behind():
    # @f1 sits behind @f2 on ws1; activating it must raise it to the stack top
    return [S("toggle", wait=700), S("event", "activate-window:@f1", 1200)]


def plan_toggle_spam():
    gaps = [60, 40, 90, 30, 200, 50, 120, 400]
    steps = [S("toggle", wait=g) for g in gaps]
    steps.append(S("close", wait=1200))
    return steps


def plan_toggle_spam_slow():
    # toggles at 0, 500, 700, 1300, 1350, 2000 ms, then an explicit close.
    # Unlike toggle_spam the gaps clear hasContentTimeoutMs (400 ms), so the
    # overview does reach opening/open and is then closed mid-flight and
    # reopened mid-close.
    gaps = [500, 200, 600, 50, 650, 600]
    steps = [S("toggle", wait=g) for g in gaps]
    steps.append(S("close", wait=1200))
    return steps


def plan_keybind_close_switch():
    # bounce-back regression: switch to ws3 with the overview open, then close.
    # The session must stay on ws3 instead of snapping back to ws1.
    return [S("toggle", wait=700), S("focus_ws", 3, 700), S("toggle", wait=900)]


def plan_switch_while_preparing():
    # the workspace keybind lands between the toggle and the first flight frame,
    # while the backdrop is still transparent: nothing of the old workspace may
    # paint over the new desktop, and the close must leave the session on ws5.
    return [S("toggle", wait=40), S("focus_ws", 3, 80), S("focus_ws", 5, 1080),
            S("toggle", wait=700), S("close", wait=0)]


def plan_switch_then_close_midslide():
    return [S("toggle", wait=700), S("focus_ws", 2, 120), S("toggle", wait=1200)]


def plan_move_window():
    return [S("toggle", wait=700), S("event", "move-window:@f3:3", 600), S("toggle", wait=800)]


def plan_escape_midslide_smooth():
    # a keybind switch, then escape at ~40 % of hyprland's 911 ms workspace
    # spring: every row must carry on from its position and speed and land
    # with no correction (analyze.py motion_checks)
    return [S("toggle", wait=700), S("focus_ws", 2, 365), S("close", wait=1200)]


def plan_move_window_in_overview():
    # the move-to-next-workspace keybind on the hovered window with the
    # overview open, onto ws2 which already has windows. `carry` runs the
    # user's own bind (~/.config/hypr/carry.lua) in the nested session, or
    # hyprland's stock follow move when that file is absent
    # f2 is the stack top and holds focus; the flight and its landing (unpin)
    # both finish before the close
    return [S("toggle", wait=700), S("carry", "@f2:1", 2600), S("toggle", wait=900)]


# a tile click, then the carry keybind (Super + Shift + Right) at `delay` ms
# after the click: inside the slide, near its end, and right after the close
# flight starts. the close is committed and input is released, so every row
# must keep one continuous close timeline (analyze.py motion_checks)
#   float: from ws2, click ws1 and carry f2 (carry.lua pins and flies it)
#   float_nohover: the same with no focus dispatch, the active window is carried
#   tiled: from ws1, click ws2 and carry t1 (stock follow move, ws2 retiles)
# the close flight runs ~760 ms here, so 650 and 720 land after the slide has
# visibly settled but before the overlay hides
TILE_CARRY_DELAYS = (30, 200, 500, 650, 720)
TILE_CARRY_VARIANTS = ("float", "float_nohover", "tiled")


def plan_tile_click_then_carry(variant, delay):
    if variant == "tiled":
        return [S("toggle", wait=700), S("event", "activate-workspace:2", delay),
                S("carry", "@t1:1", 2600)]
    sym = "@active" if variant == "float_nohover" else "@f2"
    return [S("focus_ws", 2, 600), S("toggle", wait=700),
            S("event", "activate-workspace:1", delay), S("carry", sym + ":1", 2600)]


def tile_carry_name(variant, delay):
    return "tile_click_then_carry_%s_%d" % (variant, delay)


def plan_move_window_to_empty_in_overview():
    # the same keybind from ws3, whose only window t4 is carried onto ws4: a
    # workspace with no windows that does not exist until the move creates it.
    # the snapshot has no entry for it when the move is patched in, and the
    # moved window must keep its row and its tile all the same
    return [S("focus_ws", 3, 600), S("toggle", wait=700), S("carry", "@t4:1", 2600),
            S("toggle", wait=900)]


def empty_ws_plus_ids():
    # the plus button's first three ids from ws1: the lowest fixture-empty ids
    fixture_ids = set(ws for _, _, ws, _ in FIXTURE)
    return [i for i in range(1, 11) if i not in fixture_ids][:3]


def plan_empty_ws_carry_through():
    # session A: from ws1, three plus clicks add empty tiles (4, 6, 7). the
    # carry keybind takes f2 right one workspace at a time up to the last of
    # them and back left to ws1: every empty workspace it leaves is destroyed
    # by hyprland, and its tile must stay, in its slot, until the close. then
    # the plain workspace switch through the same empty tiles. the close
    # drops the tiles of the workspaces that are really empty.
    # session B: ws4 is empty and active before the open; switching away
    # destroys it, and its tile must stay until that close too
    plus = empty_ws_plus_ids()
    last = max(plus)
    steps = [S("focus_ws", 1, 600), S("toggle", wait=700)]
    steps += [S("event", "new-workspace", wait=300) for _ in plus[:-1]]
    steps += [S("event", "new-workspace", wait=900)]
    steps += [S("carry", "@f2:1", 1500)]
    steps += [S("carry", "@active:1", 1500) for _ in range(last - 2)]
    steps += [S("carry", "@active:-1", 1500) for _ in range(last - 1)]
    for ws in plus + [plus[0], 1]:
        steps.append(S("focus_ws", ws, 900))
    steps += [S("toggle", wait=1500)]
    steps += [S("focus_ws", plus[0], 600), S("toggle", wait=900),
              S("focus_ws", 1, 900), S("focus_ws", plus[0], 900),
              S("focus_ws", 2, 900), S("toggle", wait=1500)]
    return steps


def plan_tile_live_after_move():
    # a window moved through synopsis must show live on its destination tile:
    # first dropped onto ws3's tile (f3, from ws1), then carried onto ws2 with
    # the keybind (f2). each move is probed twice while open (the capture
    # state, and frame requests growing between them) and again after a close
    # and reopen. `probe` logs every tile thumb (WorkspaceTile tile-probe) and
    # is not an action
    reopen = [S("toggle", wait=800), S("toggle"), S("wait_state", "open", 500)]
    return (DROP_OPEN + [S("probe", "d0"),
                         S("event", "drop-window:@f3:3:0.5:0.5"), DROP_DECIDED,
                         S("wait", None, 900), S("probe", "d1", 400), S("probe", "d2")]
            + reopen + [S("probe", "d3", 400), S("probe", "d4"),
                        S("carry", "@f2:1", 2600), S("probe", "k1", 400), S("probe", "k2")]
            + reopen + [S("probe", "k3", 400), S("probe", "k4"), S("toggle", wait=800)])


# the nested session's workspace leaf on a bezier (no spring), and back. `eval`
# is not an action: it runs the lua in the nested session, asks the shell to
# read the curve again (synopsis:reload-curve) and is not recorded
BEZIER_CURVE = ('hl.animation({ leaf = "workspacesIn", enabled = true, speed = 3.5, '
                'bezier = "easeOutQuint", style = "slide" })')
SPRING_CURVE = ('hl.animation({ leaf = "workspacesIn", enabled = true, speed = 3.5, '
                'spring = "gentle", style = "slide" })')


def plan_spam_switch_heavy_bezier():
    # spam_switch_heavy on a bezier workspace curve: every interrupted slide
    # continues on a hermite, and the rows appended with no velocity must still
    # follow the switch table from their first frame (analyze.py motion_checks)
    steps = [S("eval", BEZIER_CURVE, 0), S("wait_log", r"workspace curve bezier", 300)]
    steps += plan_spam_switch_heavy()
    steps += [S("wait", None, 1500), S("eval", SPRING_CURVE, 0),
              S("wait_log", r"workspace curve spring", 0)]
    return steps


# drop-window:<addr>:<ws>:<fx>:<fy> releases the exposé thumb, grabbed at its
# centre, with the pointer at the fraction (fx, fy) of that workspace's tile
# (Overview.dropWindowAt: the same probe, resolution and dispatch as a drag)
#
# the drop is sent once the log shows the overview open (the hook refuses
# anything else), and the close once the log shows the decision; the waits
# after those are settle time only. wait_state / wait_log are not actions:
# they send nothing and are not recorded
DROP_OPEN = [S("toggle"), S("wait_state", "open", 150)]
DROP_DECIDED = S("wait_log", r"drop (accept|reject)", 0)


def plan_drop_floating_position():
    return DROP_OPEN + [S("event", "drop-window:@f3:3:0.5:0.5"), DROP_DECIDED,
                        S("wait", None, 900), S("toggle", wait=800)]


def plan_drop_edge_rejected():
    # inside the tile but within its edge buffer
    return DROP_OPEN + [S("event", "drop-window:@f3:3:0.01:0.5"), DROP_DECIDED,
                        S("wait", None, 900), S("toggle", wait=800)]


def plan_drop_outside_rejected():
    # a tile and a half above the strip: over the exposé, no tile
    return DROP_OPEN + [S("event", "drop-window:@f3:3:0.5:-1.5"), DROP_DECIDED,
                        S("wait", None, 900), S("toggle", wait=800)]


def plan_keybind_enter():
    # Enter must "enter" the workspace currently shown: switch to ws3 with the
    # overview open, then confirm instead of clicking a tile. The trailing
    # close is a no-op safety net since confirm already closes the overview.
    return [S("toggle", wait=700), S("focus_ws", 3, wait=700),
            S("event", "confirm", wait=800), S("close", wait=0)]


FUZZ_WS = [1, 2, 3, 4, 5]
FUZZ_WINDOWS = ["@f1", "@f2", "@f3", "@f4", "@f5", "@fv"]


def plan_fuzz(seed=0):
    # ~40% of actions are rapid workspace switches (focus_ws keybind or an
    # activate-workspace tile click, chosen evenly) with 80-200 ms gaps, to
    # weight the fuzzer toward the spam pattern that ghosts slides; the rest
    # is the original mix with its original 20-500 ms gaps. Same seed still
    # gives the same sequence (rnd is consumed in a fixed order per step).
    rnd = random.Random(seed)
    steps = []
    for _ in range(25):
        if rnd.random() < 0.4:
            gap = rnd.randint(80, 200)
            if rnd.randrange(2) == 0:
                steps.append(S("focus_ws", rnd.choice(FUZZ_WS), gap))
            else:
                steps.append(S("event", "activate-workspace:%d" % rnd.choice(FUZZ_WS), gap))
            continue
        gap = rnd.randint(20, 500)
        pick = rnd.randrange(3)
        if pick == 0:
            steps.append(S("toggle", wait=gap))
        elif pick == 1:
            steps.append(S("event", "activate-window:%s" % rnd.choice(FUZZ_WINDOWS), gap))
        else:
            steps.append(S("event", "move-window:%s:%d" % (rnd.choice(FUZZ_WINDOWS), rnd.choice(FUZZ_WS)), gap))
    steps.append(S("close", wait=0))
    return steps


SCENARIOS = {
    "open_close": plan_open_close,
    "keybind_switch": plan_keybind_switch,
    "keybind_interrupt": plan_keybind_interrupt,
    "rapid_switch": plan_rapid_switch,
    "spam_switch_light": plan_spam_switch_light,
    "spam_switch_heavy": plan_spam_switch_heavy,
    "spam_toggle_keys": plan_spam_toggle_keys,
    "spam_click": plan_spam_click,
    "tile_click": plan_tile_click,
    "tile_click_left": plan_tile_click_left,
    "tile_click_interrupt": plan_tile_click_interrupt,
    "new_workspace": plan_new_workspace,
    "new_workspace_from_empty": plan_new_workspace_from_empty,
    "strip_scroll": plan_strip_scroll,
    "strip_autoscroll": plan_strip_autoscroll,
    "window_click_behind": plan_window_click_behind,
    "toggle_spam": plan_toggle_spam,
    "toggle_spam_slow": plan_toggle_spam_slow,
    "keybind_close_switch": plan_keybind_close_switch,
    "switch_while_preparing": plan_switch_while_preparing,
    "switch_then_close_midslide": plan_switch_then_close_midslide,
    "move_window": plan_move_window,
    "escape_midslide_smooth": plan_escape_midslide_smooth,
    "move_window_in_overview": plan_move_window_in_overview,
    "move_window_to_empty_in_overview": plan_move_window_to_empty_in_overview,
    "tile_live_after_move": plan_tile_live_after_move,
    "spam_switch_heavy_bezier": plan_spam_switch_heavy_bezier,
    "drop_floating_position": plan_drop_floating_position,
    "drop_edge_rejected": plan_drop_edge_rejected,
    "drop_outside_rejected": plan_drop_outside_rejected,
    "keybind_enter": plan_keybind_enter,
    "fuzz": plan_fuzz,
}

SCENARIO_ORDER = [
    "open_close", "keybind_switch", "keybind_interrupt", "rapid_switch",
    "spam_switch_light", "spam_switch_heavy", "spam_toggle_keys", "spam_click",
    "tile_click", "tile_click_left", "tile_click_interrupt", "new_workspace", "new_workspace_from_empty",
    "strip_scroll", "strip_autoscroll", "window_click_behind", "toggle_spam",
    "toggle_spam_slow", "keybind_close_switch", "switch_while_preparing",
    "switch_then_close_midslide", "move_window", "escape_midslide_smooth",
    "move_window_in_overview", "move_window_to_empty_in_overview",
    "tile_live_after_move",
    "spam_switch_heavy_bezier", "drop_floating_position",
    "drop_edge_rejected", "drop_outside_rejected", "keybind_enter", "fuzz",
]

# expected settle budget per scenario, in ms after the last action:
#   slideMs 911 (hyprland's workspace spring, Config.slideMs) + settleMs 60
#   + flightMs 260 + 150 slack  (shell/Core/Config.qml)
BASE_SETTLE_MS = 911 + 60 + 260 + 150
EXPECTED_SETTLE_MS = {name: BASE_SETTLE_MS for name in SCENARIOS}
EXPECTED_SETTLE_MS["toggle_spam"] = BASE_SETTLE_MS + 300
EXPECTED_SETTLE_MS["toggle_spam_slow"] = BASE_SETTLE_MS + 300
EXPECTED_SETTLE_MS["fuzz"] = BASE_SETTLE_MS + 300
EXPECTED_SETTLE_MS["switch_while_preparing"] = BASE_SETTLE_MS + 300
EXPECTED_SETTLE_MS["new_workspace"] = EXPECTED_SETTLE_MS["tile_click"] + 500
EXPECTED_SETTLE_MS["new_workspace_from_empty"] = EXPECTED_SETTLE_MS["new_workspace"]
EXPECTED_SETTLE_MS["strip_scroll"] = EXPECTED_SETTLE_MS["new_workspace"]
EXPECTED_SETTLE_MS["strip_autoscroll"] = EXPECTED_SETTLE_MS["new_workspace"]
EXPECTED_SETTLE_MS["spam_switch_heavy"] = BASE_SETTLE_MS + 600
EXPECTED_SETTLE_MS["spam_switch_heavy_bezier"] = EXPECTED_SETTLE_MS["spam_switch_heavy"]

# the tile click + carry sweep: one scenario per variant and delay, run
# together with --scenario tile_click_then_carry
SCENARIO_GROUPS = {"tile_click_then_carry": []}
for _v in TILE_CARRY_VARIANTS:
    for _d in TILE_CARRY_DELAYS:
        _n = tile_carry_name(_v, _d)
        SCENARIOS[_n] = (lambda v=_v, d=_d: plan_tile_click_then_carry(v, d))
        SCENARIO_ORDER.append(_n)
        SCENARIO_GROUPS["tile_click_then_carry"].append(_n)
        EXPECTED_SETTLE_MS[_n] = BASE_SETTLE_MS


def plan_tile_click_then_carry_reopen():
    # the float_nohover carry 200 ms after the click, then the overview keybind
    # 150 ms later, inside the slide that follows the carry: the close reverses
    # (openNow) and that slide must carry on as an open one. no row may stay
    # flat at its real rect over the exposé grid, and nothing pops on the way
    return [S("focus_ws", 2, 600), S("toggle", wait=700),
            S("event", "activate-workspace:1", 200), S("carry", "@active:1", 150),
            S("toggle", wait=1500), S("toggle", wait=1200)]


SCENARIOS["tile_click_then_carry_reopen"] = plan_tile_click_then_carry_reopen
SCENARIO_ORDER.append("tile_click_then_carry_reopen")
EXPECTED_SETTLE_MS["tile_click_then_carry_reopen"] = BASE_SETTLE_MS

SCENARIOS["empty_ws_carry_through"] = plan_empty_ws_carry_through
SCENARIO_ORDER.append("empty_ws_carry_through")
EXPECTED_SETTLE_MS["empty_ws_carry_through"] = EXPECTED_SETTLE_MS["new_workspace"]


def build_plan(name, seed=0):
    fn = SCENARIOS[name]
    return fn(seed) if name == "fuzz" else fn()


# --------------------------------------------------------------------------
# the nested session
# --------------------------------------------------------------------------

FIXTURE = [
    # (symbol, class, workspace, kind)
    ("@f1", "sim-f1", 1, "kitty"),
    ("@f2", "sim-f2", 1, "kitty"),
    ("@f3", "sim-f3", 1, "kitty"),
    ("@f4", "sim-f4", 1, "kitty"),
    ("@fv", "sim-fv", 1, "mpv"),
    ("@t1", "sim-t1", 2, "kitty"),
    ("@t2", "sim-t2", 2, "kitty"),
    ("@t3", "sim-t3", 2, "kitty"),
    ("@t4", "sim-t4", 3, "kitty"),
    ("@f5", "sim-f5", 5, "kitty"),
    ("@f6", "sim-f6", 5, "kitty"),
]

# bottom-to-top stacking wanted on ws1: f2 ends on top, f1 directly behind it
STACK_ORDER = ["@f4", "@f3", "@fv", "@f1", "@f2"]


class Session:
    def __init__(self, env, out_dir, verbose=True):
        self.env = env                       # nested child environment (dict)
        self.sig = env["HYPRLAND_INSTANCE_SIGNATURE"]
        self.out = out_dir
        self.verbose = verbose
        self.sock = HyprSock(self.sig, env.get("XDG_RUNTIME_DIR"))
        self.events = None
        self.procs = []                      # fixture subprocesses we own
        self.addr = {}                       # symbol -> hyprland address

    # -- lifecycle --------------------------------------------------------

    def log(self, msg):
        if self.verbose:
            print("[driver] " + msg, flush=True)

    def connect(self):
        self.events = HyprEvents(self.sig, self.env.get("XDG_RUNTIME_DIR")).start()
        ver = self.sock.request("version").splitlines()[:1]
        self.log("nested hyprland: %s" % (ver[0] if ver else "?"))

    def hyprland_log(self):
        p = os.path.join(self.sock.runtime, "hypr", self.sig, "hyprland.log")
        return p if os.path.exists(p) else None

    def child_env(self):
        e = dict(os.environ)
        e.update(self.env)
        e.pop("DISPLAY", None)
        return e

    def spawn(self, argv):
        p = subprocess.Popen(argv, env=self.child_env(),
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                             start_new_session=True)
        self.procs.append(p)
        return p

    def kill_fixture(self):
        for p in self.procs:
            try:
                os.killpg(os.getpgid(p.pid), signal.SIGTERM)
            except (ProcessLookupError, PermissionError):
                pass
        self.procs = []

    # -- fixture ----------------------------------------------------------

    def cmd_for(self, klass, kind):
        if kind == "mpv":
            return ["mpv", "--no-audio", "--loop-file=inf", "--vo=gpu",
                    "--wayland-app-id=" + klass, "--no-terminal", "--no-osc",
                    "av://lavfi:testsrc2=size=640x360:rate=60"]
        return ["kitty", "--class", klass, "--title", klass,
                "python3", os.path.join(REPO, "tools", "sim", "pattern.py"), klass.replace("sim-", "")]

    def build_fixture(self, timeout=25.0):
        """Spawn every fixture window, learn its address, place it silently."""
        for sym, klass, ws, kind in FIXTURE:
            mark = self.events.mark()
            self.spawn(self.cmd_for(klass, kind))
            # openwindow>>address,workspacename,class,title  (address has no 0x)
            hit = self.events.wait_for(
                lambda n, d, k=klass: n == "openwindow" and d.split(",")[2:3] == [k],
                timeout=timeout, mark=mark)
            if hit is None:
                # mpv may refuse --wayland-app-id on older builds; fall back to
                # whatever window actually appeared for this spawn
                hit = self.events.wait_for(lambda n, d: n == "openwindow", timeout=4.0, mark=mark)
            if hit is None:
                raise RuntimeError("fixture window %s (%s) never opened" % (sym, klass))
            raw = hit[2].split(",")[0]
            self.addr[sym] = raw if raw.startswith("0x") else "0x" + raw
            self.log("fixture %s %s -> %s" % (sym, klass, self.addr[sym]))
            if ws != 1:
                self.move_silent(self.addr[sym], ws)
            time.sleep(0.12)
        self.settle_stack()
        self.focus_ws(1)
        self.events.wait_quiet(600, timeout=8.0)
        self.record_home()

    def record_home(self):
        """Remember each fixture window's workspace and floating position."""
        self.home = {}
        for c in self.clients():
            for sym, addr in self.addr.items():
                if c.get("address") == addr:
                    self.home[sym] = (c.get("workspace", {}).get("id"),
                                      bool(c.get("floating")),
                                      tuple((c.get("at") or [0, 0])[:2]))

    def restore_fixture(self, timeout=4.0):
        """Put fixture windows an earlier scenario moved back where they were.

        The suite shares one session: move_window leaves f3 on ws3, and the
        drop scenarios after it then found no f3 thumb on ws1 (reason=gone).
        """
        home = getattr(self, "home", {})
        if not home:
            return

        def stray():
            out = []
            by_addr = {c.get("address"): c for c in self.clients()}
            for sym, (ws, floating, at) in home.items():
                c = by_addr.get(self.addr.get(sym))
                if c is None:
                    continue
                cur_at = tuple((c.get("at") or [0, 0])[:2])
                if c.get("workspace", {}).get("id") != ws or (floating and cur_at != at):
                    out.append((sym, ws, floating, at, c))
            return out

        moved = stray()
        if not moved:
            return
        for sym, ws, floating, at, c in moved:
            addr = self.addr[sym]
            self.log("restore %s -> ws%s at %s" % (sym, ws, at))
            if c.get("workspace", {}).get("id") != ws:
                self.move_silent(addr, ws)
            if floating:
                self.sock.dispatch_any([
                    'hl.dsp.window.move({ x = %d, y = %d, window = "address:%s" })' % (at[0], at[1], addr),
                ])
        if not wait_until(lambda: not stray(), timeout):
            self.log("restore incomplete: %s" % [m[0] for m in stray()])
        self.settle_stack()
        self.focus_ws(1)
        self.events.wait_quiet(QUIET_MS, timeout=4.0)

    def move_silent(self, addr, ws):
        return self.sock.dispatch_any([
            'hl.dsp.window.move({ workspace = %d, follow = false, window = "address:%s" })' % (ws, addr),
            'hl.dsp.window.move({ workspace = "%d silent", window = "address:%s" })' % (ws, addr),
        ])

    def settle_stack(self):
        """Raise the ws1 floats bottom-to-top so f1 ends up behind f2."""
        for sym in STACK_ORDER:
            addr = self.addr.get(sym)
            if not addr:
                continue
            self.sock.dispatch_any([
                'hl.dsp.window.alter_zorder({ window = "address:%s", z = "top" })' % addr,
                'hl.dsp.window.bring_to_top({ window = "address:%s" })' % addr,
                'hl.dsp.focus({ window = "address:%s" })' % addr,
            ])
            time.sleep(0.08)

    # -- primitives -------------------------------------------------------

    def focus_ws(self, wsid):
        return self.sock.dispatch_any([
            'hl.dsp.focus({ workspace = %d })' % wsid,
            'hl.dsp.focus({ workspace = "%d" })' % wsid,
        ])

    def carry(self, sym, direction):
        """The move-window-to-next-workspace keybind on a focused window.

        Focuses the window (hovering it in the overview does the same), then
        runs ~/.config/hypr/carry.lua's press() inside the NESTED session, the
        module the live bind calls; loaded once per session into a global.
        Without that file, hyprland's stock follow move stands in."""
        addr = self.addr.get(sym, sym)
        # @active: no focus dispatch, the pointer hovers nothing and the bind
        # carries whatever holds focus
        if sym != "@active":
            self.sock.dispatch_any([
                'hl.dsp.focus({ window = "address:%s" })' % addr,
            ])
            time.sleep(0.03)
        # the bind carries the active window, whatever the focus above did
        try:
            addr = self.sock.j("activewindow").get("address") or addr
        except Exception:
            pass
        self.carried = addr
        path = os.path.expanduser("~/.config/hypr/carry.lua")
        if os.path.exists(path):
            lua = ('if not rawget(_G, "__simcarry") then local f = io.open(%s, "r"); '
                   'local m = load(f:read("*a"), "@carry.lua")(); f:close(); m.setup(); '
                   # its log appends to $XDG_RUNTIME_DIR/carry.log, which the
                   # nested session shares with the live one: keep it quiet
                   'm.backend.log = function() end; '
                   '_G.__simcarry = m end; _G.__simcarry.press(%d)'
                   % (json.dumps(path), direction))
            reply = self.sock.request("eval " + lua).strip()
            self.log("carry %s %+d: %s" % (sym, direction, reply[:80]))
            return reply
        ws = next((c.get("workspace", {}).get("id") for c in self.clients()
                   if c.get("address") == addr), 1)
        return self.sock.dispatch_any([
            'hl.dsp.window.move({ workspace = %d, follow = true, window = "address:%s" })'
            % (ws + direction, addr),
        ])

    def custom_event(self, payload):
        """payload is e.g. 'toggle' or 'activate-workspace:2' (no synopsis: prefix)."""
        return self.sock.dispatch_any([
            'hl.dsp.event("synopsis:%s")' % payload,
            'hl.dsp.event("synopsis", "%s")' % payload,
        ])

    def resolve(self, text):
        out = text
        for sym, addr in self.addr.items():
            out = out.replace(sym, addr)
        return out

    def clients(self):
        return self.sock.j("clients")

    def active_workspace(self):
        mons = self.sock.j("monitors")
        for m in mons:
            if m.get("name") == "WAYLAND-1" or m.get("focused"):
                return m.get("activeWorkspace", {}).get("id")
        return None

    def overview_state(self, qs_log, upto=None):
        """Last '[synopsis] state <ms> <name>' seen in the qs log.

        upto, when given, is a byte offset into qs_log: only the log as it
        stood at that point is considered, so a scenario can assert the
        overview was still open right before some later action closed it
        (mid-run checks have no other way to look back in time).
        """
        try:
            with open(qs_log, "rb") as f:
                if upto is None:
                    f.seek(0, os.SEEK_END)
                    end = f.tell()
                else:
                    end = upto
                window = 65536
                while True:
                    start = max(0, end - window)
                    f.seek(start)
                    chunk = f.read(end - start).decode(errors="replace")
                    hits = re.findall(r"\[synopsis\] state (\d+) (\w+)", chunk)
                    if hits or start == 0:
                        return hits[-1][1] if hits else None
                    window *= 2
        except OSError:
            return None


# --------------------------------------------------------------------------
# recorder
# --------------------------------------------------------------------------

class Recorder:
    def __init__(self, session, path, fps=60, output="WAYLAND-1"):
        self.session = session
        self.path = path
        self.fps = fps
        self.output = output
        self.proc = None
        self.t0 = None

    def start(self):
        if not which("wf-recorder"):
            self.session.log("wf-recorder not found: running without video")
            self.t0 = now_ms()
            return None
        # record the PARENT compositor's output: it shows exactly what the
        # nested hyprland presents, and the nested screencopy path stalls
        # under a headless parent (see README, capture path)
        argv = ["wf-recorder", "-r", str(self.fps),
                "-c", "libx264", "-p", "preset=ultrafast", "-p", "crf=16",
                "-f", self.path]
        env = self.session.child_env()
        env["WAYLAND_DISPLAY"] = self.session.env.get("PARENT_WL", env.get("WAYLAND_DISPLAY", ""))
        env.pop("HYPRLAND_INSTANCE_SIGNATURE", None)
        self.errlog = open(self.path + ".rec.log", "w")
        # a still of the parent output first: a flat recording is then either
        # a capture fault (still is flat too) or a genuinely dark scene
        if which("grim"):
            try:
                subprocess.run(["grim", self.path + ".pre.png"], env=env,
                               stdout=self.errlog, stderr=subprocess.STDOUT,
                               timeout=5, check=False)
            except subprocess.TimeoutExpired:
                self.session.log("grim on the parent display timed out")
        self.proc = subprocess.Popen(argv, env=env,
                                     stdout=self.errlog,
                                     stderr=subprocess.STDOUT,
                                     start_new_session=True)
        time.sleep(0.7)          # let it negotiate the screencopy stream
        self.t0 = now_ms()
        return self.proc

    def stop(self):
        # the video clock starts at wf-recorder's first captured frame, which
        # is not t0; the analyzer anchors it from the end instead: the last
        # frame's pts lands within a frame of this stop time
        self.t_stop = now_ms()
        if not self.proc:
            return
        try:
            self.proc.send_signal(signal.SIGINT)
            self.proc.wait(timeout=15)
        except subprocess.TimeoutExpired:
            self.proc.kill()
        except ProcessLookupError:
            pass


def which(name):
    for d in os.environ.get("PATH", "").split(os.pathsep):
        p = os.path.join(d, name)
        if os.access(p, os.X_OK):
            return p
    return None


# --------------------------------------------------------------------------
# scenario execution
# --------------------------------------------------------------------------

def file_size(path):
    try:
        return os.path.getsize(path)
    except OSError:
        return 0


def write_hl_slice(hl_log, start, end, actions, dest):
    """The hyprland debug log between start and end, with one marker line
    inserted before the text that followed each action."""
    cuts = sorted(((a["hl_log_offset"], a) for a in actions if a.get("hl_log_offset")),
                  key=lambda c: c[0])
    out = []
    pos = start
    with open(hl_log, "rb") as f:
        for off, a in cuts:
            off = max(off, pos)
            f.seek(pos)
            out.append(f.read(off - pos))
            out.append(("\n#### action t=%d ms %s %s\n" % (a["t_ms"], a["verb"], a["args"] or "")).encode())
            pos = off
        f.seek(pos)
        out.append(f.read(max(0, end - pos)))
    with open(dest, "wb") as f:
        f.write(b"".join(out))


def slice_file(path, start, end):
    try:
        with open(path, "rb") as f:
            f.seek(start)
            return f.read(max(0, end - start)).decode(errors="replace")
    except OSError:
        return ""


def precondition(sess, qs_log):
    """Workspace 1, overview closed, session quiet."""
    sess.custom_event("close")
    time.sleep(0.25)
    sess.focus_ws(1)
    deadline = time.time() + 5
    while time.time() < deadline:
        st = sess.overview_state(qs_log)
        if st in (None, "closed") and sess.active_workspace() == 1:
            break
        time.sleep(0.1)
    sess.events.wait_quiet(QUIET_MS, timeout=5.0)


def run_scenario(sess, name, out_dir, qs_log, seed=0):
    plan = build_plan(name, seed)
    sess.log("scenario %s: %d steps" % (name, len(plan)))
    precondition(sess, qs_log)
    # with the overview closed: a move while it is open would be a scenario action
    sess.restore_fixture()

    mkv = os.path.join(out_dir, name + ".mkv")
    rec = Recorder(sess, mkv)
    log_start = file_size(qs_log)
    # hyprland's own debug log (hypr/<sig>/hyprland.log) has no timestamps, so
    # every action records its byte offset and the slice is written with a
    # marker line at each action; that is how "who focused what" is answered
    hl_log = sess.hyprland_log()
    hl_start = file_size(hl_log) if hl_log else 0
    ev_mark = sess.events.mark()
    rec.start()
    t0 = rec.t0

    actions = []
    for step in plan:
        # waits send nothing and are not actions: a state or log line to wait
        # for (deterministic ordering instead of a fixed sleep), then settle
        if step.verb in ("wait", "wait_state", "wait_log", "eval", "probe"):
            if step.verb == "probe":
                # every tile thumb's capture state, logged under a tag
                # (WorkspaceTile tile-probe hook); not recorded as an action
                sess.custom_event("tile-probe:" + step.arg)
                ok = wait_until(lambda: ("tile probe %s " % step.arg) in
                                slice_file(qs_log, log_start, file_size(qs_log)), 2.0)
            elif step.verb == "eval":
                sess.log("eval %s: %s" % (step.arg[:60], sess.sock.request("eval " + step.arg).strip()[:60]))
                sess.custom_event("reload-curve")
                ok = True
            elif step.verb == "wait_state":
                ok = wait_until(lambda: sess.overview_state(qs_log) == step.arg, 4.0)
            elif step.verb == "wait_log":
                ok = wait_until(lambda: re.search(
                    step.arg, slice_file(qs_log, log_start, file_size(qs_log))) is not None, 4.0)
            else:
                ok = True
            if not ok:
                sess.log("%s %s timed out" % (step.verb, step.arg))
            if step.wait:
                time.sleep(step.wait / 1000.0)
            continue
        t = now_ms() - t0
        # the qs log as it stood right before this action fired: the state a
        # scenario checks "at" the moment just before, e.g. a mid-run
        # "overview still open" assertion ahead of the step that closes it
        qs_pre_offset = file_size(qs_log)
        arg = step.arg
        if step.verb == "toggle":
            reply = sess.custom_event("toggle")
        elif step.verb == "open":
            reply = sess.custom_event("open")
        elif step.verb == "close":
            reply = sess.custom_event("close")
        elif step.verb == "focus_ws":
            reply = sess.focus_ws(int(arg))
        elif step.verb == "event":
            payload = sess.resolve(str(arg))
            reply = sess.custom_event(payload)
            arg = payload
        elif step.verb == "carry":
            sym, _, direction = str(arg).partition(":")
            reply = sess.carry(sym, int(direction or 1))
            arg = "%s:%s" % (getattr(sess, "carried", sess.resolve(sym)), direction)
        else:
            raise RuntimeError("unknown verb " + step.verb)
        actions.append({"t_ms": t, "verb": step.verb,
                        "args": None if arg is None else str(arg),
                        "reply": reply[:40],
                        "hl_log_offset": file_size(hl_log) if hl_log else 0,
                        "qs_pre_offset": qs_pre_offset})
        if step.wait:
            time.sleep(step.wait / 1000.0)

    last_action_ms = actions[-1]["t_ms"] if actions else 0
    time.sleep(TAIL_MS / 1000.0)
    rec.stop()
    end_ms = now_ms() - t0
    log_end = file_size(qs_log)

    # post-state
    clients = sess.clients()
    active_ws = sess.active_workspace()
    try:
        active_win = sess.sock.j("activewindow")
    except Exception:
        active_win = {}
    # the monitor the exposé draws on, in logical px: analyze.py judges row
    # visibility against it rather than a fixed 1280
    try:
        mons = sess.sock.j("monitors")
    except Exception:
        mons = []
    mon = next((m for m in mons if m.get("name") == "WAYLAND-1"),
               next((m for m in mons if m.get("focused")), mons[0] if mons else {}))
    mon_scale = mon.get("scale") or 1
    monitor = {"name": mon.get("name"), "x": mon.get("x", 0), "y": mon.get("y", 0),
               "w": round(mon.get("width", 0) / mon_scale, 3),
               "h": round(mon.get("height", 0) / mon_scale, 3)} if mon else {}

    qs_slice = slice_file(qs_log, log_start, log_end)
    checks = post_checks(name, sess, clients, active_win, qs_log, qs_slice, actions)

    with open(os.path.join(out_dir, name + ".qs.log"), "w") as f:
        f.write(qs_slice)
    if hl_log:
        write_hl_slice(hl_log, hl_start, file_size(hl_log), actions,
                       os.path.join(out_dir, name + ".hl.log"))
    with open(os.path.join(out_dir, name + ".events.json"), "w") as f:
        json.dump([{"t_ms": t - t0, "name": n, "data": d}
                   for (t, n, d) in sess.events.since(ev_mark)], f, indent=1)

    doc = {
        "scenario": name,
        "seed": seed if name == "fuzz" else None,
        "t0_epoch_ms": t0,
        "t_stop_epoch_ms": rec.t_stop,
        "video": os.path.basename(mkv),
        "video_bytes": file_size(mkv),
        "actions": actions,
        "last_action_ms": last_action_ms,
        "end_ms": end_ms,
        "tail_ms": TAIL_MS,
        "expected_settle_ms": EXPECTED_SETTLE_MS.get(name, BASE_SETTLE_MS),
        "qs_log": {"start": log_start, "end": log_end, "slice": name + ".qs.log"},
        "addresses": dict(sess.addr),
        "final": {
            "active_workspace": active_ws,
            "active_window": active_win.get("address", ""),
            "monitor": monitor,
            "overview_state": sess.overview_state(qs_log),
            "clients": [{"address": c.get("address"), "class": c.get("class"),
                         "workspace": c.get("workspace", {}).get("id"),
                         "floating": c.get("floating"), "at": c.get("at"),
                         "size": c.get("size")} for c in clients],
        },
        "checks": checks,
    }
    with open(os.path.join(out_dir, name + ".actions.json"), "w") as f:
        json.dump(doc, f, indent=1)
    sess.log("scenario %s done (%d checks, %d failed)"
             % (name, len(checks), sum(1 for c in checks if not c["ok"])))
    return doc


def post_checks(name, sess, clients, active_win, qs_log, qs_slice="", actions=None):
    """Scenario-specific assertions against the post-run hyprland state."""
    checks = []

    def add(label, ok, detail=""):
        checks.append({"check": label, "ok": bool(ok), "detail": detail})

    st = sess.overview_state(qs_log)
    if name in ("toggle_spam", "toggle_spam_slow", "fuzz"):
        add("overview ends closed", st in (None, "closed"), "state=%s" % st)

    if name == "window_click_behind":
        f1 = sess.addr.get("@f1", "")
        ws1_floats = [c for c in clients
                      if c.get("workspace", {}).get("id") == 1 and c.get("floating")]
        top = ws1_floats[-1].get("address") if ws1_floats else ""
        add("f1 is stack top on ws1", top == f1, "top=%s f1=%s" % (top, f1))
        add("f1 is the active window", active_win.get("address") == f1,
            "active=%s" % active_win.get("address"))

    if name in ("drop_floating_position", "drop_edge_rejected", "drop_outside_rejected"):
        f3 = sess.addr.get("@f3", "")
        c3 = next((c for c in clients if c.get("address") == f3), {})
        ws = c3.get("workspace", {}).get("id")
        add("overview ends closed", st in (None, "closed"), "state=%s" % st)
        if name == "drop_floating_position":
            add("f3 moved to ws3", ws == 3, "ws=%s" % ws)
            mons = sess.sock.j("monitors")
            mon = next((m for m in mons if m.get("name") == "WAYLAND-1"),
                       next((m for m in mons if m.get("focused")), mons[0] if mons else {}))
            scale = mon.get("scale") or 1
            mw = mon.get("width", 0) / scale
            mh = mon.get("height", 0) / scale
            w, h = (c3.get("size") or [0, 0])[:2]
            ex = mon.get("x", 0) + (0.5 * mw - w / 2.0)
            ey = mon.get("y", 0) + (0.5 * mh - h / 2.0)
            at = c3.get("at") or [0, 0]
            add("f3 at the drop position within 2 px",
                abs(at[0] - ex) <= 2 and abs(at[1] - ey) <= 2,
                "at=%s want=%.1f,%.1f" % (at, ex, ey))
            add("drop accept logged", "drop accept ws=3 at " in qs_slice,
                "count=%d" % qs_slice.count("drop accept"))
        else:
            reason = "edge" if name == "drop_edge_rejected" else "outside"
            add("f3 stays on ws1", ws == 1, "ws=%s" % ws)
            add("drop reject reason=%s logged" % reason,
                ("drop reject reason=" + reason) in qs_slice,
                "rejects=%s" % re.findall(r"drop reject reason=(\S+)", qs_slice))
            add("no drop accepted", "drop accept" not in qs_slice)
            add("one drag return started", qs_slice.count("drag return dur=") == 1,
                "count=%d" % qs_slice.count("drag return dur="))
            landed = re.findall(r"drag return landed hold=(\d+) transform=(\S+)", qs_slice)
            add("one drag return landed, layer hold 0, no transform",
                len(landed) == 1 and landed[0] == ("0", "false"), "landed=%s" % landed)

    if name == "tile_live_after_move":
        probes = {}
        for m in re.finditer(r"tile probe (\S+) (\S+) ws=(\d+) leaving=(\w+) op=([\d.]+) "
                             r"vis=([\d.]+) src=(\w+) live=(\w+) content=(\w+) "
                             r"captures=(\d+) tileVisible=(\w+)", qs_slice):
            probes.setdefault(m.group(1), []).append({
                "addr": m.group(2), "ws": int(m.group(3)), "leaving": m.group(4) == "true",
                "op": float(m.group(5)), "vis": float(m.group(6)), "src": m.group(7) == "true",
                "live": m.group(8) == "true", "content": m.group(9) == "true",
                "captures": int(m.group(10))})

        def rows(tag, addr, ws):
            return [p for p in probes.get(tag, []) if p["addr"] == addr and p["ws"] == ws]

        for sym, src_ws, dst_ws, tags in (("@f3", 1, 3, ("d1", "d2", "d3", "d4")),
                                          ("@f2", 1, 2, ("k1", "k2", "k3", "k4"))):
            addr = sess.addr.get(sym, "").lower().replace("0x", "")
            ws_now = next((c.get("workspace", {}).get("id") for c in clients
                           if c.get("address", "").lower().replace("0x", "") == addr), None)
            add("%s ends on ws%d" % (sym, dst_ws), ws_now == dst_ws, "ws=%s" % ws_now)
            for i in (0, 2):
                first, second = tags[i], tags[i + 1]
                a = rows(first, addr, dst_ws)
                b = rows(second, addr, dst_ws)
                ok = (len(a) == 1 and len(b) == 1 and
                      all(not p["leaving"] and p["op"] == 1 and p["vis"] == 1 and
                          p["src"] and p["content"] for p in a + b))
                add("%s shown with content on ws%d tile at %s/%s" % (sym, dst_ws, first, second),
                    ok, "rows=%s" % (a + b))
                live = bool(a and b) and (all(p["live"] for p in a + b) or
                                          b[0]["captures"] > a[0]["captures"])
                add("%s capture keeps updating on ws%d tile at %s/%s" % (sym, dst_ws, first, second),
                    live, "")
                add("%s gone from ws%d tile at %s" % (sym, src_ws, second),
                    not rows(second, addr, src_ws), "rows=%s" % rows(second, addr, src_ws))

    if name == "move_window":
        f3 = sess.addr.get("@f3", "")
        ws = next((c.get("workspace", {}).get("id") for c in clients
                   if c.get("address") == f3), None)
        add("f3 moved to ws3", ws == 3, "ws=%s" % ws)

    if name in ("tile_click", "tile_click_left"):
        add("landed on ws2", sess.active_workspace() == 2,
            "active=%s" % sess.active_workspace())
        add("overview ends closed", st in (None, "closed"), "state=%s" % st)
        # the arriving rows must slide in: present, starting off to the side
        # the destination lies on (sign of the slide's arrive=), and attached
        # so they have a capture to draw during the close
        arrive = re.findall(r"tile arrive rows=(\d+) startOff=([-\d,]*)", qs_slice)
        signs = re.findall(r"\] \d+ slide \S+ arrive=(-?1) ", qs_slice)
        rows = int(arrive[-1][0]) if arrive else 0
        offs = [int(v) for v in arrive[-1][1].split(",") if v] if arrive else []
        want = (1 if name == "tile_click" else -1)
        sign = int(signs[-1]) if signs else 0
        add("arriving rows > 0", rows > 0, "arrive=%s" % (arrive[-1:] or None))
        add("arriving rows start off screen side", bool(offs) and
            all(o != 0 and (o > 0) == (sign > 0) for o in offs),
            "startOff=%s arrive=%s" % (offs, sign))
        add("arrive direction arrive=%d" % want, sign == want, "arrive=%s" % sign)
        # the arriving rows skip the flight: real rect, scale 1, from the first
        # frame of the slide, so only x moves (no rise, no growth)
        geoms = re.findall(r"tile arrive geom addr=(\S+) x=(-?\d+) y=(-?\d+) "
                           r"w=(\d+) h=(\d+) scale=(\S+) flight=(\d)", qs_slice)
        mons = sess.sock.j("monitors")
        mon = next((m for m in mons if m.get("name") == "WAYLAND-1"),
                   next((m for m in mons if m.get("focused")), mons[0] if mons else {}))
        by_addr = {str(c.get("address", "")).replace("0x", "", 1): c for c in clients}
        bad = []
        for addr, gx, gy, gw, gh, gs, fl in geoms[-rows:] if rows else []:
            c = by_addr.get(addr.replace("0x", "", 1), {})
            at = c.get("at") or [None, None]
            size = c.get("size") or [None, None]
            if at[1] is None:
                bad.append((addr, "no client"))
                continue
            ry = at[1] - mon.get("y", 0)
            if (abs(int(gy) - ry) > 1 or abs(int(gh) - size[1]) > 1
                    or fl != "0" or float(gs) != 1):
                bad.append((addr, "y=%s h=%s real y=%s h=%s scale=%s flight=%s"
                            % (gy, gh, ry, size[1], gs, fl)))
        add("arriving rows start at real y/h, scale 1, no flight",
            rows > 0 and len(geoms) >= rows and not bad,
            "geoms=%d rows=%d bad=%s" % (len(geoms), rows, bad[:3]))
        # and the last slide frame is the real window, pixel for pixel
        lands = re.findall(r"tile arrive land dx=(\S+) dy=(\S+) dw=(\S+) dh=(\S+) off=(\S+)",
                           qs_slice)
        off_px = [v for v in lands if any(abs(float(x)) > 0.001 for x in v)]
        add("arriving rows land pixel exact", len(lands) >= rows > 0 and not off_px,
            "lands=%d off=%s" % (len(lands), off_px[:3]))
        add("arriving thumbs attached during close",
            "tile switch close attach resumed" in qs_slice)
    if name == "tile_click_interrupt":
        # the second click arrives while the first click's close is running
        add("stays on ws2", sess.active_workspace() == 2,
            "active=%s" % sess.active_workspace())
        add("overview ends closed", st in (None, "closed"), "state=%s" % st)
    if name in ("tile_click", "tile_click_left", "tile_click_interrupt"):
        timeouts = qs_slice.count("switch timeout")
        add("no switch timeout", timeouts == 0, "count=%d" % timeouts)
    if name == "new_workspace":
        # the plus button only adds a virtual tile; it neither switches nor
        # closes the overview, so two clicks change nothing observable here
        add("overview ends closed", st in (None, "closed"), "state=%s" % st)
        add("active workspace unchanged (ws1)", sess.active_workspace() == 1,
            "active=%s" % sess.active_workspace())
        if actions:
            pre = actions[-1].get("qs_pre_offset")
            mid_st = sess.overview_state(qs_log, upto=pre) if pre is not None else None
            add("overview still open before final toggle", mid_st == "open",
                "state=%s" % mid_st)
    if name == "new_workspace_from_empty":
        # the first plus's virtual tile is the first fixture-empty id (ws4);
        # activating it makes it real. reopened on that now-active, still
        # empty workspace, a second plus must skip it and add virtual ws6,
        # which is discarded, unused, when the overview closes for good
        fixture_ids = set(ws for _, _, ws, _ in FIXTURE)
        target = next(i for i in range(1, 11) if i not in fixture_ids)
        add("overview ends closed", st in (None, "closed"), "state=%s" % st)
        add("landed on ws%d" % target, sess.active_workspace() == target,
            "active=%s" % sess.active_workspace())
        cleared = re.findall(r"virtual workspaces cleared \((\d+)\)", qs_slice)
        add("virtual workspace cleared, unused, on final close",
            bool(cleared) and cleared[-1] == "1", "cleared=%s" % cleared)
        timeouts = qs_slice.count("switch timeout")
        add("no switch timeout", timeouts == 0, "count=%d" % timeouts)
    if name == "empty_ws_carry_through":
        plus = empty_ws_plus_ids()
        fixture_ids = set(ws for _, _, ws, _ in FIXTURE)
        add("overview ends closed", st in (None, "closed"), "state=%s" % st)
        # walk the log in order: the tile ids as of each strip sync, sampled
        # at every open and at every sync until the matching closed
        marks = [(m.start(), "state", m.group(1))
                 for m in re.finditer(r"\[synopsis\] state \d+ (\w+)", qs_slice)]
        marks += [(m.start(), "sync", ([int(x) for x in m.group(1).split(",") if x],
                                       [int(x) for x in m.group(2).split(",") if x]))
                  for m in re.finditer(r"strip sync \S+ tiles=\d+ ids=([\d,-]*) removed=([\d,-]*) inserted=", qs_slice)]
        marks.sort(key=lambda x: x[0])
        sessions, cur, live = [], [], None
        for _, kind, data in marks:
            if kind == "state":
                if data == "open" and live is None:
                    live = {"samples": [list(cur)], "removed": []}
                    sessions.append(live)
                elif data in ("closing", "closed"):
                    # finishClose prunes before it logs closed: the close
                    # itself is where retained tiles are meant to go
                    live = None
            else:
                cur = data[0]
                if live is not None:
                    live["samples"].append(list(cur))
                    live["removed"] += data[1]
        add("two open sessions logged", len(sessions) >= 2, "sessions=%d" % len(sessions))
        removed = [r for s in sessions for r in s["removed"]]
        add("no tile removed while open", not removed, "removed=%s" % removed)
        drops = [(a, b) for s in sessions for a, b in zip(s["samples"], s["samples"][1:])
                 if len(b) < len(a) or [i for i in a if i not in b]]
        add("tile count never drops while open", not drops, "drops=%s" % drops[:2])
        unsorted = [x for s in sessions for x in s["samples"] if x != sorted(x)]
        add("tile order stable (ascending ids)", not unsorted, "bad=%s" % unsorted[:2])
        if sessions:
            a = sessions[0]["samples"]
            first = next((k for k, x in enumerate(a) if set(plus) <= set(x)), None)
            gone = [x for x in a[first:]] if first is not None else []
            gone = [x for x in gone if not set(plus) <= set(x)]
            add("plus tiles %s shown and kept until close" % plus,
                first is not None and not gone, "first=%s gone=%s last=%s" % (first, gone[:2], a[-1:]))
            add("no strip overflow (every tile visible)",
                not re.search(r"strip overflow on", qs_slice) and max(len(x) for x in a) <= 7,
                "max tiles=%d" % max(len(x) for x in a))
        if len(sessions) >= 2:
            b = sessions[1]["samples"]
            missing = [x for x in b if plus[0] not in x]
            add("pre-existing empty ws%d keeps its tile while open" % plus[0],
                not missing, "missing=%s" % missing[:2])
        # the window the carries really took: the bind carries whatever holds
        # focus, which is f2 unless the focus dispatch was refused
        f2 = next((str(x.get("args", "")).split(":")[0] for x in (actions or [])
                   if x.get("verb") == "carry"), sess.addr.get("@f2", ""))
        add("the carried window is f2", f2 == sess.addr.get("@f2", ""),
            "carried=%s f2=%s" % (f2, sess.addr.get("@f2", "")))
        f2n = f2[2:] if f2.startswith("0x") else f2
        path = list(range(2, max(plus) + 1)) + [1]
        no_thumb = [ws for ws in path
                    if not re.search(r"tile thumb created (0x)?%s ws=%d open=true" % (re.escape(f2n), ws), qs_slice)]
        add("carried f2 arrives live in every tile on its path", f2n and not no_thumb,
            "missing ws=%s" % no_thumb)
        c2 = next((c for c in clients if c.get("address") == f2), {})
        add("f2 back on ws1", c2.get("workspace", {}).get("id") == 1,
            "ws=%s" % c2.get("workspace", {}).get("id"))
        real = sorted(w.get("id") for w in sess.sock.j("workspaces") if w.get("id", 0) > 0)
        add("empty workspaces pruned after close", set(real) == fixture_ids, "real=%s" % real)
        last_closed = max((p for p, k, d in marks if k == "state" and d == "closed"), default=-1)
        after = [d[0] for p, k, d in marks if k == "sync" and p > last_closed]
        final_ids = after[-1] if after else cur
        add("strip tiles pruned to the real workspaces on close",
            set(final_ids) == fixture_ids, "ids=%s" % final_ids)
        cleared = re.findall(r"retained workspaces cleared \((\d+)\)", qs_slice)
        add("retained workspaces cleared on close", any(int(n) > 0 for n in cleared),
            "cleared=%s" % cleared)
    if name == "strip_scroll":
        add("overview ends closed", st in (None, "closed"), "state=%s" % st)
        add("active workspace unchanged (ws1)", sess.active_workspace() == 1,
            "active=%s" % sess.active_workspace())
        if actions and len(actions) > 13:
            pre = actions[13].get("qs_pre_offset")
            mid_st = sess.overview_state(qs_log, upto=pre) if pre is not None else None
            add("overview still open before close toggle", mid_st == "open",
                "state=%s" % mid_st)
        ov = [(m.start(), m.group(1), int(m.group(2)), m.group(3), m.group(4))
              for m in re.finditer(r"strip overflow (on|off) \S+ tiles=(\d+) w=([\d.]+) h=([\d.]+)", qs_slice)]
        on = [o for o in ov if o[1] == "on"]
        off = [o for o in ov if o[1] == "off"]
        add("overflow on at 8+ tiles", bool(on) and on[0][2] >= 8,
            "on=%s" % [o[2] for o in on])
        add("overflow off after on", bool(on) and bool(off) and off[-1][0] > on[0][0],
            "off=%s" % [o[2] for o in off])
        # every plus click from overflow on reveals its new last tile at the
        # right end: the right fade never shows on the way (it used to ease
        # in for the ~60 ms reveal scroll, gated on while the row had grown
        # and the scroll had no target yet)
        if on:
            close = re.search(r"\] state \d+ closing", qs_slice[on[0][0]:])
            seg = qs_slice[on[0][0]:on[0][0] + close.start()] if close else qs_slice[on[0][0]:]
            right_on = len(re.findall(r"strip fade right on", seg))
            shown = [float(v) for v in re.findall(r"strip cx=\S+ layer=\d fadeR=([\d.]+)", seg)]
            add("plus clicks at the right end show no right fade",
                right_on == 0 and bool(shown) and max(shown) == 0.0,
                "fade right on=%d, max fadeR=%s over %d cx frames"
                % (right_on, max(shown) if shown else None, len(shown)))
        cleared = re.findall(r"virtual workspaces cleared \((\d+)\)", qs_slice)
        add("virtual workspaces cleared (12) on close", "12" in cleared,
            "cleared=%s" % cleared)
        tile = [(m.start(), m.group(1), m.group(2), int(m.group(3)))
                for m in re.finditer(r"strip tile w=([\d.]+) h=([\d.]+) tiles=(\d+)", qs_slice)]
        last_off = off[-1][0] if off else -1
        reopen = [t for t in tile if t[0] > last_off]
        add("reopen logs tiles, no overflow after the last off",
            bool(reopen) and not any(o[0] > last_off for o in on),
            "reopen tiles=%s" % [t[3] for t in reopen])
        sizes = set((t[1], t[2]) for t in tile) | set((o[3], o[4]) for o in ov)
        counts = [t[3] for t in tile]
        add("tile size identical at few and 13+ tiles",
            len(sizes) == 1 and bool(counts) and min(counts) <= 4 and max(counts) >= 13,
            "sizes=%s counts=%s" % (sorted(sizes), counts))
        button = [m.groupdict() for m in re.finditer(
            r"strip overflow (?P<state>on|off) \S+ tiles=(?P<tiles>\d+) "
            r"viewport=(?P<viewport>[\d.]+) button=(?P<button>[\d.]+) "
            r"size=(?P<size>[\d.]+) area=(?P<area>[\d.]+) gap=(?P<gap>[\d.]+)", qs_slice)]
        # fitting ("off"): the viewport is the full area, the button trails
        # the centred row, so only its own bound against the area matters.
        # overflowing ("on"): the viewport is narrowed to leave room for it
        def button_fits(b):
            fits = float(b["button"]) + float(b["size"]) <= float(b["area"]) + 0.5
            if b["state"] == "on":
                fits = fits and float(b["viewport"]) + float(b["gap"]) + float(b["size"]) <= float(b["area"]) + 0.5
            return fits
        button_ok = all(button_fits(b) for b in button)
        add("button stays inside the strip area on every overflow toggle",
            bool(button) and button_ok,
            "button=%s" % [(b["state"], b["tiles"], b["viewport"], b["button"]) for b in button])
    if name == "strip_autoscroll":
        add("overview ends closed", st in (None, "closed"), "state=%s" % st)
        add("back on ws1", sess.active_workspace() == 1, "active=%s" % sess.active_workspace())
        num = r"(-?[\d.]+)"

        # qs_pre_offset is a byte offset into the whole qs log; qs_slice starts
        # where this scenario began, found by its own opening bytes
        try:
            with open(qs_log, "rb") as f:
                slice_start = f.read().find(qs_slice[:4096].encode(errors="replace"))
        except OSError:
            slice_start = -1

        def at_action(i):
            if slice_start >= 0 and actions and len(actions) > i and actions[i].get("qs_pre_offset") is not None:
                return max(0, min(len(qs_slice), actions[i]["qs_pre_offset"] - slice_start))
            return len(qs_slice)
        # the three original switches end at action 16; (a) (b) (c) follow
        base = qs_slice[:at_action(16)]
        starts = [(m.start(), int(m.group(1)), float(m.group(2)), float(m.group(3)),
                   float(m.group(4)), float(m.group(5)), m.group(6) == "1")
                  for m in re.finditer(r"strip move start id=(\d+) ms=\d+ hx=%s->%s cx=%s->%s scroll=(\d)"
                                       % (num, num, num, num), base)]
        frames = [(m.start(), float(m.group(1)), float(m.group(2)), float(m.group(3)))
                  for m in re.finditer(r"strip move t=%s hx=%s cx=%s scroll=1" % (num, num, num), base)]
        ends = [(m.start(), int(m.group(1)), m.group(2) == "1")
                for m in re.finditer(r"strip move end id=(\d+) .* visible=(\d)", base)]
        fades = [(m.start(), m.group(1), m.group(2) == "on")
                 for m in re.finditer(r"strip fade (left|right) (on|off)", base)]
        scrolls = [s for s in starts if s[6]]
        add("switches to ws2, ws16 and ws1 each scroll on the highlight move",
            all(any(s[1] == i for s in scrolls) for i in (2, 16, 1)),
            "scroll moves=%s" % [s[1] for s in scrolls])
        # each scrolling move: highlight and contentX at the same eased fraction
        # on every frame (one clock), no jump between frames, both land together
        worst_sync, worst_step, landed = 0.0, 0.0, True
        for k, s in enumerate(starts):
            if not s[6]:
                continue
            nxt = starts[k + 1][0] if k + 1 < len(starts) else len(base)
            # a retarget re-solves the move's from values: its frames after
            # that no longer follow this start line
            nxt = min([nxt] + [mm.start() for mm in re.finditer(r"strip move retarget", base)
                               if s[0] < mm.start() < nxt])
            fr = [f for f in frames if s[0] < f[0] < nxt]
            dh, dc = s[3] - s[2], s[5] - s[4]
            if not fr or abs(dh) < 1 or abs(dc) < 1:
                continue
            prev = 0.0
            for f in fr:
                ph, pc = (f[2] - s[2]) / dh, (f[3] - s[4]) / dc
                worst_sync = max(worst_sync, abs(ph - pc))
                worst_step = max(worst_step, abs(pc - prev))
                prev = pc
            if fr[-1][1] >= 1.0:
                landed = landed and abs(fr[-1][2] - s[3]) < 0.5 and abs(fr[-1][3] - s[5]) < 0.5
        add("highlight x and contentX move in lock step (same eased fraction per frame)",
            bool(scrolls) and worst_sync < 0.01, "worst fraction gap=%.4f" % worst_sync)
        add("no jump in a scrolling move (per-frame fraction step < 0.25)",
            bool(scrolls) and worst_step < 0.25, "worst step=%.3f" % worst_step)
        add("highlight and contentX settle together on their targets", landed)
        last_end = {}
        for e in ends:
            last_end[e[1]] = e
        add("tiles of ws2, ws16 and ws1 fully visible after their switches",
            all(i in last_end and last_end[i][2] for i in (2, 16, 1)),
            "visible=%s" % {i: last_end[i][2] for i in last_end})

        def fade_state(side, upto):
            st_ = [f[2] for f in fades if f[1] == side and f[0] < upto]
            return st_[-1] if st_ else False
        e16 = last_end.get(16)
        after16 = next((s[0] for s in starts if e16 and s[0] > e16[0]), len(base))
        add("right fade off at the right end (after ws16), left fade on",
            bool(e16) and not fade_state("right", after16) and fade_state("left", after16),
            "right=%s left=%s" % (fade_state("right", after16), fade_state("left", after16)))
        e1 = last_end.get(1)
        close_at = base.find("strip tile", e1[0]) if e1 else -1
        close_at = close_at if close_at >= 0 else len(base)
        add("left fade off at the start (after ws1), right fade on",
            bool(e1) and not fade_state("left", close_at) and fade_state("right", close_at),
            "left=%s right=%s" % (fade_state("left", close_at), fade_state("right", close_at)))

        # (c) ws3 emptied under the scrolling move to ws12 (actions 16-17).
        # hyprland destroys ws3, but a workspace shown while the overview is
        # open keeps its tile until the close (Overview.retainedWorkspaces):
        # the row must not shift, so the move needs no retarget
        part = qs_slice[at_action(16):at_action(18)]
        removed3 = [m for m in re.findall(r"strip sync \S+ tiles=\d+ ids=\S* removed=([\d,]*)", part)
                    if "3" in m.split(",")]
        retarget = re.search(r"strip move retarget id=12 ", part)
        add("(c) ws3 emptied mid-move keeps its tile, the move is not retargeted",
            not removed3 and retarget is None,
            "removed=%s retarget=%s" % (removed3, retarget is not None))
        c_end = re.findall(r"strip move end id=12 .*tile=%s\.\.%s view=%s\.\.%s visible=(\d) pad=%s"
                           % (num, num, num, num, num), part)
        c_ok = bool(c_end) and c_end[-1][4] == "1" and \
            abs((float(c_end[-1][3]) - float(c_end[-1][1])) - float(c_end[-1][5])) <= 1.5
        add("(c) ws12 ends in view, clear of the right fade by exactly revealPad", c_ok,
            "end=%s" % (c_end[-1:],))

        def cx_steps(seg, start_cx):
            cxs = [float(v) for v in re.findall(r"strip cx=(-?[\d.]+)", seg)]
            prev = [start_cx] + cxs
            return cxs, max([abs(v - p) for p, v in zip(prev, cxs)] or [0.0])

        # (a) a touchpad swipe mid-move (action 19)
        part = qs_slice[at_action(19):at_action(20)]
        m = re.search(r"strip scroll pixel d=%s cx=%s->%s to=%s took=(\d)" % (num, num, num, num), part)
        add("(a) swipe mid-move takes the scroll from the view, no jump (|dcx| <= 3.5)",
            m is not None and m.group(5) == "1" and abs(float(m.group(3)) - float(m.group(2))) <= 3.5,
            "line=%s" % (m.group(0) if m else None))
        after = part[m.end():] if m else ""
        stale = len(re.findall(r"strip move t=\S+ hx=\S+ cx=\S+ scroll=1", after))
        _, worst = cx_steps(after, float(m.group(3)) if m else 0.0)
        add("(a) after the swipe no move writes contentX (no scroll frame, cx still)",
            m is not None and stale == 0 and worst <= 0.5, "scroll frames=%d max step=%.2f" % (stale, worst))
        add("(a) the highlight still finishes its move to ws2",
            re.search(r"strip move end id=2 ", after) is not None)

        # (a) a wheel notch mid-move (action 21)
        part = qs_slice[at_action(21):at_action(22)]
        m = re.search(r"strip scroll angle d=%s cx=%s->%s to=%s took=(\d)" % (num, num, num, num), part)
        tile_w = re.findall(r"strip tile w=([\d.]+)", qs_slice)
        notch = float(tile_w[0]) * 1.5 + 1 if tile_w else 1e9
        a_ok = m is not None and m.group(5) == "1" and abs(float(m.group(3)) - float(m.group(2))) <= 0.5
        a_ok = a_ok and float(m.group(4)) <= float(m.group(2)) + 0.5 and float(m.group(2)) - float(m.group(4)) <= notch
        add("(a) wheel notch mid-move steps one tile from the view, not from the move's target", a_ok,
            "line=%s" % (m.group(0) if m else None))
        after = part[m.end():] if m else ""
        stale = len(re.findall(r"strip move t=\S+ hx=\S+ cx=\S+ scroll=1", after))
        cxs, worst = cx_steps(after, float(m.group(2)) if m else 0.0)
        span = abs(float(m.group(2)) - float(m.group(4))) if m else 0.0
        add("(a) after the notch only its own glide moves contentX, no jump, lands on target",
            m is not None and stale == 0 and worst <= max(1.0, 0.6 * span)
            and (not cxs or abs(cxs[-1] - float(m.group(4))) <= 0.5),
            "scroll frames=%d max step=%.2f span=%.1f" % (stale, worst, span))
        add("(a) the highlight still finishes its move to ws1",
            re.search(r"strip move end id=1 ", after) is not None)

        # (b) Escape mid-move to ws14 (action 23), reopen (action 24)
        states = [(mm.start(), mm.group(1)) for mm in re.finditer(r"\[synopsis\] state \d+ (\w+)", qs_slice)]
        closing = next((p for p, s_ in states if p >= at_action(23) and s_ == "closing"), None)
        closed = next((p for p, s_ in states if closing is not None and p > closing and s_ == "closed"), None)
        lead = qs_slice[at_action(22):closing if closing is not None else at_action(23)]
        mid = re.search(r"strip move start id=14 ms=\d+ hx=\S+ cx=\S+ scroll=1", lead)
        add("(b) Escape lands during the scrolling move to ws14",
            closing is not None and mid is not None and "strip move end id=14 " not in lead[mid.end():])
        seg = qs_slice[closing:at_action(25)] if closing is not None else ""
        add("(b) no scrolling move frame after closing",
            closing is not None and not re.search(r"strip move t=\S+ hx=\S+ cx=\S+ scroll=1", seg))
        seg = qs_slice[closed:at_action(24)] if closed is not None else ""
        add("(b) closed before the reopen, no move frame after closed",
            closed is not None and "strip move t=" not in seg)
        op = re.search(r"strip open id=(\d+) cx=\S+ view=\S+ visible=(\d) moving=(\d)",
                       qs_slice[at_action(24):at_action(25)])
        add("(b) reopen at rest with the active tile in view",
            op is not None and op.group(2) == "1" and op.group(3) == "0",
            "line=%s" % (op.group(0) if op else None))
    if name == "keybind_switch":
        add("back on ws1", sess.active_workspace() == 1)
    if name == "rapid_switch":
        add("ends on ws3", sess.active_workspace() == 3)
        add("overview ends closed", st in (None, "closed"), "state=%s" % st)
    if name == "spam_switch_light":
        add("ends on ws2", sess.active_workspace() == 2)
        add("overview ends closed", st in (None, "closed"), "state=%s" % st)
    if name in ("spam_switch_heavy", "spam_switch_heavy_bezier"):
        add("ends on ws3", sess.active_workspace() == 3)
        add("overview ends closed", st in (None, "closed"), "state=%s" % st)
    if name == "spam_toggle_keys":
        add("ends on ws3", sess.active_workspace() == 3)
        add("overview ends closed", st in (None, "closed"), "state=%s" % st)
    if name == "spam_click":
        add("ends on ws2", sess.active_workspace() == 2)
        add("overview ends closed", st in (None, "closed"), "state=%s" % st)
    if name in ("toggle_spam", "toggle_spam_slow"):
        add("ends on ws1", sess.active_workspace() == 1)
    if name == "keybind_close_switch":
        # closing the overview must not bounce the session back to ws1
        add("stays on ws3", sess.active_workspace() == 3)
        add("overview ends closed", st in (None, "closed"), "state=%s" % st)
    if name == "switch_while_preparing":
        # the switches arrived while the overview was still preparing
        add("ends on ws5", sess.active_workspace() == 5)
        add("overview ends closed", st in (None, "closed"), "state=%s" % st)
    if name == "keybind_enter":
        # Enter confirms the workspace currently shown, like clicking its tile
        add("stays on ws3", sess.active_workspace() == 3)
        add("overview ends closed", st in (None, "closed"), "state=%s" % st)
    return checks


# --------------------------------------------------------------------------
# env / safety
# --------------------------------------------------------------------------

def load_env_file(path):
    env = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            env[k] = v.strip().strip('"')
    return env


def safety_check(env):
    sig = env.get("HYPRLAND_INSTANCE_SIGNATURE", "")
    live = os.environ.get("SIM_LIVE_SIGNATURE") or os.environ.get("HYPRLAND_INSTANCE_SIGNATURE", "")
    if not sig:
        raise SystemExit("refusing to run: nested HYPRLAND_INSTANCE_SIGNATURE is empty")
    if live and sig == live:
        raise SystemExit("refusing to run: nested signature equals the LIVE session (%s)" % sig)
    wl = env.get("WAYLAND_DISPLAY", "")
    live_wl = os.environ.get("SIM_LIVE_WAYLAND_DISPLAY") or os.environ.get("WAYLAND_DISPLAY", "")
    if wl and live_wl and wl == live_wl:
        raise SystemExit("refusing to run: nested WAYLAND_DISPLAY equals the live one (%s)" % wl)


# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------

def dry_run(names, seed):
    for name in names:
        plan = build_plan(name, seed)
        total = sum(s.wait for s in plan) + TAIL_MS
        print("\n=== %s  (%d steps, ~%d ms + %d ms tail, budget %d ms) ==="
              % (name, len(plan), total - TAIL_MS, TAIL_MS, EXPECTED_SETTLE_MS.get(name, BASE_SETTLE_MS)))
        t = 0
        for s in plan:
            print("  t=%5d ms  %s" % (t, s.describe()))
            t += s.wait
        print("  t=%5d ms  stop recorder" % (t + TAIL_MS))
    print("\nfixture: " + ", ".join("%s=%s" % (s, k) for s, k, _, _ in FIXTURE))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description="synopsis simulator scenario driver")
    ap.add_argument("--scenario", default="all", help="scenario name or 'all'")
    ap.add_argument("--out", default=None, help="output directory")
    ap.add_argument("--env", default=None, help="env file written by run.sh (default <out>/env)")
    ap.add_argument("--seed", type=int, default=0, help="seed for the fuzz scenario")
    ap.add_argument("--dry-run", action="store_true", help="print the plan, touch nothing")
    ap.add_argument("--no-fixture", action="store_true", help="assume the fixture windows already exist")
    ap.add_argument("--keep-fixture", action="store_true", help="leave fixture windows running on exit")
    args = ap.parse_args(argv)

    if args.scenario == "all":
        names = SCENARIO_ORDER
    else:
        names = []
        for part in args.scenario.split(","):
            names += SCENARIO_GROUPS.get(part, [part])
    for n in names:
        if n not in SCENARIOS:
            raise SystemExit("unknown scenario: %s (have: %s)" % (n, ", ".join(SCENARIO_ORDER)))

    if args.dry_run:
        return dry_run(names, args.seed)

    if not args.out:
        raise SystemExit("--out is required unless --dry-run")
    out = os.path.abspath(args.out)
    os.makedirs(out, exist_ok=True)
    env = load_env_file(args.env or os.path.join(out, "env"))
    safety_check(env)

    qs_log = env.get("QS_LOG", os.path.join(out, "qs.log"))
    sess = Session(env, out)
    sess.connect()

    if not sess.sock.alive():
        raise SystemExit("nested hyprland request socket is not answering: %s" % sess.sock.path)

    rc = 0
    try:
        if args.no_fixture:
            for c in sess.clients():
                for sym, klass, _ws, _k in FIXTURE:
                    if c.get("class") == klass:
                        sess.addr[sym] = c.get("address")
            sess.record_home()
        else:
            sess.build_fixture()
        docs = []
        for name in names:
            docs.append(run_scenario(sess, name, out, qs_log, args.seed))
        failed = [c for d in docs for c in d["checks"] if not c["ok"]]
        rc = 1 if failed else 0
        for c in failed:
            print("[driver] FAIL %s: %s" % (c["check"], c["detail"]), flush=True)
    finally:
        if not args.keep_fixture:
            sess.kill_fixture()
        if sess.events:
            sess.events.stop()
    return rc


if __name__ == "__main__":
    sys.exit(main())
