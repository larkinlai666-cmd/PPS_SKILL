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
Write-Output 'Verification attestation: caller confirmed the declared environment and project checks passed.'
Write-Output 'PPS readiness: OK'
