[CmdletBinding()]
param(
    [string]$Root,
    [string]$Task,
    [switch]$RecordBaseline,
    [switch]$AllowPreexisting
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

$git = Get-Command git -ErrorAction SilentlyContinue
if ($null -eq $git) {
    Write-Host "ERROR: git is unavailable; boundary check needs worktree status."
    exit 1
}
& $git.Source -C $rootFull rev-parse --is-inside-work-tree *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: not a Git repository: $rootFull"
    exit 1
}

$baselinePath = Join-Path $rootFull '.pps/boundary-baseline'

function Get-ChangedPaths {
    $lines = @(& $git.Source -C $rootFull status --porcelain --untracked-files=all 2>$null)
    $paths = @()
    foreach ($statusLine in $lines) {
        $line = "$statusLine"
        if ($line.Length -le 3) { continue }
        $changed = $line.Substring(3).Trim('"')
        if ($changed.Contains(' -> ')) {
            $changed = $changed.Split(' -> ')[-1]
        }
        $paths += $changed
    }
    return $paths
}

if ($RecordBaseline) {
    $baselineDir = Join-Path $rootFull '.pps'
    if (-not (Test-Path -LiteralPath $baselineDir)) {
        New-Item -ItemType Directory -Path $baselineDir -Force | Out-Null
    }
    $paths = Get-ChangedPaths
    [System.IO.File]::WriteAllText(
        $baselinePath,
        (($paths -join "`n") + $(if ($paths.Count -gt 0) { "`n" } else { '' })),
        [System.Text.UTF8Encoding]::new($false))
    Write-Host "Boundary baseline recorded: $($paths.Count) pre-existing dirty path(s)."
    Write-Host "PPS boundary check: BASELINE RECORDED"
    exit 0
}

function Get-SectionField([string]$Path, [string]$Section, [string]$Field) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $inside = $false
    foreach ($line in [System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::UTF8)) {
        if ($line -eq "## $Section") { $inside = $true; continue }
        if ($inside -and $line -match '^## ') { break }
        if ($inside -and $line.StartsWith("- ${Field}:")) {
            return $line.Substring(("- ${Field}:").Length).Trim()
        }
    }
    return $null
}

function Get-TaskBlockField([string]$TaskIndexText, [string]$TaskId, [string]$Field) {
    $blockMatch = [regex]::Match(
        $TaskIndexText,
        '(?ms)^###\s+' + [regex]::Escape($TaskId) + '\s*\r?\n(?<body>.*?)(?=^###\s+|\z)')
    if (-not $blockMatch.Success) { return $null }
    $fieldMatch = [regex]::Match(
        $blockMatch.Groups['body'].Value,
        '(?m)^-\s+' + [regex]::Escape($Field) + ':\s*(.*?)\s*$')
    if ($fieldMatch.Success) { return $fieldMatch.Groups[1].Value }
    return $null
}

# Resolve the acting subject. Claims come only from that subject's own
# declarations: canonical identity never grants automatic write permission.
$taskIndexPath = Join-Path $rootFull 'TASK_INDEX.md'
$subject = ''
$subjectRole = ''
$subjectCapsule = ''
$subjectOutputRoot = ''
if (Test-Path -LiteralPath $taskIndexPath -PathType Leaf) {
    $taskIndexText = [System.IO.File]::ReadAllText($taskIndexPath, [System.Text.Encoding]::UTF8)
    if (-not [string]::IsNullOrWhiteSpace($Task)) {
        $subject = $Task
    } else {
        $subject = Get-SectionField (Join-Path $rootFull 'PROJECT_STATE.md') 'Hot State' 'Writer'
    }
    if ([string]::IsNullOrWhiteSpace($subject)) {
        Write-Host "ERROR: multitask project but no acting task; pass -Task T-ID or set Hot State Writer."
        exit 1
    }
    if ($taskIndexText -notmatch ('(?m)^###\s+' + [regex]::Escape($subject) + '\s*$')) {
        Write-Host "ERROR: acting task '$subject' is not registered in TASK_INDEX.md."
        exit 1
    }
    $subjectRole = Get-TaskBlockField $taskIndexText $subject 'Role'
    $subjectCapsule = Get-TaskBlockField $taskIndexText $subject 'Capsule'
    $subjectOutputRoot = Get-TaskBlockField $taskIndexText $subject 'Output Root'
} else {
    if (-not [string]::IsNullOrWhiteSpace($Task)) {
        Write-Host "ERROR: -Task was given but TASK_INDEX.md does not exist."
        exit 1
    }
    $subject = 'canonical'
    $subjectRole = 'integrator'
    $subjectCapsule = 'CONTEXT.md'
}

$claims = [System.Collections.Generic.List[string]]::new()
function Add-Claims([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -eq 'none') { return }
    foreach ($entry in @($Value.Split(',') | ForEach-Object { $_.Trim() })) {
        if (-not [string]::IsNullOrWhiteSpace($entry)) { $script:claims.Add($entry) }
    }
}

if (-not [string]::IsNullOrWhiteSpace($subjectCapsule) -and $subjectCapsule -ne 'none') {
    $capsulePath = Join-Path $rootFull $subjectCapsule
    if (Test-Path -LiteralPath $capsulePath -PathType Leaf) {
        Add-Claims (Get-SectionField $capsulePath 'Workset Manifest' 'Write')
    }
}
if (-not [string]::IsNullOrWhiteSpace($subjectOutputRoot) -and $subjectOutputRoot -ne 'none') {
    $claims.Add($subjectOutputRoot)
}
# The verify stamp and boundary baseline are tool-owned local artifacts.
$claims.Add('.pps')
$claims = [System.Collections.Generic.List[string]]@($claims | Select-Object -Unique)

if ($claims.Count -le 1) {
    Write-Host "ERROR: acting subject '$subject' has no usable Write claims; declare Write paths in its capsule first."
    exit 1
}

Write-Host "Acting subject: $subject ($subjectRole)"

function Test-Claimed([string]$Path) {
    foreach ($claim in $claims) {
        if ([string]::IsNullOrWhiteSpace($claim)) { continue }
        if ($Path -eq $claim -or $Path.StartsWith("$claim/")) { return $true }
    }
    return $false
}

$baselinePaths = @()
if (Test-Path -LiteralPath $baselinePath -PathType Leaf) {
    $baselinePaths = @([System.IO.File]::ReadAllLines($baselinePath, [System.Text.Encoding]::UTF8) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

$changedPaths = Get-ChangedPaths
if ($changedPaths.Count -eq 0) {
    Write-Host "Boundary check: worktree clean; nothing to classify."
    Write-Host "PPS boundary check: OK"
    exit 0
}

$unclaimed = 0
foreach ($changedPath in $changedPaths) {
    if (Test-Claimed $changedPath) {
        Write-Host "claimed: $changedPath"
    } elseif ($AllowPreexisting -and ($changedPath -in $baselinePaths)) {
        Write-Host "preexisting (baseline): $changedPath"
    } else {
        if ($AllowPreexisting -and -not (Test-Path -LiteralPath $baselinePath -PathType Leaf)) {
            Write-Host "ERROR: -AllowPreexisting requires a recorded baseline; run -RecordBaseline at session start."
            exit 1
        }
        Write-Host "unclaimed_write: $changedPath"
        $unclaimed++
    }
}

if ($unclaimed -gt 0) {
    Write-Host "PPS boundary check: FAILED ($unclaimed unclaimed change(s))"
    Write-Host "Claim each path in the acting subject's Write set or Output Root, revert it, or record it in the session baseline before starting work."
    exit 1
}
Write-Host "PPS boundary check: OK"
exit 0
