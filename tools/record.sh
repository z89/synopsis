#!/usr/bin/env bash
# Record the live desktop for a bug report: a video of the focused monitor
# plus a timestamped Hyprland event log, anchored to wall-clock epoch ms so
# tools/sim/analyze.py --live can line them up against the shell log.
#
# Usage: tools/record.sh [--output NAME] [--seconds N] [--dir DIR]
#                        [--region "X,Y WxH"] [--shell|--no-shell]
#                        [--keep-screen-share]
#                        [--codec auto|vaapi|nvenc|x264|ENCODER]
#                        [--device PATH] [--qp N] [--fps N]
#                        [--pixfmt FMT] [--no-dmabuf] [--no-quality-check]
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
#   --keep-screen-share
#                   leave hypr/synopsis.lua's no_screen_share = true alone.
#                   The overlay is then blacked out in the recording, which
#                   is almost never what you want; see below.
#   --codec WHICH   auto (default) uses a GPU encoder whenever there is a
#                   render node and libavcodec can actually open the encoder
#                   at this capture size; vaapi and nvenc force hardware and
#                   fail loudly if it does not work; x264 (or software)
#                   forces libx264. An explicit encoder name (hevc_vaapi,
#                   h264_vaapi, h264_nvenc, libx264 ...) is used as given.
#   --device PATH   render node for the hardware encoder (default:
#                   /dev/dri/renderD128, else the first /dev/dri/renderD*)
#   --qp N          hardware encoder quality, lower is better (default 18)
#   --fps N         force a CONSTANT frame rate of N. wf-recorder then adds
#                   an `fps=N` filter, which pads still periods with
#                   duplicate frames and throws away updates that arrive
#                   faster than N. Only use this if something downstream
#                   cannot read variable frame rate video; the analyzer can.
#   --pixfmt FMT    wf-recorder -x; try `--pixfmt yuv420p` if a hardware
#                   capture comes out green, striped or corrupted
#   --no-dmabuf     pass wf-recorder --no-dmabuf (forces a CPU copy of every
#                   frame; only needed if the GPU path glitches)
#   --no-quality-check
#                   skip the post-run frame-count measurement
#
# FRAME RATE. Nothing is forced by default. wf-recorder asks the compositor
# for a frame only when the screen actually changes, so desktop.mkv is
# VARIABLE frame rate: a frame's pts is the moment that content appeared and
# there are no duplicate frames. Anything reading the video must use pts, not
# frame_index / fps. The "nominal" fps printed when the capture starts is
# only the reference the quality check compares against: min(refresh, 120)
# with a hardware encoder, min(refresh, 60) for software encoding of a
# capture wider than 3000 px.
#
# ENCODER. Software encoding of a 5120x1440 output is the reason earlier
# recordings showed 4-15 real updates per second and felt laggy: libx264 at
# that size saturates the CPU and starves the compositor. With a VAAPI or
# NVENC encoder the frames stay on the GPU (wf-recorder uses dma-buf) and the
# compositor keeps its CPU. Note that VAAPI H.264 on AMD tops out at 4096 px
# wide, so a 5120 px capture picks hevc_vaapi; the probe below is what
# decides, not a guess.
#
# hypr/synopsis.lua declares the `synopsis` and `synopsis-backdrop` layer
# rules with no_screen_share = true, and Hyprland's screencopy paints a black
# rectangle over any such layer (ScreenshareFrame.cpp), so wf-recorder would
# record the overview as a black screen. Before the capture this script
# re-declares both rules with no_screen_share = false via `hyprctl eval`
# (re-declaring by name reuses the same rule object and the later value of an
# effect wins, LuaBindingsConfigRules.cpp hlLayerRule), and it restores the
# rules exactly as synopsis.lua declares them afterwards, including on abort.
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
SCREEN_SHARE_FIX=1
CODEC_MODE="auto"
DEVICE=""
QP=18
FPS_FORCE=""
PIXFMT=""
NO_DMABUF=0
QUALITY_CHECK=1

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output) OUTPUT_NAME="$2"; shift 2 ;;
        --seconds) SECONDS_LIMIT="$2"; shift 2 ;;
        --dir) DIR="$2"; shift 2 ;;
        --region) REGION="$2"; shift 2 ;;
        --shell) MANAGE_SHELL=1; shift ;;
        --no-shell) MANAGE_SHELL=0; shift ;;
        --keep-screen-share) SCREEN_SHARE_FIX=0; shift ;;
        --codec) CODEC_MODE="$2"; shift 2 ;;
        --device) DEVICE="$2"; shift 2 ;;
        --qp) QP="$2"; shift 2 ;;
        --fps) FPS_FORCE="$2"; shift 2 ;;
        --pixfmt) PIXFMT="$2"; shift 2 ;;
        --no-dmabuf) NO_DMABUF=1; shift ;;
        --no-quality-check) QUALITY_CHECK=0; shift ;;
        -h|--help)
            awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
            exit 0
            ;;
        *) echo "unknown argument: $1" >&2; exit 1 ;;
    esac
