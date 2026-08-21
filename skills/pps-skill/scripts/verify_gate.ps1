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

# Any previous stamp is invalid the moment a new verification starts. A failed
# run must never leave behind a stamp that readiness could accept.
$stampPath = Join-Path $rootFull '.pps/verify-stamp'
if (Test-Path -LiteralPath $stampPath) {
    Remove-Item -LiteralPath $stampPath -Force
}

Write-Host "-- Step 1/4: structural validation"
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

Write-Host "-- Step 2/4: Verify declaration routing"
$contextText = [System.IO.File]::ReadAllText(
    (Join-Path $rootFull 'CONTEXT.md'), [System.Text.Encoding]::UTF8)
$worksetMatch = [regex]::Match(
    $contextText,
    '(?ms)^##\s+Workset Manifest\s*\r?\n(?<body>.*?)(?=^##\s+|\z)')
$verifyDecl = ''
if ($worksetMatch.Success) {
    $verifyMatch = [regex]::Match(
        $worksetMatch.Groups['body'].Value, '(?m)^-\s+Verify:\s*(.*?)\s*$')
    if ($verifyMatch.Success) { $verifyDecl = $verifyMatch.Groups[1].Value }
}
if ($verifyDecl -notmatch 'scripts/(verify_gate|project_verify)') {
    Write-Host "ERROR: the Workset Verify declaration must route through scripts/verify_gate.* (which executes scripts/project_verify.*)."
    Write-Host "Found unrouted declaration: $verifyDecl"
    Write-Host "Put the actual commands into scripts/project_verify.*; the gate never passes free-form Markdown text to a shell."
    Write-Host "PPS verify gate: FAILED (unrouted Verify declaration)"
    exit 1
}
Write-Host "Verify routing: declaration routes through the gate entry"

Write-Host "-- Step 2b/4: gate substance"
$verifyEntry = Join-Path $rootFull 'scripts/project_verify.ps1'
if (-not (Test-Path -LiteralPath $verifyEntry -PathType Leaf)) {
    Write-Host "ERROR: missing verification entry: scripts/project_verify.ps1"
    Write-Host "PPS verify gate: FAILED (missing verification entry)"
    exit 1
}
# A gate that executes an empty entry proves execution of nothing. Refuse the
# hollow entry outright: this is the "knowing is not doing" failure the stamp
# exists to prevent.
$entryLinesAll = [System.IO.File]::ReadAllLines($verifyEntry, [System.Text.Encoding]::UTF8)
$substantive = @($entryLinesAll | Where-Object {
    $trimmed = $_.Trim()
    $trimmed -ne '' -and -not $trimmed.StartsWith('#') -and
    $trimmed -notmatch '^(exit\s+0|return|Write-(Host|Output)\s)' 
})
$hasCheckCalls = ($entryLinesAll | Where-Object { $_ -match 'Invoke-Check\s|check\s+"' }).Count -gt 0
if (-not $hasCheckCalls -or $substantive.Count -lt 5) {
    Write-Host "ERROR: scripts/project_verify.ps1 has no real checks; an unconditional 'exit 0' or an echo-only entry defeats the gate."
    Write-Host "Declare at least one check that fails non-zero when the project is broken."
    Write-Host "PPS verify gate: FAILED (hollow verification entry)"
    exit 1
}
$entryText = [System.IO.File]::ReadAllText($verifyEntry, [System.Text.Encoding]::UTF8)
$stateText = [System.IO.File]::ReadAllText((Join-Path $rootFull 'PROJECT_STATE.md'), [System.Text.Encoding]::UTF8)
$modeMatch = [regex]::Match($stateText, '(?m)^-\s+Mode:\s*(.*?)\s*$')
$modeValue = if ($modeMatch.Success) { $modeMatch.Groups[1].Value } else { '' }
if ($modeValue -in @('software', 'hybrid')) {
    # Unit tests can pass while the caller path is broken: a software package
    # needs at least one check that is not the structural validator itself.
    $behavioral = @($entryLinesAll | Where-Object {
        ($_ -match 'Invoke-Check\s|check\s+"') -and ($_ -notmatch 'validate_project|validate_skill')
    })
    if ($behavioral.Count -lt 1) {
        Write-Host "ERROR: software package needs a behavioral check: scripts/project_verify.ps1 declares only structural validation."
        Write-Host "Add at least one check that exercises the product the way a user reaches it."
        Write-Host "PPS verify gate: FAILED (no behavioral check)"
        exit 1
    }
}
Write-Host "gate substance: entry declares real checks"

