#Requires -Version 5.1
<#
.SYNOPSIS
    ESP32-C3 gauge controller simulator.

.DESCRIPTION
    Pretends to be the ESP32 firmware so that windows/gauges.ps1 can be tested
    without hardware.

    It accepts the same newline-terminated commands as the real firmware
    (CPU=n, RAM=n and the LED=... commands), answers with the same ACKs, and
    draws two analogue dials and an RGB LED status indicator in the console.

    The simulator also reproduces the firmware's 3 second communication
    timeout: if no telemetry arrives, it reports SIGNAL LOST over the link,
    turns the LED solid red at full brightness and sweeps both needles until
    telemetry returns.

    Two transports are supported:

      -Tcp     (default) listens on 127.0.0.1:7777 and gauges.ps1 connects with
               -Simulate. No drivers or extra hardware are needed.

      -Port    opens a real serial port, for use with a virtual null-modem pair
               such as com0com (for example COM10 <-> COM11), so that the
               serial code path in gauges.ps1 is exercised too.

.PARAMETER TcpPort
    TCP port to listen on in TCP mode. Defaults to 7777.

.PARAMETER Port
    Serial port to open in serial mode, for example COM11.

.PARAMETER Baud
    Serial baud rate. Defaults to 115200.

.PARAMETER NoUi
    Print one status line per second instead of drawing the dials.

.PARAMETER Preview
    Draw a single frame with the given percentage on both dials and exit. Handy
    for checking how the dials render in a particular console.

.PARAMETER Duration
    Exit after this many seconds. Zero (the default) runs until interrupted.

.EXAMPLE
    .\simulator.ps1

.EXAMPLE
    .\simulator.ps1 -Port COM11

.EXAMPLE
    .\simulator.ps1 -NoUi -Duration 30
#>
[CmdletBinding()]
param(
    [int]$TcpPort = 7777,

    [string]$Port = '',
    [int]$Baud = 115200,

    [switch]$NoUi,
    [double]$Preview = -1,

    [int]$Duration = 0
)

# =============================================================================
# Firmware behaviour
# =============================================================================

$script:SignalTimeoutSeconds = 3.0
$script:FaultSweepSeconds = 4.0
$script:DefaultLedDimPercent = 50

# =============================================================================
# Simulator state
# =============================================================================

$script:CpuPercent = 0.0
$script:RamPercent = 0.0

$script:HasSignal = $false
$script:LastSignal = Get-Date
$script:SignalFault = $false

$script:LedMode = 'AUTO'        # AUTO or MANUAL
$script:LedEnabled = $true
$script:LedDimPercent = $script:DefaultLedDimPercent
$script:BootFullBrightness = $true
$script:ManualRed = 0
$script:ManualGreen = 0
$script:ManualBlue = 0

$script:LastCommand = '(none)'

# =============================================================================
# Rendering
# =============================================================================

function Get-DialLines {
    param(
        [double]$Value,
        [string]$Label,
        [int]$Width = 17,
        [int]$Height = 7
    )

    if ($Value -lt 0) { $Value = 0 }
    if ($Value -gt 100) { $Value = 100 }

    $centreX = [math]::Floor($Width / 2)
    $centreY = $Height - 1
    $radiusX = [math]::Floor(($Width - 3) / 2)
    $radiusY = $Height - 2

    $grid = New-Object 'string[,]' $Height, $Width
    for ($y = 0; $y -lt $Height; $y++) {
        for ($x = 0; $x -lt $Width; $x++) { $grid[$y, $x] = ' ' }
    }

    # Scale marks along the arc.
    for ($i = 0; $i -le 24; $i++) {
        $angle = [math]::PI * $i / 24
        $x = $centreX + [int][math]::Round($radiusX * [math]::Cos($angle))
        $y = $centreY - [int][math]::Round($radiusY * [math]::Sin($angle))
        if ($y -ge 0 -and $y -lt $Height -and $x -ge 0 -and $x -lt $Width) {
            $grid[$y, $x] = '.'
        }
    }

    # Needle.
    $needleAngle = [math]::PI * (1.0 - ($Value / 100.0))
    $tipX = $centreX + $radiusX * [math]::Cos($needleAngle)
    $tipY = $centreY - $radiusY * [math]::Sin($needleAngle)

    $steps = 24
    for ($s = 1; $s -le $steps; $s++) {
        $t = $s / $steps
        $x = $centreX + [int][math]::Round(($tipX - $centreX) * $t)
        $y = $centreY - [int][math]::Round(($centreY - $tipY) * $t)
        if ($y -ge 0 -and $y -lt $Height -and $x -ge 0 -and $x -lt $Width) {
            $grid[$y, $x] = '*'
        }
    }

    $grid[$centreY, $centreX] = '+'

    if ($tipY -ge 0 -and $tipY -lt $Height -and $tipX -ge 0 -and $tipX -lt $Width) {
        $grid[[int]$tipY, [int]$tipX] = 'O'
    }

    $lines = @()
    for ($y = 0; $y -lt $Height; $y++) {
        $line = ''
        for ($x = 0; $x -lt $Width; $x++) { $line += $grid[$y, $x] }
        $lines += $line
    }

    $lines += ('{0,6}%  {1}' -f [int][math]::Round($Value), $Label)

    return $lines
}