done

for n in "$QP" ${FPS_FORCE:+"$FPS_FORCE"}; do
    [[ "$n" =~ ^[0-9]+$ ]] || { echo "--qp / --fps want a number, got: $n" >&2; exit 1; }
done

# Every encoder name libavcodec knows, one per line; fails when there is no
# ffmpeg binary to ask.
ffmpeg_encoders() {
    command -v ffmpeg >/dev/null 2>&1 || return 1
    ffmpeg -hide_banner -encoders 2>/dev/null | awk 'NF >= 2 { print $2 }'
}

have_encoder() {            # $1 = libavcodec encoder name
    # with no ffmpeg binary there is nothing to ask, so say yes and let the
    # probe report "cannot verify" instead of silently skipping every codec
    local list
    list="$(ffmpeg_encoders)" || return 0
    printf '%s\n' "$list" | grep -qxF -- "$1"
}

# Resolved and verified here, before anything touches the session: the
# size-specific probe only runs once the capture geometry is known, and by
# then the shell has been restarted, so `--codec h264_vappi` used to kill the
# shell and fail afterwards. Nothing above this point has created a
# directory, started a process or changed a layer rule, so every exit below
# leaves the session exactly as it was.
case "$CODEC_MODE" in
    auto)          CODEC_NAMES=(h264_nvenc hevc_nvenc h264_vaapi hevc_vaapi libx264) ;;
    vaapi)         CODEC_NAMES=(h264_vaapi hevc_vaapi) ;;
    nvenc)         CODEC_NAMES=(h264_nvenc hevc_nvenc) ;;
    x264|software) CODEC_NAMES=(libx264) ;;
    "")            echo "--codec wants a value (auto|vaapi|nvenc|x264|<encoder name>)" >&2; exit 1 ;;
    *)             CODEC_NAMES=("$CODEC_MODE") ;;
esac

if ENCODER_LIST="$(ffmpeg_encoders)"; then
    CODEC_OK=0
    for name in "${CODEC_NAMES[@]}"; do
        if printf '%s\n' "$ENCODER_LIST" | grep -qxF -- "$name"; then
            CODEC_OK=1
            break
        fi
    done
    if [[ "$CODEC_OK" -ne 1 ]]; then
        if [[ "$CODEC_MODE" == "auto" ]]; then
            echo "this ffmpeg has none of the encoders --codec auto can use (${CODEC_NAMES[*]});" >&2
            echo "  install one, or name an encoder that exists: ffmpeg -hide_banner -encoders" >&2
        else
            echo "unknown --codec '$CODEC_MODE': this ffmpeg has no encoder named ${CODEC_NAMES[*]}" >&2
            echo "  list the ones it does have with: ffmpeg -hide_banner -encoders" >&2
        fi
        exit 1
    fi
else
    # no ffmpeg to check the name against: fall back to the shape of the name
    case "$CODEC_MODE" in
        auto|vaapi|nvenc|x264|software|lib*|*_*) ;;
        *) echo "unknown --codec '$CODEC_MODE' (auto|vaapi|nvenc|x264|<encoder name>)" >&2; exit 1 ;;
    esac
    if [[ "$CODEC_MODE" != "auto" ]]; then
        echo "warning: no ffmpeg binary to check --codec '$CODEC_MODE' against; it cannot be" >&2
        echo "  verified before the recording starts" >&2
    fi
fi

