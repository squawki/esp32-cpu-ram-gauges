#Requires -Version 5.1
<#
.SYNOPSIS
    CPU and RAM gauge telemetry for the ESP32-C3 gauge controller.

.DESCRIPTION
    Windows port of linux/gauges.sh.

    Sends CPU and physical memory utilisation to the ESP32 over USB serial at
    115200 baud, reads the ESP32 acknowledgements and, optionally, watches
    internet connectivity and blinks the RGB LED while the connection is down.

    The ESP32 protocol is unchanged: CPU=n, RAM=n and LED=... commands are sent
    as newline-terminated text, and the ESP32 answers with ACK CPU=xx.x,
    ACK RAM=xx.x or ACK LED=....

.PARAMETER Port
    Serial port name, for example COM3. Defaults to the first available port.

.PARAMETER Baud
    Serial baud rate. The firmware uses 115200.

.PARAMETER Simulate
    Connect to windows/simulator.ps1 over TCP instead of a serial port. Useful
    for testing the whole script without hardware.

.PARAMETER SimulatorHost
    Host used with -Simulate. Defaults to 127.0.0.1.

.PARAMETER SimulatorPort
    TCP port used with -Simulate. Defaults to 7777.

.PARAMETER Source
    Where CPU and memory readings come from: Cim (Windows performance data),
    Proc (/proc, for testing on Linux) or Random (simulator testing).
    Auto selects Cim on Windows and Proc elsewhere.

.PARAMETER InternetCheck
    Enable the optional internet outage detection described below.

.PARAMETER PingTarget
    Address pinged by the connectivity check. Defaults to 1.1.1.1.

.PARAMETER CheckInterval
    Seconds between checks while the internet is up. Defaults to 60.

.PARAMETER BlinkInterval
    Seconds between blink sequences while the internet is down. Defaults to 30.

.PARAMETER LogFile
    Optional path for outage and recovery log lines.

.PARAMETER Duration
    Stop after this many seconds. Zero (the default) runs until interrupted.

.EXAMPLE
    .\gauges.ps1 -Port COM3

.EXAMPLE
    .\gauges.ps1 -Simulate -Source Random

.EXAMPLE
    .\gauges.ps1 -Port COM3 -InternetCheck -PingTarget 8.8.8.8
#>
[CmdletBinding()]
param(
    [string]$Port,
    [int]$Baud = 115200,

    [switch]$Simulate,
    [string]$SimulatorHost = '127.0.0.1',
    [int]$SimulatorPort = 7777,

    [ValidateSet('Auto', 'Cim', 'Proc', 'Random')]
    [string]$Source = 'Auto',

    [switch]$InternetCheck,
    [string]$PingTarget = '',
    [int]$CheckInterval = 0,
    [int]$BlinkInterval = 0,

    [string]$LogFile = '',
    [int]$Duration = 0
)

# =============================================================================
# Settings
# =============================================================================
#
# These mirror the configuration block in linux/gauges.sh. The matching
# command-line parameters above override the values here.

$script:Interval = 1                 # seconds between telemetry updates
$script:AckTimeoutMs = 500           # wait for the ESP32 acknowledgements

$script:InternetCheckEnabled = [bool]$InternetCheck
$script:PingTargetName = '1.1.1.1'   # address pinged; an IP avoids DNS
$script:PingAttempts = 3             # retry only after a failed attempt
$script:PingTimeoutMs = 2000         # per-attempt timeout
$script:CheckIntervalSeconds = 60    # between checks while up
$script:BlinkIntervalSeconds = 30    # between blinks while down
$script:BlinkCount = 5
$script:BlinkStepMs = 250
$script:LedOutage = 'LED=RGB,255,0,255'
$script:LedNormal = 'LED=AUTO'

# =============================================================================

if ($PingTarget) { $script:PingTargetName = $PingTarget }
if ($CheckInterval -gt 0) { $script:CheckIntervalSeconds = $CheckInterval }
if ($BlinkInterval -gt 0) { $script:BlinkIntervalSeconds = $BlinkInterval }

$script:LogFile = $LogFile
$script:IsWindowsHost = ($env:OS -eq 'Windows_NT')
$script:DeviceDescription = ''

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------

function Write-LogEntry {
    param([string]$Message)

    $line = '{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $Message

    if ($script:LogFile) {
        try {
            Add-Content -Path $script:LogFile -Value $line -ErrorAction Stop
        }
        catch {
            Write-Warning "Could not write to log file: $($_.Exception.Message)"
        }
    }
}

# -----------------------------------------------------------------------------
# Device transport
# -----------------------------------------------------------------------------
#
# The transport is either a serial port or, with -Simulate, a TCP connection to
# windows/simulator.ps1. Both carry the same newline-terminated protocol.

