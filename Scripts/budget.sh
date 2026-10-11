#!/bin/sh
# Checks the running cost of Landfill against its budget, using a throwaway zone.
#   usage: Scripts/budget.sh [file-count]     (default 500)
# Fails if memory footprint exceeds 120 MB or idle CPU averages above 1% of a core.
set -e
cd "$(dirname "$0")/.."

COUNT="${1:-500}"
MAX_MB=120
MAX_IDLE_PCT=1
SETTLE=25
IDLE=60

BIN=build/Landfill.app/Contents/MacOS/Landfill
[ -x "$BIN" ] || ./Scripts/bundle.sh

ZONE="$(mktemp -d)/zone"
mkdir -p "$ZONE"
i=1
while [ "$i" -le "$COUNT" ]; do echo "file $i" > "$ZONE/file $i.txt"; i=$((i + 1)); done

LANDFILL_ROOT="$ZONE" "$BIN" &
PID=$!
trap 'kill $PID 2>/dev/null' EXIT

cpu_seconds() { ps -p "$PID" -o time= | awk -F'[:.]' '{ print $1 * 60 + $2 + $3 / 100 }'; }
megabytes() { footprint "$PID" | awk -v key="$1" '$1 == key { print ($3 == "GB") ? $2 * 1024 : ($3 == "KB") ? $2 / 1024 : $2 }'; }

sleep "$SETTLE"
BEFORE=$(cpu_seconds)
sleep "$IDLE"
AFTER=$(cpu_seconds)

NOW_MB=$(megabytes phys_footprint:)
PEAK_MB=$(megabytes phys_footprint_peak:)
IDLE_PCT=$(echo "scale=3; ($AFTER - $BEFORE) * 100 / $IDLE" | bc)

echo "files: $COUNT   memory: ${NOW_MB} MB (peak ${PEAK_MB} MB, limit ${MAX_MB})   idle cpu: ${IDLE_PCT}% (limit ${MAX_IDLE_PCT}%)"
[ "$(echo "$PEAK_MB <= $MAX_MB" | bc)" = 1 ] || { echo "FAIL: memory over budget"; exit 1; }
[ "$(echo "$IDLE_PCT <= $MAX_IDLE_PCT" | bc)" = 1 ] || { echo "FAIL: idle cpu over budget"; exit 1; }
echo "PASS"
