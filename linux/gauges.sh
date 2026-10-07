#!/bin/bash

# =============================================================================
# Proxmox ESP32 Gauge Telemetry
# =============================================================================
#
# Sends CPU and physical RAM utilisation from a Linux/Proxmox server to an
# ESP32-C3-Zero over USB serial.
#
# The ESP32 drives two analogue moving-coil gauges:
#
#   CPU gauge -> CPU utilisation
#   RAM gauge -> physical memory utilisation
#
# The ESP32 also has an RGB status LED. The firmware supports a number of
# LED control commands, although this server script currently only sends
# CPU and RAM telemetry.
#
# -----------------------------------------------------------------------------
# Serial protocol
# -----------------------------------------------------------------------------
#
# CPU and RAM values are sent as newline-terminated commands:
#
#   CPU=0
#   CPU=25
#   CPU=50
#   CPU=75
#   CPU=100
#
#   RAM=0
#   RAM=25
#   RAM=50
#   RAM=75
#   RAM=100
#
# The ESP32 acknowledges each received value with:
#
#   ACK CPU=xx.x
#   ACK RAM=xx.x
#
# These acknowledgements are used to determine whether communication with the
# ESP32 is working correctly.
#
# -----------------------------------------------------------------------------
# ESP32 LED commands
# -----------------------------------------------------------------------------
#
# The ESP32 firmware also accepts the following LED commands. They are
# documented here for future use, but this script does not currently send them.
#
# Automatic mode:
#
#   LED=AUTO
#
# Manual colours:
#
#   LED=RED
#   LED=GREEN
#   LED=BLUE
#   LED=YELLOW
#   LED=CYAN
#   LED=MAGENTA
#   LED=WHITE
#
# Arbitrary RGB colour:
#
#   LED=RGB,255,128,0
#
# LED power:
#
#   LED=ON
#   LED=OFF
#
# Brightness:
#
#   LED=DIM,50
#
# DIM is independent of ON/OFF state. For example:
#
#   LED=RED
#   LED=DIM,25
#   LED=OFF
#   LED=ON
#
# will restore the previous red colour at 25% brightness.
#
# The ESP32 firmware has separate handling for communication failure. If
# telemetry stops arriving for 3 seconds, it forces the RGB LED to solid red
# at 100% brightness and moves the CPU and RAM gauges through an alternating
# fault sweep.
#
# When communication is restored, the ESP32 returns to its previous normal
# LED state and resumes normal gauge operation.
#
# -----------------------------------------------------------------------------
# Automatic LED behaviour in the ESP32 firmware
# -----------------------------------------------------------------------------
#
# LED=AUTO uses:
#
#   Blue  = waiting for the first telemetry message
#   Green = communicating normally
#   Red   = communication failure
#
# The normal LED brightness defaults to 50%.
# Startup and communication-failure indication use 100% brightness.
#
# -----------------------------------------------------------------------------
# Data sources
# -----------------------------------------------------------------------------
#
# CPU utilisation is calculated from Linux /proc/stat CPU counters.
#
# RAM utilisation is calculated from:
#
#   MemTotal - MemAvailable
#
# Swap is not included in the RAM percentage.
#
# -----------------------------------------------------------------------------
# Requirements
# -----------------------------------------------------------------------------
#
# - Linux server
# - Bash
# - awk
# - stty
# - ESP32-C3-Zero connected by USB
# - ESP32 firmware configured for the same 115200 baud serial connection
#
# The default serial device is /dev/ttyACM0.
#
# =============================================================================


DEVICE="/dev/ttyACM0"
INTERVAL=1

# How long to wait for ESP32 acknowledgements after sending CPU/RAM.
ACK_TIMEOUT=0.5

# -----------------------------------------------------------------------------
# Check that the serial device exists
# -----------------------------------------------------------------------------

if [ ! -e "$DEVICE" ]; then
    echo "ERROR: Serial device not found: $DEVICE"
    exit 1
fi

