#!/usr/bin/env python3
"""Parse synopsis frame logs into per-cycle timing summaries.

Reads lines produced by the shell's frame log, from stdin or a file given as
the first argument. Two line shapes are recognised:

    [synopsis] frame <screen> <epoch_ms> <progress>
    [synopsis] state <epoch_ms> <name>

A cycle starts at a "state ... opening" or "state ... closing" line and ends
at the next "state ... open" or "state ... hidden" line. For each cycle this
prints the frame count, duration in ms, mean gap, max gap, the number of
gaps over 9ms, and the first frame latency measured from the preceding
"state ... preparing" line, when one was seen.

Usage:
    journalctl --user -u synopsis.service -o cat | python3 tools/framelog.py
"""

import sys
from dataclasses import dataclass, field


FRAME_PREFIX = "[synopsis] frame "
STATE_PREFIX = "[synopsis] state "

START_STATES = {"opening", "closing"}
END_STATES = {"open", "hidden"}


@dataclass
class Cycle:
    start_state: str
    frames: list = field(default_factory=list)  # list of (epoch_ms, progress)
    preparing_ms: "int | None" = None


def parse_lines(lines):
    cycles = []
    current = None
    last_preparing_ms = None

    for raw in lines:
        line = raw.rstrip("\n")

        if FRAME_PREFIX in line:
            rest = line.split(FRAME_PREFIX, 1)[1]
            parts = rest.split()
            if len(parts) < 3:
                continue
            _screen, epoch_ms, progress = parts[0], parts[1], parts[2]
            if current is not None:
                try:
                    current.frames.append((int(epoch_ms), float(progress)))
                except ValueError:
                    continue
            continue

        if STATE_PREFIX in line:
            rest = line.split(STATE_PREFIX, 1)[1]
            parts = rest.split()
            if len(parts) < 2:
                continue
            epoch_ms, name = parts[0], parts[1]
            try:
                epoch_ms = int(epoch_ms)
            except ValueError:
                continue

            if name == "preparing":
                last_preparing_ms = epoch_ms
            elif name in START_STATES:
                current = Cycle(start_state=name, preparing_ms=last_preparing_ms)
            elif name in END_STATES:
                if current is not None:
                    cycles.append(current)
                    current = None
                last_preparing_ms = None
            continue

    if current is not None and current.frames:
        cycles.append(current)

    return cycles


def summarize(cycle):
    frames = cycle.frames
    count = len(frames)
    if count == 0:
        return {
            "state": cycle.start_state,
            "frames": 0,
            "duration_ms": 0,
            "mean_gap_ms": 0.0,
            "max_gap_ms": 0,
            "gaps_over_9ms": 0,
            "first_frame_latency_ms": None,
        }

    times = [t for t, _ in frames]
    duration_ms = times[-1] - times[0]

    gaps = [b - a for a, b in zip(times, times[1:])]
    mean_gap = sum(gaps) / len(gaps) if gaps else 0.0
    max_gap = max(gaps) if gaps else 0
    gaps_over_9ms = sum(1 for g in gaps if g > 9)

    first_frame_latency_ms = None
    if cycle.preparing_ms is not None:
        first_frame_latency_ms = times[0] - cycle.preparing_ms

    return {
        "state": cycle.start_state,
        "frames": count,
        "duration_ms": duration_ms,
        "mean_gap_ms": mean_gap,
        "max_gap_ms": max_gap,
        "gaps_over_9ms": gaps_over_9ms,
        "first_frame_latency_ms": first_frame_latency_ms,
    }


def main(argv):
    if len(argv) > 1:
        with open(argv[1], "r") as f:
            lines = f.readlines()
    else:
        lines = sys.stdin.readlines()

    cycles = parse_lines(lines)

    for i, cycle in enumerate(cycles, 1):
        s = summarize(cycle)
        latency = (
            f"{s['first_frame_latency_ms']}ms"
            if s["first_frame_latency_ms"] is not None
            else "n/a"
        )
        print(
            f"cycle {i} [{s['state']}]: "
            f"frames={s['frames']} duration={s['duration_ms']}ms "
            f"mean_gap={s['mean_gap_ms']:.2f}ms max_gap={s['max_gap_ms']}ms "
            f"gaps>9ms={s['gaps_over_9ms']} first_frame_latency={latency}"
        )

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