function Get-LedState {
    if ($script:SignalFault) {
        return @{ Red = 255; Green = 0; Blue = 0; Percent = 100; Name = 'red'; ConsoleColour = 'Red' }
    }

    if (-not $script:LedEnabled) {
        return @{ Red = 0; Green = 0; Blue = 0; Percent = 0; Name = 'off'; ConsoleColour = 'DarkGray' }
    }

    $percent = $script:LedDimPercent
    if ($script:BootFullBrightness) { $percent = 100 }

    if ($script:LedMode -eq 'MANUAL') {
        $name = 'custom'
        $consoleColour = 'Magenta'

        if ($script:ManualRed -eq 0 -and $script:ManualGreen -eq 0 -and $script:ManualBlue -eq 0) { $name = 'off'; $consoleColour = 'DarkGray' }
        elseif ($script:ManualRed -eq 255 -and $script:ManualGreen -eq 0 -and $script:ManualBlue -eq 0) { $name = 'red'; $consoleColour = 'Red' }
        elseif ($script:ManualRed -eq 0 -and $script:ManualGreen -eq 255 -and $script:ManualBlue -eq 0) { $name = 'green'; $consoleColour = 'Green' }
        elseif ($script:ManualRed -eq 0 -and $script:ManualGreen -eq 0 -and $script:ManualBlue -eq 255) { $name = 'blue'; $consoleColour = 'Blue' }
        elseif ($script:ManualRed -eq 255 -and $script:ManualGreen -eq 255 -and $script:ManualBlue -eq 0) { $name = 'yellow'; $consoleColour = 'Yellow' }
        elseif ($script:ManualRed -eq 0 -and $script:ManualGreen -eq 255 -and $script:ManualBlue -eq 255) { $name = 'cyan'; $consoleColour = 'Cyan' }
        elseif ($script:ManualRed -eq 255 -and $script:ManualGreen -eq 0 -and $script:ManualBlue -eq 255) { $name = 'magenta'; $consoleColour = 'Magenta' }
        elseif ($script:ManualRed -eq 255 -and $script:ManualGreen -eq 255 -and $script:ManualBlue -eq 255) { $name = 'white'; $consoleColour = 'White' }

        return @{
            Red = $script:ManualRed; Green = $script:ManualGreen; Blue = $script:ManualBlue
            Percent = $percent; Name = $name; ConsoleColour = $consoleColour
        }
    }

    if ($script:HasSignal) {
        return @{ Red = 0; Green = 255; Blue = 0; Percent = $percent; Name = 'green'; ConsoleColour = 'Green' }
    }

    return @{ Red = 0; Green = 0; Blue = 255; Percent = $percent; Name = 'blue'; ConsoleColour = 'Blue' }
}

function Get-PanelLines {
    param([double]$Cpu, [double]$Ram)

    $cpuDial = Get-DialLines -Value $Cpu -Label 'CPU'
    $ramDial = Get-DialLines -Value $Ram -Label 'RAM'

    $lines = @()
    $lines += ''
    $lines += '  ESP32-C3 gauge controller simulator'

    $dialRows = [math]::Max($cpuDial.Count, $ramDial.Count)

    for ($i = 0; $i -lt $dialRows; $i++) {
        $left = ''
        $right = ''
        if ($i -lt $cpuDial.Count) { $left = $cpuDial[$i] }
        if ($i -lt $ramDial.Count) { $right = $ramDial[$i] }
        $lines += ('   {0}    {1}' -f $left.PadRight(21), $right)
    }

    if ($script:SignalFault) {
        $state = 'FAULT - no telemetry from the server'
    }
    elseif (-not $script:HasSignal) {
        $state = 'waiting for telemetry'
    }
    else {
        $state = 'OK'
    }

    $led = Get-LedState

    $lines += ''
    $lines += ('   LED: {0} ({1}%)   state: {2}' -f $led.Name.ToUpper(), $led.Percent, $state)
    $lines += ('   last command: {0}' -f $script:LastCommand)
    $lines += ''

    return $lines
}

