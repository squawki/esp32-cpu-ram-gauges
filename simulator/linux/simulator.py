#!/usr/bin/env python3
"""ESP32-C3 gauge controller simulator (Linux).

Pretends to be the ESP32 firmware so that linux/gauges.sh can be tested
without hardware. It accepts the same newline-terminated commands as the real
firmware (CPU=n, RAM=n and the LED=... commands), answers with the same ACKs,
and draws two analogue dials plus an RGB LED indicator in the terminal.

The simulator also reproduces the firmware's 3 second communication timeout:
if no telemetry arrives it reports SIGNAL LOST on the link, turns the LED solid
red at full brightness and sweeps both needles until telemetry returns.

Transport: a pseudo-terminal. The simulator prints the device path the sender
should use, for example:

    Device: /dev/pts/7
    Attach the sender: DEVICE=/dev/pts/7 ./linux/gauges.sh

Use --write-device-file to have the path written to a file as well, which is
what simulator/linux/simulate.sh uses.
"""

from __future__ import annotations

import argparse
import math
import os
import pty
import select
import shutil
import sys
import time
import tty

SIGNAL_TIMEOUT = 3.0
FAULT_SWEEP_SECONDS = 4.0
DEFAULT_LED_DIM_PERCENT = 50

NAMED_COLOURS = {
    'RED': (255, 0, 0),
    'GREEN': (0, 255, 0),
    'BLUE': (0, 0, 255),
    'YELLOW': (255, 255, 0),
    'CYAN': (0, 255, 255),
    'MAGENTA': (255, 0, 255),
    'WHITE': (255, 255, 255),
}


class State:
    """Everything the firmware would keep in RAM."""

    def __init__(self) -> None:
        self.cpu = 0.0
        self.ram = 0.0

        self.has_signal = False
        self.last_signal = 0.0
        self.fault = False

        self.led_mode = 'AUTO'
        self.led_enabled = True
        self.dim = DEFAULT_LED_DIM_PERCENT
        self.boot_full = True
        self.manual: tuple[int, int, int] = (0, 0, 0)

        self.last_command = '(none)'
        self.last_cpu_rx = '(none)'
        self.last_ram_rx = '(none)'


# -----------------------------------------------------------------------------
# LED state
# -----------------------------------------------------------------------------

def led_state(state: State) -> dict:
    if state.fault:
        return {'rgb': (255, 0, 0), 'percent': 100, 'name': 'red'}

    if not state.led_enabled:
        return {'rgb': (0, 0, 0), 'percent': 0, 'name': 'off'}

    percent = 100 if state.boot_full else state.dim

    if state.led_mode == 'MANUAL':
        rgb = state.manual

        name = 'custom'
        if rgb == (0, 0, 0):
            name = 'off'
        else:
            for candidate, value in NAMED_COLOURS.items():
                if rgb == value:
                    name = candidate.lower()
                    break

        return {'rgb': rgb, 'percent': percent, 'name': name}

    if state.has_signal:
        return {'rgb': (0, 255, 0), 'percent': percent, 'name': 'green'}

    return {'rgb': (0, 0, 255), 'percent': percent, 'name': 'blue'}


def ansi_color(rgb: tuple) -> str:
    r, g, b = rgb
    return f'\x1b[38;2;{r};{g};{b}m'


# -----------------------------------------------------------------------------
# Rendering
# -----------------------------------------------------------------------------

def dial_lines(value: float, label: str, width: int = 17, height: int = 7) -> list:
    value = max(0.0, min(100.0, value))

    centre_x = width // 2
    centre_y = height - 1
    radius_x = (width - 3) // 2
    radius_y = height - 2

    grid = [[' '] * width for _ in range(height)]

    # Scale marks along the arc.
    for step in range(25):
        angle = math.pi * step / 24
        x = centre_x + round(radius_x * math.cos(angle))
        y = centre_y - round(radius_y * math.sin(angle))
        if 0 <= y < height and 0 <= x < width:
            grid[y][x] = '.'

    # Needle.
    needle_angle = math.pi * (1.0 - value / 100.0)
    tip_x = centre_x + radius_x * math.cos(needle_angle)
    tip_y = centre_y - radius_y * math.sin(needle_angle)

    steps = 24
    for step in range(1, steps + 1):
        fraction = step / steps
        x = centre_x + round((tip_x - centre_x) * fraction)
        y = centre_y - round((centre_y - tip_y) * fraction)
        if 0 <= y < height and 0 <= x < width:
            grid[y][x] = '*'

    grid[centre_y][centre_x] = '+'

    tip_col = round(tip_x)
    tip_row = round(tip_y)
    if 0 <= tip_row < height and 0 <= tip_col < width:
        grid[tip_row][tip_col] = 'O'

    lines = [''.join(row) for row in grid]
    lines.append(f'{round(value):>6}%  {label}')
    return lines


