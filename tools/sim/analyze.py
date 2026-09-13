#!/usr/bin/env python3
"""Analyze the recordings the synopsis simulator produced.

Input:  a run directory containing, per scenario,
          <name>.mkv            the recording (VFR: wf-recorder only writes
                                damaged frames, so a still screen writes none)
          <name>.actions.json   actions with ms offsets from recorder start
          <name>.qs.log         the quickshell log slice for that scenario
Output: <out>/report.md, <out>/report.json and <out>/frames/*.png for every
        flagged event (the flagged frame plus its neighbours, full resolution)

numpy is used when present; otherwise the same metrics are computed in pure
python on a further-subsampled grid.

Usage:
    analyze.py --out tools/sim/out/<timestamp>
    analyze.py --self-test [--keep]     # synthesise videos, prove detectors fire
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

try:
    import numpy as np
except ImportError:                                    # pragma: no cover
    np = None


# --------------------------------------------------------------------------
# thresholds (all diffs are mean absolute luma difference, 0..255, on the
# 320-wide grayscale decode of the recording)
# --------------------------------------------------------------------------

THRESHOLDS = {
    # a frame is "quiet" (nothing moving) below this mean diff. Terminal
    # patterns tick at 10 Hz, so a settled screen is not perfectly zero.
    "T_quiet": 1.2,
    # number of consecutive quiet frames that count as settled
    "QUIET_RUN": 8,
    # a spike this large is a candidate flash (white/black frame, thumbnail
    # popping to a placeholder, a layer appearing for one frame)
    "T_flash": 18.0,
    # ... and it only counts as a flash if the screen reverts: the frame after
    # the spike differs from the frame before it by less than this
    "T_flash_revert": 6.0,
    # longest run of frames that still counts as one flash rather than a change
    "FLASH_MAX_FRAMES": 3,
    # a diff this large is a hard cut (the whole screen changed at once)
    "T_cut": 30.0,
    # a cut is explained if an action happened in
    # [t - CUT_ACTION_PRE_MS, t + CUT_ACTION_LAG_MS]. The spec's 30 ms is the
    # pre-window; the lag allows for the compositor/shell reacting to the
    # dispatch a frame or two later.
    "CUT_ACTION_PRE_MS": 30.0,
    "CUT_ACTION_LAG_MS": 120.0,
    # animation windows, from shell/Core/Config.qml. While a flight or a slide
    # is running the whole screen is meant to change, so a big diff there is
    # not a cut; only a spike against its own neighbourhood is flagged.
    "FLIGHT_MS": 260.0,
    "SWITCH_MS": 450.0,
    "SETTLE_MS": 60.0,
    "WINDOW_SLACK_MS": 100.0,
    "ACTION_WINDOW_MS": 150.0,
    "T_SPIKE": 25.0,
    "SPIKE_RATIO": 2.5,
    "SPIKE_HALF": 4,
    # frame cadence inside a flight: a gap over T_FLIGHT_GAP_MS is listed,
    # a flight whose worst gap is over T_FLIGHT_STALL_MS counts as a stall
    "T_FLIGHT_GAP_MS": 50.0,
    "T_FLIGHT_STALL_MS": 80.0,
    # no frame written for this long while an animation should be running
    # means the shell stopped painting mid-flight
    "T_STALE_MS": 250.0,
    # settle budget fallback when the actions file has none:
    # switchMs 450 + settleMs 60 + flightMs 260 + 150 slack
    "SETTLE_BUDGET_MS": 920.0,
    # a frame is black when its mean luminance is no more than this above the
    # recording's black level. Hyprland's screencopy paints a solid black
    # rectangle over a layer whose rule says no_screen_share, so a capture of
    # the overview taken that way is one flat value: 0 in a full-range video,
    # 16 in the limited range wf-recorder writes by default.
    "T_black": 8.0,
    # decode width; height follows the source aspect
    "GRID_W": 320,
    # pure-python fallback subsampling stride (every Nth pixel)
    "PY_STRIDE": 4,
}


# --------------------------------------------------------------------------
# ffmpeg helpers
# --------------------------------------------------------------------------

def run(argv, **kw):
    return subprocess.run(argv, check=False, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, **kw)


def probe_pts(path):
    """Presentation time (seconds) of every video frame, in decode order."""
    r = run(["ffprobe", "-v", "error", "-select_streams", "v:0",
             "-show_entries", "frame=best_effort_timestamp_time,pts_time",
             "-of", "csv=p=0", path])
    out = []
    for line in r.stdout.decode().splitlines():
        for tok in line.split(","):
            tok = tok.strip()
            if not tok or tok == "N/A":
                continue
            try:
                out.append(float(tok))
            except ValueError:
                pass
            break
    return out


def decode_gray(path, width):
    """Decode the whole file to raw gray at `width` px wide. Returns bytes."""
    r = run(["ffmpeg", "-v", "error", "-i", path,
             "-vf", "scale=%d:-2,format=gray" % width,
             "-fps_mode", "passthrough", "-f", "rawvideo", "-"])
    if r.returncode != 0 and not r.stdout:
        # older ffmpeg: -fps_mode does not exist, use -vsync 0
        r = run(["ffmpeg", "-v", "error", "-i", path,
                 "-vf", "scale=%d:-2,format=gray" % width,
                 "-vsync", "0", "-f", "rawvideo", "-"])
    return r.stdout


def extract_png(video, index, dest):
    r = run(["ffmpeg", "-v", "error", "-y", "-i", video,
             "-vf", "select=eq(n\\,%d)" % index, "-fps_mode", "passthrough",
             "-frames:v", "1", dest])
    if not os.path.exists(dest):
        run(["ffmpeg", "-v", "error", "-y", "-i", video,
             "-vf", "select=eq(n\\,%d)" % index, "-vsync", "0",
             "-frames:v", "1", dest])
    return os.path.exists(dest)


def extract_png_scaled(video, index, dest, width=426, height=240):
    """Like extract_png but downscaled, for contact-sheet tiles."""
    vf = "select=eq(n\\,%d),scale=%d:%d" % (index, width, height)
    r = run(["ffmpeg", "-v", "error", "-y", "-i", video,
             "-vf", vf, "-fps_mode", "passthrough", "-frames:v", "1", dest])
    if not os.path.exists(dest):
        run(["ffmpeg", "-v", "error", "-y", "-i", video,
             "-vf", vf, "-vsync", "0", "-frames:v", "1", dest])
    return os.path.exists(dest)


def extract_all_frames(video, dest_dir, width=640):
    """Every decoded frame, downscaled, for manual scrubbing of a recording."""
    os.makedirs(dest_dir, exist_ok=True)
    pattern = os.path.join(dest_dir, "%05d.png")
    vf = "scale=%d:-2" % width
    r = run(["ffmpeg", "-v", "error", "-y", "-i", video,
             "-vf", vf, "-fps_mode", "passthrough", pattern])
    if r.returncode != 0:
        run(["ffmpeg", "-v", "error", "-y", "-i", video,
             "-vf", vf, "-vsync", "0", pattern])
    return sorted(os.listdir(dest_dir))


# --------------------------------------------------------------------------
# frame metrics
# --------------------------------------------------------------------------

class Frames:
    """Decoded frames plus the per-frame diff series."""

    def __init__(self, path):
        self.path = path
        self.pts = probe_pts(path)
        raw = decode_gray(path, THRESHOLDS["GRID_W"])
        self.n = len(self.pts)
        self.w = THRESHOLDS["GRID_W"]
        self.h = 0
        self.ok = False
        if self.n and raw:
            fsize = len(raw) // self.n
            if fsize:
                self.h = fsize // self.w
                self.ok = self.h > 0
        self.raw = raw
        self.arr = None
        self._black_level = None
        self.d = []              # d[i] = mean|f[i]-f[i-1]|, d[0] = 0
        if self.ok:
            self._diffs()

    def _frame(self, i):
        fsize = self.w * self.h
        return self.raw[i * fsize:(i + 1) * fsize]

    def _diffs(self):
        fsize = self.w * self.h
        if np is not None:
            arr = np.frombuffer(self.raw[:fsize * self.n], dtype=np.uint8)
            arr = arr.reshape(self.n, self.h, self.w).astype(np.int16)
            self.arr = arr
            self.d = [0.0] + [float(np.abs(arr[i] - arr[i - 1]).mean())
                              for i in range(1, self.n)]
        else:
            stride = THRESHOLDS["PY_STRIDE"]
            self.arr = None
            prev = None
            self.d = []
            for i in range(self.n):
                cur = self._frame(i)[::stride]
                if prev is None:
                    self.d.append(0.0)
                else:
                    tot = 0
                    for a, b in zip(cur, prev):
                        tot += a - b if a > b else b - a
                    self.d.append(tot / float(len(cur) or 1))
                prev = cur

    def diff(self, i, j):
        """Mean absolute difference between two arbitrary frames."""
        if np is not None:
            return float(np.abs(self.arr[i] - self.arr[j]).mean())
        stride = THRESHOLDS["PY_STRIDE"]
        a, b = self._frame(i)[::stride], self._frame(j)[::stride]
        tot = sum((x - y) if x > y else (y - x) for x, y in zip(a, b))
        return tot / float(len(a) or 1)

    def mean(self, i):
        """Mean luminance (0..255) of frame i."""
        if np is not None and self.arr is not None:
            return float(self.arr[i].mean())
        buf = self._frame(i)[::THRESHOLDS["PY_STRIDE"]]
        return sum(buf) / float(len(buf) or 1)

    def black_level(self):
        """What "black" decodes to here: 0 for a full-range recording, 16 for
        the limited range wf-recorder writes by default. Taken as the darkest
        pixel in the whole file, never counted above the limited-range floor
        so a recording that happens to contain nothing truly black cannot
        raise the bar."""
        if self._black_level is None:
            if np is not None and self.arr is not None:
                level = float(self.arr.min())
            else:
                stride = THRESHOLDS["PY_STRIDE"]
                level = min((min(self._frame(i)[::stride] or [0])
                             for i in range(self.n)), default=0)
            self._black_level = min(float(level), 16.0)
        return self._black_level

    def t_ms(self, i):
        return self.pts[i] * 1000.0 if i < len(self.pts) else 0.0


def find_flashes(f):
    """A spike that reverts: the screen jumped and came straight back.

    The one-frame case is d[i] > T_flash, d[i+1] > T_flash and frame i+1 close
    to frame i-1. A flash can last a couple of frames (a white layer drawn for
    two vsyncs), so runs of up to FLASH_MAX_FRAMES are checked the same way:
    spike in, spike out, and the screen after equals the screen before.
    """
    out = []
    seen = set()
    for i in range(1, f.n - 1):
        if f.d[i] <= THRESHOLDS["T_flash"] or i in seen:
            continue
        for L in range(1, THRESHOLDS["FLASH_MAX_FRAMES"] + 1):
            j = i + L                      # first frame back to normal
            if j >= f.n:
                break
            if f.d[j] <= THRESHOLDS["T_flash"]:
                continue
            revert = f.diff(j, i - 1)
            if revert >= THRESHOLDS["T_flash_revert"]:
                continue
            out.append({"index": i, "t_ms": round(f.t_ms(i), 1), "frames": L,
                        "d": round(f.d[i], 2), "d_next": round(f.d[j], 2),
                        "revert": round(revert, 2)})
            seen.update(range(i, j + 1))
            break
    return out


def find_reversals(qs):
    """Epoch of every opening<->closing state flip in the qs log.

    A flight that gets reversed mid-way (the open trigger fires, then the
    close trigger fires before it finished, or vice versa) produces a visible
    jump on screen that is not a defect: the shell is doing exactly what it
    was told, twice, within one flightMs. Returns the epoch of the second
    state in each such pair, in order.
    """
    out = []
    states = qs["states"]
    for a, b in zip(states, states[1:]):
        if (a["state"], b["state"]) in (("opening", "closing"), ("closing", "opening")):
            out.append(b["epoch_ms"])
    return out


def classify_flashes(flashes, reversal_epochs, video_zero):
    """Split candidate flashes into real flashes and expected reversals.

    A flash is reclassified as a reversal when its video time maps to an
    epoch within flightMs after a logged opening<->closing flip: the flight
    reversed direction underneath it, so the jump-and-revert the detector
    saw is the shell changing its mind, not a bug.
    """
    if video_zero is None or not reversal_epochs:
        return flashes, []
    kept, reversals = [], []
    for x in flashes:
        flash_epoch = video_zero + x["t_ms"]
        match = next((e for e in reversal_epochs
                      if 0 <= flash_epoch - e <= THRESHOLDS["FLIGHT_MS"]), None)
        if match is None:
            kept.append(x)
        else:
            reversals.append(dict(x, reversal_epoch_ms=match,
                                  reversal_gap_ms=round(flash_epoch - match, 1)))
    return kept, reversals


def median(vals):
    v = sorted(vals)
    n = len(v)
    if not n:
        return 0.0
    return v[n // 2] if n % 2 else 0.5 * (v[n // 2 - 1] + v[n // 2])


def is_spike(f, i):
    """d[i] stands out from its own neighbourhood, not just from zero."""
    h = THRESHOLDS["SPIKE_HALF"]
    lo, hi = max(1, i - h), min(f.n - 1, i + h)
    neigh = [f.d[j] for j in range(lo, hi + 1) if j != i]
    if not neigh:
        return False
    return (f.d[i] > THRESHOLDS["T_SPIKE"]
            and f.d[i] > THRESHOLDS["SPIKE_RATIO"] * median(neigh))


def find_cuts(f, actions, windows=()):
    """Whole-screen changes with no action to explain them.

    `windows` are (start_ms, end_ms, label) spans in video time in which an
    animation was running (see animation_windows). Inside one of those the
    screen is supposed to change wholesale, so the hard-cut rule would fire on
    every flight; a frame there is only reported when it spikes against its
    neighbours. Outside them the old whole-screen rule stands.
    """
    act = [a["t_ms"] for a in actions]
    pre, lag = THRESHOLDS["CUT_ACTION_PRE_MS"], THRESHOLDS["CUT_ACTION_LAG_MS"]
    out = []
    floor = min(THRESHOLDS["T_cut"], THRESHOLDS["T_SPIKE"])
    for i in range(1, f.n):
        if f.d[i] <= floor:
            continue
        t = f.t_ms(i)
        if any(t - lag <= a <= t + pre for a in act):
            continue
        win = next((w for w in windows if w[0] <= t <= w[1]), None)
        if win is not None:
            if is_spike(f, i):
                out.append({"index": i, "t_ms": round(t, 1), "d": round(f.d[i], 2),
                            "kind": "spike", "window": win[2]})
        elif f.d[i] > THRESHOLDS["T_cut"]:
            out.append({"index": i, "t_ms": round(t, 1), "d": round(f.d[i], 2),
                        "kind": "cut"})
    return out


def _stdev(vals):
    if len(vals) < 2:
        return 0.0
    m = sum(vals) / len(vals)
    var = sum((x - m) ** 2 for x in vals) / len(vals)
    return var ** 0.5


def steady_baseline(f, skip=()):
    """Baseline for the tail of the recording (last 30 non-skipped frames, or
    the last third if shorter). A fixture window that ticks a full-screen
    pattern at 10 Hz (e.g. workspace 3's sim-t4) only redraws on roughly one
    in every six captured frames, so the *median* of the tail is near zero
    even though the recording never truly goes quiet: the tick spike itself
    is part of the steady state. The baseline is therefore the tail's peak
    (max), which the periodic spike sits at every cycle, with the median
    kept only to size the run-to-run spread. A tail is "stable" (std <=
    baseline) when its variation is consistent with that repeating spike
    rather than something still trending toward a different level.

    Frames in `skip` (black ones) carry no information about the steady
    state and are excluded from the tail: including them would let a
    black-to-visible transition near the end of the recording inflate the
    baseline and make every scenario look instantly settled. If fewer than
    5 non-skipped frames remain, fall back to the plain last-30-frames tail."""
    n = f.n
    if n < 2:
        return 0.0, True
    idxs = [i for i in range(n) if i not in skip]
    if len(idxs) >= 5:
        tail_idxs = idxs[-min(30, len(idxs)):]
        tail = [f.d[i] for i in tail_idxs]
    else:
        tail_len = min(30, max(1, (n - 1) // 3))
        tail = f.d[n - tail_len:n]
    baseline = max(tail)
    std = _stdev(tail)
    stable = std <= baseline if baseline > 0 else True
    return baseline, stable


def settle_ms(f, last_action_ms, skip=()):
    """ms from the last action to the first run of QUIET_RUN frames that
    have reached the recording's steady state.

    Frames in `skip` (black ones, see black_frames) are neither counted as
    quiet nor allowed to break a quiet run: they carry no information about
    what the screen was doing.

    Normally that steady state is silence (T_quiet). When the tail of the
    recording sits above T_quiet but is itself stable (an animating fixture
    window rather than something still settling), frames are compared
    against that tail's baseline plus a tolerance instead of raw zero, so a
    continuously-ticking pattern still counts as "settled" once nothing else
    is changing on top of it."""
    threshold = THRESHOLDS["T_quiet"]
    baseline, stable = steady_baseline(f, skip=skip)
    steady_baseline_out = 0.0
    if baseline > THRESHOLDS["T_quiet"] and stable:
        tol = max(THRESHOLDS["T_quiet"], 0.35 * baseline + 3)
        threshold = baseline + tol
        steady_baseline_out = baseline

    run_len = 0
    run_start = None
    need = THRESHOLDS["QUIET_RUN"]
    for i in range(1, f.n):
        if f.t_ms(i) < last_action_ms:
            run_len = 0
            run_start = None
            continue
        if i in skip:
            # a skipped (black) frame carries no information: it breaks the
            # run rather than being silently passed over, otherwise a quiet
            # run spanning a black region would fuse pre- and post-black
            # frames together and could report a black frame as the start
            run_len = 0
            run_start = None
            continue
        if f.d[i] < threshold:
            if run_len == 0:
                run_start = i
            run_len += 1
            if run_len >= need:
                return round(f.t_ms(run_start) - last_action_ms, 1), run_start, steady_baseline_out
        else:
            run_len = 0
            run_start = None
    return None, None, steady_baseline_out


def find_stale(f, actions, budget_ms):
    """Frame gaps over T_STALE_MS inside a window where something should move."""
    out = []
    windows = [(a["t_ms"], a["t_ms"] + budget_ms) for a in actions]
    for i in range(1, f.n):
        gap = f.t_ms(i) - f.t_ms(i - 1)
        if gap <= THRESHOLDS["T_STALE_MS"]:
            continue
        a, b = f.t_ms(i - 1), f.t_ms(i)
        if any(not (b < w0 or a > w1) for w0, w1 in windows):
            out.append({"index": i, "t_ms": round(a, 1), "gap_ms": round(gap, 1)})
    return out


# the overlay is on screen in these states; `preparing` is before the first
# paint and `closed` is after the last, so neither is counted
OVERVIEW_VISIBLE_STATES = ("opening", "open", "closing")


def overview_spans(qs, tail_ms):
    """(start_epoch, end_epoch) for every stretch the overlay was on screen.

    A visible state runs until the next state line; the last one has no
    successor, so it is given `tail_ms` (one flight) of its own.
    """
    states = sorted((s for s in qs["states"] if s.get("epoch_ms")),
                    key=lambda s: s["epoch_ms"])
    out = []
    for i, s in enumerate(states):
        if s["state"] not in OVERVIEW_VISIBLE_STATES:
            continue
        end = (states[i + 1]["epoch_ms"] if i + 1 < len(states)
               else s["epoch_ms"] + tail_ms)
        if out and s["epoch_ms"] <= out[-1][1]:
            out[-1][1] = max(out[-1][1], end)
        else:
            out.append([s["epoch_ms"], end])
    return [(a, b) for a, b in out]


def black_frames(f, spans):
    """Frames below T_black while the shell says the overlay was on screen.

    hypr/synopsis.lua puts `no_screen_share = true` on the synopsis layer
    rules, and Hyprland's screencopy then paints a black rectangle over them
    (ScreenshareFrame.cpp), so the whole capture goes black for as long as the
    overview is up. `spans` are (start, end) in video ms.
    """
    if not spans:
        return []
    limit = f.black_level() + THRESHOLDS["T_black"]
    seeds = [i for i in range(f.n)
             if any(t0 <= f.t_ms(i) <= t1 for t0, t1 in spans)
             and f.mean(i) <= limit]
    if not seeds:
        return []
    # the video clock is anchored on t_stop, and a still screen writes no
    # frames at all (VFR), so the anchor can sit a second or so off the shell's
    # epochs. A black run that starts inside a span therefore keeps its whole
    # run, however far past the span's edge the run reaches.
    out = set(seeds)
    for i in (min(seeds), max(seeds)):
        for step in (-1, 1):
            j = i + step
            while 0 <= j < f.n and j not in out and f.mean(j) <= limit:
                out.add(j)
                j += step
    return sorted(out)


# --------------------------------------------------------------------------
# qs log
# --------------------------------------------------------------------------

STATE_RE = re.compile(r"\[synopsis\] state (\d+) (\w+)")
FRAME_RE = re.compile(r"\[synopsis\] frame (\S+) (\d+) ([-\d.]+)")
EVENT_RE = re.compile(r"\[synopsis\] (\d+) event (\S+)")
SLIDE_RE = re.compile(r"\[synopsis\] (?:(\d+) )?slide\b")
# `slide <mon> arrive=1 dur=450 live=2 leaving=3` and whatever numeric fields
# are added later (interval=, ...): every key=number pair is kept, none required
SLIDE_FIELD_RE = re.compile(r"(\w+)=(-?\d+(?:\.\d+)?)\b")
ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")
ERROR_RE = re.compile(r"(TypeError|ReferenceError|is not a function|QML .*Error|^.*\berror\b)", re.I)

# a `slide` line carries no timestamp; it is stamped with the workspace event
# that caused it when one is this recent, otherwise with the last stamped line
WS_EVENT_MAX_AGE_MS = 500


def read_qs_log(path):
    """Parse the shell log slice.

    `log` keeps every kept line in file order with the epoch of the last
    timestamped line at or before it, so a frame gap can be annotated with
    whatever the shell was doing while it was not painting.
    """
    info = {"states": [], "switch": [], "slide": [], "placeholder": [],
            "errors": [], "frames": [], "events": [], "log": [], "lines": 0,
            "duplicate": []}
    if not os.path.exists(path):
        return info
    last_epoch = None
    last_ws = None
    with open(path, errors="replace") as f:
        for line in f:
            info["lines"] += 1
            if "PeerClosedError" in line:
                continue   # hyprland closes the request socket after every reply; expected
            text = ANSI_RE.sub("", line).strip()
            idx = len(info["log"])
            m = STATE_RE.search(line)
            if m:
                last_epoch = int(m.group(1))
                info["states"].append({"epoch_ms": last_epoch, "state": m.group(2),
                                       "line": idx})
            m = FRAME_RE.search(line)
            if m:
                last_epoch = int(m.group(2))
                info["frames"].append({"monitor": m.group(1), "epoch_ms": last_epoch,
                                       "progress": float(m.group(3)), "line": idx})
            m = EVENT_RE.search(line)
            if m:
                last_epoch = int(m.group(1))
                info["events"].append({"epoch_ms": last_epoch, "event": m.group(2),
                                       "line": idx})
                if m.group(2).startswith("workspace"):
                    last_ws = last_epoch
            if "[synopsis] switch" in line:
                info["switch"].append(text)
            m = SLIDE_RE.search(line)
            if m:
                stamped = m.group(1) is not None
                if stamped:
                    ts = int(m.group(1))
                    last_epoch = ts
                else:
                    # older logs: the slide line carried no clock of its own
                    ts = last_epoch
                    if last_ws is not None and (last_epoch is None
                                                or last_epoch - last_ws <= WS_EVENT_MAX_AGE_MS):
                        ts = last_ws
                fields = {k: float(v) for k, v in SLIDE_FIELD_RE.findall(text)}
                info["slide"].append({"epoch_ms": ts, "text": text, "line": idx,
                                      "stamped": stamped, "fields": fields})
            if "duplicate row" in line:
                info["duplicate"].append(text[:200])
            if "placeholder" in line:
                info["placeholder"].append(text)
            if ERROR_RE.search(line) and "[synopsis]" not in line:
                info["errors"].append(text[:200])
            info["log"].append({"epoch_ms": last_epoch, "text": text})
    return info


# the exposé must follow the keypress, not the refresh that notices it later:
# a switch driven by the refresh pipeline arrives ~150 ms late and replays the
# switches a burst passed through (tuning.md, event-driven active workspace)
SWITCH_LATENCY_MAX_MS = 400
# above this the slide is visibly behind the keypress; a note, not a failure
SWITCH_LATENCY_NOTE_MS = 60
# HyprState's raw-event handler runs before the one that prints the `event`
# line, so a slide driven straight off the event is logged a few ms *before*
# the event it answers. A slide this close in front of one counts as 0 ms.
SWITCH_LOG_SKEW_MS = 20


def switch_latency(qs):
    """Event-to-slide latency for every workspacev2 the shell reacted to.

    A switch with no slide within SWITCH_LATENCY_MAX_MS is skipped: the
    overview was not interactive, so nothing was meant to move.
    """
    # only a slide line that carries its own clock can be measured against an
    # event; an older log borrowed that event's timestamp and would read 0 ms
    slides = sorted(sl["epoch_ms"] for sl in qs["slide"]
                    if sl["epoch_ms"] and sl.get("stamped"))
    out = []
    for ev in qs["events"]:
        if ev["event"] != "workspacev2" or not ev["epoch_ms"]:
            continue
        nxt = next((t for t in slides if t >= ev["epoch_ms"] - SWITCH_LOG_SKEW_MS), None)
        if nxt is None or nxt - ev["epoch_ms"] > SWITCH_LATENCY_MAX_MS:
            continue
        out.append({"epoch_ms": ev["epoch_ms"],
                    "latency_ms": max(0, nxt - ev["epoch_ms"])})
    return out


SLIDE_MON_RE = re.compile(r"slide\s+(\S+)")


def slide_stats(qs):
    """How much slide traffic the log carries and how tightly switches were
    cadenced.

    The shell only runs one slide animation per monitor at a time
    (`startSlide` stops the previous one before starting the next), so
    overlapping [start, start + dur] windows on the same monitor cannot
    happen and would not measure concurrency even if they did. What matters
    instead is switch cadence: `min_gap` is the smallest interval between
    the start times of two consecutive slide lines on the same monitor
    (omitted, i.e. None, when no monitor logged more than one slide).
    """
    if not qs["slide"]:
        return None
    fields = [sl.get("fields") or {} for sl in qs["slide"]]
    max_leaving = max((int(fl.get("leaving", 0)) for fl in fields), default=0)
    by_mon = {}
    for sl in qs["slide"]:
        if not sl.get("epoch_ms"):
            continue
        m = SLIDE_MON_RE.search(sl["text"])
        mon = m.group(1) if m else ""
        by_mon.setdefault(mon, []).append(sl["epoch_ms"])
    gaps = []
    for times in by_mon.values():
        times.sort()
        gaps.extend(b - a for a, b in zip(times, times[1:]))
    min_gap = min(gaps) if gaps else None
    return {"count": len(qs["slide"]), "max_leaving": max_leaving,
            "min_gap": min_gap}


# --------------------------------------------------------------------------
# animations: windows for the cut detector, flights for the cadence report
# --------------------------------------------------------------------------

def animation_spans(qs):
    """(start_epoch, end_epoch, label) for every animation the log announces.

    The end is where the log says the animation ended: the matching `open` or
    `closed` state, or one flight later when the shell never got there. Slides
    carry no end line, so they run for switchMs.
    """
    spans = []
    states = qs["states"]
    flight = THRESHOLDS["FLIGHT_MS"] + THRESHOLDS["SETTLE_MS"]
    for i, s in enumerate(states):
        if s["state"] == "opening":
            kind, done = "open", ("open", "closed")
        elif s["state"] == "closing":
            kind, done = "close", ("closed", "open")
        else:
            continue
        end = next((x for x in states[i + 1:] if x["state"] in done), None)
        t1 = end["epoch_ms"] if end else s["epoch_ms"] + flight
        spans.append((s["epoch_ms"], t1, kind))
    for sl in qs["slide"]:
        if sl["epoch_ms"]:
            spans.append((sl["epoch_ms"], sl["epoch_ms"] + THRESHOLDS["SWITCH_MS"], "slide"))
    spans.sort()
    return spans


def animation_windows(spans, actions):
    """Cut-detector windows: while these run the screen is meant to change.

    A window is measured from the announcement, not from where the animation
    actually ended: a flight that reports `closed` after 4 ms still repaints
    for flightMs afterwards, and the frames for a slide keep coming for
    switchMs. Each action opens a short window of its own, as before.
    """
    slack = THRESHOLDS["WINDOW_SLACK_MS"]
    flight = THRESHOLDS["FLIGHT_MS"] + THRESHOLDS["SETTLE_MS"] + slack
    out = []
    for t0, t1, label in spans:
        span = THRESHOLDS["SWITCH_MS"] + slack if label == "slide" else flight
        out.append((t0, max(t1, t0 + span), label))
    out += [(a["t_ms"], a["t_ms"] + THRESHOLDS["ACTION_WINDOW_MS"], "action")
            for a in actions]
    out.sort()
    return out


def context_lines(qs, lo, hi, limit=6, width=100):
    out = []
    for row in qs["log"][lo + 1:hi]:
        if not row["text"]:
            continue
        out.append(row["text"][:width])
        if len(out) >= limit:
            break
    return out


def build_flights(qs, spans):
    """Per-monitor frame cadence inside each animation span."""
    out = []
    frames = qs["frames"]
    for t0, t1, kind in spans:
        inside = [x for x in frames if t0 <= x["epoch_ms"] <= t1]
        by_mon = {}
        for x in inside:
            by_mon.setdefault(x["monitor"], []).append(x)
        if not by_mon:
            by_mon = {"-": []}
        for mon, xs in sorted(by_mon.items()):
            gaps, worst = [], 0.0
            for a, b in zip(xs, xs[1:]):
                g = b["epoch_ms"] - a["epoch_ms"]
                worst = max(worst, g)
                if g > THRESHOLDS["T_FLIGHT_GAP_MS"]:
                    gaps.append({"epoch_ms": a["epoch_ms"], "gap_ms": g,
                                 "context": context_lines(qs, a["line"], b["line"])})
            dur = (xs[-1]["epoch_ms"] - t0) if (kind == "slide" and xs) else t1 - t0
            out.append({"kind": kind, "monitor": mon, "t0_epoch_ms": t0,
                        "frames": len(xs), "duration_ms": round(dur, 1),
                        "max_gap_ms": round(worst, 1), "gaps": gaps,
                        "stall": worst > THRESHOLDS["T_FLIGHT_STALL_MS"]})
    return out


def flights_line(flights, limit=8):
    parts = []
    for k, fl in enumerate(flights[:limit]):
        if k == 0:
            parts.append("%s %d frames / %.0f ms (max gap %.0f ms)"
                         % (fl["kind"], fl["frames"], fl["duration_ms"], fl["max_gap_ms"]))
        else:
            parts.append("%s %d / %.0f (%.0f)"
                         % (fl["kind"], fl["frames"], fl["duration_ms"], fl["max_gap_ms"]))
    if len(flights) > limit:
        parts.append("+%d more" % (len(flights) - limit))
    return "- flights: " + ("; ".join(parts) if parts else "none in the qs log")


# --------------------------------------------------------------------------
# per-scenario analysis
# --------------------------------------------------------------------------

def analyze_scenario(out_dir, doc, save_frames=True):
    name = doc["scenario"]
    video = os.path.join(out_dir, doc.get("video") or (name + ".mkv"))
    res = {"scenario": name, "video": os.path.basename(video),
           "frames": 0, "flashes": [], "reversals": [], "cuts": [], "stale": [],
           "settle_ms": None, "budget_ms": doc.get("expected_settle_ms",
                                                   THRESHOLDS["SETTLE_BUDGET_MS"]),
           "checks": doc.get("checks", []), "qs": {}, "png": [], "verdict": "no-video",
           "notes": [], "flights": [], "stalls": 0, "black_frames": 0,
           "slides": None}

    qs = read_qs_log(os.path.join(out_dir, name + ".qs.log"))
    res["qs"] = {"states": [s["state"] for s in qs["states"]],
                 "switch": qs["switch"], "slide_events": len(qs["slide"]),
                 "errors": qs["errors"], "duplicate": qs["duplicate"]}
    # one address may only ever have one exposé row: a duplicate means a window
    # is drawn twice and captured twice
    if qs["duplicate"]:
        res["notes"].append("%d duplicate exposé row(s): %s"
                            % (len(qs["duplicate"]), qs["duplicate"][0]))
    res["switch_latency"] = switch_latency(qs)
    res["slides"] = slide_stats(qs)
    spans = animation_spans(qs)
    res["flights"] = build_flights(qs, spans)
    res["stalls"] = sum(1 for fl in res["flights"] if fl["stall"])
    painted = any(s["state"] in ("opening", "open") for s in qs["states"])

    if not os.path.exists(video) or os.path.getsize(video) == 0:
        res["notes"].append("no recording found (wf-recorder missing or failed)")
        return res

    f = Frames(video)
    if not f.ok:
        res["notes"].append("could not decode %s" % os.path.basename(video))
        return res

    res["frames"] = f.n
    res["duration_ms"] = round(f.t_ms(f.n - 1), 1) if f.n else 0
    # anchor the video clock: the recording ends at t_stop, so the video's
    # zero is t_stop - duration in wall time, and every action moves by the
    # difference between that and t0
    if doc.get("t_stop_epoch_ms") and doc.get("t0_epoch_ms") and f.n > 1:
        video_zero = doc["t_stop_epoch_ms"] - f.t_ms(f.n - 1)
        shift = doc["t0_epoch_ms"] - video_zero
        res["clock_shift_ms"] = round(shift, 1)
        doc = dict(doc)
        doc["actions"] = [dict(a, t_ms=a["t_ms"] + shift) for a in doc.get("actions", [])]
        doc["last_action_ms"] = doc.get("last_action_ms", 0) + shift
        res["actions_video_ms"] = [round(a["t_ms"]) for a in doc["actions"]]
    # a recording that never changes is normally a capture fault. It is not one
    # when the shell agrees nothing was ever drawn: toggles that arrive faster
    # than hasContentTimeoutMs only produce preparing -> closing -> closed, the
    # overview never reaches `opening`, so a flat screen is the correct result.
    if f.n > 1 and max(f.d[1:]) < THRESHOLDS["T_quiet"]:
        res["notes"].append("recording is flat (max frame diff %.2f)" % max(f.d[1:]))
        if painted or not qs["states"]:
            res["notes"].append("capture fault, nothing measured")
            res["verdict"] = "no-content"
            return res
        cycles = sum(1 for s in qs["states"] if s["state"] == "preparing")
        res["notes"].append("nothing painted: overview never reached opening "
                            "(%d prepare/close cycles)" % cycles)
        res["verdict"] = "FAIL" if (qs["errors"] or qs["duplicate"]) else "pass"
        return res
    actions = doc.get("actions", [])
    windows = []
    if "clock_shift_ms" in res and doc.get("t_stop_epoch_ms"):
        video_zero = doc["t_stop_epoch_ms"] - f.t_ms(f.n - 1)
        windows = animation_windows(
            [(t0 - video_zero, t1 - video_zero, k) for t0, t1, k in spans], actions)
        res["windows"] = [(round(w[0]), round(w[1]), w[2]) for w in windows]
    video_zero = None
    if "clock_shift_ms" in res and doc.get("t_stop_epoch_ms"):
        video_zero = doc["t_stop_epoch_ms"] - f.t_ms(f.n - 1)
    # frames blacked out by the screencopy rule carry nothing measurable, and
    # the step into and out of black is a full-screen diff that would show up
    # as a cut or a flash in every one of them
    black = []
    if video_zero is not None:
        black = black_frames(f, [(t0 - video_zero, t1 - video_zero) for t0, t1
                                 in overview_spans(qs, THRESHOLDS["FLIGHT_MS"])])
    res["black_frames"] = len(black)
    tainted = set(black) | {i + 1 for i in black}

    res["flashes"], res["reversals"] = classify_flashes(
        find_flashes(f), find_reversals(qs), video_zero)
    res["cuts"] = find_cuts(f, actions, windows)
    if tainted:
        for key in ("flashes", "reversals", "cuts"):
            res[key] = [x for x in res[key] if x["index"] not in tainted]
    st, st_index, steady_base = settle_ms(f, doc.get("last_action_ms", 0),
                                          skip=tainted)
    res["settle_ms"] = st
    res["settle_index"] = st_index
    res["steady_baseline"] = steady_base
    res["stale"] = find_stale(f, actions, res["budget_ms"])
    if tainted:
        res["stale"] = [x for x in res["stale"] if x["index"] not in tainted]

    flagged = ([x["index"] for x in res["flashes"]]
               + [x["index"] for x in res["reversals"]]
               + [x["index"] for x in res["cuts"]]
               + [x["index"] for x in res["stale"]])
    if save_frames and flagged:
        fdir = os.path.join(out_dir, "frames")
        os.makedirs(fdir, exist_ok=True)
        for idx in sorted(set(flagged)):
            for j in (idx - 1, idx, idx + 1):
                if 0 <= j < f.n:
                    dest = os.path.join(fdir, "%s-%05d.png" % (name, j))
                    if not os.path.exists(dest) and extract_png(video, j, dest):
                        res["png"].append(os.path.relpath(dest, out_dir))

    # spikes (inside an animation window) and stalls (frame cadence) are
    # reported but do not fail the verdict yet: mid-flight the screen is
    # supposed to change, so they are leads rather than defects
    hard_cuts = [x for x in res["cuts"] if x.get("kind") != "spike"]
    bad = (len(res["flashes"]) or len(hard_cuts) or len(res["stale"])
           or res["black_frames"]
           or res["qs"]["errors"] or res["qs"]["duplicate"]
           or any(not c.get("ok") for c in res["checks"])
           or (st is not None and st > res["budget_ms"])
           or st is None)
    if st is None:
        res["notes"].append("never settled inside the recording")
    res["verdict"] = "FAIL" if bad else "pass"
    return res


# --------------------------------------------------------------------------
# report
# --------------------------------------------------------------------------

def write_report(out_dir, results):
    js = os.path.join(out_dir, "report.json")
    with open(js, "w") as f:
        json.dump({"thresholds": THRESHOLDS, "scenarios": results}, f, indent=1)

    md = [ "# synopsis simulator report", "",
           "Run directory: `%s`" % out_dir, "",
           "| scenario | frames | flashes | reversals | cuts | spikes | stale | stalls | settle ms | budget | verdict |",
           "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|" ]
    for r in results:
        cuts = [x for x in r["cuts"] if x.get("kind") != "spike"]
        spikes = [x for x in r["cuts"] if x.get("kind") == "spike"]
        md.append("| %s | %d | %d | %d | %d | %d | %d | %d | %s | %d | %s |" % (
            r["scenario"], r["frames"], len(r["flashes"]), len(r.get("reversals", [])),
            len(cuts), len(spikes),
            len(r["stale"]), r.get("stalls", 0),
            "-" if r["settle_ms"] is None else "%.0f" % r["settle_ms"],
            r["budget_ms"], r["verdict"]))
    md.append("")
    for r in results:
        if r.get("slides"):
            gap = r["slides"]["min_gap"]
            md.append("- %s slides: %d, max concurrent leaving rows %d, "
                      "min switch gap %s"
                      % (r["scenario"], r["slides"]["count"], r["slides"]["max_leaving"],
                         "-" if gap is None else "%d ms" % gap))
    md.append("")

    for r in results:
        flags = (r["flashes"] or r.get("reversals") or r["cuts"] or r["stale"]
                 or r["qs"]["errors"] or r.get("switch_latency")
                 or r.get("black_frames")
                 or [c for c in r["checks"] if not c.get("ok")] or r["notes"])
        if r["verdict"] == "no-content":
            md.append("- **no content**: " + "; ".join(r["notes"]))
            continue
        show_baseline = r.get("steady_baseline", 0) > THRESHOLDS["T_quiet"]
        if not flags and not r.get("flights") and r["verdict"] == "pass" and not show_baseline:
            continue
        md.append("## %s" % r["scenario"])
        for n in r["notes"]:
            md.append("- note: %s" % n)
        if r.get("black_frames"):
            md.append("- **overlay not captured**: %d frames black while open "
                      "(no_screen_share?)" % r["black_frames"])
        if show_baseline:
            md.append("- steady tail: baseline %.1f (animating window)" % r["steady_baseline"])
        lat = r.get("switch_latency") or []
        if lat:
            worst = max(x["latency_ms"] for x in lat)
            md.append("- switch latency: max %d ms (%d switches)%s"
                      % (worst, len(lat),
                         "" if worst <= SWITCH_LATENCY_NOTE_MS
                         else " - note: the slide is meant to start on the event"))
        if r.get("flights"):
            md.append(flights_line(r["flights"]))
            for fl in r["flights"]:
                for g in fl["gaps"]:
                    md.append("- %s at %d gap %.0f ms (%s flight, %s)"
                              % ("**stall**" if fl["stall"] else "gap",
                                 g["epoch_ms"], g["gap_ms"], fl["kind"],
                                 fl["monitor"]))
                    for c in g["context"]:
                        md.append("    - `%s`" % c)
        for c in r["checks"]:
            if not c.get("ok"):
                md.append("- **assertion failed**: %s (%s)" % (c["check"], c.get("detail", "")))
        for x in r["flashes"]:
            md.append("- **flash** at %.0f ms (frame %d): d=%.1f, next d=%.1f, revert=%.1f %s"
                      % (x["t_ms"], x["index"], x["d"], x["d_next"], x["revert"],
                         png_refs(r, x["index"])))
        for x in r.get("reversals", []):
            md.append("- reversal at %.0f ms (frame %d): d=%.1f, next d=%.1f, revert=%.1f, "
                      "flight reversed %d ms earlier %s"
                      % (x["t_ms"], x["index"], x["d"], x["d_next"], x["revert"],
                         x["reversal_gap_ms"], png_refs(r, x["index"])))
        for x in r["cuts"]:
            if x.get("kind") == "spike":
                md.append("- **spike** at %.0f ms (frame %d): d=%.1f, %.1fx its neighbours "
                          "inside the %s window %s"
                          % (x["t_ms"], x["index"], x["d"], THRESHOLDS["SPIKE_RATIO"],
                             x.get("window", "animation"), png_refs(r, x["index"])))
            else:
                md.append("- **hard cut** at %.0f ms (frame %d): d=%.1f, no action within %d ms %s"
                          % (x["t_ms"], x["index"], x["d"], THRESHOLDS["CUT_ACTION_LAG_MS"],
                             png_refs(r, x["index"])))
        for x in r["stale"]:
            md.append("- **stale** %.0f ms with no frame from %.0f ms (frame %d) %s"
                      % (x["gap_ms"], x["t_ms"], x["index"], png_refs(r, x["index"])))
        if r["settle_ms"] is not None and r["settle_ms"] > r["budget_ms"]:
            md.append("- **slow settle**: %.0f ms (budget %d ms)" % (r["settle_ms"], r["budget_ms"]))
        for e in r["qs"]["errors"][:10]:
            md.append("- **qs log**: `%s`" % e)
        for s in r["qs"]["switch"][:10]:
            md.append("- switch: `%s`" % s)
        md.append("")

    md.append("## thresholds")
    for k, v in THRESHOLDS.items():
        md.append("- `%s` = %s" % (k, v))
    md.append("")
    path = os.path.join(out_dir, "report.md")
    with open(path, "w") as f:
        f.write("\n".join(md))
    return path


def png_refs(r, index):
    names = [p for p in r["png"] if p.endswith("-%05d.png" % index)
             or p.endswith("-%05d.png" % (index - 1)) or p.endswith("-%05d.png" % (index + 1))]
    return "(" + ", ".join("`%s`" % n for n in names) + ")" if names else ""


# --------------------------------------------------------------------------
# self test: synthesise videos and prove the detectors fire
# --------------------------------------------------------------------------

def self_test(keep=False):
    tmp = tempfile.mkdtemp(prefix="simtest-")
    print("self-test dir: %s" % tmp)
    flash_mkv = os.path.join(tmp, "flashy.mkv")
    # 3 s of motion with a one-frame white flash at t=1.0 s, then a static tail
    # from t=2.0 s (so the settle metric has something to find).
    filt = ("testsrc2=size=320x180:rate=30:duration=2,"
            "drawbox=x=0:y=0:w=iw:h=ih:color=white@1.0:t=fill:"
            "enable='between(n,30,31)'[a];"
            "color=c=gray:size=320x180:rate=30:duration=2[b];"
            "[a][b]concat=n=2:v=1:a=0")
    r = run(["ffmpeg", "-v", "error", "-y", "-filter_complex", filt,
             "-c:v", "libx264", "-preset", "ultrafast", "-crf", "18",
             "-pix_fmt", "yuv420p", flash_mkv])
    if r.returncode != 0:
        print("ffmpeg failed: %s" % r.stderr.decode()[:400])
        return 2

    doc = {"scenario": "flashy", "video": "flashy.mkv",
           "actions": [{"t_ms": 0, "verb": "toggle", "args": None}],
           "last_action_ms": 0, "expected_settle_ms": 920, "checks": []}
    with open(os.path.join(tmp, "flashy.actions.json"), "w") as f:
        json.dump(doc, f)

    res = analyze_scenario(tmp, doc, save_frames=True)
    ok = True
    print("frames=%d flashes=%d cuts=%d settle=%s verdict=%s"
          % (res["frames"], len(res["flashes"]), len(res["cuts"]),
             res["settle_ms"], res["verdict"]))
    if not res["flashes"]:
        print("FAIL: flash detector did not fire on the injected white frame")
        ok = False
    else:
        print("ok: flash at %.0f ms (frame %d)" % (res["flashes"][0]["t_ms"], res["flashes"][0]["index"]))
    if res["settle_ms"] is None:
        print("FAIL: settle time never found on a video with a static tail")
        ok = False
    else:
        print("ok: settle %.0f ms (expected ~2000 ms, the static tail)" % res["settle_ms"])
        if not (1500 <= res["settle_ms"] <= 2600):
            print("FAIL: settle time %.0f ms outside the expected band" % res["settle_ms"])
            ok = False
    if not res["cuts"]:
        print("note: no unexplained hard cut in this clip (concat boundary may be under T_cut)")
    if not res["png"]:
        print("FAIL: no frame PNGs were extracted for the flagged frames")
        ok = False
    else:
        print("ok: %d frame PNGs extracted (e.g. %s)" % (len(res["png"]), res["png"][0]))
    path = write_report(tmp, [res])
    print("report: %s" % path)
    if not keep:
        print("(left in place for inspection; delete %s when done)" % tmp)
    return 0 if ok else 1


# --------------------------------------------------------------------------

# --------------------------------------------------------------------------
# live desktop recordings (tools/record.sh)
# --------------------------------------------------------------------------

# a raw Hyprland socket2 line, prefixed by record.sh with its own epoch ms:
# "<epoch_ms> <event>>><data>"
LIVE_EVENT_RE = re.compile(r"^(\d+)\s+([A-Za-z0-9]+)>>(.*)$")


def parse_live_events(path):
    """Turn workspacev2 switches and synopsis: custom events into actions.

    Every other socket2 event is ignored: only these two drive the shell's
    own state machine, so only these two explain a hard cut in the video.
    """
    out = []
    if not os.path.exists(path):
        return out
    with open(path, errors="replace") as f:
        for line in f:
            m = LIVE_EVENT_RE.match(line.rstrip("\n"))
            if not m:
                continue
            epoch, name, data = int(m.group(1)), m.group(2), m.group(3)
            if name == "workspacev2":
                out.append({"epoch_ms": epoch, "verb": "focus_ws",
                           "args": data.split(",")[0]})
            elif name == "custom" and data.startswith("synopsis:"):
                out.append({"epoch_ms": epoch, "verb": "custom", "args": data})
    return out


def build_live_doc(out_dir):
    """Fabricate an actions.json-shaped doc from a tools/record.sh directory."""
    meta_path = os.path.join(out_dir, "meta.json")
    if not os.path.exists(meta_path):
        raise SystemExit("no meta.json in %s (run tools/record.sh first)" % out_dir)
    with open(meta_path) as f:
        meta = json.load(f)
    t0 = meta.get("t0_epoch_ms")
    t_stop = meta.get("t_stop_epoch_ms")
    if not t0 or not t_stop:
        raise SystemExit("meta.json is missing t0_epoch_ms/t_stop_epoch_ms")

    raw = parse_live_events(os.path.join(out_dir, "events.log"))
    actions = sorted(
        [{"t_ms": a["epoch_ms"] - t0, "verb": a["verb"], "args": a["args"]}
         for a in raw],
        key=lambda a: a["t_ms"])
    last_action_ms = actions[-1]["t_ms"] if actions else 0

    # read_qs_log() looks for "<scenario>.qs.log"; a live recording's shell
    # log is named shell.log by record.sh, so hand it a copy under that name
    shell_log = os.path.join(out_dir, "shell.log")
    qs_dest = os.path.join(out_dir, "live.qs.log")
    if os.path.exists(shell_log) and not os.path.exists(qs_dest):
        shutil.copyfile(shell_log, qs_dest)

    return {
        "scenario": "live",
        "video": "desktop.mkv",
        "t0_epoch_ms": t0,
        "t_stop_epoch_ms": t_stop,
        "actions": actions,
        "last_action_ms": last_action_ms,
        "expected_settle_ms": THRESHOLDS["SETTLE_BUDGET_MS"],
        "checks": [],
    }


def build_sheets(out_dir, video, res):
    """Contact sheets around every flagged frame, for a quick visual scan."""
    if not shutil.which("magick"):
        print("note: 'magick' (ImageMagick) not found, skipping contact sheets")
        return
    n = res.get("frames", 0)
    if not n or not os.path.exists(video):
        return
    categories = [
        ("flash", res["flashes"]),
        ("reversal", res.get("reversals", [])),
        ("cut", [x for x in res["cuts"] if x.get("kind") != "spike"]),
        ("spike", [x for x in res["cuts"] if x.get("kind") == "spike"]),
        ("stale", res["stale"]),
    ]
    fdir = os.path.join(out_dir, "frames")
    sdir = os.path.join(out_dir, "sheets")
    os.makedirs(fdir, exist_ok=True)
    os.makedirs(sdir, exist_ok=True)
    for label, items in categories:
        for item in items:
            idx = item["index"]
            tiles = []
            for off in range(-6, 8, 2):
                j = idx + off
                if j < 0 or j >= n:
                    continue
                dest = os.path.join(fdir, "sheet-%s-%05d-%05d.png" % (label, idx, j))
                if not os.path.exists(dest):
                    extract_png_scaled(video, j, dest)
                if os.path.exists(dest):
                    tiles.append(dest)
            if not tiles:
                continue
            sheet = os.path.join(sdir, "%s-%05d.png" % (label, idx))
            run(["magick", "montage"] + tiles
                + ["-tile", "3x", "-geometry", "426x240+2+2", sheet])


def main(argv=None):
    ap = argparse.ArgumentParser(description="analyze synopsis simulator recordings")
    ap.add_argument("--out", help="run directory produced by run.sh")
    ap.add_argument("--scenario", default=None, help="only this scenario")
    ap.add_argument("--no-frames", action="store_true", help="skip PNG extraction")
    ap.add_argument("--self-test", action="store_true", help="synthetic detector test")
    ap.add_argument("--keep", action="store_true")
    ap.add_argument("--live", help="a directory produced by tools/record.sh "
                                    "(desktop.mkv, meta.json, events.log, "
                                    "optional shell.log)")
    ap.add_argument("--all-frames", action="store_true",
                    help="with --live, also extract every frame (640w) into "
                         "frames-all/ for manual scrubbing")
    args = ap.parse_args(argv)

    if args.self_test:
        return self_test(args.keep)
    if args.live:
        out = os.path.abspath(args.live)
        doc = build_live_doc(out)
        res = analyze_scenario(out, doc, save_frames=True)
        path = write_report(out, [res])
        print(path)
        build_sheets(out, os.path.join(out, doc["video"]), res)
        if args.all_frames:
            extract_all_frames(os.path.join(out, doc["video"]),
                               os.path.join(out, "frames-all"))
        return 1 if res["verdict"] in ("FAIL", "no-content") else 0
    if not args.out:
        raise SystemExit("--out is required")

    out = os.path.abspath(args.out)
    docs = []
    for fn in sorted(os.listdir(out)):
        if not fn.endswith(".actions.json"):
            continue
        with open(os.path.join(out, fn)) as f:
            doc = json.load(f)
        if args.scenario and doc.get("scenario") != args.scenario:
            continue
        docs.append(doc)
    if not docs:
        raise SystemExit("no *.actions.json in %s" % out)

    results = [analyze_scenario(out, d, save_frames=not args.no_frames) for d in docs]
    path = write_report(out, results)
    print(path)
    return 1 if any(r["verdict"] in ("FAIL", "no-content") for r in results) else 0


if __name__ == "__main__":
    sys.exit(main())