function Write-PanelFrame {
    param([string[]]$Lines)

    if (-not $script:Interactive) {
        return
    }

    try { [Console]::SetCursorPosition(0, 0) } catch { return }

    $width = 0
    try { $width = [Console]::WindowWidth } catch { }

    $led = Get-LedState

    foreach ($line in $Lines) {
        $text = $line
        if ($width -gt 1 -and $text.Length -ge $width) {
            $text = $text.Substring(0, $width - 1)
        }

        $padded = $text.PadRight([math]::Max($width - 1, $text.Length))

        if ($line -like '   LED:*') {
            Write-Host $padded -ForegroundColor $led.ConsoleColour
        }
        else {
            Write-Host $padded
        }
    }
}

# =============================================================================
# Command handling
# =============================================================================

function Format-AckValue {
    param([double]$Value)
    return $Value.ToString('0.0', [System.Globalization.CultureInfo]::InvariantCulture)
}

function Set-CpuValue {
    param([string]$Value)

    $number = 0.0
    if (-not [double]::TryParse($Value, [ref]$number)) {
        return 'ERROR: CPU must be a number'
    }

    if ($number -lt 0 -or $number -gt 100) {
        return 'ERROR: CPU must be between 0 and 100'
    }

    $script:CpuPercent = $number
    $script:HasSignal = $true
    $script:LastSignal = Get-Date
    $script:BootFullBrightness = $false

    return ('ACK CPU={0}' -f (Format-AckValue $number))
}

function Set-RamValue {
    param([string]$Value)

    $number = 0.0
    if (-not [double]::TryParse($Value, [ref]$number)) {
        return 'ERROR: RAM must be a number'
    }

    if ($number -lt 0 -or $number -gt 100) {
        return 'ERROR: RAM must be between 0 and 100'
    }

    $script:RamPercent = $number
    $script:HasSignal = $true
    $script:LastSignal = Get-Date
    $script:BootFullBrightness = $false

    return ('ACK RAM={0}' -f (Format-AckValue $number))
}

function Set-LedCommand {
    param([string]$Command)

    $value = $Command.Substring(4).Trim().ToUpper()

    switch ($value) {

        'AUTO' {
            $script:LedMode = 'AUTO'
            $script:LedEnabled = $true
            $script:BootFullBrightness = $false
            return 'ACK LED=AUTO'
        }

        'ON' {
            $script:LedEnabled = $true
            $script:BootFullBrightness = $false
            return ('ACK LED=ON DIM={0}' -f $script:LedDimPercent)
        }

        'OFF' {
            $script:LedEnabled = $false
            $script:BootFullBrightness = $false
            return 'ACK LED=OFF'
        }

        'RED' { $script:LedMode = 'MANUAL'; $script:LedEnabled = $true; $script:BootFullBrightness = $false; $script:ManualRed = 255; $script:ManualGreen = 0; $script:ManualBlue = 0; return 'ACK LED=RED' }
        'GREEN' { $script:LedMode = 'MANUAL'; $script:LedEnabled = $true; $script:BootFullBrightness = $false; $script:ManualRed = 0; $script:ManualGreen = 255; $script:ManualBlue = 0; return 'ACK LED=GREEN' }
        'BLUE' { $script:LedMode = 'MANUAL'; $script:LedEnabled = $true; $script:BootFullBrightness = $false; $script:ManualRed = 0; $script:ManualGreen = 0; $script:ManualBlue = 255; return 'ACK LED=BLUE' }
        'YELLOW' { $script:LedMode = 'MANUAL'; $script:LedEnabled = $true; $script:BootFullBrightness = $false; $script:ManualRed = 255; $script:ManualGreen = 255; $script:ManualBlue = 0; return 'ACK LED=YELLOW' }
        'CYAN' { $script:LedMode = 'MANUAL'; $script:LedEnabled = $true; $script:BootFullBrightness = $false; $script:ManualRed = 0; $script:ManualGreen = 255; $script:ManualBlue = 255; return 'ACK LED=CYAN' }
        'MAGENTA' { $script:LedMode = 'MANUAL'; $script:LedEnabled = $true; $script:BootFullBrightness = $false; $script:ManualRed = 255; $script:ManualGreen = 0; $script:ManualBlue = 255; return 'ACK LED=MAGENTA' }
        'WHITE' { $script:LedMode = 'MANUAL'; $script:LedEnabled = $true; $script:BootFullBrightness = $false; $script:ManualRed = 255; $script:ManualGreen = 255; $script:ManualBlue = 255; return 'ACK LED=WHITE' }
    }

    if ($value.StartsWith('DIM,')) {

        $dimText = $value.Substring(4)
        $dim = 0

        if (-not [int]::TryParse($dimText, [ref]$dim) -or $dim -lt 0 -or $dim -gt 100) {
            return 'ERROR: DIM must be between 0 and 100'
        }

        $script:LedDimPercent = $dim
        $script:BootFullBrightness = $false

        return ('ACK LED=DIM,{0}' -f $dim)
    }

    if ($value.StartsWith('RGB,')) {

        $parts = $value.Substring(4).Split(',')

        if ($parts.Count -ne 3) {
            return 'ERROR: RGB format is LED=RGB,R,G,B'
        }

        $red = 0
        $green = 0
        $blue = 0

        $parsed = [int]::TryParse($parts[0], [ref]$red) -and
                  [int]::TryParse($parts[1], [ref]$green) -and
                  [int]::TryParse($parts[2], [ref]$blue)

        if (-not $parsed -or
            $red -lt 0 -or $red -gt 255 -or
            $green -lt 0 -or $green -gt 255 -or
            $blue -lt 0 -or $blue -gt 255) {
            return 'ERROR: RGB values must be between 0 and 255'
        }

        $script:LedMode = 'MANUAL'
        $script:LedEnabled = $true
        $script:BootFullBrightness = $false
        $script:ManualRed = $red
        $script:ManualGreen = $green
        $script:ManualBlue = $blue

        return ('ACK LED=RGB,{0},{1},{2}' -f $red, $green, $blue)
    }

    return ('ERROR: Unknown LED command: {0}' -f $value)
}