def panel_lines(state: State, cpu: float, ram: float) -> list:
    cpu_dial = dial_lines(cpu, 'CPU')
    ram_dial = dial_lines(ram, 'RAM')

    if state.fault:
        status = 'FAULT - no telemetry from the server'
    elif not state.has_signal:
        status = 'waiting for telemetry'
    else:
        status = 'OK'

    led = led_state(state)

    lines = [
        '',
        '  ESP32-C3 gauge controller simulator',
    ]

    for index in range(max(len(cpu_dial), len(ram_dial))):
        left = cpu_dial[index] if index < len(cpu_dial) else ''
        right = ram_dial[index] if index < len(ram_dial) else ''
        lines.append(f'   {left:<21}    {right}')

    lines += [
        '',
        f"   LED: {led['name'].upper()} ({led['percent']}%)   state: {status}",
        f'   rx: CPU={state.last_cpu_rx}  RAM={state.last_ram_rx}',
        f'   last command: {state.last_command}',
        '',
    ]

    return lines


def render(state: State, cpu: float, ram: float, use_colour: bool) -> None:
    lines = panel_lines(state, cpu, ram)

    try:
        width = shutil.get_terminal_size().columns
    except OSError:
        width = 80

    out = ['\x1b[H']

    for line in lines:
        text = line[:max(width - 1, 1)].ljust(max(width - 1, 1))
        if use_colour and line.strip().startswith('LED:'):
            out.append(ansi_color(led_state(state)['rgb']) + text + '\x1b[0m')
        else:
            out.append(text)
        out.append('\n')

    sys.stdout.write(''.join(out))
    sys.stdout.flush()


# -----------------------------------------------------------------------------
# Command handling
# -----------------------------------------------------------------------------

def ack_value(value: float) -> str:
    return f'{value:.1f}'


def set_cpu(state: State, text: str) -> str:
    try:
        value = float(text)
    except ValueError:
        return 'ERROR: CPU must be a number'

    if value < 0 or value > 100:
        return 'ERROR: CPU must be between 0 and 100'

    state.cpu = value
    state.has_signal = True
    state.last_signal = time.monotonic()
    state.boot_full = False
    state.last_cpu_rx = ack_value(value)

    return f'ACK CPU={ack_value(value)}'


def set_ram(state: State, text: str) -> str:
    try:
        value = float(text)
    except ValueError:
        return 'ERROR: RAM must be a number'

    if value < 0 or value > 100:
        return 'ERROR: RAM must be between 0 and 100'

    state.ram = value
    state.has_signal = True
    state.last_signal = time.monotonic()
    state.boot_full = False
    state.last_ram_rx = ack_value(value)

    return f'ACK RAM={ack_value(value)}'


def set_led(state: State, command: str) -> str:
    value = command[4:].strip().upper()

    if value == 'AUTO':
        state.led_mode = 'AUTO'
        state.led_enabled = True
        state.boot_full = False
        return 'ACK LED=AUTO'

    if value == 'ON':
        state.led_enabled = True
        state.boot_full = False
        return f'ACK LED=ON DIM={state.dim}'

    if value == 'OFF':
        state.led_enabled = False
        state.boot_full = False
        return 'ACK LED=OFF'

    if value in NAMED_COLOURS:
        state.led_mode = 'MANUAL'
        state.led_enabled = True
        state.boot_full = False
        state.manual = NAMED_COLOURS[value]
        return f'ACK LED={value}'

    if value.startswith('DIM,'):
        try:
            dim = int(value[4:])
        except ValueError:
            return 'ERROR: DIM must be between 0 and 100'

        if dim < 0 or dim > 100:
            return 'ERROR: DIM must be between 0 and 100'

        state.dim = dim
        state.boot_full = False
        return f'ACK LED=DIM,{dim}'

    if value.startswith('RGB,'):
        parts = value[4:].split(',')

        if len(parts) != 3:
            return 'ERROR: RGB format is LED=RGB,R,G,B'

        try:
            red_text, green_text, blue_text = parts
            rgb = (int(red_text), int(green_text), int(blue_text))
        except ValueError:
            return 'ERROR: RGB values must be between 0 and 255'

        if any(channel < 0 or channel > 255 for channel in rgb):
            return 'ERROR: RGB values must be between 0 and 255'

        state.led_mode = 'MANUAL'
        state.led_enabled = True
        state.boot_full = False
        state.manual = rgb

        return 'ACK LED=RGB,{0},{1},{2}'.format(*rgb)

    return f'ERROR: Unknown LED command: {value}'


