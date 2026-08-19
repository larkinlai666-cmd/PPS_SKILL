[CmdletBinding()]
param(
    [string]$Root
)

# Project verification entry. scripts/verify_gate.ps1 executes this file and
# refuses to write a verify stamp unless it exits 0.
#
# Replace and extend the checks below with the project's real verification:
# unit tests, builds, linters, and at least one behavioral end-to-end
# assertion for software packages. Every check must exit non-zero on failure.
# Keep checks deterministic and bounded. This file must stay a real
# verification entry: an unconditional `exit 0` defeats the gate.

$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($Root)) {
    $Root = Split-Path -Parent $PSScriptRoot
}
$rootFull = (Resolve-Path -LiteralPath $Root).Path
$failures = 0

function Invoke-Check([string]$Label, [scriptblock]$Body) {
    $ok = $false
    try { $ok = & $Body } catch { $ok = $false }
    if ($ok) {
        Write-Host "PASS project_verify: $Label"
    } else {
        Write-Host "FAIL project_verify: $Label"
        $script:failures++
    }
}

$stateText = [System.IO.File]::ReadAllText(
    (Join-Path $rootFull 'PROJECT_STATE.md'), [System.Text.Encoding]::UTF8)
$hotMatch = [regex]::Match(
    $stateText, '(?ms)^##\s+Hot State\s*\r?\n(?<body>.*?)(?=^##\s+|\z)')
$mainRel = ''
if ($hotMatch.Success) {
    $mainMatch = [regex]::Match(
        $hotMatch.Groups['body'].Value, '(?m)^-\s+Main:\s*(.*?)\s*$')
    if ($mainMatch.Success) { $mainRel = $mainMatch.Groups[1].Value }
}

Invoke-Check "main artifact exists ($mainRel)" {
    -not [string]::IsNullOrWhiteSpace($mainRel) -and
    (Test-Path -LiteralPath (Join-Path $rootFull $mainRel))
}
Invoke-Check "EVENTS.md records at least one event" {
    $eventsText = [System.IO.File]::ReadAllText(
        (Join-Path $rootFull 'EVENTS.md'), [System.Text.Encoding]::UTF8)
    $eventsText -match '(?m)^- \d{4}-\d{2}-\d{2}: \[PKG-'
}

# Add project-specific checks here, for example:
#   Invoke-Check "unit tests" { npm test; $LASTEXITCODE -eq 0 }
#   Invoke-Check "e2e smoke" { node scripts/e2e-smoke.js; $LASTEXITCODE -eq 0 }

if ($failures -gt 0) {
    Write-Host "project_verify: FAILED ($failures check(s))"
    exit 1
}
Write-Host "project_verify: OK"
exit 0
