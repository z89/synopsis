#!/usr/bin/env bash
# tools/gpu-sample.sh [seconds]
#
# Samples the first /sys/class/drm/card*/device/gpu_busy_percent found, every
# 100ms, for the given number of seconds (default 10). Prints one line per
# sample as "epoch_ms value", then a final line "min avg max".
set -euo pipefail

duration="${1:-10}"

busy_file=""
for f in /sys/class/drm/card*/device/gpu_busy_percent; do
    if [ -e "$f" ]; then
        busy_file="$f"
        break
    fi
done

if [ -z "$busy_file" ]; then
    echo "tools/gpu-sample.sh: no gpu_busy_percent file found under /sys/class/drm" >&2
    exit 1
fi

samples=$((duration * 10))
min=""
max=""
sum=0
count=0

for ((i = 0; i < samples; i++)); do
    value="$(cat "$busy_file")"
    epoch_ms="$(($(date +%s%N) / 1000000))"
    echo "$epoch_ms $value"

    sum=$((sum + value))
    count=$((count + 1))
    if [ -z "$min" ] || [ "$value" -lt "$min" ]; then
        min="$value"
    fi
    if [ -z "$max" ] || [ "$value" -gt "$max" ]; then
        max="$value"
    fi

    sleep 0.1
done

avg=0
if [ "$count" -gt 0 ]; then
    avg=$((sum / count))
fi

echo "$min $avg $max"