# same trap, one step further along: a vaapi encoder without a render node
# fails in the probe, which only runs after the shell has been restarted
case "$CODEC_MODE" in
    vaapi|*vaapi*)
        if [[ -n "$DEVICE" && ! -e "$DEVICE" ]]; then
            echo "--device '$DEVICE' does not exist" >&2
            exit 1
        fi
        if [[ -z "$DEVICE" ]] && ! ls /dev/dri/renderD* >/dev/null 2>&1; then
            echo "--codec $CODEC_MODE needs a DRM render node and /dev/dri has none" >&2
            echo "  (pass --device PATH, or use --codec x264 for the CPU encoder)" >&2
            exit 1
        fi
        ;;
esac

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

# Last exit before anything is created: every check above leaves the session
# and the filesystem untouched, so no empty recording directory is left
# behind by an early failure.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -z "$DIR" ]]; then
    DIR="$HOME/synopsis-recordings/$(date +%Y%m%d-%H%M%S)"
fi
mkdir -p "$DIR"
DIR="$(cd "$DIR" && pwd)"

EVENT_PID=""
REC_PID=""
SCREEN_SHARE_PATCHED=0
PROBE_DIR=""

# The two layer rules hypr/synopsis.lua declares, written out exactly as that
# file writes them apart from the no_screen_share value. hl.layer_rule looks
# the rule up by name (CConfigManager::m_luaLayerRules) and reuses the same
# rule object when it finds one, so this re-declaration edits the live rules
# rather than adding new ones; the match is repeated so that the rules are
# still namespace-scoped even if the name is not known (after a config reload,
# say), and so a restore can never widen them to every layer.
layer_rule_lua() {          # $1 = rule name, $2 = true|false, $3 = extra fields
    printf 'hl.layer_rule({ name = "%s", match = { namespace = "^%s$" }, no_anim = true, no_screen_share = %s%s })' \
        "$1" "$1" "$2" "$3"
}

# Returns non-zero when hyprctl did not answer "ok" for both rules.
set_no_screen_share() {     # $1 = true|false
    local value="$1" spec name extra out rc=0
    for spec in "synopsis|" "synopsis-backdrop|, order = 1"; do
        name="${spec%%|*}"
        extra="${spec#*|}"
        out="$(hyprctl eval "$(layer_rule_lua "$name" "$value" "$extra")" 2>&1 || true)"
        if [[ "$out" != "ok" ]]; then
            echo "warning: hyprctl eval for layer rule $name: ${out:-no reply}" >&2
            rc=1
        fi
    done
    return "$rc"
}

restore_screen_share() {
    [[ "$SCREEN_SHARE_PATCHED" -eq 1 ]] || return 0
    SCREEN_SHARE_PATCHED=0
    if set_no_screen_share true; then
        echo "screen share: restored no_screen_share = true on the synopsis and synopsis-backdrop layer rules"
        echo "  (Hyprland only re-applies a layer rule when the layer maps: if the overlay is open right now," \
             "it stays capturable until it is closed once, even though the rule is restored)"
    else
        echo "warning: could not restore no_screen_share; the overview is capturable until you run:" >&2
        echo "  hyprctl reload" >&2
    fi
}

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
    [[ -n "$PROBE_DIR" && -d "$PROBE_DIR" ]] && rm -rf "$PROBE_DIR"
    # an abort must never leave the overlay capturable
    restore_screen_share
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

# merge extra keys into meta.json; each argument is key=<json or bare string>
meta_update() {
    python3 - "$DIR/meta.json" "$@" <<'PYEOF'
import json, sys
dest = sys.argv[1]
with open(dest) as f:
    meta = json.load(f)
for arg in sys.argv[2:]:
    key, _, value = arg.partition("=")
    try:
        meta[key] = json.loads(value)
    except ValueError:
        meta[key] = value
with open(dest, "w") as f:
    json.dump(meta, f, indent=1)
PYEOF
}

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

# --- focused monitor: name, refresh rate, and the pixel size it captures ---
MON_INFO="$(hyprctl monitors -j | python3 -c '
import json, sys
mons = json.load(sys.stdin)
m = next((m for m in mons if m.get("focused")), mons[0] if mons else None)
if m is None:
    sys.exit(1)
rate = max(1, round(float(m.get("refreshRate", 60))))
w, h = int(m.get("width", 0)), int(m.get("height", 0))
if int(m.get("transform", 0)) % 2:
    w, h = h, w
