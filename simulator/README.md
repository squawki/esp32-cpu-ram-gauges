# Gauge simulator

A stand-in for the ESP32-C3 gauge controller, so the server side of the project can be built and tested without hardware.

The project has two halves: the server script that sends CPU and RAM values, and the ESP32 that drives the two gauges and the RGB LED. This directory contains a fake ESP32 that speaks the same serial protocol, answers with the same acknowledgements and behaves the same way when telemetry stops arriving.

```text
simulator/
└── windows/
    ├── simulator.ps1   # the fake ESP32: dials, LED, ACKs, fault mode
    └── simulate.ps1    # starts the simulator and the sender together
```

The sender it is designed to work with lives in [`../windows/gauges.ps1`](../windows/gauges.ps1).

## Requirements

- Windows 10 or 11 with PowerShell 5.1 (built in) or PowerShell 7
- PowerShell 7 on Linux or macOS also runs the simulator, which is handy for testing the script itself

No drivers and no hardware are needed: the simulator and the script talk to each other over TCP on `127.0.0.1`.

## Quick start

From the repository root:

```powershell
.\simulator\windows\simulate.ps1
```

This opens the simulator in its own console window, waits for it to start, then runs the sender against it. Two dials and an LED appear in the simulator window and the sender's console shows one status line per second:

```text
CPU: 34%  RAM: 51%  (16.3 / 32.0 GiB)  ESP32: CONNECTED
```

Close the sender with `Ctrl+C`; the simulator window is closed for you.

If script execution is disabled on the machine, start it like this instead:

```powershell
powershell -ExecutionPolicy Bypass -File .\simulator\windows\simulate.ps1
```

## Headless mode

`-NoUi` runs the simulator without the dials and prints its log when the test finishes. Useful for a quick check or for capturing output:

```powershell
.\simulator\windows\simulate.ps1 -NoUi -Duration 30
```

## Options

### simulate.ps1

| Option | Default | Meaning |
|---|---|---|
| `-TcpPort` | `7777` | Port shared by the simulator and the sender |
| `-Source` | `Auto` | What the sender reports: `Auto` (real CPU and memory of this machine), `Cim` (force Windows counters), `Proc` (force `/proc`), `Random` (invented values on a pretend 32 GiB machine) |
| `-NoUi` | off | Headless simulator, log printed at the end |
| `-Duration` | `0` (forever) | Stop after this many seconds |
| `-InternetCheck` | off | Enable outage detection in the sender so the purple blink can be watched |
| `-PingTarget`, `-CheckInterval`, `-BlinkInterval` | script defaults | Passed straight to the sender |
| `-GaugesPath` | `..\..\windows\gauges.ps1` | Override the sender location |
| `-KeepSimulatorOpen` | off | Leave the simulator window open after the sender exits |

### simulator.ps1

| Option | Default | Meaning |
|---|---|---|
| `-TcpPort` | `7777` | Listen for one TCP client |
| `-Port` | none | Use a real or virtual serial port instead of TCP, for example `COM11` |
| `-Baud` | `115200` | Serial baud rate |
| `-NoUi` | off | One status line per second instead of the dials |
| `-Preview` | none | Draw one frame at the given percentage and exit, for example `-Preview 42` |
| `-Duration` | `0` (forever) | Stop after this many seconds |

## What it reproduces

- `CPU=n` and `RAM=n`, clamped to `0..100`, with `ACK CPU=xx.x` / `ACK RAM=xx.x`
- Every `LED=` command the firmware accepts: `AUTO`, `ON`, `OFF`, `DIM,n`, the seven named colours and `RGB,r,g,b`, with the matching `ACK LED=...` and `ERROR:` replies
- The 3 second communication timeout: `SIGNAL LOST`, the LED forced to red at full brightness and the needles sweeping until telemetry returns (`SIGNAL RESTORED`)
- Dimming to the configured brightness after the first telemetry message
- Brightness retained when the colour changes, and `LED=AUTO` returning to green

It does not reproduce the 500 Hz PWM, the gauge smoothing (needles move instantly) or the physical gauge faces.

## Watching the outage blink

Point the sender at an address that cannot answer, so the outage path triggers immediately:

```powershell
.\simulator\windows\simulate.ps1 -InternetCheck -PingTarget 192.0.2.1 -CheckInterval 10 -BlinkInterval 8
```

The LED in the simulator turns purple, blinks five times, returns to green, and repeats every eight seconds.

## Testing the real serial path

TCP skips the serial code in the sender. To exercise it, install a virtual null-modem pair such as [com0com](https://sourceforge.net/projects/com0com/) (`COM10` <-> `COM11`), then run the two halves separately:

```powershell
.\simulator\windows\simulator.ps1 -Port COM11        # fake ESP32
.\windows\gauges.ps1 -Port COM10 -InternetCheck      # sender
```

## Troubleshooting

- **"running scripts is disabled on this system"** — start PowerShell with `-ExecutionPolicy Bypass`, as shown above.
- **"Could not connect to the simulator at 127.0.0.1:7777"** — the simulator is not running, or another program owns the port. Pass `-TcpPort 7778` to both halves.
- **Dials do not appear** — cursor positioning is unavailable in PowerShell ISE and some redirected consoles; use a normal console window, or `-NoUi`.
- **Needles never move** — the sender is not connected: check for `ESP32: CONNECTED` in its output, and that both halves use the same TCP port.

## Using the real device instead

With the ESP32 plugged in, the simulator is not needed:

```powershell
.\windows\gauges.ps1 -Port COM3
```

See the [Windows section](../README.md#windows) of the main README for running the sender at startup.
