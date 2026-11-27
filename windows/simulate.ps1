#Requires -Version 5.1
<#
.SYNOPSIS
    Runs the gauge simulator and gauges.ps1 together.

.DESCRIPTION
    Starts windows/simulator.ps1 (a fake ESP32-C3 with two moving-coil dials and
    an RGB LED) and then runs windows/gauges.ps1 against it over TCP, so the
    whole telemetry path can be exercised without any hardware.

    By default the simulator opens in its own console window so the dials stay
    visible. With -NoUi it runs headless and its log is printed when the test
    ends.

.PARAMETER TcpPort
    TCP port shared by the simulator and gauges.ps1. Defaults to 7777.

.PARAMETER Source
    Metric source passed to gauges.ps1. Random (the default) makes the needles
    move on their own; Cim reads real Windows performance counters.

.PARAMETER NoUi
    Run the simulator headless and print its log at the end.

.PARAMETER Duration
    How long to run, in seconds. Zero runs until Ctrl+C.

.PARAMETER InternetCheck
    Enable internet outage detection in gauges.ps1 so the blink can be seen in
    the simulator.

.PARAMETER KeepSimulatorOpen
    Leave the simulator window open after gauges.ps1 exits.

.EXAMPLE
    .\simulate.ps1

.EXAMPLE
    .\simulate.ps1 -Duration 30

.EXAMPLE
    .\simulate.ps1 -NoUi -InternetCheck -PingTarget 192.0.2.1 -CheckInterval 10 -BlinkInterval 8 -Duration 30
#>
[CmdletBinding()]
param(
    [int]$TcpPort = 7777,

    [ValidateSet('Auto', 'Cim', 'Proc', 'Random')]
    [string]$Source = 'Random',

    [switch]$NoUi,
    [int]$Duration = 0,

    [switch]$InternetCheck,
    [string]$PingTarget = '',
    [int]$CheckInterval = 0,
    [int]$BlinkInterval = 0,

    [switch]$KeepSimulatorOpen
)

$here = $PSScriptRoot
$simulatorPath = Join-Path $here 'simulator.ps1'
$gaugesPath = Join-Path $here 'gauges.ps1'

foreach ($path in @($simulatorPath, $gaugesPath)) {
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Missing file: $path"
    }
}

$pwshPath = (Get-Process -Id $PID).Path

# Start-Process joins an -ArgumentList array with spaces and does not quote
# entries, so quote the script path in case the repository lives somewhere with
# spaces in the path (for example C:\Users\First Last\...).
$simulatorArgs = @('-NoProfile', '-File', ('"{0}"' -f $simulatorPath), '-TcpPort', $TcpPort)

if ($NoUi) { $simulatorArgs += '-NoUi' }
if ($Duration -gt 0) { $simulatorArgs += @('-Duration', ($Duration + 10)) }

$simulatorLog = $null
$simulator = $null

try {

    if ($NoUi) {
        $simulatorLog = Join-Path ([System.IO.Path]::GetTempPath()) ('gauges-sim-{0}.log' -f ([guid]::NewGuid().ToString('N')))

        $simulator = Start-Process -FilePath $pwshPath -ArgumentList $simulatorArgs `
            -RedirectStandardOutput $simulatorLog -RedirectStandardError ($simulatorLog + '.err') `
            -PassThru -NoNewWindow
    }
    else {
        $simulator = Start-Process -FilePath $pwshPath -ArgumentList $simulatorArgs -PassThru
    }

    $gaugeArgs = @(
        '-NoProfile', '-File', $gaugesPath,
        '-Simulate', '-SimulatorPort', $TcpPort,
        '-Source', $Source
    )

    if ($InternetCheck) { $gaugeArgs += '-InternetCheck' }
    if ($PingTarget) { $gaugeArgs += @('-PingTarget', $PingTarget) }
    if ($CheckInterval -gt 0) { $gaugeArgs += @('-CheckInterval', $CheckInterval) }
    if ($BlinkInterval -gt 0) { $gaugeArgs += @('-BlinkInterval', $BlinkInterval) }
    if ($Duration -gt 0) { $gaugeArgs += @('-Duration', $Duration) }

    & $pwshPath @gaugeArgs
}
finally {

    if ($simulator -and -not $simulator.HasExited -and -not $KeepSimulatorOpen) {
        Stop-Process -Id $simulator.Id -Force -ErrorAction SilentlyContinue
    }

    if ($simulatorLog -and (Test-Path -LiteralPath $simulatorLog)) {
        Write-Host ''
        Write-Host '--- simulator log ---'
        Get-Content -LiteralPath $simulatorLog | Select-Object -Last 15
    }
}
