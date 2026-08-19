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
    $stamp = @{}
    foreach ($line in [System.IO.File]::ReadAllLines($stampPath, [System.Text.Encoding]::UTF8)) {
        $sep = $line.IndexOf(':')
        if ($sep -gt 0) {
            $stamp[$line.Substring(0, $sep).Trim()] = $line.Substring($sep + 1).Trim()
        }
    }
    function Deny-StaleStamp([string]$Reason) {
        Write-Output 'PPS readiness: VERIFY EVIDENCE STALE'
        Write-Output $Reason
        Write-Output 'Rerun scripts/verify_gate.* on this device.'
        exit 4
    }
    if ($stamp['package'] -ne $packageId) {
        Deny-StaleStamp "Verify stamp names '$($stamp['package'])' but the current package is '$packageId'."
    }
    if ($stamp['result'] -ne 'pass') {
        Deny-StaleStamp "Verify stamp records result '$($stamp['result'])', not 'pass'."
    }
    $entryRel = $stamp['entry']
    $entryPath = if ([string]::IsNullOrWhiteSpace($entryRel)) { $null } else { Join-Path $rootFull $entryRel }
    if ($null -eq $entryPath -or -not (Test-Path -LiteralPath $entryPath -PathType Leaf)) {
        Deny-StaleStamp "Verify stamp names entry '$entryRel' which does not exist."
    }
    $currentEntrySha = (Get-FileHash -LiteralPath $entryPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($stamp['entry_sha256'] -ne $currentEntrySha) {
        Deny-StaleStamp "Verification entry '$entryRel' changed after the stamp was written."
    }
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($null -ne $git) {
        & $git.Source -C $rootFull rev-parse --is-inside-work-tree *> $null
        if ($LASTEXITCODE -eq 0) {
            $headSha = ((& $git.Source -C $rootFull rev-parse HEAD 2>$null) | Out-String).Trim()
            if ([string]::IsNullOrWhiteSpace($headSha)) { $headSha = 'no-commit' }
            $porcelain = ((& $git.Source -C $rootFull status --porcelain --untracked-files=all 2>$null) | Out-String).TrimEnd()
            $shaObj = [System.Security.Cryptography.SHA256]::Create()
            try {
                $porcelainSha = ([System.BitConverter]::ToString(
                    $shaObj.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($porcelain))
                ) -replace '-', '').ToLowerInvariant()
            } finally {
                $shaObj.Dispose()
            }
            $currentWorktree = $headSha + '+' + $porcelainSha
            if ($stamp['worktree'] -ne $currentWorktree) {
                Deny-StaleStamp 'The worktree changed after the stamp was written; the verified state is not the current state.'
            }
        }
    }
    Write-Output "Verify stamp: $($stamp['package']) ($($stamp['verified_at']), entry $entryRel)"
}
Write-Output 'Verification attestation: caller confirmed the declared environment and project checks passed.'
Write-Output 'PPS readiness: OK'