function Initialize-Device {
    param(
        [string]$PortName,
        [int]$BaudRate,
        [switch]$UseTcp,
        [string]$HostName,
        [int]$TcpPort
    )

    if ($UseTcp) {

        $client = $null
        $deadline = (Get-Date).AddSeconds(15)

        while ($true) {
            try {
                $client = New-Object System.Net.Sockets.TcpClient
                $client.Connect($HostName, $TcpPort)
                break
            }
            catch {
                if ($client) { $client.Dispose(); $client = $null }

                if ((Get-Date) -ge $deadline) {
                    throw "Could not connect to the simulator at ${HostName}:${TcpPort}. Is windows/simulator.ps1 running?"
                }

                Start-Sleep -Milliseconds 500
            }
        }

        $script:NetStream = $client.GetStream()
        $script:NetStream.ReadTimeout = $script:AckTimeoutMs

        $script:Reader = New-Object System.IO.StreamReader($script:NetStream)
        $script:Writer = New-Object System.IO.StreamWriter($script:NetStream)
        $script:Writer.AutoFlush = $true

        $script:DeviceMode = 'Tcp'
        $script:DeviceDescription = "simulator ${HostName}:${TcpPort}"
        return
    }

    if (-not $PortName) {
        $available = [System.IO.Ports.SerialPort]::GetPortNames()

        if (-not $available -or $available.Count -eq 0) {
            throw 'No serial ports found. Connect the ESP32 or specify -Port COM3.'
        }

        $PortName = $available[0]
    }

    $serial = New-Object System.IO.Ports.SerialPort $PortName, $BaudRate, 'None', 8, 'One'
    $serial.ReadTimeout = $script:AckTimeoutMs
    $serial.WriteTimeout = 1000
    $serial.NewLine = "`n"

    try {
        $serial.Open()
    }
    catch {
        throw "Could not open ${PortName}: $($_.Exception.Message)"
    }

    $script:Serial = $serial
    $script:DeviceMode = 'Serial'
    $script:DeviceDescription = "serial port ${PortName} at ${BaudRate} baud"
}

function Send-Line {
    param([string]$Line)

    try {
        if ($script:DeviceMode -eq 'Tcp') {
            $script:Writer.WriteLine($Line)
        }
        else {
            $script:Serial.WriteLine($Line)
        }
    }
    catch {
        throw "Failed to send to the ESP32: $Line ($($_.Exception.Message))"
    }
}

function Read-Line {
    param([int]$TimeoutMs = 500)

    if ($script:DeviceMode -eq 'Tcp') {
        $script:NetStream.ReadTimeout = $TimeoutMs
        try {
            return $script:Reader.ReadLine()
        }
        catch [System.IO.IOException] {
            return $null
        }
        catch [System.TimeoutException] {
            return $null
        }
        catch [System.ObjectDisposedException] {
            return $null
        }
    }

    $script:Serial.ReadTimeout = $TimeoutMs

    try {
        return $script:Serial.ReadLine()
    }
    catch [System.TimeoutException] {
        return $null
    }
    catch [System.IO.IOException] {
        return $null
    }
}

function Close-Device {
    if ($script:DeviceMode -eq 'Tcp') {
        if ($script:Writer) { $script:Writer.Dispose() }
        if ($script:Reader) { $script:Reader.Dispose() }
        if ($script:NetStream) { $script:NetStream.Dispose() }
    }
    elseif ($script:Serial) {
        if ($script:Serial.IsOpen) { $script:Serial.Close() }
        $script:Serial.Dispose()
    }
}

# -----------------------------------------------------------------------------
# CPU and memory readings
# -----------------------------------------------------------------------------

$script:SourceMethod = $Source

if ($script:SourceMethod -eq 'Auto') {
    if ($script:IsWindowsHost) { $script:SourceMethod = 'Cim' }
    else { $script:SourceMethod = 'Proc' }
}

$script:TotalMemoryMb = 0
$script:RandomCpu = 25.0
$script:RandomRam = 50.0
$script:PrevTotal = 0
$script:PrevIdle = 0

function Initialize-Metrics {
    switch ($script:SourceMethod) {

        'Cim' {
            $os = Get-CimInstance -ClassName Win32_OperatingSystem
            $script:TotalMemoryMb = [double]$os.TotalVisibleMemorySize / 1024.0
        }

        'Proc' {
            $info = Get-Content /proc/meminfo
            foreach ($line in $info) {
                if ($line -match '^MemTotal:\s+(\d+)') {
                    $script:TotalMemoryMb = [double]$Matches[1] / 1024.0
                }
            }

            $stat = (Get-Content /proc/stat -TotalCount 1) -split '\s+'
            $script:PrevIdle = [double]$stat[4] + [double]$stat[5]
            $script:PrevTotal = 0.0
            for ($i = 1; $i -le 8; $i++) { $script:PrevTotal += [double]$stat[$i] }
        }

        default {
            # A plausible machine for simulator runs.
            $script:TotalMemoryMb = 32768.0
        }
    }
}

