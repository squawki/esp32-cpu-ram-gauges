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
# LED control commands, which this script uses for the optional internet
# outage detection described below.
#
# -----------------------------------------------------------------------------
# Optional internet outage detection
# -----------------------------------------------------------------------------
#
# Setting INTERNET_CHECK_ENABLED=1 makes the script ping PING_TARGET every
# CHECK_INTERVAL seconds. The first attempt is followed by a retry only if it
# fails, up to PING_ATTEMPTS attempts in total.
#
# If every attempt fails the internet is considered down and the LED blinks
# LED_OUTAGE BLINK_COUNT times at the current brightness, then returns to
# LED_NORMAL (LED=AUTO, i.e. green while telemetry is flowing). The blink
# repeats every BLINK_INTERVAL seconds while the internet is down, with a
# fresh check before each blink so recovery is picked up within one interval.
#
# The pings run in a background subshell and telemetry is sent between blink
# steps, so the ESP32's 3 second communication timeout is never reached and
# the gauges do not enter the fault sweep during a check or a blink.
#
# This feature is disabled by default. When disabled the script behaves
# exactly as before and never sends LED commands, leaving the ESP32 in its
# automatic LED mode.
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
# The ESP32 firmware also accepts the following LED commands. The script only
# sends them when internet outage detection is enabled; otherwise the LED
# stays in its automatic mode.
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
# - ping (only when internet outage detection is enabled)
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

# =============================================================================
# Internet outage detection (optional)
# =============================================================================
#
# Set INTERNET_CHECK_ENABLED=1 to enable the internet outage blink alert,
# or 0 to disable it.
INTERNET_CHECK_ENABLED=0

# Address pinged by the connectivity check. An IP address is used so that the
# check does not depend on DNS.
PING_TARGET="1.1.1.1"

# Total attempts per check. Attempt 2 is only made if attempt 1 fails, and
# attempt 3 only if attempt 2 fails.
PING_ATTEMPTS=3

# Per-attempt timeout in seconds.
PING_TIMEOUT=2

# Seconds between checks while the internet is up.
CHECK_INTERVAL=60

# Seconds between blink sequences while the internet is down.
BLINK_INTERVAL=30

# Number of flashes per blink sequence.
BLINK_COUNT=5

# Time in seconds the LED stays on, and then off, during a blink.
BLINK_STEP=0.25

# LED command used for the blink. LED=RGB keeps the LED's current brightness.
# Any LED command can be used, for example LED=MAGENTA or LED=RED.
LED_OUTAGE="LED=RGB,255,0,255"

# LED command sent after each blink to restore the normal colour.
# LED=AUTO returns to automatic mode (green while telemetry is flowing).
LED_NORMAL="LED=AUTO"

# Abandon a connectivity check that has not finished in this many seconds and
# treat the internet as up.
CHECK_WATCHDOG=20

# =============================================================================

if [ "$INTERNET_CHECK_ENABLED" != "0" ] && [ "$INTERNET_CHECK_ENABLED" != "1" ]; then
    echo "ERROR: INTERNET_CHECK_ENABLED must be 0 or 1"
    exit 1
fi

if [ "$INTERNET_CHECK_ENABLED" -eq 1 ] && ! command -v ping >/dev/null 2>&1; then
    echo "ERROR: Internet outage detection requires the ping command"
    exit 1
fi

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

# -----------------------------------------------------------------------------
# State directory for the background connectivity check
# -----------------------------------------------------------------------------

if [ "$INTERNET_CHECK_ENABLED" -eq 1 ]; then
    STATE_DIR=$(mktemp -d) || exit 1
    NET_STATE="$STATE_DIR/net.state"

    # Close serial device and clean up state on exit.
    trap 'exec 3>&-; rm -rf "$STATE_DIR"' EXIT
else
    NET_STATE=""

    # Close serial device cleanly when the script exits.
    trap 'exec 3>&-' EXIT
fi

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
# Send a command to the ESP32
# -----------------------------------------------------------------------------

