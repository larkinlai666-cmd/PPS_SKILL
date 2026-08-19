[CmdletBinding()]
param(
    [string]$Root,
    [switch]$Verified
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($Root)) {
    $Root = Split-Path -Parent $PSScriptRoot
}
$rootFull = [System.IO.Path]::GetFullPath($Root)
$engine = Get-Command pwsh -ErrorAction SilentlyContinue
if ($null -eq $engine) { $engine = Get-Command powershell -ErrorAction Stop }

& $engine.Source -NoProfile -ExecutionPolicy Bypass -File `
    (Join-Path $rootFull 'scripts/validate_project.ps1') -Root $rootFull
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& $engine.Source -NoProfile -ExecutionPolicy Bypass -File `
    (Join-Path $rootFull 'scripts/asset_check.ps1') -Root $rootFull -Handoff -Risk
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$contextLines = [System.IO.File]::ReadAllLines(
    (Join-Path $rootFull 'CONTEXT.md'),
    [System.Text.Encoding]::UTF8
)
$inside = $false
$verify = ''
foreach ($line in $contextLines) {
    if ($line -eq '## Workset Manifest') { $inside = $true; continue }
    if ($inside -and $line -match '^## ') { break }
    if ($inside -and $line.StartsWith('- Verify:')) {
        $verify = $line.Substring('- Verify:'.Length).Trim()
        break
    }
}
$environmentLines = [System.IO.File]::ReadAllLines(
    (Join-Path $rootFull 'ENVIRONMENT.md'),
    [System.Text.Encoding]::UTF8
)
$inside = $false
$environmentVerify = 'none'
foreach ($line in $environmentLines) {
    if ($line -eq '## Project Commands') { $inside = $true; continue }
    if ($inside -and $line -match '^## ') { break }
    if ($inside -and $line.StartsWith('- Environment verify:')) {
        $environmentVerify = $line.Substring('- Environment verify:'.Length).Trim()
        break
    }
}
Write-Output "Declared environment Verify: $environmentVerify"
Write-Output "Declared project Verify: $verify"
if (-not $Verified) {
    Write-Output 'PPS readiness: VERIFY PENDING'
    Write-Output 'Inspect and run the declared project verification, then rerun with -Verified only after it passes.'
    exit 3
}
$stateLines = [System.IO.File]::ReadAllLines(
    (Join-Path $rootFull 'PROJECT_STATE.md'),
    [System.Text.Encoding]::UTF8
)
$inside = $false
$protocol = ''
$packageId = ''
foreach ($line in $stateLines) {
    if ($line -eq '## Hot State') { $inside = $true; continue }
    if ($inside -and $line -match '^## ') { break }
    if ($inside -and $line.StartsWith('- Protocol:')) {
        $protocol = $line.Substring('- Protocol:'.Length).Trim()
    }
    if ($inside -and $line.StartsWith('- Package:')) {
        $packageId = $line.Substring('- Package:'.Length).Trim()
    }
}
if ($protocol -eq 'PPS/1.2') {
    $stampPath = Join-Path $rootFull '.pps/verify-stamp'
    if (-not (Test-Path -LiteralPath $stampPath -PathType Leaf)) {
        Write-Output 'PPS readiness: VERIFY EVIDENCE MISSING'
        Write-Output 'No verify stamp found; run scripts/verify_gate.* on this device first.'
        exit 4
    }
    $stampLines = [System.IO.File]::ReadAllLines($stampPath, [System.Text.Encoding]::UTF8)
    $stampPackage = ''
    $stampTime = ''
    foreach ($line in $stampLines) {
        if ($line.StartsWith('package:')) { $stampPackage = $line.Substring('package:'.Length).Trim() }
        if ($line.StartsWith('verified_at:')) { $stampTime = $line.Substring('verified_at:'.Length).Trim() }
    }
    if ($stampPackage -ne $packageId) {
        Write-Output 'PPS readiness: VERIFY EVIDENCE STALE'
        Write-Output "Verify stamp names '$stampPackage' but the current package is '$packageId'; rerun scripts/verify_gate.*."
        exit 4
    }
    Write-Output "Verify stamp: $stampPackage ($stampTime)"
}
Write-Output 'Verification attestation: caller confirmed the declared environment and project checks passed.'
Write-Output 'PPS readiness: OK'
