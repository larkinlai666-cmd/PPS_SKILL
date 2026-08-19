[CmdletBinding()]
param(
    [string]$Root,
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

$claims = [System.Collections.Generic.List[string]]::new()
function Add-Claims([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -eq 'none') { return }
    foreach ($entry in @($Value.Split(',') | ForEach-Object { $_.Trim() })) {
        if (-not [string]::IsNullOrWhiteSpace($entry)) { $script:claims.Add($entry) }
    }
}

Add-Claims (Get-SectionField (Join-Path $rootFull 'CONTEXT.md') 'Workset Manifest' 'Write')
foreach ($canonical in @(
    'PROJECT_STATE.md', 'DECISIONS.md', 'CONTEXT.md', 'EVENTS.md',
    'PROJECT_MAP.md', 'ENVIRONMENT.md', 'ASSETS.md', 'SOURCE_INDEX.md',
    'TASK_INDEX.md', 'MERGES.md', 'docs/coverage.md', 'docs/CURRENT_REVIEW_EVIDENCE.md'
)) {
    $claims.Add($canonical)
}

$taskIndexPath = Join-Path $rootFull 'TASK_INDEX.md'
if (Test-Path -LiteralPath $taskIndexPath -PathType Leaf) {
    $taskIndexText = [System.IO.File]::ReadAllText($taskIndexPath, [System.Text.Encoding]::UTF8)
    foreach ($heading in [regex]::Matches(
        $taskIndexText,
        '(?m)^###\s+(?<id>T-[A-Za-z0-9](?:[A-Za-z0-9_-]*[A-Za-z0-9])?)\s*$')) {
        $taskId = $heading.Groups['id'].Value
        $blockMatch = [regex]::Match(
            $taskIndexText,
            '(?ms)^###\s+' + [regex]::Escape($taskId) + '\s*\r?\n(?<body>.*?)(?=^###\s+|\z)')
        $body = if ($blockMatch.Success) { $blockMatch.Groups['body'].Value } else { '' }
        $taskStatus = [regex]::Match($body, '(?m)^-\s+Status:\s*(.*?)\s*$').Groups[1].Value
        if ($taskStatus -eq 'archived') { continue }
        $outputRoot = [regex]::Match($body, '(?m)^-\s+Output Root:\s*(.*?)\s*$').Groups[1].Value
        if (-not [string]::IsNullOrWhiteSpace($outputRoot) -and $outputRoot -ne 'none') {
            $claims.Add($outputRoot)
        }
        $capsule = [regex]::Match($body, '(?m)^-\s+Capsule:\s*(.*?)\s*$').Groups[1].Value
        if (-not [string]::IsNullOrWhiteSpace($capsule)) {
            $capsulePath = Join-Path $rootFull $capsule
            if (Test-Path -LiteralPath $capsulePath -PathType Leaf) {
                $claims.Add($capsule)
                Add-Claims (Get-SectionField $capsulePath 'Workset Manifest' 'Write')
            }
        }
    }
}
$claims = [System.Collections.Generic.List[string]]@($claims | Select-Object -Unique)

function Test-Claimed([string]$Path) {
    foreach ($claim in $claims) {
        if ([string]::IsNullOrWhiteSpace($claim)) { continue }
        if ($Path -eq $claim -or $Path.StartsWith("$claim/")) { return $true }
    }
    return $false
}

$statusLines = @(& $git.Source -C $rootFull status --porcelain --untracked-files=all 2>$null)
if ($statusLines.Count -eq 0) {
    Write-Host "Boundary check: worktree clean; nothing to classify."
    Write-Host "PPS boundary check: OK"
    exit 0
}

$unclaimed = 0
foreach ($statusLine in $statusLines) {
    $line = "$statusLine"
    if ($line.Length -le 3) { continue }
    $changedPath = $line.Substring(3).Trim('"')
    if ($changedPath.Contains(' -> ')) {
        $changedPath = $changedPath.Split(' -> ')[-1]
    }
    if (Test-Claimed $changedPath) {
        Write-Host "claimed: $changedPath"
    } elseif ($AllowPreexisting) {
        Write-Host "preexisting (unclassified): $changedPath"
    } else {
        Write-Host "unclaimed_write: $changedPath"
        $unclaimed++
    }
}

if ($unclaimed -gt 0) {
    Write-Host "PPS boundary check: FAILED ($unclaimed unclaimed change(s))"
    Write-Host "Claim each path in a Write set or task Output Root, revert it, or classify it explicitly with -AllowPreexisting."
    exit 1
}
Write-Host "PPS boundary check: OK"
exit 0
