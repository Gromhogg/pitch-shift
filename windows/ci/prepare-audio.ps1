# GitHub checks only: gets a runner ready for sound tests. Installs VB-CABLE, allows apps to use
# the microphone, and makes the cable the default speakers and microphone.
# (A runner has no real microphone, and VB-CABLE allows only one copy, so the cable is also the
# only microphone there.)
param([Parameter(Mandatory)] [string]$Tool)
$ErrorActionPreference = 'Stop'

& (Join-Path $PSScriptRoot 'install-vbcable.ps1')

$policy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy'
New-Item -Path $policy -Force | Out-Null
New-ItemProperty -Path $policy -Name LetAppsAccessMicrophone -Value 1 -PropertyType DWord -Force | Out-Null
foreach ($root in 'HKLM:', 'HKCU:') {
    $store = "$root\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone"
    New-Item -Path $store -Force | Out-Null
    New-ItemProperty -Path $store -Name Value -Value Allow -PropertyType String -Force | Out-Null
    New-Item -Path "$store\NonPackaged" -Force | Out-Null
    New-ItemProperty -Path "$store\NonPackaged" -Name Value -Value Allow -PropertyType String -Force | Out-Null
}

# Remember which cable is "ours" (setup-mic finds it already installed and just writes that down).
& $Tool setup-mic --silent

& $Tool set-default playback pitch-shift-feed
& $Tool set-default recording pitch-shift-mic
Get-PnpDevice -Class AudioEndpoint -ErrorAction SilentlyContinue | Format-Table -AutoSize Status, FriendlyName | Out-String -Width 200 | Write-Host
$global:LASTEXITCODE = 0