print(m["name"])
print(rate)
print(w)
print(h)
')"
MON_NAME="$(echo "$MON_INFO" | sed -n 1p)"
MON_RATE="$(echo "$MON_INFO" | sed -n 2p)"
CAP_W="$(echo "$MON_INFO" | sed -n 3p)"
CAP_H="$(echo "$MON_INFO" | sed -n 4p)"

if [[ -z "$MON_NAME" ]]; then
    echo "could not determine the focused monitor from hyprctl monitors -j" >&2
    exit 1
fi

# a region overrides the capture size the encoder has to cope with
if [[ -n "$REGION" ]]; then
    RSIZE="${REGION##* }"
    RW="${RSIZE%%x*}"
    RH="${RSIZE##*x}"
    if [[ "$RW" =~ ^[0-9]+$ && "$RH" =~ ^[0-9]+$ ]]; then
        CAP_W="$RW"
        CAP_H="$RH"
    else
        echo "warning: could not read a WxH out of --region '$REGION'; using the monitor size for the encoder probe" >&2
    fi
fi
[[ "$CAP_W" =~ ^[0-9]+$ && "$CAP_W" -gt 0 ]] || CAP_W=1920
[[ "$CAP_H" =~ ^[0-9]+$ && "$CAP_H" -gt 0 ]] || CAP_H=1080

# --- pick an encoder -------------------------------------------------------
# The probe is the whole point: VAAPI H.264 on this GPU family refuses
# anything wider than 4096 px, and the failure mode inside wf-recorder is an
# immediate exit with a useless message, so ask libavcodec first.
GPU_VENDOR="unknown"
if command -v lspci >/dev/null 2>&1; then
    GPU_LINE="$(lspci 2>/dev/null | grep -iE 'vga|3d controller|display controller' | head -3 || true)"
    case "${GPU_LINE,,}" in
        *nvidia*) GPU_VENDOR="nvidia" ;;
        *amd*|*ati*|*radeon*) GPU_VENDOR="amd" ;;
        *intel*) GPU_VENDOR="intel" ;;
    esac
fi

if [[ -z "$DEVICE" ]]; then
    if [[ -e /dev/dri/renderD128 ]]; then
        DEVICE="/dev/dri/renderD128"
    else
        DEVICE="$(ls /dev/dri/renderD* 2>/dev/null | head -1 || true)"
    fi
fi

# Opens the encoder on a two-frame synthetic clip at the real capture size.
# Returns 0 when it works, 1 when it does not, 2 when there is no ffmpeg to
# ask (caller then has to trust the name).
probe_encoder() {           # $1 = encoder, $2 = device or ""
    local enc="$1" dev="$2" w h out rc
    command -v ffmpeg >/dev/null 2>&1 || return 2
    w=$(( (CAP_W + 1) / 2 * 2 ))
    h=$(( (CAP_H + 1) / 2 * 2 ))
    [[ -n "$PROBE_DIR" ]] || PROBE_DIR="$(mktemp -d)"
    out="$PROBE_DIR/probe.mkv"
    rm -f "$out"
    set +e
    if [[ "$enc" == *vaapi* ]]; then
        [[ -e "$dev" ]] || { set -e; return 1; }
        ffmpeg -hide_banner -loglevel error -f lavfi \
            -i "color=c=black:size=${w}x${h}:rate=30" -frames:v 2 \
            -vaapi_device "$dev" -vf 'format=nv12,hwupload' \
            -c:v "$enc" -qp "$QP" -f matroska -y "$out" >/dev/null 2>&1
    else
        ffmpeg -hide_banner -loglevel error -f lavfi \
            -i "color=c=black:size=${w}x${h}:rate=30" -frames:v 2 \
            -c:v "$enc" -f matroska -y "$out" >/dev/null 2>&1
    fi
    rc=$?
    set -e
    [[ "$rc" -eq 0 && -s "$out" ]]
}

ENCODER=""
ENC_KIND=""                 # vaapi | nvenc | software
CANDIDATES=()

case "$CODEC_MODE" in
    auto)
        if [[ "$GPU_VENDOR" == "nvidia" ]]; then
            CANDIDATES=(h264_nvenc hevc_nvenc h264_vaapi hevc_vaapi)
        else
            CANDIDATES=(h264_vaapi hevc_vaapi)
        fi
        ;;
    vaapi) CANDIDATES=(h264_vaapi hevc_vaapi) ;;
    nvenc) CANDIDATES=(h264_nvenc hevc_nvenc) ;;
    x264|software|libx264) CANDIDATES=() ;;
    *_*|lib*) CANDIDATES=("$CODEC_MODE") ;;
    *) echo "unknown --codec '$CODEC_MODE' (auto|vaapi|nvenc|x264|<encoder name>)" >&2; exit 1 ;;