Write-Host "-- Step 2c/4: red line wiring"
# Red lines may name the check that enforces them: "(verify: path)". When a
# red line names one, the gate entry must actually reference that path, or the
# red line is a wish rather than a rule.
$redlineTargets = @()
$agentsPath = Join-Path $rootFull 'AGENTS.md'
if (Test-Path -LiteralPath $agentsPath -PathType Leaf) {
    $agentsText = [System.IO.File]::ReadAllText($agentsPath, [System.Text.Encoding]::UTF8)
    $redlineSection = [regex]::Match(
        $agentsText, '(?ms)^##\s+Red Lines\s*\r?\n(?<body>.*?)(?=^##\s+|\z)')
    if ($redlineSection.Success) {
        foreach ($m in [regex]::Matches($redlineSection.Groups['body'].Value, '\(verify:\s*([^)]+)\)')) {
            $candidate = $m.Groups[1].Value.Trim()
            if ($candidate -and ($candidate -notin $redlineTargets)) { $redlineTargets += $candidate }
        }
    }
}
if ($redlineTargets.Count -gt 0) {
    $manifestPath = Join-Path $rootFull '.pps/verify-manifest.txt'
    $manifestText = if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
        [System.IO.File]::ReadAllText($manifestPath, [System.Text.Encoding]::UTF8)
    } else { '' }
    $unwired = $false
    foreach ($target in $redlineTargets) {
        if ($entryText.Contains($target)) { continue }
        if ($manifestText.Contains($target) -and $entryText.Contains('verify-manifest')) { continue }
        Write-Host "ERROR: red line names '(verify: $target)' but scripts/project_verify.ps1 does not reference it."
        $unwired = $true
    }
    if ($unwired) {
        Write-Host "Wire the named check into the gate entry (or list it in .pps/verify-manifest.txt and read that manifest)."
        Write-Host "PPS verify gate: FAILED (red line not wired to the gate)"
        exit 1
    }
    Write-Host "red line wiring: all named checks are wired into the gate entry"
} else {
    Write-Host "red line wiring: no red line names a machine check (human-only red lines are allowed)"
}

Write-Host "-- Step 3/4: project verification entry"
$entryRel = 'scripts/project_verify.ps1'
$entryPath = Join-Path $rootFull $entryRel
if (-not (Test-Path -LiteralPath $entryPath -PathType Leaf)) {
    Write-Host "ERROR: missing project verification entry: $entryRel"
    Write-Host "PPS verify gate: FAILED (missing project_verify)"
    exit 1
}
& $engine.Source -NoProfile -ExecutionPolicy Bypass -File $entryPath -Root $rootFull
if ($LASTEXITCODE -ne 0) {
    Write-Host "project verification: FAILED (exit $LASTEXITCODE)"
    Write-Host "PPS verify gate: FAILED (project verification)"
    exit 1
}
Write-Host "project verification: pass"

Write-Host "-- Step 4/4: recording verify stamp"
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

function Get-FileSha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}
function Get-TextSha256([string]$Text) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

$entrySha = Get-FileSha256 $entryPath
$capsuleSha = Get-FileSha256 (Join-Path $rootFull 'CONTEXT.md')

function Invoke-NativeProbe([scriptblock]$Command) {
    $previousPreference = $ErrorActionPreference
    try {
        # Windows PowerShell 5 promotes native stderr to error records; a
        # non-repository is a normal probe result, not a terminating error.
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

$git = Get-Command git -ErrorAction SilentlyContinue
$worktreeId = 'no-git'
if ($null -ne $git) {
    $repoProbe = Invoke-NativeProbe { & $git.Source -C $rootFull rev-parse --is-inside-work-tree }
    if ($repoProbe.Code -eq 0 -and $repoProbe.Text -eq 'true') {
        $headProbe = Invoke-NativeProbe { & $git.Source -C $rootFull rev-parse HEAD }
        $headSha = if ($headProbe.Code -eq 0 -and -not [string]::IsNullOrWhiteSpace($headProbe.Text)) {
            $headProbe.Text
        } else {
            'no-commit'
        }
        # Content-level fingerprint: HEAD plus, for every changed path, its
        # status AND the SHA-256 of its current bytes. Porcelain text alone is
        # blind to an already-dirty file changing again; this is not.
        $statusProbe = Invoke-NativeProbe {
            $prevEnc = [Console]::OutputEncoding
            try {
                [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
                & $git.Source -C $rootFull status --porcelain -z --untracked-files=all
            } finally {
                [Console]::OutputEncoding = $prevEnc
            }
        }
        $entryLines = @()
        $rawStatus = ($statusProbe.Output | ForEach-Object { "$_" }) -join "`n"
        $skipNext = $false
        foreach ($statusEntry in $rawStatus.Split([char]0)) {
            if ($skipNext) { $skipNext = $false; continue }
            $line = "$statusEntry"
            if ($line.Length -le 3) { continue }
            $entryStatus = $line.Substring(0, 2)
            $entryPath = $line.Substring(3)
            if ($entryStatus -match '^[RC]') { $skipNext = $true }
            $entryFile = Join-Path $rootFull $entryPath
            $contentHash = if (Test-Path -LiteralPath $entryFile -PathType Leaf) {
                Get-FileSha256 $entryFile
            } else {
                'absent'
            }
            $entryLines += "$entryStatus`t$entryPath`t$contentHash"
        }
        $entryText = ''
        if ($entryLines.Count -gt 0) {
            [System.Array]::Sort($entryLines, [System.StringComparer]::Ordinal)
            $entryText = $entryLines -join "`n"
        }
        $worktreeId = $headSha + '+' + (Get-TextSha256 $entryText)
    }
}

$stampDir = Join-Path $rootFull '.pps'
if (-not (Test-Path -LiteralPath $stampDir)) {
    New-Item -ItemType Directory -Path $stampDir -Force | Out-Null
}
$utcNow = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
$stampLines = @(
    "package: $packageId",
    "entry: $entryRel",
    "entry_sha256: $entrySha",
    "capsule_sha256: $capsuleSha",
    "platform: powershell",
    "result: pass",
    "worktree: $worktreeId",
    "verified_at: $utcNow"
)
[System.IO.File]::WriteAllText(
    $stampPath,
    ($stampLines -join "`n") + "`n",
    [System.Text.UTF8Encoding]::new($false))
Write-Host "verify stamp: $packageId"
Write-Host "PPS verify gate: OK"
exit 0
