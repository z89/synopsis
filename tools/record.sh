#!/usr/bin/env bash
# Record the live desktop for a bug report: a video of the focused monitor
# plus a timestamped Hyprland event log, anchored to wall-clock epoch ms so
# tools/sim/analyze.py --live can line them up against the shell log.
#
# Usage: tools/record.sh [--output NAME] [--seconds N] [--dir DIR]
#                         [--region "X,Y WxH"] [--shell|--no-shell]
#
#   --output NAME   label stored in meta.json (default: "bug")
#   --seconds N     stop automatically after N seconds instead of waiting
#                   for Enter
#   --dir DIR       recording directory (default: ~/synopsis-recordings/<ts>)
#   --region SPEC   capture only this region instead of the whole monitor,
#                   passed straight through to wf-recorder as -g, e.g.
#                   --region "1280,0 2560x1440"
#   --shell         manage the synopsis shell for you (default)
#   --no-shell      do not touch the shell; capture whatever is already
#                   running and rely on the journalctl slice or a manually
#                   copied shell.log
#
# Never run from an automated agent against a real desktop: this starts
# wf-recorder and a hyprctl socket listener against whatever is on screen,
# and by default it may terminate and restart a hand-started shell.
set -euo pipefail

OUTPUT_NAME="bug"
SECONDS_LIMIT=""
DIR=""
REGION=""
MANAGE_SHELL=1

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output) OUTPUT_NAME="$2"; shift 2 ;;
        --seconds) SECONDS_LIMIT="$2"; shift 2 ;;
        --dir) DIR="$2"; shift 2 ;;
        --region) REGION="$2"; shift 2 ;;
        --shell) MANAGE_SHELL=1; shift ;;
        --no-shell) MANAGE_SHELL=0; shift ;;
        -h|--help)
            sed -n '2,22p' "$0"
            exit 0
            ;;
        *) echo "unknown argument: $1" >&2; exit 1 ;;
    esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -z "$DIR" ]]; then
    DIR="$HOME/synopsis-recordings/$(date +%Y%m%d-%H%M%S)"
fi
mkdir -p "$DIR"
DIR="$(cd "$DIR" && pwd)"

: "${XDG_RUNTIME_DIR:?XDG_RUNTIME_DIR is not set}"
: "${HYPRLAND_INSTANCE_SIGNATURE:?not running inside a Hyprland session}"

SOCK2="$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock"
if [[ ! -S "$SOCK2" ]]; then
    echo "hyprland event socket not found: $SOCK2" >&2
    exit 1
fi

if ! command -v wf-recorder >/dev/null 2>&1; then
    echo "wf-recorder is required and was not found on PATH" >&2
    exit 1
fi

EVENT_PID=""
REC_PID=""

cleanup() {
    # only the processes this script itself started and owns for its whole
    # lifetime; a freshly started shell is deliberately left running
    if [[ -n "$EVENT_PID" ]] && kill -0 "$EVENT_PID" 2>/dev/null; then
        kill "$EVENT_PID" 2>/dev/null || true
        wait "$EVENT_PID" 2>/dev/null || true
    fi
    if [[ -n "$REC_PID" ]] && kill -0 "$REC_PID" 2>/dev/null; then
        kill -INT "$REC_PID" 2>/dev/null || true
        wait "$REC_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# --- meta.json: t0, output name, and the tool versions the analyzer wants ---
T0_EPOCH_MS="$(date +%s%3N)"
HYPRCTL_VERSION_JSON="$(hyprctl version -j 2>/dev/null || echo 'null')"
QS_VERSION="$(qs --version 2>&1 || true)"

python3 - "$DIR/meta.json" "$T0_EPOCH_MS" "$OUTPUT_NAME" "$HYPRCTL_VERSION_JSON" "$QS_VERSION" <<'PYEOF'
import json, sys
dest, t0, output_name, hv_json, qs_version = sys.argv[1:6]
try:
    hv = json.loads(hv_json)
except ValueError:
    hv = None
with open(dest, "w") as f:
    json.dump({
        "output": output_name,
        "t0_epoch_ms": int(t0),
        "hyprctl_version": hv,
        "qs_version": qs_version.strip(),
    }, f, indent=1)
PYEOF

# --- shell management: make sure a frame-logging shell is running ---
SHELL_PID=""
if [[ "$MANAGE_SHELL" -eq 1 ]]; then
    if systemctl --user is-active --quiet synopsis.service 2>/dev/null; then
        echo "synopsis.service is active: leaving it running, capturing its journal instead"
        CFG="$HOME/.config/synopsis/config.json"
        FRAMELOG_OK="$(python3 - "$CFG" <<'PYEOF'
import json, sys
path = sys.argv[1]
try:
    with open(path) as f:
        cfg = json.load(f)
    print("OK" if cfg.get("frameLog") is True else "MISSING")
except Exception:
    print("MISSING")
PYEOF
)"
        if [[ "$FRAMELOG_OK" != "OK" ]]; then
            echo "warning: $CFG does not have frame logging on; add this line:"
            echo '  "frameLog": true,'
            echo "and restart synopsis.service, or the shell log will have no frame timings."
        fi
    else
        EXISTING_PID="$(pgrep -f 'qs -c synopsis' | head -1 || true)"
        if [[ -n "$EXISTING_PID" ]]; then
            echo "found a hand-started shell (pid $EXISTING_PID), restarting it with frame logging on"
            kill "$EXISTING_PID" 2>/dev/null || true
            for _ in $(seq 1 20); do
                kill -0 "$EXISTING_PID" 2>/dev/null || break
                sleep 0.1
            done
        fi
        ( cd "$REPO_ROOT" && SYNOPSIS_FRAMELOG=1 setsid qs -c synopsis >"$DIR/shell.log" 2>&1 & )
        sleep 0.2
        SHELL_PID="$(pgrep -f 'qs -c synopsis' | head -1 || true)"
        for _ in $(seq 1 30); do
            grep -q '\[synopsis\]' "$DIR/shell.log" 2>/dev/null && break
            sleep 0.1
        done
        if [[ -n "$SHELL_PID" ]]; then
            echo "started synopsis shell (pid $SHELL_PID), logging to $DIR/shell.log"
            echo "it is left running after this script exits"
        else
            echo "warning: could not confirm the shell started; check $DIR/shell.log"
        fi
    fi