function Invoke-DeviceCommand {
    param([string]$Command)

    $Command = $Command.Trim()
    if ($Command -eq '') { return $null }

    $script:LastCommand = $Command

    if ($Command.StartsWith('LED=')) { return (Set-LedCommand -Command $Command) }
    if ($Command.StartsWith('CPU=')) { return (Set-CpuValue -Value $Command.Substring(4)) }
    if ($Command.StartsWith('RAM=')) { return (Set-RamValue -Value $Command.Substring(4)) }

    return ('ERROR: Unknown command: {0}' -f $Command)
}

# =============================================================================
# Transport
# =============================================================================

function Initialize-SimulatorTransport {
    param([string]$PortName, [int]$BaudRate, [int]$TcpListenPort)

    if ($PortName) {

        $serial = New-Object System.IO.Ports.SerialPort $PortName, $BaudRate, 'None', 8, 'One'
        $serial.NewLine = "`n"
        $serial.ReadTimeout = 100
        $serial.WriteTimeout = 1000

        try { $serial.Open() }
        catch { throw "Could not open ${PortName}: $($_.Exception.Message)" }

        $script:Serial = $serial
        $script:Mode = 'Serial'
        $script:Description = "serial port ${PortName} at ${BaudRate} baud"

        return
    }

    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $TcpListenPort)
    $listener.Start()

    Write-Host ("Listening on 127.0.0.1:{0} - start gauges.ps1 with -Simulate" -f $TcpListenPort)

    $client = $listener.AcceptTcpClient()
    $client.NoDelay = $true

    $stream = $client.GetStream()

    $script:Listener = $listener
    $script:Client = $client
    $script:NetStream = $stream
    $script:Writer = New-Object System.IO.StreamWriter($stream)
    $script:Writer.AutoFlush = $true

    $script:Mode = 'Tcp'
    $script:Description = ("TCP 127.0.0.1:{0}" -f $TcpListenPort)
}

function Read-Available {
    if ($script:Mode -eq 'Serial') {
        return $script:Serial.ReadExisting()
    }

    if (-not $script:NetStream -or -not $script:NetStream.DataAvailable) { return '' }

    $buffer = New-Object byte[] 4096
    $read = $script:NetStream.Read($buffer, 0, $buffer.Length)

    if ($read -le 0) { return '' }

    return [System.Text.Encoding]::ASCII.GetString($buffer, 0, $read)
}

function Send-Reply {
    param([string]$Line)

    if (-not $Line) { return }

    if ($script:Mode -eq 'Serial') {
        $script:Serial.WriteLine($Line)
    }
    else {
        $script:Writer.WriteLine($Line)
    }
}