esac

for cand in ${CANDIDATES+"${CANDIDATES[@]}"}; do
    case "$cand" in
        *vaapi*) kind="vaapi" ;;
        *nvenc*|*qsv*) kind="nvenc" ;;
        *) kind="software" ;;
    esac
    if [[ "$kind" == "vaapi" && ! -e "$DEVICE" ]]; then
        continue
    fi
    if ! have_encoder "$cand"; then
        continue
    fi
    probe_rc=0
    probe_encoder "$cand" "$DEVICE" || probe_rc=$?
    if [[ "$probe_rc" -eq 0 ]]; then
        ENCODER="$cand"
        ENC_KIND="$kind"
        break
    fi
    if [[ "$probe_rc" -eq 2 ]]; then
        # no ffmpeg binary to probe with; take the first plausible candidate
        ENCODER="$cand"
        ENC_KIND="$kind"
        echo "warning: no ffmpeg binary to probe encoders with; trying $cand unverified" >&2
        break
    fi
    echo "encoder $cand cannot open ${CAP_W}x${CAP_H} on this GPU, trying the next one"
done

if [[ -z "$ENCODER" ]]; then
    case "$CODEC_MODE" in
        vaapi|nvenc|*_*)
            echo "--codec $CODEC_MODE was requested but no such encoder works at ${CAP_W}x${CAP_H}" >&2
            echo "  device: ${DEVICE:-none}  gpu: $GPU_VENDOR" >&2
            exit 1
            ;;
    esac
    ENCODER="libx264"
    ENC_KIND="software"
    if [[ "$CODEC_MODE" == "auto" ]]; then
        echo "warning: no usable hardware encoder (gpu: $GPU_VENDOR, device: ${DEVICE:-none}); falling back to libx264 on the CPU" >&2
    fi
fi

# --- frame rate: nominal reference only, nothing is forced by default ------
if [[ "$ENC_KIND" == "software" ]] && [[ "$CAP_W" -gt 3000 ]]; then
    NOMINAL_FPS=$(( MON_RATE < 60 ? MON_RATE : 60 ))
else
    NOMINAL_FPS=$(( MON_RATE < 120 ? MON_RATE : 120 ))
fi
if [[ -n "$FPS_FORCE" ]]; then
    NOMINAL_FPS="$FPS_FORCE"
fi

if [[ "$ENC_KIND" == "software" ]] && [[ "$CAP_W" -gt 3000 ]]; then
    echo "warning: software encoding a ${CAP_W}x${CAP_H} capture. libx264 cannot keep up at this size:"
    echo "  it costs real frames and takes CPU away from the compositor, which looks like lag in the"
    echo "  recording and in the session. Expect roughly ${NOMINAL_FPS}fps at best; a GPU encoder is worth fixing."
fi

# --- let the overlay through screencopy for the length of the capture ---
if [[ "$SCREEN_SHARE_FIX" -eq 1 ]]; then
    if set_no_screen_share false; then
        SCREEN_SHARE_PATCHED=1
        echo "screen share: set no_screen_share = false on the synopsis and synopsis-backdrop layer rules (restored when this script exits)"
    else
        echo
        echo "############################################################"
        echo "# could not turn no_screen_share off through hyprctl eval. #"
        echo "# The overview WILL be recorded as a black rectangle.      #"
        echo "#                                                          #"
        echo "# Stop now, edit hypr/synopsis.lua (and the copy at        #"
        echo "# ~/.config/hypr/synopsis.lua), set no_screen_share =      #"
        echo "# false in BOTH layer rules, reload hyprland, record, then  #"
        echo "# put both back to true.                                   #"
        echo "############################################################"
        echo
    fi
else
    echo "screen share: leaving no_screen_share alone (--keep-screen-share); the overview will be black in the video"
fi

