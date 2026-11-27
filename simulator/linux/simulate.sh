#!/bin/bash

# =============================================================================
# Run the gauge simulator and linux/gauges.sh together
# =============================================================================
#
# The simulator creates a pseudo-terminal and the gauge script is pointed at it
# with the DEVICE environment variable, so no hardware and no virtual serial
# driver are needed.
#
# The simulator runs headless here and its log is printed when the run ends.
# To watch the dials, run the two halves separately in different terminals:
#
#   ./simulator/linux/simulator.py
#   DEVICE=/dev/pts/N ./linux/gauges.sh
#
# Usage:
#   ./simulator/linux/simulate.sh [simulator options]
#
#   ./simulate.sh --duration 60          stop after a minute
#   ./simulate.sh --fault-timeout 3      seconds before the fault sweep
# =============================================================================

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
simulator="$here/simulator.py"
gauges="$here/../../linux/gauges.sh"

if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: python3 is required for the simulator" >&2
    exit 1
fi

for file in "$simulator" "$gauges"; do
    if [ ! -f "$file" ]; then
        echo "ERROR: missing $file" >&2
        exit 1
    fi
done

device_file="$(mktemp)"
log_file="$(mktemp)"
simulator_pid=""

cleanup() {
    if [ -n "$simulator_pid" ] && kill -0 "$simulator_pid" 2>/dev/null; then
        kill "$simulator_pid" 2>/dev/null
        wait "$simulator_pid" 2>/dev/null
    fi
    rm -f "$device_file"
}

on_exit() {
    echo
    echo "--- simulator log ---"
    tail -n 15 "$log_file" 2>/dev/null
    cleanup
    rm -f "$log_file"
}

trap on_exit EXIT

python3 -u "$simulator" --no-ui --write-device-file "$device_file" "$@" > "$log_file" 2>&1 &
simulator_pid=$!

for _ in $(seq 1 50); do
    [ -s "$device_file" ] && break
    sleep 0.1
done

if [ ! -s "$device_file" ]; then
    echo "ERROR: the simulator did not start:" >&2
    sed -n '1,10p' "$log_file" >&2
    exit 1
fi

device="$(cat "$device_file")"

echo "Simulator device: $device"
echo "Sending CPU and RAM usage every second (Ctrl+C to stop)"
echo

DEVICE="$device" bash "$gauges"