if [ ! -r "$DEVICE" ] || [ ! -w "$DEVICE" ]; then
    echo "ERROR: Cannot read/write serial device: $DEVICE"
    echo "Check that the current user has permission to access the device."
    exit 1
fi

# -----------------------------------------------------------------------------
# Configure USB serial
# -----------------------------------------------------------------------------
#
# The ESP32 firmware uses 115200 baud, 8 data bits, no parity and one stop bit.
#
# Software flow control is disabled because the telemetry protocol does not
# use XON/XOFF.
#
# The terminal is configured for raw-style line handling so the script can
# communicate directly with the ESP32 firmware.
# -----------------------------------------------------------------------------

if ! stty -F "$DEVICE" 115200 cs8 -cstopb -parenb \
    -ixon -ixoff -echo -icanon min 0 time 1
then
    echo "ERROR: Could not configure serial device: $DEVICE"
    exit 1
fi

# -----------------------------------------------------------------------------
# Open the serial device for both reading and writing
# -----------------------------------------------------------------------------

if ! exec 3<> "$DEVICE"; then
    echo "ERROR: Could not open serial device for read/write: $DEVICE"
    exit 1
fi

# Close serial device cleanly when the script exits.
trap 'exec 3>&-' EXIT

# -----------------------------------------------------------------------------
# Read CPU counters
# -----------------------------------------------------------------------------
#
# Linux exposes cumulative CPU counters through /proc/stat.
#
# Two readings are compared over time:
#
#   total CPU time
#   idle CPU time
#
# The difference between readings gives the CPU utilisation during the
# measurement interval.
# -----------------------------------------------------------------------------

read_cpu() {
    awk '/^cpu / {
        idle = $5 + $6
        total = $2 + $3 + $4 + $5 + $6 + $7 + $8 + $9
        print total, idle
        exit
    }' /proc/stat
}

# -----------------------------------------------------------------------------
# Read physical memory usage
# -----------------------------------------------------------------------------
#
# MemAvailable is used rather than simply subtracting free memory. This gives
# a more useful representation of how much memory Linux considers available
# for applications.
#
# Swap is deliberately ignored.
# -----------------------------------------------------------------------------

read_memory() {
    awk '
    /^MemTotal:/ {
        total = $2
    }

    /^MemAvailable:/ {
        available = $2
    }

    END {
        used = total - available
        print total, used
    }
    ' /proc/meminfo
}

# -----------------------------------------------------------------------------
# Read acknowledgements from ESP32
# -----------------------------------------------------------------------------
#
# After sending CPU and RAM values, the ESP32 normally responds with:
#
#   ACK CPU=xx.x
#   ACK RAM=xx.x
#
# The script waits briefly for these responses.
#
# Other messages from the ESP32, such as:
#
#   SIGNAL LOST
#   SIGNAL RESTORED
#   ERROR: ...
#
# are displayed on the server console.
#
# -----------------------------------------------------------------------------

read_acknowledgements() {

    CPU_ACK=0
    RAM_ACK=0

    local RESPONSE

    # Read responses for a short period.
    #
    # The ESP32 sends:
    #
    #   ACK CPU=xx
    #   ACK RAM=xx
    #
    # We keep reading until both have arrived or the timeout expires.

    while true; do

        # Both acknowledgements received.
        if [ "$CPU_ACK" -eq 1 ] && [ "$RAM_ACK" -eq 1 ]; then
            break
        fi

        if IFS= read -r -t "$ACK_TIMEOUT" -u 3 RESPONSE; then

            # Ignore blank lines
            if [ -z "$RESPONSE" ]; then
                continue
            fi

            # CPU acknowledgement
            if [[ "$RESPONSE" == ACK\ CPU=* ]]; then
                CPU_ACK=1
                continue
            fi

            # RAM acknowledgement
            if [[ "$RESPONSE" == ACK\ RAM=* ]]; then
                RAM_ACK=1
                continue
            fi

            # Display other ESP32 messages
            echo "ESP32: $RESPONSE"

        else
            # No more data arrived during the timeout.
            break
        fi

    done
}