else
    echo "not managing the shell (--no-shell); relying on journalctl or a hand-copied shell.log"
fi

# --- event logger: every socket2 line, prefixed with epoch ms ---
python3 - "$SOCK2" "$DIR/events.log" <<'PYEOF' &
import socket, sys, time

sock_path, dest = sys.argv[1], sys.argv[2]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sock_path)
with open(dest, "w", buffering=1) as out:
    buf = b""
    while True:
        chunk = s.recv(4096)
        if not chunk:
            break
        buf += chunk
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            if not line:
                continue
            out.write("%d %s\n" % (int(time.time() * 1000), line.decode(errors="replace")))
PYEOF
EVENT_PID=$!

# --- pick the focused monitor and its refresh rate (nearest int, cap 120) ---
MON_INFO="$(hyprctl monitors -j | python3 -c '
import json, sys
mons = json.load(sys.stdin)
m = next((m for m in mons if m.get("focused")), mons[0] if mons else None)
if m is None:
    sys.exit(1)
rate = round(float(m.get("refreshRate", 60)))
rate = max(1, min(rate, 120))
print(m["name"])
print(rate)
')"
MON_NAME="$(echo "$MON_INFO" | sed -n 1p)"
MON_RATE="$(echo "$MON_INFO" | sed -n 2p)"

if [[ -z "$MON_NAME" ]]; then
    echo "could not determine the focused monitor from hyprctl monitors -j" >&2
    exit 1
fi

# --- start wf-recorder ---
WF_LOG="$DIR/wf-recorder.log"
WF_ARGS=(-o "$MON_NAME" -r "$MON_RATE"
         -c libx264 -p preset=ultrafast -p crf=14 -p tune=zerolatency
         -f "$DIR/desktop.mkv")
if [[ -n "$REGION" ]]; then
    WF_ARGS=(-g "$REGION" "${WF_ARGS[@]}")
fi
set +e
wf-recorder "${WF_ARGS[@]}" >"$WF_LOG" 2>&1 &
REC_PID=$!
sleep 0.7
if ! kill -0 "$REC_PID" 2>/dev/null; then
    echo "wf-recorder exited immediately, see $WF_LOG" >&2
    exit 1
fi
set -e

echo "recording focused monitor $MON_NAME at ${MON_RATE}fps -> $DIR/desktop.mkv"
if [[ -n "$REGION" ]]; then
    echo "region: $REGION"
fi
echo

if [[ -n "$SECONDS_LIMIT" ]]; then
    echo "recording for ${SECONDS_LIMIT}s..."
    sleep "$SECONDS_LIMIT"
else
    echo "recording, press Enter to stop"
    read -r _ || true
fi

if [[ -n "$REC_PID" ]] && kill -0 "$REC_PID" 2>/dev/null; then
    kill -INT "$REC_PID" 2>/dev/null || true
    wait "$REC_PID" 2>/dev/null || true
fi
REC_PID=""

T_STOP_EPOCH_MS="$(date +%s%3N)"
python3 - "$DIR/meta.json" "$T_STOP_EPOCH_MS" <<'PYEOF'
import json, sys
dest, t_stop = sys.argv[1], sys.argv[2]
with open(dest) as f:
    meta = json.load(f)
meta["t_stop_epoch_ms"] = int(t_stop)
with open(dest, "w") as f:
    json.dump(meta, f, indent=1)
PYEOF

if [[ -n "$EVENT_PID" ]] && kill -0 "$EVENT_PID" 2>/dev/null; then
    kill "$EVENT_PID" 2>/dev/null || true
    wait "$EVENT_PID" 2>/dev/null || true
fi
EVENT_PID=""

# --- pull the matching slice of the systemd shell log, if there is one ---
if command -v journalctl >/dev/null 2>&1 \
    && journalctl --user -u synopsis.service --since "@$((T0_EPOCH_MS / 1000))" \
        --no-pager -q 2>/dev/null | head -1 | grep -q .; then
    journalctl --user -u synopsis.service --since "@$((T0_EPOCH_MS / 1000))" \
        --until "@$((T_STOP_EPOCH_MS / 1000 + 1))" --no-pager -q \
        > "$DIR/shell.log" 2>/dev/null || true
    echo "saved journalctl slice for synopsis.service to $DIR/shell.log"
elif [[ -s "$DIR/shell.log" ]]; then
    echo "shell log already captured at $DIR/shell.log"
else
    echo "no synopsis.service journal entries found in the recording window;"
    echo "if you ran a hand-started shell, copy its tee'd log to $DIR/shell.log"
fi

if [[ -n "$SHELL_PID" ]]; then
    echo "the synopsis shell (pid $SHELL_PID) is still running; stop it yourself when done"
fi

echo
echo "$DIR"
echo "python3 tools/sim/analyze.py --live '$DIR'"
echo "send Claude the directory path plus when the glitch happens in the clip"
