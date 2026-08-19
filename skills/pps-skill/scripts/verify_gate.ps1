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
        $statusProbe = Invoke-NativeProbe { & $git.Source -C $rootFull status --porcelain --untracked-files=all }
        $worktreeId = $headSha + '+' + (Get-TextSha256 $statusProbe.Text)
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
