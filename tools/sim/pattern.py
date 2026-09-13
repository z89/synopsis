#!/usr/bin/env python3
"""Moving terminal test pattern for the synopsis simulator fixture windows.

Each fixture window runs `python3 tools/sim/pattern.py <name>` inside kitty.
The output is a full-terminal animated pattern in a hue derived from <name>, so
every fixture window looks different in a recorded frame and any window that
stops painting (a stale thumbnail, a frozen capture) is obvious to both the
analyzer and a human reviewing the extracted PNGs.

  - diagonal stripes that scroll one cell per tick (10 Hz)
  - the window name in large-ish block letters made of the name itself
  - a monotonically increasing tick counter, so a frozen frame is provable

SIGWINCH is handled crudely: the size is re-queried every tick, so a resize
takes effect within 100 ms without a signal handler racing the draw.

Usage:  pattern.py NAME [--hz 10]
"""

import os
import shutil
import sys
import time
import zlib

HZ = 10.0


def hue_for(name):
    """Stable, well-spread hue per name (0..359)."""
    return (zlib.crc32(name.encode()) * 47) % 360


def hsv_rgb(h, s, v):
    """h in degrees, s/v in 0..1 -> (r, g, b) bytes."""
    c = v * s
    x = c * (1 - abs(((h / 60.0) % 2) - 1))
    m = v - c
    seg = int(h // 60) % 6
    r, g, b = [
        (c, x, 0), (x, c, 0), (0, c, x),
        (0, x, c), (x, 0, c), (c, 0, x),
    ][seg]
    return (int((r + m) * 255), int((g + m) * 255), int((b + m) * 255))


def fg(rgb):
    return "\033[38;2;%d;%d;%dm" % rgb


def bg(rgb):
    return "\033[48;2;%d;%d;%dm" % rgb


RESET = "\033[0m"
HOME = "\033[H"
CLEAR = "\033[2J"
HIDE = "\033[?25l"
SHOW = "\033[?25h"

GLYPHS = "█▓▒░"  # full, dark, medium, light shade


def size():
    try:
        c = shutil.get_terminal_size((80, 24))
        return max(8, c.columns), max(4, c.lines)
    except Exception:
        return 80, 24


def frame(name, tick, cols, rows, hue):
    base = hsv_rgb(hue, 0.55, 0.22)
    out = [HOME, bg(base)]
    label = " %s  %04d " % (name.upper(), tick % 10000)
    lab_row = rows // 2
    for y in range(rows):
        row = []
        for x in range(cols):
            d = (x + y * 2 + tick) % 24
            shade = GLYPHS[(d // 6) % len(GLYPHS)]
            lum = 0.30 + 0.45 * (d / 24.0)
            row.append(fg(hsv_rgb((hue + d * 3) % 360, 0.85, lum)) + shade)
        line = "".join(row)
        if y == lab_row:
            # overlay the label centred, in inverse video so it reads in a thumbnail
            pad = max(0, (cols - len(label)) // 2)
            line = "".join(row[:pad]) if pad else ""
            line += (bg(hsv_rgb(hue, 0.9, 0.95)) + fg((10, 10, 10)) + label
                     + RESET + bg(base))
            used = pad + len(label)
            if used < cols:
                line += "".join(row[used:])
        out.append(line)
        if y < rows - 1:
            out.append("\r\n")
    out.append(RESET)
    return "".join(out)


def main(argv):
    name = argv[1] if len(argv) > 1 else "sim"
    hz = HZ
    if "--hz" in argv:
        try:
            hz = float(argv[argv.index("--hz") + 1])
        except (ValueError, IndexError):
            pass
    period = 1.0 / max(0.5, hz)
    hue = hue_for(name)
    w = sys.stdout.write
    w(HIDE + CLEAR)
    sys.stdout.flush()
    tick = 0
    last_size = None
    try:
        while True:
            cols, rows = size()  # crude SIGWINCH handling: re-query every tick
            if (cols, rows) != last_size:
                w(CLEAR)
                last_size = (cols, rows)
            w(frame(name, tick, cols, rows, hue))
            sys.stdout.flush()
            tick += 1
            time.sleep(period)
    except (KeyboardInterrupt, BrokenPipeError):
        pass
    finally:
        try:
            w(RESET + SHOW + "\n")
            sys.stdout.flush()
        except BrokenPipeError:
            os._exit(0)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
