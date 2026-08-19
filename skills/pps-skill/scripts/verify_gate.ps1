[CmdletBinding()]
param(
    [string]$Root
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($Root)) {
    $Root = Split-Path -Parent $PSScriptRoot
}
$rootFull = [System.IO.Path]::GetFullPath($Root)
if (-not (Test-Path -LiteralPath $rootFull -PathType Container)) {
    Write-Host "ERROR: project root is not a directory: $Root"
    exit 1
}
$rootFull = (Resolve-Path -LiteralPath $rootFull).Path

Write-Host "== PPS verify gate =="

Write-Host "-- Step 1/3: structural validation"
$engine = Get-Command pwsh -ErrorAction SilentlyContinue
if ($null -eq $engine) {
    $engine = Get-Command powershell -ErrorAction Stop
}
& $engine.Source -NoProfile -ExecutionPolicy Bypass -File `
    (Join-Path $rootFull 'scripts/validate_project.ps1') -Root $rootFull -Quiet
if ($LASTEXITCODE -ne 0) {
    Write-Host "PPS verify gate: FAILED (structural validation)"
    exit 1
}
Write-Host "structural validation: pass"

Write-Host "-- Step 2/3: project checks"
# Add ordered project-specific checks below. Each check must exit non-zero on
# failure. Keep them deterministic and bounded. Include at least one
# behavioral assertion (user-visible end-to-end smoke check) for software
# packages: unit-green does not prove the wired system works, and a deployed
# file is not necessarily a loaded file.
#
# Example:
#   npm test -- app; if ($LASTEXITCODE -ne 0) { exit 1 }
#   node scripts/e2e-smoke.js; if ($LASTEXITCODE -ne 0) { exit 1 }
Write-Host "project checks: none declared yet (extend this script)"

Write-Host "-- Step 3/3: recording verify stamp"
$stateText = [System.IO.File]::ReadAllText(
    (Join-Path $rootFull 'PROJECT_STATE.md'), [System.Text.Encoding]::UTF8)
$hotMatch = [regex]::Match(
    $stateText,
    '(?ms)^##\s+Hot State\s*\r?\n(?<body>.*?)(?=^##\s+|\z)')
$packageId = $null
if ($hotMatch.Success) {
    $packageMatch = [regex]::Match(
        $hotMatch.Groups['body'].Value, '(?m)^-\s+Package:\s*(.*?)\s*$')
    if ($packageMatch.Success) {
        $packageId = $packageMatch.Groups[1].Value
    }
}
if ([string]::IsNullOrWhiteSpace($packageId)) {
    Write-Host "PPS verify gate: FAILED (cannot resolve current package)"
    exit 1
}
$stampDir = Join-Path $rootFull '.pps'
if (-not (Test-Path -LiteralPath $stampDir)) {
    New-Item -ItemType Directory -Path $stampDir -Force | Out-Null
}
$utcNow = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
$stampText = "package: $packageId`nverified_at: $utcNow`n"
[System.IO.File]::WriteAllText(
    (Join-Path $stampDir 'verify-stamp'),
    $stampText,
    [System.Text.UTF8Encoding]::new($false))
Write-Host "verify stamp: $packageId"
Write-Host "PPS verify gate: OK"
exit 0
