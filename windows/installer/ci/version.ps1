# GitHub checks only: picks the version number for this build and saves it for the next steps.
#   A release tagged "v2.0.0-beta.3" -> 2.0.0-beta.3 (Windows file version 2.0.0.0)
#   Any other build                  -> 2.0.0-beta.dev<run number> (file version 2.0.0.<run number>)
$tag = if ($env:GITHUB_EVENT_NAME -eq 'release') { $env:GITHUB_REF_NAME } else { '' }
if ($tag -match '^v?((\d+)\.(\d+)\.(\d+).*)$') {
    $version = $Matches[1]
    $numeric = "$($Matches[2]).$($Matches[3]).$($Matches[4]).0"
} else {
    $run = [int]($env:GITHUB_RUN_NUMBER ?? '0') % 65535
    $version = "2.0.0-beta.dev$run"
    $numeric = "2.0.0.$run"
}
Write-Host "Version: $version ($numeric)"
if ($env:GITHUB_ENV) {
    "PS_VERSION=$version" | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding utf8
    "PS_NUMERIC_VERSION=$numeric" | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding utf8
}
