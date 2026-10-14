# GitHub checks only: turns the JSON reports in a folder into a table on the run's summary page.
param([Parameter(Mandatory)] [string]$Folder, [string]$Title = 'Checks')
if (-not (Test-Path $Folder)) { exit 0 }
$lines = @("## $Title", '')
foreach ($file in Get-ChildItem -Path $Folder -Filter *.json) {
    $r = Get-Content $file.FullName -Raw | ConvertFrom-Json
    if (-not $r.PSObject.Properties['checks']) { continue }
    $lines += "### $($file.BaseName) ($($r.machine), $($r.os))"
    if ($r.PSObject.Properties['recommended_mode']) { $lines += "Recommended quieting mode: **$($r.recommended_mode)**" }
    $lines += '', '| check | result | value | meaning |', '|---|---|---|---|'
    foreach ($p in $r.checks.PSObject.Properties) {
        $c = $p.Value
        $mark = if ($null -eq $c.pass) { 'info' } elseif ($c.pass) { 'pass' } else { '**FAIL**' }
        $lines += "| $($p.Name) | $mark | $($c.value | ConvertTo-Json -Compress -Depth 5) | $($c.meaning) |"
    }
    $lines += ''
    foreach ($n in $r.notes) { $lines += "- $n" }
    $lines += ''
}
if ($env:GITHUB_STEP_SUMMARY) { $lines -join "`n" | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8 }
else { $lines -join "`n" }
