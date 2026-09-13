#!/usr/bin/env bash
# synopsis headless simulator: start a nested session, drive it, analyze it.
#
# Nothing here touches the live Hyprland session. A headless PARENT compositor
# is started first (cage by default, weston if it is installed), and Hyprland is
# nested inside it as a plain Wayland client: aquamarine 0.15 has no GPU
# allocator without a DRM or Wayland parent, so a pure headless Hyprland aborts
# with "no allocator available".
#
#   run.sh [--scenario NAME|all] [--w N] [--h N] [--seed N] [--keep] [--out DIR]
#          [--parent cage|weston] [--force-size] [--no-analyze]
#
# Defaults: --scenario all, 1280x720 (cage's fixed headless output size),
#           --out tools/sim/out/<timestamp>.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SIM="$REPO/tools/sim"

SCENARIO="all"
SIM_W=1280
SIM_H=720
SEED=0
KEEP=0
FORCE_SIZE=0
ANALYZE=1
PARENT="auto"
OUT=""

die()  { printf '%s\n' "run.sh: $*" >&2; exit 1; }
note() { printf '%s\n' "[run] $*" >&2; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --scenario) SCENARIO="${2:?}"; shift 2 ;;
        --w)        SIM_W="${2:?}"; shift 2 ;;
        --h)        SIM_H="${2:?}"; shift 2 ;;
        --seed)     SEED="${2:?}"; shift 2 ;;
        --out)      OUT="${2:?}"; shift 2 ;;
        --parent)   PARENT="${2:?}"; shift 2 ;;
        --keep)     KEEP=1; shift ;;
        --force-size) FORCE_SIZE=1; shift ;;
        --no-analyze) ANALYZE=0; shift ;;
        -h|--help)  sed -n '2,16p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) die "unknown option: $1" ;;
    esac
done

[[ -n "$OUT" ]] || OUT="$SIM/out/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

# ---------------------------------------------------------------- preflight --

have() { command -v "$1" >/dev/null 2>&1; }

[[ -n "${XDG_RUNTIME_DIR:-}" ]] || die "XDG_RUNTIME_DIR is unset; cannot find hyprland sockets"
[[ -d "$REPO/shell" ]] || die "no shell/ directory in $REPO"

for b in Hyprland qs python3 ffmpeg ffprobe kitty; do
    have "$b" || die "required binary not found: $b"
done
have wf-recorder || note "WARNING: wf-recorder not found; scenarios will run without video and the analyzer will report 'no recording'"
have mpv || note "WARNING: mpv not found; the video fixture window will be missing"

if [[ "$PARENT" == "auto" ]]; then
    if [[ -x "${CAGE_BIN:-$SIM/.cache/cage/cage}" ]]; then PARENT="cage"
    elif have weston; then PARENT="weston"
    else die "no headless parent compositor found: install cage (preferred here) or weston"
    fi
fi
have "$PARENT" || die "parent compositor '$PARENT' is not installed"

if [[ "$PARENT" == "cage" && ( "$SIM_W" != 1280 || "$SIM_H" != 720 ) && $FORCE_SIZE -eq 0 ]]; then
    note "cage's headless output is fixed at 1280x720; overriding ${SIM_W}x${SIM_H} (use --force-size to keep it)"
    SIM_W=1280; SIM_H=720
fi

# --------------------------------------------------------------- safety net --

LIVE_SIG="${HYPRLAND_INSTANCE_SIGNATURE:-}"
LIVE_WL="${WAYLAND_DISPLAY:-}"
export SIM_LIVE_SIGNATURE="$LIVE_SIG"
export SIM_LIVE_WAYLAND_DISPLAY="$LIVE_WL"

PRE_INSTANCES="$(cd "$XDG_RUNTIME_DIR/hypr" 2>/dev/null && ls -1 | tr '\n' ' ' || true)"
PRE_SOCKETS="$(cd "$XDG_RUNTIME_DIR" && ls -1 | grep -E '^wayland-[0-9]+$' | tr '\n' ' ' || true)"

PIDS=()
cleanup() {
    local rc=$?
    if [[ $KEEP -eq 1 ]]; then
        note "--keep: leaving the nested session up. Kill it with:"
        note "  kill -TERM ${PIDS[*]:-} 2>/dev/null"
        exit $rc
    fi
    local p
    for p in "${PIDS[@]:-}"; do
        [[ -n "$p" ]] || continue
        # each tracked process was started with setsid, so its pgid == its pid:
        # this kills the nested session's own process group and nothing else
        kill -TERM "-$p" 2>/dev/null || kill -TERM "$p" 2>/dev/null || true
    done
    sleep 0.5
    for p in "${PIDS[@]:-}"; do
        [[ -n "$p" ]] || continue
        kill -KILL "-$p" 2>/dev/null || true
    done
    exit $rc
}
trap cleanup EXIT INT TERM

# ------------------------------------------------------------ start session --