function Close-SimulatorTransport {
    if ($script:Mode -eq 'Serial' -and $script:Serial) {
        if ($script:Serial.IsOpen) { $script:Serial.Close() }
        $script:Serial.Dispose()
    }
    elseif ($script:Mode -eq 'Tcp') {
        if ($script:Writer) { $script:Writer.Dispose() }
        if ($script:NetStream) { $script:NetStream.Dispose() }
        if ($script:Client) { $script:Client.Dispose() }
        if ($script:Listener) { $script:Listener.Stop() }
    }
}

# =============================================================================
# Preview
# =============================================================================

if ($Preview -ge 0) {
    $previewLines = Get-PanelLines -Cpu $Preview -Ram ([math]::Max(0, 100 - $Preview))
    Write-Host ($previewLines -join "`n")
    exit 0
}

# =============================================================================
# Main
# =============================================================================

$script:Interactive = (-not $NoUi) -and (-not [Console]::IsOutputRedirected)

Initialize-SimulatorTransport -PortName $Port -BaudRate $Baud -TcpListenPort $TcpPort

Write-Host ''
Write-Host 'ESP32-C3 gauge simulator'
Write-Host "Device: $($script:Description)"
Write-Host 'Waiting for commands (Ctrl+C to stop)'
Write-Host ''

$startedAt = Get-Date
$lastRender = (Get-Date).AddSeconds(-1)
$lastNoUi = (Get-Date).AddSeconds(-1)

$pending = New-Object System.Text.StringBuilder

try {

    while ($true) {

        $chunk = Read-Available
        if ($chunk) {
            [void]$pending.Append($chunk)

            while ($pending.ToString().Contains("`n")) {

                $text = $pending.ToString()
                $index = $text.IndexOf("`n")
                $line = $text.Substring(0, $index).TrimEnd("`r")
                [void]$pending.Remove(0, $index + 1)

                $reply = Invoke-DeviceCommand -Command $line
                if ($reply) { Send-Reply -Line $reply }
            }
        }

        # Communication timeout, matching the firmware.
        if ($script:HasSignal -and -not $script:SignalFault) {
            $age = ((Get-Date) - $script:LastSignal).TotalSeconds
            if ($age -gt $script:SignalTimeoutSeconds) {
                $script:SignalFault = $true
                Send-Reply -Line 'SIGNAL LOST'
                Send-Reply -Line 'Entering gauge fault sweep'
            }
        }

        if ($script:SignalFault -and $script:HasSignal) {
            $age = ((Get-Date) - $script:LastSignal).TotalSeconds
            if ($age -le $script:SignalTimeoutSeconds) {
                $script:SignalFault = $false
                Send-Reply -Line 'SIGNAL RESTORED'
            }
        }

        $now = Get-Date

        $displayCpu = $script:CpuPercent
        $displayRam = $script:RamPercent

        if ($script:SignalFault) {
            $phase = 2 * [math]::PI * (($now - $script:LastSignal).TotalSeconds / $script:FaultSweepSeconds)
            $displayCpu = 50 + 45 * [math]::Sin($phase)
            $displayRam = 50 - 45 * [math]::Sin($phase)
        }

        if ($script:Interactive) {

            if (($now - $lastRender).TotalMilliseconds -ge 100) {
                $lines = Get-PanelLines -Cpu $displayCpu -Ram $displayRam
                Write-PanelFrame -Lines $lines
                $lastRender = $now
            }
        }
        elseif (($now - $lastNoUi).TotalMilliseconds -ge 1000) {

            $led = Get-LedState
            $state = 'OK'
            if ($script:SignalFault) { $state = 'FAULT' }
            elseif (-not $script:HasSignal) { $state = 'READY' }

            Write-Host ('[{0,6:0.0}s] CPU={1,5:0.0} RAM={2,5:0.0} LED={3}({4}%) state={5} last="{6}"' -f `
                ($now - $startedAt).TotalSeconds, $displayCpu, $displayRam, $led.Name.ToUpper(), $led.Percent, $state, $script:LastCommand)

            $lastNoUi = $now
        }

        Start-Sleep -Milliseconds 50

        if ($Duration -gt 0 -and ($now - $startedAt).TotalSeconds -ge $Duration) {
            Write-Host ''
            Write-Host ("Simulator stopped after {0}s" -f $Duration)
            break
        }
    }
}
finally {
    Close-SimulatorTransport
}