function Get-CpuPercent {
    switch ($script:SourceMethod) {

        'Cim' {
            $perf = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'"
            return [double]$perf.PercentProcessorTime
        }

        'Proc' {
            $stat = (Get-Content /proc/stat -TotalCount 1) -split '\s+'
            $idle = [double]$stat[4] + [double]$stat[5]
            $total = 0.0
            for ($i = 1; $i -le 8; $i++) { $total += [double]$stat[$i] }

            $totalDelta = $total - $script:PrevTotal
            $idleDelta = $idle - $script:PrevIdle

            $script:PrevTotal = $total
            $script:PrevIdle = $idle

            if ($totalDelta -le 0) { return 0.0 }

            $value = 100.0 * ($totalDelta - $idleDelta) / $totalDelta
            if ($value -lt 0) { $value = 0 }
            if ($value -gt 100) { $value = 100 }
            return $value
        }

        default {
            $script:RandomCpu += Get-Random -Minimum -9 -Maximum 10
            if ($script:RandomCpu -lt 3) { $script:RandomCpu = 3 }
            if ($script:RandomCpu -gt 97) { $script:RandomCpu = 97 }
            return [math]::Round($script:RandomCpu, 0)
        }
    }
}

function Get-MemoryUsedMb {
    switch ($script:SourceMethod) {

        'Cim' {
            $perf = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_Memory
            return $script:TotalMemoryMb - [double]$perf.AvailableMBytes
        }

        'Proc' {
            $available = 0.0
            foreach ($line in (Get-Content /proc/meminfo)) {
                if ($line -match '^MemAvailable:\s+(\d+)') { $available = [double]$Matches[1] / 1024.0 }
            }
            return $script:TotalMemoryMb - $available
        }

        default {
            $script:RandomRam += Get-Random -Minimum -2 -Maximum 3
            if ($script:RandomRam -lt 20) { $script:RandomRam = 20 }
            if ($script:RandomRam -gt 90) { $script:RandomRam = 90 }
            return $script:TotalMemoryMb * ($script:RandomRam / 100.0)
        }
    }
}

# -----------------------------------------------------------------------------
# Telemetry
# -----------------------------------------------------------------------------

function Update-Telemetry {
    param([switch]$Quiet)

    $cpu = Get-CpuPercent
    $usedMb = Get-MemoryUsedMb

    if ($script:TotalMemoryMb -le 0) { $script:TotalMemoryMb = $usedMb }

    $ram = 0
    if ($script:TotalMemoryMb -gt 0) {
        $ram = [math]::Round(100.0 * $usedMb / $script:TotalMemoryMb, 0)
    }
    if ($ram -lt 0) { $ram = 0 }
    if ($ram -gt 100) { $ram = 100 }

    Send-Line ('CPU={0}' -f [int]$cpu)
    Send-Line ('RAM={0}' -f [int]$ram)

    $cpuAck = $false
    $ramAck = $false
    $deadline = (Get-Date).AddMilliseconds($script:AckTimeoutMs + 1000)

    while (-not ($cpuAck -and $ramAck) -and (Get-Date) -lt $deadline) {
        $response = Read-Line -TimeoutMs $script:AckTimeoutMs
        if ($null -eq $response -or $response -eq '') {
            if ($null -eq $response) { break }
            continue
        }

        $response = $response.TrimEnd("`r")

        if ($response -like 'ACK CPU=*') { $cpuAck = $true; continue }
        if ($response -like 'ACK RAM=*') { $ramAck = $true; continue }
        if ($response -like 'ACK LED=*') { continue }

        if (-not $Quiet) { Write-Host "ESP32: $response" }
    }

    $status = 'NO ACK'
    if ($cpuAck -and $ramAck) { $status = 'CONNECTED' }
    elseif ($cpuAck -or $ramAck) { $status = 'PARTIAL ACK' }

    return [pscustomobject]@{
        Cpu       = [int]$cpu
        Ram       = [int]$ram
        MemUsedGb = [math]::Round($usedMb / 1024.0, 1)
        MemTotGb  = [math]::Round($script:TotalMemoryMb / 1024.0, 1)
        Status    = $status
    }
}

# -----------------------------------------------------------------------------
# Internet outage detection
# -----------------------------------------------------------------------------

$script:Pinger = $null
$script:PingTask = $null
$script:PingAttempt = 0
$script:InternetUp = $true
$script:NextCheck = (Get-Date)
$script:CheckStartedAt = Get-Date

