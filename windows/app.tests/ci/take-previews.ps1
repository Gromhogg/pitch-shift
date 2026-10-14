# GitHub checks only: pictures of the window in many states, light and dark (no sound, no clicking).
# Uses PitchShift.exe --preview <states> --screenshot <file> (see windows/app/Preview.cs).
param(
    [Parameter(Mandatory)] [string]$Exe,
    [string]$Out = 'shots',
    [double]$Scale = 2
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$Out = (Resolve-Path $Out).Path

# name = preview states (like the Mac screenshots: on, waiting, typing, recording...)
$states = [ordered]@{
    'on'        = 'hear-on,voice-on,cartoon'
    'waiting'   = 'hear-on,waiting,cartoon'
    'typing'    = 'hear-on,typing,cartoon'
    'recording' = 'hear-on,voice-on,cartoon,recording'
    'playing'   = 'hear-on,voice-on,playing'
    'in-use'    = 'hear-on,voice-on,in-use,all'
    'two-apps'  = 'hear-on,two-apps,voice-on'
    'off'       = ''
    'repair'    = 'hear-on,repair'
    'restart'   = 'hear-on,restart'
    'allow-mic' = 'hear-on,voice-on,allow-mic'
    'no-mic'    = 'hear-on,no-mic'
    'menu'      = 'hear-on,voice-on,menu'
}
$failed = 0
foreach ($theme in 'light', 'dark') {
    foreach ($name in $states.Keys) {
        $file = Join-Path $Out "$name-$theme.png"
        $arguments = @('--preview', "`"$($states[$name])`"", '--theme', $theme, '--scale', "$Scale", '--screenshot', "`"$file`"")
        $p = Start-Process -FilePath $Exe -ArgumentList $arguments -PassThru
        if (-not $p.WaitForExit(60000)) { $p.Kill(); Write-Host "Timed out: $name ($theme)"; $failed++; continue }
        if ((Test-Path $file) -and $p.ExitCode -eq 0) { Write-Host "Saved $file" } else { Write-Host "No picture: $name ($theme), exit $($p.ExitCode)"; $failed++ }
    }
}
$log = Join-Path $env:LOCALAPPDATA 'Pitch Shift\app-log.txt'
if (Test-Path $log) { Write-Host '--- app log ---'; Get-Content $log | Write-Host }
if ($failed) { throw "$failed picture(s) missing" }