HYPR_LOG="$OUT/hyprland.log"
QS_LOG="$OUT/qs.log"
: > "$HYPR_LOG"
: > "$QS_LOG"

export SYNOPSIS_REPO="$REPO"
export SIM_W SIM_H

# HYPRLAND_NO_SD_VARS is essential: without it the nested Hyprland runs
# "systemctl --user import-environment WAYLAND_DISPLAY HYPRLAND_INSTANCE_SIGNATURE …"
# at startup and would repoint the LIVE session's systemd/dbus environment at
# the nested instance.
NESTED_ENV=(
    env
    -u DISPLAY
    -u HYPRLAND_INSTANCE_SIGNATURE
    HYPRLAND_NO_SD_VARS=1
    SYNOPSIS_REPO="$REPO"
    SIM_W="$SIM_W" SIM_H="$SIM_H"
    XDG_CURRENT_DESKTOP=Hyprland
)

HYPR_CMD=(Hyprland -c "$SIM/hyprland.lua")

note "parent=$PARENT  size=${SIM_W}x${SIM_H}  out=$OUT"

if [[ "$PARENT" == "weston" ]]; then
    setsid weston --backend=headless --renderer=gl \
        --width="$SIM_W" --height="$SIM_H" \
        --shell=kiosk-shell.so --socket=synopsis-sim-parent \
        >"$OUT/parent.log" 2>&1 &
    PARENT_PID=$!
    PIDS+=("$PARENT_PID")
    for _ in $(seq 1 100); do
        [[ -S "$XDG_RUNTIME_DIR/synopsis-sim-parent" ]] && break
        sleep 0.1
    done
    [[ -S "$XDG_RUNTIME_DIR/synopsis-sim-parent" ]] || die "weston never created its socket (see $OUT/parent.log)"
    setsid "${NESTED_ENV[@]}" WAYLAND_DISPLAY=synopsis-sim-parent \
        "${HYPR_CMD[@]}" >>"$HYPR_LOG" 2>&1 &
    NEST_PID=$!
    PIDS+=("$NEST_PID")
else
    # cage runs exactly one client and fullscreens it: the client is Hyprland,
    # and cage hands it WAYLAND_DISPLAY itself. Its headless output is 1280x720.
    setsid env WLR_BACKENDS=headless WLR_RENDERER=gles2 WLR_SCENE_DISABLE_DIRECT_SCANOUT=1 \
        WLR_RENDER_DRM_DEVICE="${WLR_RENDER_DRM_DEVICE:-/dev/dri/renderD128}" \
        WLR_LIBINPUT_NO_DEVICES=1 \
        "${CAGE_BIN:-$SIM/.cache/cage/cage}" -- "${NESTED_ENV[@]}" "${HYPR_CMD[@]}" \
        >>"$HYPR_LOG" 2>&1 &
    NEST_PID=$!
    PIDS+=("$NEST_PID")
fi

# --------------------------------------------- discover the nested instance --
# Hyprland buffers its log, so the signature and display are found from what
# appeared under $XDG_RUNTIME_DIR after the launch: a new instance directory
# whose request socket answers, and a new wayland-N socket that is neither the
# live display nor the parent's own.

SIG=""
NEST_WL=""
PARENT_WL=""
for _ in $(seq 1 300); do
    if [[ -z "$PARENT_WL" ]]; then
        PARENT_WL="$(grep -ao 'running on Wayland display [^ ]*' "$HYPR_LOG" 2>/dev/null | tail -1 | awk '{print $5}' || true)"
    fi
    if [[ -z "$SIG" ]]; then
        for d in "$XDG_RUNTIME_DIR"/hypr/*/; do
            d="${d%/}"; n="${d##*/}"
            [[ " $PRE_INSTANCES " == *" $n "* ]] && continue
            [[ -S "$d/.socket.sock" ]] || continue
            SIG="$n"
        done
    fi
    if [[ -z "$NEST_WL" ]]; then
        for sck in "$XDG_RUNTIME_DIR"/wayland-[0-9]*; do
            [[ -S "$sck" ]] || continue
            n="${sck##*/}"
            [[ " $PRE_SOCKETS " == *" $n "* ]] && continue
            [[ "$n" == "$PARENT_WL" ]] && continue
            NEST_WL="$n"
        done
    fi
    [[ -n "$SIG" && -n "$NEST_WL" ]] && break
    kill -0 "$NEST_PID" 2>/dev/null || die "the nested Hyprland exited early (see $HYPR_LOG)"
    sleep 0.1
done

[[ -n "$SIG" ]] || die "could not determine the nested instance signature (see $HYPR_LOG)"
[[ "$SIG" != "$LIVE_SIG" ]] || die "REFUSING TO CONTINUE: discovered signature equals the LIVE session ($SIG)"
[[ -z "$NEST_WL" || "$NEST_WL" != "$LIVE_WL" ]] || die "REFUSING TO CONTINUE: nested WAYLAND_DISPLAY equals the live one ($NEST_WL)"
[[ -n "$NEST_WL" ]] || die "could not determine the nested WAYLAND_DISPLAY (see $HYPR_LOG)"

