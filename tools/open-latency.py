#!/usr/bin/env python3
"""Per-open latency table from the synopsis frame log (journal lines).

Splits the log at `prepare begin`, collects prepare/flight/video/cover
figures per open (max across monitors) and prints a table or JSON.
"""
import argparse
import json
import re
import statistics
import sys

ANSI = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
LINE = re.compile(r"\[synopsis\] (\d+) (.*)")
KV = re.compile(r"(\w+)=(\d+)")


def mx(d, k, v):
    d[k] = max(d.get(k, v), v)


def parse(lines):
    opens, cur = [], None
    for raw in lines:
        m = LINE.search(ANSI.sub("", raw))
        if not m:
            continue
        ts, msg = int(m.group(1)), m.group(2).strip()
        if msg.startswith("prepare begin"):
            cur = {"begin": ts, "cancelled": False}
            opens.append(cur)
        elif cur is None:
            continue
        elif msg.startswith("cancel prepare"):
            cur["cancelled"] = True
            cur = None
        elif msg.startswith("prepare breakdown"):
            kv = {k: int(v) for k, v in KV.findall(msg)}
            for k in ("total", "refresh", "gate"):
                if k in kv:
                    mx(cur, k, kv[k])
        elif msg.startswith("keyboard exclusive after backdrop"):
            if "flight" not in cur:
                cur["flight"] = ts - cur["begin"]
                cur["source"] = "timer" if msg.endswith("timer") else "frame"
        elif re.match(r"video \S+ seek", msg):
            m2 = re.search(r"latency (\d+)", msg)
            if m2:
                mx(cur, "seek", int(m2.group(1)))
            m2 = re.search(r"wait (\d+)", msg)
            if m2:
                mx(cur, "wait", int(m2.group(1)))
        elif re.match(r"cover \S+ ack top true", msg):
            m2 = re.search(r"after (\d+) ms", msg)
            if m2:
                mx(cur, "cover_ack", int(m2.group(1)))
        elif re.match(r"cover \S+ fallback still", msg):
            cur["fallback"] = True
    return opens


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="usage: open-latency.py [--json] LOG|-   (use - for stdin)")
    ap.add_argument("log", help="log file path, or - for stdin")
    ap.add_argument("--json", action="store_true", help="print JSON")
    a = ap.parse_args()
    f = sys.stdin if a.log == "-" else open(a.log, errors="replace")
    opens = parse(f)
    done = [o for o in opens if not o["cancelled"]]
    cancelled = len(opens) - len(done)
    fl = [o["flight"] for o in done if "flight" in o]
    summ = {"opens": len(done), "cancelled": cancelled}
    if fl:
        summ.update(flight_min=min(fl), flight_median=statistics.median(fl), flight_max=max(fl))
    rows = [{"index": i + 1, "total": o.get("total"), "refresh": o.get("refresh"),
             "gate": o.get("gate"), "flight_start_ms": o.get("flight"),
             "source": o.get("source"), "video_seek_ms": o.get("seek"),
             "video_wait_ms": o.get("wait"), "cover_ack_ms": o.get("cover_ack"),
             "fallback": bool(o.get("fallback"))} for i, o in enumerate(done)]
    if a.json:
        print(json.dumps({"rows": rows, "summary": summ}, indent=2))
        return
    if not done:
        print("no opens found" + (f" ({cancelled} cancelled)" if cancelled else ""))
        return
    s = lambda v: "-" if v is None else str(v)
    hdr = ["#", "total", "refresh", "gate", "flight", "src", "seek", "wait", "cover", "fallback"]
    tab = [hdr] + [[str(r["index"]), s(r["total"]), s(r["refresh"]), s(r["gate"]),
                    s(r["flight_start_ms"]), s(r["source"]), s(r["video_seek_ms"]),
                    s(r["video_wait_ms"]), s(r["cover_ack_ms"]),
                    "yes" if r["fallback"] else "-"] for r in rows]
    w = [max(len(r[i]) for r in tab) for i in range(len(hdr))]
    for r in tab:
        print("  ".join(c.rjust(w[i]) for i, c in enumerate(r)))
    line = f"opens {len(done)}  cancelled {cancelled}"
    if fl:
        line += f"  flight start ms min {min(fl)} / median {statistics.median(fl):g} / max {max(fl)}"
    print(line)


if __name__ == "__main__":
    main()