send_command() {
    if ! printf '%s\n' "$1" >&3; then
        echo "ERROR: Failed to send command to ESP32: $1"
        exit 1
    fi
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
# LED commands are acknowledged with "ACK LED=...". Those acknowledgements are
# consumed silently because they carry no telemetry information.
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

            # LED acknowledgement
            if [[ "$RESPONSE" == ACK\ LED=* ]]; then
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
# Internet connectivity check
# -----------------------------------------------------------------------------
#
# Runs in a background subshell so that telemetry keeps flowing, and records
# UP or DOWN in $NET_STATE.
#
# The first ping is always attempted. A retry is only made after a failure, so
# a healthy connection costs a single ping per check.

check_connectivity() {
    local attempt

    for (( attempt = 1; attempt <= PING_ATTEMPTS; attempt++ )); do

        if ping -n -q -c 1 -W "$PING_TIMEOUT" "$PING_TARGET" >/dev/null 2>&1; then
            printf 'UP\n' > "$NET_STATE"
            return 0
        fi

    done

    printf 'DOWN\n' > "$NET_STATE"
    return 1
}

start_internet_check() {
    rm -f "$NET_STATE"
    ( check_connectivity ) &
    CHECK_PID=$!
    CHECK_STARTED=$SECONDS
}

# -----------------------------------------------------------------------------
# Read CPU/RAM and send telemetry
# -----------------------------------------------------------------------------
#
# Calculate utilisation from the change in cumulative CPU counters since the
# previous reading and from MemTotal and MemAvailable, then send both values
# and wait for the acknowledgements.
#
# Sets CPU, RAM, MEM_USED, MEM_TOTAL and ESP_STATUS for the caller.

update_telemetry() {
    local CURR_TOTAL CURR_IDLE TOTAL_DELTA IDLE_DELTA

    CURR_TOTAL=0
    CURR_IDLE=0

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

    # CPU and RAM are sent independently so the ESP32 can acknowledge each
    # value separately.
    send_command "CPU=$CPU"
    send_command "RAM=$RAM"

    read_acknowledgements

    if [ "$CPU_ACK" -eq 1 ] && [ "$RAM_ACK" -eq 1 ]; then
        ESP_STATUS="CONNECTED"
    elif [ "$CPU_ACK" -eq 1 ] || [ "$RAM_ACK" -eq 1 ]; then
        ESP_STATUS="PARTIAL ACK"
    else
        ESP_STATUS="NO ACK"
    fi

    PREV_TOTAL=$CURR_TOTAL
    PREV_IDLE=$CURR_IDLE
}

# -----------------------------------------------------------------------------
# Blink the LED for an internet outage
# -----------------------------------------------------------------------------
#
# Telemetry is sent between blink steps so the ESP32 never reaches its 3 second
# signal timeout, which would force the LED to red and sweep the gauges.

blink_outage() {
    local i

    echo "Internet DOWN: blinking ${BLINK_COUNT}x ${LED_OUTAGE}"

    for (( i = 0; i < BLINK_COUNT; i++ )); do

        send_command "$LED_OUTAGE"
        sleep "$BLINK_STEP"
        update_telemetry

        send_command "LED=OFF"
        sleep "$BLINK_STEP"
        update_telemetry

    done

    # Back to the normal colour (green while telemetry flows).
    send_command "$LED_NORMAL"
}

# -----------------------------------------------------------------------------
# Initial readings
# -----------------------------------------------------------------------------

read PREV_TOTAL PREV_IDLE <<< "$(read_cpu)"

echo "CPU and RAM gauge started"
echo "Device: $DEVICE"
echo "Sending CPU and RAM usage every second"
echo "Waiting for ESP32 acknowledgements"

if [ "$INTERNET_CHECK_ENABLED" -eq 1 ]; then
    echo "Internet check: $PING_TARGET every ${CHECK_INTERVAL}s (up to ${PING_ATTEMPTS} attempts)"
else
    echo "Internet check: disabled"
fi

echo "Press Ctrl+C to stop"
echo

# -----------------------------------------------------------------------------
# Main loop
# -----------------------------------------------------------------------------

INTERNET_UP=1
NEXT_CHECK=0
NEXT_BLINK=0
CHECK_PID=""
CHECK_STARTED=0

while true; do

    sleep "$INTERVAL"

    update_telemetry

    # -------------------------------------------------------------------------
    # Display values
    # -------------------------------------------------------------------------

    MEM_USED_GB=$(awk "BEGIN { printf \"%.1f\", $MEM_USED / 1024 / 1024 }")
    MEM_TOTAL_GB=$(awk "BEGIN { printf \"%.1f\", $MEM_TOTAL / 1024 / 1024 }")

    echo "CPU: ${CPU}%  RAM: ${RAM}%  (${MEM_USED_GB} / ${MEM_TOTAL_GB} GiB)  ESP32: ${ESP_STATUS}"

    # -------------------------------------------------------------------------
    # Internet outage detection
    # -------------------------------------------------------------------------

    if [ "$INTERNET_CHECK_ENABLED" -eq 1 ]; then

        NOW=$SECONDS

        # Abandon a check that has hung (for example a misbehaving ping) and
        # assume the internet is up rather than raising a false alarm.
        if [ -n "$CHECK_PID" ] && [ $((NOW - CHECK_STARTED)) -ge "$CHECK_WATCHDOG" ]; then
            kill "$CHECK_PID" 2>/dev/null
            CHECK_PID=""
            echo "WARNING: connectivity check timed out; assuming internet is up"
            NEXT_CHECK=$((NOW + CHECK_INTERVAL))
        fi

        # Start a connectivity check when due.
        if [ -z "$CHECK_PID" ] && [ "$NOW" -ge "$NEXT_CHECK" ]; then
            start_internet_check
            NEXT_CHECK=$((NOW + CHECK_INTERVAL))
        fi

        # Collect a finished check.
        if [ -n "$CHECK_PID" ] && [ -s "$NET_STATE" ]; then

            RESULT=$(<"$NET_STATE")
            CHECK_PID=""

            if [ "$RESULT" = "DOWN" ]; then

                if [ "$INTERNET_UP" -eq 1 ]; then
                    echo "Internet outage detected (no reply from $PING_TARGET after $PING_ATTEMPTS attempts)"
                    logger -t gauges "Internet outage: no reply from $PING_TARGET after $PING_ATTEMPTS attempts"
                fi

                INTERNET_UP=0
                NEXT_BLINK=$NOW
                NEXT_CHECK=$((NOW + BLINK_INTERVAL))

            elif [ "$RESULT" = "UP" ]; then

                if [ "$INTERNET_UP" -eq 0 ]; then
                    echo "Internet restored"
                    logger -t gauges "Internet restored (reply from $PING_TARGET)"
                fi

                INTERNET_UP=1
                NEXT_CHECK=$((NOW + CHECK_INTERVAL))
                NEXT_BLINK=0

            fi

        fi

        # Blink while the internet is down.
        if [ "$INTERNET_UP" -eq 0 ] && [ "$NOW" -ge "$NEXT_BLINK" ]; then
            blink_outage
            NEXT_BLINK=$((SECONDS + BLINK_INTERVAL))
        fi

    fi

done
