#!/usr/bin/env bash
# a small proxy of a video wallpaper for the strip tiles. the tiles are a
# few hundred px wide, so a second full-size hardware decoder for them only
# burns the decode engine the live wallpaper needs.
#
# usage: wallpaper-proxy.sh SRC
# prints the path of the json that describes the proxy and exits 0. the
# work runs once per clip (keyed on its name, size and mtime), every later
# call finds the cache and exits at once. any failure exits non-zero and
# leaves no partial files behind.
set -euo pipefail

src=${1:-}
if [[ -z $src || ! -f $src ]]; then
    echo "wallpaper-proxy: no such file: $src" >&2
    exit 2
fi
src=$(realpath -- "$src")

dir="${XDG_CACHE_HOME:-$HOME/.cache}/synopsis/wallpaper"
base=$(basename -- "$src")
size=$(stat -c %s -- "$src")
mtime=$(stat -c %Y -- "$src")
key="$base-$size-$mtime"
mp4="$dir/$key.mp4"
json="$dir/$key.json"

# the common case, nothing to do
if [[ -f $mp4 && -f $json ]]; then
    printf '%s\n' "$json"
    exit 0
fi

mkdir -p -- "$dir"

# a second caller waits here, then finds the files the first one wrote
exec 9>"$dir/.lock"
flock 9

if [[ -f $mp4 && -f $json ]]; then
    printf '%s\n' "$json"
    exit 0
fi

tmp_mp4=$(mktemp --suffix=.mp4 -- "$dir/.$key.XXXXXX")
tmp_json=$(mktemp --suffix=.json -- "$dir/.$key.XXXXXX")
done_ok=0
moved_mp4=0
cleanup() {
    rm -f -- "$tmp_mp4" "$tmp_json"
    # the mp4 alone is a partial result, the next call would trust it
    if [[ $done_ok -eq 0 && $moved_mp4 -eq 1 ]]; then
        rm -f -- "$mp4"
    fi
}
trap cleanup EXIT
trap 'exit 143' TERM INT HUP

# json string escaping for the two paths, enough for any file name
jstr() {
    local s=$1
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\t'/\\t}
    s=${s//$'\n'/\\n}
    s=${s//$'\r'/\\r}
    printf '"%s"' "$s"
}

low() {
    nice -n 19 ionice -c 3 "$@"
}

duration=$(low ffprobe -v error -show_entries format=duration -of csv=p=0 -- "$src" |
    awk '$1 ~ /^[0-9.]+$/ { printf "%d", $1 * 1000 + 0.5 }')
if [[ -z $duration || $duration -le 0 ]]; then
    echo "wallpaper-proxy: no duration for $src" >&2
    exit 1
fi

# software decode only. a hardware decode burst here would make the live
# wallpaper stutter, and the thread cap keeps the machine usable meanwhile.
# short gops keep every seek in the proxy down to a few small frames
low ffmpeg -nostdin -v error -y -threads 4 -i "$src" -an \
    -vf "scale=1280:-2:flags=lanczos,fps=30,format=yuv420p" -filter_threads 2 \
    -c:v libx264 -preset medium -crf 20 -threads 4 \
    -g 15 -keyint_min 15 -sc_threshold 0 \
    -movflags +faststart -f mp4 "$tmp_mp4"

dims=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 -- "$tmp_mp4")
width=${dims%%,*}
height=${dims##*,}
if [[ ! $width =~ ^[0-9]+$ || ! $height =~ ^[0-9]+$ ]]; then
    echo "wallpaper-proxy: unreadable proxy for $src" >&2
    exit 1
fi

printf '{"source": %s, "proxy": %s, "duration": %s, "width": %s, "height": %s}\n' \
    "$(jstr "$src")" "$(jstr "$mp4")" "$duration" "$width" "$height" >"$tmp_json"

mv -f -- "$tmp_mp4" "$mp4"
moved_mp4=1
mv -f -- "$tmp_json" "$json"
done_ok=1

# older proxies of the same clip (another size or mtime), nothing else.
# the name is compared as a literal prefix, so glob characters in it match
# nothing they should not
for f in "$dir"/*; do
    [[ -f $f ]] || continue
    name=${f##*/}
    [[ $name == "$base-"* ]] || continue
    rest=${name#"$base-"}
    [[ $rest =~ ^[0-9]+-[0-9]+\.(mp4|json)$ ]] || continue
    [[ $name == "$key.mp4" || $name == "$key.json" ]] && continue
    rm -f -- "$f"
done

printf '%s\n' "$json"
