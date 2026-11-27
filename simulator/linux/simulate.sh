#!/bin/bash

# =============================================================================
# Run the gauge simulator and linux/gauges.sh together
# =============================================================================
#
# The simulator creates a pseudo-terminal and the gauge script is pointed at it
# with the DEVICE environment variable, so no hardware and no virtual serial
# driver are needed.
#
# In a terminal the dials are drawn in place (the sender's log is written to a
# temporary file and shown when you stop). When output is redirected, or with
# --no-ui, the simulator prints one status line per second instead.
#
# To run the halves separately in two terminals:
#
#   ./simulator/linux/simulator.py
#   DEVICE=/dev/pts/N ./linux/gauges.sh
#
# Usage:
#   ./simulator/linux/simulate.sh [--ui|--no-ui] [simulator options]
#
#   ./simulate.sh                        dials in the current terminal
#   ./simulate.sh --no-ui                text log only
#   ./simulate.sh --duration 60          stop after a minute
#   ./simulate.sh --fault-timeout 2      seconds before the fault sweep
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

# --ui / --no-ui are handled here; everything else is passed to the simulator.
mode="auto"
simulator_options=()

for argument in "$@"; do
    case "$argument" in
        --ui)
            mode="ui"
            ;;
        --no-ui)
            mode="headless"
            ;;
        *)
            simulator_options+=("$argument")
            ;;
    esac
done

if [ "$mode" = "auto" ]; then
    if [ -t 1 ]; then
        mode="ui"
    else
        mode="headless"
    fi
fi

device_file="$(mktemp)"
simulator_log="$(mktemp)"
sender_log="$(mktemp)"
simulator_pid=""

stop_simulator() {
    if [ -n "$simulator_pid" ] && kill -0 "$simulator_pid" 2>/dev/null; then
        kill "$simulator_pid" 2>/dev/null
        wait "$simulator_pid" 2>/dev/null
    fi
}

on_exit() {
    stop_simulator

    if [ "$mode" = "ui" ]; then
        echo
        echo "--- sender log (last 10 lines) ---"
        tail -n 10 "$sender_log" 2>/dev/null

        if [ -s "$simulator_log" ]; then
            echo
            echo "--- simulator log (last 10 lines) ---"
            tail -n 10 "$simulator_log" 2>/dev/null
        fi
    else
        echo
        echo "--- simulator log ---"
        tail -n 15 "$simulator_log" 2>/dev/null
    fi

    rm -f "$device_file" "$simulator_log" "$sender_log"
}

trap on_exit EXIT

if [ "$mode" = "ui" ]; then
    python3 -u "$simulator" --write-device-file "$device_file" "${simulator_options[@]}" &
else
    python3 -u "$simulator" --no-ui --write-device-file "$device_file" "${simulator_options[@]}" > "$simulator_log" 2>&1 &
fi

simulator_pid=$!

for _ in $(seq 1 50); do
    [ -s "$device_file" ] && break
    sleep 0.1
done

if [ ! -s "$device_file" ]; then
    echo "ERROR: the simulator did not start:" >&2
    sed -n '1,10p' "$simulator_log" >&2
    exit 1
fi

device="$(cat "$device_file")"

if [ "$mode" = "ui" ]; then
    # The panel owns the screen, so the sender writes to its log instead.
    DEVICE="$device" bash "$gauges" > "$sender_log" 2>&1
else
    echo "Simulator device: $device"
    echo "Sending CPU and RAM usage every second (Ctrl+C to stop)"
    echo

    DEVICE="$device" bash "$gauges"
fi