SOCK="$XDG_RUNTIME_DIR/hypr/$SIG/.socket.sock"
for _ in $(seq 1 200); do
    if python3 - "$SOCK" <<'PY'
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.settimeout(1.0)
try:
    s.connect(sys.argv[1]); s.sendall(b"j/version")
    sys.exit(0 if s.recv(64) else 1)
except OSError:
    sys.exit(1)
PY
    then break; fi
    sleep 0.1
done
note "nested instance: sig=$SIG display=$NEST_WL"

# the nested instance must own exactly the simulated output. If this ever fails
# the session did not nest the way it should have; stop rather than drive it.
python3 - "$SOCK" <<'MON' || die "nested hyprland is not presenting WAYLAND-1 (see $HYPR_LOG)"
import json, socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.settimeout(2.0)
s.connect(sys.argv[1]); s.sendall(b"j/monitors")
buf = b""
while True:
    chunk = s.recv(65536)
    if not chunk:
        break
    buf += chunk
mons = json.loads(buf.decode())
names = [m.get("name") for m in mons]
print("[run] nested monitors: %s" % names, file=sys.stderr)
sys.exit(0 if names == ["WAYLAND-1"] else 1)
MON

# -------------------------------------------------------------- start shell --

# `qs -c synopsis` would reuse the live instance's config name; the path form
# keeps this a distinct instance. Override with QS_ARGS if you need the -c form.
QS_ARGS="${QS_ARGS:--p $REPO/shell}"

# the desktop behind the overview: the same wallpaper the backdrop paints, so
# the backdrop mapping is invisible here just as it is on the real desktop
SIM_WALLPAPER="${SIM_WALLPAPER:-$(python3 -c 'import json,os,sys
try: print(json.load(open(os.path.expanduser("~/.local/state/DankMaterialShell/session.json"))).get("wallpaperPath",""))
except Exception: print("")' 2>/dev/null)}"
if [[ -n "$SIM_WALLPAPER" && -r "$SIM_WALLPAPER" ]]; then
    setsid env WAYLAND_DISPLAY="$NEST_WL" HYPRLAND_INSTANCE_SIGNATURE="$SIG" \
        HYPRLAND_NO_SD_VARS=1 SIM_WALLPAPER="$SIM_WALLPAPER" QT_QPA_PLATFORM=wayland \
        qs -p "$SIM/wallpaper" >>"$OUT/wallpaper.log" 2>&1 &
    PIDS+=("$!")
    note "wallpaper: $SIM_WALLPAPER"
else
    note "no wallpaper found (SIM_WALLPAPER unset); the backdrop will show as a cut in recordings"
fi
# shellcheck disable=SC2086
# SIM_QS_ENV adds NAME=VALUE pairs to the shell's environment, e.g.
# SIM_QS_ENV="WAYLAND_DEBUG=client" to trace the layer-surface protocol
# shellcheck disable=SC2086
setsid env WAYLAND_DISPLAY="$NEST_WL" HYPRLAND_INSTANCE_SIGNATURE="$SIG" \
    HYPRLAND_NO_SD_VARS=1 SYNOPSIS_FRAMELOG=1 SYNOPSIS_REPO="$REPO" \
    QT_QPA_PLATFORM=wayland ${SIM_QS_ENV:-} \
    qs $QS_ARGS >>"$QS_LOG" 2>&1 &
QS_PID=$!
PIDS+=("$QS_PID")
sleep 2
kill -0 "$QS_PID" 2>/dev/null || die "qs exited immediately (see $QS_LOG)"

cat > "$OUT/env" <<EOF
XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR
WAYLAND_DISPLAY=$NEST_WL
HYPRLAND_INSTANCE_SIGNATURE=$SIG
HYPRLAND_NO_SD_VARS=1
SYNOPSIS_REPO=$REPO
SIM_W=$SIM_W
SIM_H=$SIM_H
QS_LOG=$QS_LOG
QS_PID=$QS_PID
PARENT=$PARENT
PARENT_WL=${PARENT_WL:-synopsis-sim-parent}
EOF

# ------------------------------------------------------------------- drive ---

set +e
python3 "$SIM/driver.py" --scenario "$SCENARIO" --out "$OUT" --seed "$SEED"
DRIVER_RC=$?
set -e
[[ $DRIVER_RC -eq 0 ]] || note "driver exited $DRIVER_RC (assertion failures are reported in report.md)"

ANALYZE_RC=0
if [[ $ANALYZE -eq 1 ]]; then
    set +e
    python3 "$SIM/analyze.py" --out "$OUT"
    ANALYZE_RC=$?
    set -e
fi

note "report:  $OUT/report.md"
note "json:    $OUT/report.json"
note "logs:    $QS_LOG  $HYPR_LOG"

if [[ $DRIVER_RC -ne 0 || $ANALYZE_RC -ne 0 ]]; then
    exit 1
fi
exit 0