# --- start wf-recorder -----------------------------------------------------
# No -r and no fps= filter: -r makes wf-recorder insert an `fps=` filter,
# which is what padded the old recordings with duplicate frames. Without it
# wf-recorder follows compositor damage and writes variable frame rate video.
WF_LOG="$DIR/wf-recorder.log"
WF_ARGS=(-o "$MON_NAME" -c "$ENCODER")
case "$ENC_KIND" in
    vaapi)
        WF_ARGS+=(-d "$DEVICE" -p qp="$QP")
        ;;
    nvenc)
        WF_ARGS+=(-p rc=constqp -p qp="$QP" -p preset=p4 -p tune=ll)
        ;;
    *)
        WF_ARGS+=(-p preset=ultrafast -p crf=14 -p tune=zerolatency)
        ;;
esac
if [[ -n "$PIXFMT" ]]; then
    WF_ARGS+=(-x "$PIXFMT")
fi
if [[ "$NO_DMABUF" -eq 1 ]]; then
    WF_ARGS+=(--no-dmabuf)
fi
if [[ -n "$FPS_FORCE" ]]; then
    WF_ARGS+=(-r "$FPS_FORCE")
    echo "note: --fps $FPS_FORCE forces constant frame rate; wf-recorder will pad stills with duplicate"
    echo "  frames and drop updates faster than ${FPS_FORCE}fps. The analyzer reads pts and does not need this."
fi
WF_ARGS+=(-f "$DIR/desktop.mkv")
if [[ -n "$REGION" ]]; then
    WF_ARGS=(-g "$REGION" "${WF_ARGS[@]}")
fi

meta_update "capture_width=$CAP_W" "capture_height=$CAP_H" \
    "encoder=$ENCODER" "encoder_kind=$ENC_KIND" "gpu_vendor=$GPU_VENDOR" \
    "monitor=$MON_NAME" "refresh_hz=$MON_RATE" "nominal_fps=$NOMINAL_FPS" \
    "constant_frame_rate=$([[ -n "$FPS_FORCE" ]] && echo true || echo false)"

set +e
wf-recorder "${WF_ARGS[@]}" >"$WF_LOG" 2>&1 &
REC_PID=$!
sleep 0.7
if ! kill -0 "$REC_PID" 2>/dev/null; then
    echo "wf-recorder exited immediately, see $WF_LOG" >&2
    tail -5 "$WF_LOG" >&2 || true
    exit 1
fi
set -e

case "$ENC_KIND" in
    vaapi)  ENC_DESC="$ENCODER on $DEVICE (GPU, qp=$QP)" ;;
    nvenc)  ENC_DESC="$ENCODER (GPU, qp=$QP)" ;;
    *)      ENC_DESC="$ENCODER (CPU)" ;;
esac
echo "recording focused monitor $MON_NAME ${CAP_W}x${CAP_H} -> $DIR/desktop.mkv"
echo "encoder: $ENC_DESC"
if [[ -n "$FPS_FORCE" ]]; then
    echo "frame rate: constant ${FPS_FORCE}fps (forced)"
else
    echo "frame rate: variable (damage driven), nominal reference ${NOMINAL_FPS}fps at ${MON_RATE}Hz"
fi
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

restore_screen_share

T_STOP_EPOCH_MS="$(date +%s%3N)"
meta_update "t_stop_epoch_ms=$T_STOP_EPOCH_MS"

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