def handle_command(state: State, command: str):
    command = command.strip()

    if not command:
        return None

    state.last_command = command

    if command.startswith('LED='):
        return set_led(state, command)
    if command.startswith('CPU='):
        return set_cpu(state, command[4:])
    if command.startswith('RAM='):
        return set_ram(state, command[4:])

    return f'ERROR: Unknown command: {command}'


# -----------------------------------------------------------------------------
# Transport
# -----------------------------------------------------------------------------

def open_transport(device: str):
    """Returns (read_fd, write_fd, peer_path, own_fds)."""

    if device:
        fd = os.open(device, os.O_RDWR | os.O_NOCTTY)
        tty.setraw(fd)
        return fd, fd, device, [fd]

    master, slave = pty.openpty()
    tty.setraw(slave)

    peer = os.ttyname(slave)

    return master, master, peer, [master, slave]


def main() -> int:
    parser = argparse.ArgumentParser(description='ESP32-C3 gauge controller simulator')
    parser.add_argument('--device', default='', help='attach to an existing tty/pty instead of creating one')
    parser.add_argument('--write-device-file', default='', help='write the device path to this file')
    parser.add_argument('--no-ui', action='store_true', help='one status line per second instead of the dials')
    parser.add_argument('--no-color', action='store_true', help='do not colour the LED line')
    parser.add_argument('--preview', type=float, default=None, help='draw one frame at this percentage and exit')
    parser.add_argument('--duration', type=float, default=0.0, help='stop after this many seconds (0 = forever)')
    parser.add_argument('--fault-timeout', type=float, default=SIGNAL_TIMEOUT, help='seconds without telemetry before the fault sweep')
    args = parser.parse_args()

    state = State()

    if args.preview is not None:
        cpu = max(0.0, min(100.0, args.preview))
        for line in panel_lines(state, cpu, 100.0 - cpu):
            print(line)
        return 0

    read_fd, write_fd, peer, own_fds = open_transport(args.device)

    if args.write_device_file:
        with open(args.write_device_file, 'w', encoding='utf-8') as handle:
            handle.write(peer + '\n')

    interactive = (not args.no_ui) and sys.stdout.isatty()
    use_colour = interactive and (not args.no_color) and not os.environ.get('NO_COLOR')

    print()
    print('ESP32-C3 gauge simulator')
    print(f'Device: {peer}')
    print(f'Attach the sender: DEVICE={peer} ./linux/gauges.sh')
    print('Waiting for commands (Ctrl+C to stop)')
    print()

    if interactive:
        sys.stdout.write('\x1b[2J')
        sys.stdout.flush()

    pending = ''
    started = time.monotonic()
    last_render = 0.0
    last_line = 0.0

    def write_line(text: str) -> None:
        os.write(write_fd, (text + '\n').encode('utf-8'))

    try:
        while True:
            ready, _, _ = select.select([read_fd], [], [], 0.05)

            if ready:
                try:
                    chunk = os.read(read_fd, 4096)
                except OSError:
                    chunk = b''

                if chunk:
                    pending += chunk.decode('utf-8', 'replace')

                    while '\n' in pending:
                        line, pending = pending.split('\n', 1)
                        reply = handle_command(state, line.rstrip('\r'))
                        if reply:
                            write_line(reply)

            now = time.monotonic()

            # Communication timeout, matching the firmware.
            if state.has_signal and not state.fault:
                if now - state.last_signal > args.fault_timeout:
                    state.fault = True
                    write_line('SIGNAL LOST')
                    write_line('Entering gauge fault sweep')

            if state.fault and state.has_signal and (now - state.last_signal) <= args.fault_timeout:
                state.fault = False
                write_line('SIGNAL RESTORED')

            display_cpu = state.cpu
            display_ram = state.ram

            if state.fault:
                phase = 2 * math.pi * ((now - state.last_signal) / FAULT_SWEEP_SECONDS)
                display_cpu = 50 + 45 * math.sin(phase)
                display_ram = 50 - 45 * math.sin(phase)

            if interactive:
                if now - last_render >= 0.1:
                    render(state, display_cpu, display_ram, use_colour)
                    last_render = now
            elif now - last_line >= 1.0:
                led = led_state(state)
                status = 'FAULT' if state.fault else ('OK' if state.has_signal else 'READY')
                print(f'[{now - started:6.1f}s] CPU={display_cpu:5.1f} RAM={display_ram:5.1f} '
                      f"LED={led['name'].upper()}({led['percent']}%) state={status} "
                      f'last="{state.last_command}"', flush=True)
                last_line = now

            if args.duration > 0 and (now - started) >= args.duration:
                break

    except KeyboardInterrupt:
        pass
    finally:
        for fd in own_fds:
            try:
                os.close(fd)
            except OSError:
                pass

    print()
    print('Simulator stopped')
    return 0


if __name__ == '__main__':
    sys.exit(main())