# -----------------------------------------------------------------------------
# Initial readings
# -----------------------------------------------------------------------------

read PREV_TOTAL PREV_IDLE <<< "$(read_cpu)"

echo "CPU and RAM gauge started"
echo "Device: $DEVICE"
echo "Sending CPU and RAM usage every second"
echo "Waiting for ESP32 acknowledgements"
echo "Press Ctrl+C to stop"
echo

# -----------------------------------------------------------------------------
# Main loop
# -----------------------------------------------------------------------------

while true; do

    sleep "$INTERVAL"

    # -------------------------------------------------------------------------
    # CPU
    # -------------------------------------------------------------------------
    #
    # Calculate utilisation from the change in cumulative CPU counters since
    # the previous reading.
    # -------------------------------------------------------------------------

    read CURR_TOTAL CURR_IDLE <<< "$(read_cpu)"

    TOTAL_DELTA=$((CURR_TOTAL - PREV_TOTAL))
    IDLE_DELTA=$((CURR_IDLE - PREV_IDLE))

    if [ "$TOTAL_DELTA" -gt 0 ]; then
        CPU=$((100 * (TOTAL_DELTA - IDLE_DELTA) / TOTAL_DELTA))
    else
        CPU=0
    fi

    # Keep CPU between 0 and 100.
    if [ "$CPU" -lt 0 ]; then
        CPU=0
    fi

    if [ "$CPU" -gt 100 ]; then
        CPU=100
    fi

    # -------------------------------------------------------------------------
    # RAM
    # -------------------------------------------------------------------------
    #
    # Calculate physical memory utilisation from MemTotal and MemAvailable.
    # -------------------------------------------------------------------------

    read MEM_TOTAL MEM_USED <<< "$(read_memory)"

    if [ "$MEM_TOTAL" -gt 0 ]; then
        RAM=$((100 * MEM_USED / MEM_TOTAL))
    else
        RAM=0
    fi

    # Keep RAM between 0 and 100.
    if [ "$RAM" -lt 0 ]; then
        RAM=0
    fi

    if [ "$RAM" -gt 100 ]; then
        RAM=100
    fi

    # -------------------------------------------------------------------------
    # Send values to ESP32
    # -------------------------------------------------------------------------
    #
    # CPU and RAM are sent independently so the ESP32 can acknowledge each
    # value separately.
    # -------------------------------------------------------------------------

    if ! printf "CPU=%d\n" "$CPU" >&3; then
        echo "ERROR: Failed to send CPU value to ESP32"
        exit 1
    fi

    if ! printf "RAM=%d\n" "$RAM" >&3; then
        echo "ERROR: Failed to send RAM value to ESP32"
        exit 1
    fi

    # -------------------------------------------------------------------------
    # Wait for ESP32 acknowledgements
    # -------------------------------------------------------------------------

    read_acknowledgements

    if [ "$CPU_ACK" -eq 1 ] && [ "$RAM_ACK" -eq 1 ]; then
        ESP_STATUS="CONNECTED"
    elif [ "$CPU_ACK" -eq 1 ] || [ "$RAM_ACK" -eq 1 ]; then
        ESP_STATUS="PARTIAL ACK"
    else
        ESP_STATUS="NO ACK"
    fi

    # -------------------------------------------------------------------------
    # Display values
    # -------------------------------------------------------------------------

    MEM_USED_GB=$(awk "BEGIN { printf \"%.1f\", $MEM_USED / 1024 / 1024 }")
    MEM_TOTAL_GB=$(awk "BEGIN { printf \"%.1f\", $MEM_TOTAL / 1024 / 1024 }")

    echo "CPU: ${CPU}%  RAM: ${RAM}%  (${MEM_USED_GB} / ${MEM_TOTAL_GB} GiB)  ESP32: ${ESP_STATUS}"

    # -------------------------------------------------------------------------
    # Update CPU baseline
    # -------------------------------------------------------------------------

    PREV_TOTAL=$CURR_TOTAL
    PREV_IDLE=$CURR_IDLE

done