function Start-PingAttempt {
    if (-not $script:Pinger) {
        $script:Pinger = New-Object System.Net.NetworkInformation.Ping
    }

    if ($script:PingAttempt -eq 0) { $script:CheckStartedAt = Get-Date }

    $script:PingAttempt++
    $script:PingTask = $script:Pinger.SendPingAsync($script:PingTargetName, $script:PingTimeoutMs)
}

function Test-PingTaskSucceeded {
    try {
        return ($script:PingTask.Result.Status -eq [System.Net.NetworkInformation.IPStatus]::Success)
    }
    catch {
        return $false
    }
}

function Blink-Outage {
    Write-Host ("Internet DOWN: blinking {0}x {1}" -f $script:BlinkCount, $script:LedOutage)

    for ($i = 0; $i -lt $script:BlinkCount; $i++) {
        Send-Line $script:LedOutage
        Start-Sleep -Milliseconds $script:BlinkStepMs
        Update-Telemetry -Quiet | Out-Null

        Send-Line 'LED=OFF'
        Start-Sleep -Milliseconds $script:BlinkStepMs
        Update-Telemetry -Quiet | Out-Null
    }

    Send-Line $script:LedNormal
}

function Invoke-InternetCheckTick {
    $now = Get-Date

    if (-not $script:PingTask -and $now -ge $script:NextCheck) {
        Start-PingAttempt
    }

    if ($script:PingTask -and $script:PingTask.IsCompleted) {

        $succeeded = Test-PingTaskSucceeded
        $script:PingTask = $null

        if (-not $succeeded -and $script:PingAttempt -lt $script:PingAttempts) {
            Start-PingAttempt
            return
        }

        if (-not $succeeded) {

            $script:PingAttempt = 0

            if ($script:InternetUp) {
                Write-Host ("Internet outage detected (no reply from {0} after {1} attempts)" -f $script:PingTargetName, $script:PingAttempts)
                Write-LogEntry ("Internet outage: no reply from {0} after {1} attempts" -f $script:PingTargetName, $script:PingAttempts)
            }

            $script:InternetUp = $false

            # Blink straight away, then schedule the next check so that the
            # following blink lands about BlinkInterval seconds after this one,
            # whatever the ping took to fail.
            $checkDuration = (Get-Date) - $script:CheckStartedAt
            $blinkStartedAt = Get-Date

            Blink-Outage

            $nextCheckAt = $blinkStartedAt.AddSeconds($script:BlinkIntervalSeconds) - $checkDuration
            $lead = ($nextCheckAt - (Get-Date)).TotalSeconds
            if ($lead -lt 0) { $lead = 0 }

            $script:NextCheck = (Get-Date).AddSeconds($lead)
        }
        else {

            $script:PingAttempt = 0

            if (-not $script:InternetUp) {
                Write-Host 'Internet restored'
                Write-LogEntry ("Internet restored (reply from {0})" -f $script:PingTargetName)
            }

            $script:InternetUp = $true
            $script:NextCheck = $now.AddSeconds($script:CheckIntervalSeconds)
        }
    }
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

$script:LogFile = $LogFile

Initialize-Device -PortName $Port -BaudRate $Baud -UseTcp:$Simulate `
    -HostName $SimulatorHost -TcpPort $SimulatorPort

Initialize-Metrics

Write-Host 'CPU and RAM gauge started'
Write-Host "Device: $($script:DeviceDescription)"
Write-Host 'Sending CPU and RAM usage every second'
Write-Host 'Waiting for ESP32 acknowledgements'

if ($script:InternetCheckEnabled) {
    Write-Host ("Internet check: {0} every {1}s (up to {2} attempts)" -f $script:PingTargetName, $script:CheckIntervalSeconds, $script:PingAttempts)
}
else {
    Write-Host 'Internet check: disabled'
}

Write-Host 'Press Ctrl+C to stop'
Write-Host ''

$startedAt = Get-Date

try {
    while ($true) {

        Start-Sleep -Milliseconds ($script:Interval * 1000)

        $reading = Update-Telemetry

        Write-Host ("CPU: {0}%  RAM: {1}%  ({2:0.0} / {3:0.0} GiB)  ESP32: {4}" -f `
            $reading.Cpu, $reading.Ram, $reading.MemUsedGb, $reading.MemTotGb, $reading.Status)

        if ($script:InternetCheckEnabled) {
            Invoke-InternetCheckTick
        }

        if ($Duration -gt 0 -and ((Get-Date) - $startedAt).TotalSeconds -ge $Duration) {
            Write-Host ''
            Write-Host ("Stopped after {0}s" -f $Duration)
            break
        }
    }
}
finally {
    Close-Device
}
