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
    function Get-StampFileSha256([string]$Path) {
        return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    function Get-StampTextSha256([string]$Text) {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            return ([System.BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '').ToLowerInvariant()
        } finally {
            $sha.Dispose()
        }
    }
    foreach ($requiredField in @(
        'package', 'entry', 'entry_sha256', 'capsule_sha256',
        'platform', 'result', 'worktree', 'verified_at'
    )) {
        if (-not $stamp.ContainsKey($requiredField) -or
            [string]::IsNullOrWhiteSpace($stamp[$requiredField])) {
            Deny-StaleStamp "Verify stamp is missing the '$requiredField' field; only the current gate writes complete stamps."
        }
    }
    if ($stamp['package'] -ne $packageId) {
        Deny-StaleStamp "Verify stamp names '$($stamp['package'])' but the current package is '$packageId'."
    }
    if ($stamp['result'] -ne 'pass') {
        Deny-StaleStamp "Verify stamp records result '$($stamp['result'])', not 'pass'."
    }
    if ($stamp['platform'] -notin @('bash', 'powershell')) {
        Deny-StaleStamp "Verify stamp records unknown platform '$($stamp['platform'])'."
    }
    $entryRel = $stamp['entry']
    $entryPath = if ([string]::IsNullOrWhiteSpace($entryRel)) { $null } else { Join-Path $rootFull $entryRel }
    if ($null -eq $entryPath -or -not (Test-Path -LiteralPath $entryPath -PathType Leaf)) {
        Deny-StaleStamp "Verify stamp names entry '$entryRel' which does not exist."
    }
    $currentEntrySha = Get-StampFileSha256 $entryPath
    if ($stamp['entry_sha256'] -ne $currentEntrySha) {
        Deny-StaleStamp "Verification entry '$entryRel' changed after the stamp was written."
    }
    $currentCapsuleSha = Get-StampFileSha256 (Join-Path $rootFull 'CONTEXT.md')
    if ($stamp['capsule_sha256'] -ne $currentCapsuleSha) {
        Deny-StaleStamp 'CONTEXT.md changed after the stamp was written; the verified capsule is not the current capsule.'
    }
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($null -ne $git) {
        function Invoke-NativeProbe([scriptblock]$Command) {
            $previousPreference = $ErrorActionPreference
            try {
                $ErrorActionPreference = 'SilentlyContinue'
                $output = @(& $Command 2>$null)
                $exitCode = $LASTEXITCODE
            } finally {
                $ErrorActionPreference = $previousPreference
            }
            return @{
                Code = $exitCode
                Output = $output
                Text = (($output | ForEach-Object { "$_" }) -join "`n").Trim()
            }
        }
        $repoProbe = Invoke-NativeProbe { & $git.Source -C $rootFull rev-parse --is-inside-work-tree }
        if ($repoProbe.Code -eq 0 -and $repoProbe.Text -eq 'true') {
            $headProbe = Invoke-NativeProbe { & $git.Source -C $rootFull rev-parse HEAD }
            $headSha = if ($headProbe.Code -eq 0 -and -not [string]::IsNullOrWhiteSpace($headProbe.Text)) {
                $headProbe.Text
            } else {
                'no-commit'
            }
            $statusProbe = Invoke-NativeProbe { & $git.Source -C $rootFull status --porcelain --untracked-files=all }
            $entryLines = @()
            foreach ($statusLine in $statusProbe.Output) {
                $line = "$statusLine"
                if ($line.Length -le 3) { continue }
                $entryStatus = $line.Substring(0, 2)
                $changedPath = $line.Substring(3).Trim('"')
                if ($changedPath.Contains(' -> ')) {
                    $changedPath = $changedPath.Split(' -> ')[-1]
                }
                $changedFile = Join-Path $rootFull $changedPath
                $contentHash = if (Test-Path -LiteralPath $changedFile -PathType Leaf) {
                    Get-StampFileSha256 $changedFile
                } else {
                    'absent'
                }
                $entryLines += "$entryStatus`t$changedPath`t$contentHash"
            }
            $entryText = ''
            if ($entryLines.Count -gt 0) {
                [System.Array]::Sort($entryLines, [System.StringComparer]::Ordinal)
                $entryText = $entryLines -join "`n"
            }
            $currentWorktree = $headSha + '+' + (Get-StampTextSha256 $entryText)
            if ($stamp['worktree'] -ne $currentWorktree) {
                Deny-StaleStamp 'The worktree content changed after the stamp was written; the verified state is not the current state.'
            }
        }
    }
    Write-Output "Verify stamp: $($stamp['package']) ($($stamp['verified_at']), entry $entryRel)"
}
Write-Output 'Verification attestation: caller confirmed the declared environment and project checks passed.'
Write-Output 'PPS readiness: OK'