# --- capture quality: how many of those frames are real updates? -----------
# mpdecimate on a downscaled copy counts the frames that actually differ from
# their predecessor. Padded captures (a forced fps= filter) and captures the
# encoder could not keep up with both show up as a real rate far below
# nominal. The 50 % threshold is the one analyze.py uses for CAPTURE-FAIL.
quality_report() {          # $1 = video, $2 = nominal fps
    local video="$1" nominal="$2" packets duration report
    local qc_timeout=420 ff_rc=0 ff_log
    [[ -s "$video" ]] || { echo "capture quality: $video is empty"; return 0; }
    if ! command -v ffprobe >/dev/null 2>&1 || ! command -v ffmpeg >/dev/null 2>&1; then
        echo "capture quality: ffmpeg/ffprobe not found, skipped"
        return 0
    fi
    packets="$(ffprobe -v error -select_streams v:0 -count_packets \
        -show_entries stream=nb_read_packets -of default=nw=1:nk=1 "$video" 2>/dev/null | head -1)"
    [[ "$packets" =~ ^[0-9]+$ ]] || packets=0
    duration="$(ffprobe -v error -show_entries format=duration \
        -of default=nw=1:nk=1 "$video" 2>/dev/null | head -1)"
    [[ "$duration" =~ ^[0-9]+([.][0-9]+)?$ ]] || duration=0
    echo "measuring capture quality (decoding $video once, this takes a moment)..."
    # mpdecimate thresholds well below the defaults: the defaults need a third
    # of the blocks to move before a frame counts as new, which throws away
    # genuine animation frames (verified against a synthetic 60fps clip, where
    # the defaults kept 40 of 120 real frames and these keep all 120, while a
    # 10fps clip padded to 120 keeps exactly its 20 real ones).
    # ffmpeg writes to a file rather than straight into the pipe: with a
    # pipeline the exit status belongs to python, so a decode killed by the
    # timeout used to be summarised as a confident verdict over a truncated
    # frame list.
    [[ -n "$PROBE_DIR" ]] || PROBE_DIR="$(mktemp -d)"
    ff_log="$PROBE_DIR/quality.log"
    set +e
    timeout "$qc_timeout" ffmpeg -hide_banner -nostats -loglevel info -i "$video" \
        -vf 'scale=640:-2:flags=bilinear,mpdecimate=hi=128:lo=64:frac=0.005,showinfo' \
        -an -sn -f null - >"$ff_log" 2>&1
    ff_rc=$?
    set -e
    if [[ "$ff_rc" -eq 124 || "$ff_rc" -eq 137 ]]; then
        rm -f "$ff_log"
        echo "capture quality: check timed out after ${qc_timeout}s, no verdict"
        return 0
    fi
    if [[ "$ff_rc" -ne 0 ]]; then
        rm -f "$ff_log"
        echo "capture quality: decode failed (ffmpeg exit $ff_rc), no verdict; check $video by eye"
        return 0
    fi
    set +e
    report="$(python3 -c '
import re, sys

pts = []
pat = re.compile(r"pts_time:\s*([0-9.]+)")
for line in sys.stdin:
    if "showinfo" not in line:
        continue
    m = pat.search(line)
    if m:
        try:
            pts.append(float(m.group(1)))
        except ValueError:
            pass
if not pts:
    print("NODATA")
    sys.exit(0)
span = max(pts) - min(pts)
buckets = {}
for t in pts:
    buckets[int(t)] = buckets.get(int(t), 0) + 1
peak = max(buckets.values())
print("%d %.3f %d" % (len(pts), span, peak))
' <"$ff_log")"
    set -e
    rm -f "$ff_log"
    if [[ -z "$report" || "$report" == "NODATA" ]]; then
        echo "capture quality: could not measure (the decode produced no frame timings); check $video by eye"
        return 0
    fi
    python3 - "$report" "$packets" "$nominal" "$duration" <<'PYEOF'
import sys
report, packets, nominal = sys.argv[1], int(sys.argv[2]), float(sys.argv[3])
duration = float(sys.argv[4])
real, span, peak = report.split()
real, span, peak = int(real), float(span), int(peak)
# the container duration includes a trailing still period that produces no
# frames at all, so it is the honest denominator for the mean
span = max(span, duration)
mean = real / span if span > 0 else 0.0
dup = packets - real
verdict = "capture looks usable" if peak >= 0.5 * nominal else "capture is padded/dropped, re-record"
print("capture quality: %d real frames of %d in %.1fs "
      "(mean %.1f/s, peak %d/s, %d duplicate%s) vs nominal %g/s -> %s"
      % (real, packets, span, mean, peak, dup, "" if dup == 1 else "s", nominal, verdict))
if peak < 0.5 * nominal:
    print("  a low peak means the encoder or the compositor could not deliver frames during the fast parts;")
    print("  try a hardware encoder (--codec vaapi), a smaller --region, or drop --fps if you forced it.")
else:
    print("  mean is low on purpose: an idle desktop produces no frames. Peak is the rate that matters.")
PYEOF
}

if [[ "$QUALITY_CHECK" -eq 1 ]]; then
    quality_report "$DIR/desktop.mkv" "$NOMINAL_FPS" || true
fi

if [[ -n "$SHELL_PID" ]]; then
    echo "the synopsis shell (pid $SHELL_PID) is still running; stop it yourself when done"
fi

echo
echo "$DIR"
echo "python3 tools/sim/analyze.py --live '$DIR'"
echo "send Claude the directory path plus when the glitch happens in the clip"
