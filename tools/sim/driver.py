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
    # are 30, 30, 240, 30, 570. The two sub-40 ms gaps (30 ms, at the 2nd and
    # 5th toggles) are exactly the pairs a coalescing debounce (Track 2,
    # inputCoalesceMs=40) would drop, whether it rebaselines on the last
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


def plan_tile_click_interrupt():
    return [S("toggle", wait=700), S("event", "activate-workspace:2", 150),
            S("event", "activate-workspace:3", 1500)]


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
    "tile_click_interrupt": plan_tile_click_interrupt,
    "window_click_behind": plan_window_click_behind,
    "toggle_spam": plan_toggle_spam,
    "toggle_spam_slow": plan_toggle_spam_slow,
    "keybind_close_switch": plan_keybind_close_switch,
    "switch_while_preparing": plan_switch_while_preparing,
    "switch_then_close_midslide": plan_switch_then_close_midslide,
    "move_window": plan_move_window,
    "keybind_enter": plan_keybind_enter,
    "fuzz": plan_fuzz,
}

SCENARIO_ORDER = [
    "open_close", "keybind_switch", "keybind_interrupt", "rapid_switch",
    "spam_switch_light", "spam_switch_heavy", "spam_toggle_keys", "spam_click",
    "tile_click", "tile_click_interrupt", "window_click_behind", "toggle_spam",
    "toggle_spam_slow", "keybind_close_switch", "switch_while_preparing",
    "switch_then_close_midslide", "move_window", "keybind_enter", "fuzz",
]

# expected settle budget per scenario, in ms after the last action:
#   switchMs 450 + settleMs 60 + flightMs 260 + 150 slack  (shell/Core/Config.qml)
BASE_SETTLE_MS = 450 + 60 + 260 + 150
EXPECTED_SETTLE_MS = {name: BASE_SETTLE_MS for name in SCENARIOS}
EXPECTED_SETTLE_MS["toggle_spam"] = BASE_SETTLE_MS + 300
EXPECTED_SETTLE_MS["toggle_spam_slow"] = BASE_SETTLE_MS + 300
EXPECTED_SETTLE_MS["fuzz"] = BASE_SETTLE_MS + 300
EXPECTED_SETTLE_MS["switch_while_preparing"] = BASE_SETTLE_MS + 300
EXPECTED_SETTLE_MS["spam_switch_heavy"] = BASE_SETTLE_MS + 600


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

    def overview_state(self, qs_log):
        """Last '[synopsis] state <ms> <name>' seen in the qs log."""
        try:
            with open(qs_log, "rb") as f:
                try:
                    f.seek(-65536, os.SEEK_END)
                except OSError:
                    f.seek(0)
                tail = f.read().decode(errors="replace")
        except OSError:
            return None
        hits = re.findall(r"\[synopsis\] state (\d+) (\w+)", tail)
        return hits[-1][1] if hits else None


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
        t = now_ms() - t0
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
        else:
            raise RuntimeError("unknown verb " + step.verb)
        actions.append({"t_ms": t, "verb": step.verb,
                        "args": None if arg is None else str(arg),
                        "reply": reply[:40],
                        "hl_log_offset": file_size(hl_log) if hl_log else 0})
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

    checks = post_checks(name, sess, clients, active_win, qs_log)

    qs_slice = slice_file(qs_log, log_start, log_end)
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


def post_checks(name, sess, clients, active_win, qs_log):
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

    if name == "move_window":
        f3 = sess.addr.get("@f3", "")
        ws = next((c.get("workspace", {}).get("id") for c in clients
                   if c.get("address") == f3), None)
        add("f3 moved to ws3", ws == 3, "ws=%s" % ws)

    if name == "tile_click":
        add("landed on ws2", sess.active_workspace() == 2)
    if name == "tile_click_interrupt":
        add("landed on ws3", sess.active_workspace() == 3)
    if name == "keybind_switch":
        add("back on ws1", sess.active_workspace() == 1)
    if name == "rapid_switch":
        add("ends on ws3", sess.active_workspace() == 3)
        add("overview ends closed", st in (None, "closed"), "state=%s" % st)
    if name == "spam_switch_light":
        add("ends on ws2", sess.active_workspace() == 2)
        add("overview ends closed", st in (None, "closed"), "state=%s" % st)
    if name == "spam_switch_heavy":
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

    names = SCENARIO_ORDER if args.scenario == "all" else [args.scenario]
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
