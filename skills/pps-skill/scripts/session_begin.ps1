#!/usr/bin/env pwsh
#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$Root = (Split-Path -Parent $PSScriptRoot),
    [switch]$Takeover,
    [string]$Agent = ''
)

# Session begin: record the handover snapshot for this working session.
#
# Git only protects committed history. The dangerous moment in a single-writer
# relay project is the handover instant: the previous session may have left
# uncommitted work inside the very files the next session is allowed to write.
# This script turns "run git status first" from a sentence into an artifact.

$ErrorActionPreference = 'Stop'

function Invoke-NativeProbe([scriptblock]$Command) {
    $previousPreference = $ErrorActionPreference
    try {
        # Windows PowerShell 5 promotes native stderr to error records; a
        # negative probe result is normal, not a terminating error.
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

function Get-PathSha256([string]$Path) {
    try {
        return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    } catch {
        return 'unhashable'
    }
}

if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
    Write-Output "ERROR: project root is not a directory: $Root"
    exit 1
}
$rootFull = (Resolve-Path -LiteralPath $Root).Path
$snapshotDir = Join-Path $rootFull '.pps'
$snapshotFile = Join-Path $snapshotDir 'session-snapshot'
if (-not (Test-Path -LiteralPath $snapshotDir -PathType Container)) {
    New-Item -ItemType Directory -Path $snapshotDir -Force | Out-Null
}

$nowUtc = [DateTime]::UtcNow
$nowEpoch = [long][Math]::Floor(($nowUtc - [DateTime]'1970-01-01').TotalSeconds)
$nowIso = $nowUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')

# A prior snapshot means a previous session may still hold uncommitted work.
# Age does NOT dissolve that claim: an agent relay spans days, so a snapshot
# that "expired" overnight still describes work Git is not protecting.
$snapshotTtlSeconds = if ($env:PPS_SNAPSHOT_TTL_SECONDS) {
    [long]$env:PPS_SNAPSHOT_TTL_SECONDS
} else {
    604800
}
$previousProtected = @()
if (Test-Path -LiteralPath $snapshotFile -PathType Leaf) {
    $previousLines = [System.IO.File]::ReadAllLines($snapshotFile, [System.Text.Encoding]::UTF8)
    $previousEpoch = 0
    $previousStarted = 'unknown'
    $previousDevice = 'unknown'
    $inPreviousDirty = $false
    foreach ($line in $previousLines) {
        if ($line -eq '-- dirty --') { $inPreviousDirty = $true; continue }
        if ($inPreviousDirty) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $previousProtected += $line
            continue
        }
        if ($line -match '^started_epoch:\s*(\d+)') { $previousEpoch = [long]$Matches[1] }
        elseif ($line -match '^started_at:\s*(.+)$') { $previousStarted = $Matches[1].Trim() }
        elseif ($line -match '^device:\s*(.+)$') { $previousDevice = $Matches[1].Trim() }
    }
    if (-not $Takeover -and $previousEpoch -gt 0) {
        $snapshotAge = $nowEpoch - $previousEpoch
        if ($snapshotAge -lt $snapshotTtlSeconds) {
            Write-Output "ERROR: an unexpired session snapshot already exists (started $previousStarted on $previousDevice)."
        } else {
            Write-Output "ERROR: a stale session snapshot exists (started $previousStarted on $previousDevice, $([Math]::Floor($snapshotAge / 86400)) day(s) ago)."
            Write-Output 'Age does not release the claim: an agent relay spans days, and Git still is not protecting that work.'
        }
        $protectedNames = @($previousProtected | ForEach-Object { ($_ -split "`t")[1] } |
            Where-Object { $_ } | Select-Object -First 10)
        if ($protectedNames.Count -gt 0) {
            Write-Output "Protected paths recorded by that session: $($protectedNames -join ', ')"
        }
        Write-Output 'Re-run with -Takeover to claim the worktree; the takeover is recorded as a relay event automatically.'
        exit 3
    }
    # A snapshot taken AFTER the overwrite records the overwriting bytes and can
    # never detect the loss. Surface that explicitly on takeover.
    if ($Takeover) {
        $staleOverwrites = @()
        foreach ($record in $previousProtected) {
            $parts = $record -split "`t"
            if ($parts.Count -lt 3) { continue }
            $previousFull = Join-Path $rootFull $parts[1]
            $currentPreviousHash = if (Test-Path -LiteralPath $previousFull -PathType Leaf) {
                Get-PathSha256 $previousFull
            } else {
                'absent'
            }
            if ($currentPreviousHash -ne $parts[2]) { $staleOverwrites += $parts[1] }
        }
        if ($staleOverwrites.Count -gt 0) {
            Write-Output "NOTE: taking over after the following protected paths already changed: $($staleOverwrites -join ', ')"
            Write-Output "The relay event below records that the predecessor's uncommitted bytes are gone."
        }
    }
}

$deviceName = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } elseif ($env:HOSTNAME) { $env:HOSTNAME } else { 'unknown' }
$agentHint = if ([string]::IsNullOrWhiteSpace($Agent)) { 'unspecified' } else { $Agent }
$takeoverFlag = if ($Takeover) { '1' } else { '0' }

$lines = @()
$lines += "started_at: $nowIso"
$lines += "started_epoch: $nowEpoch"
$lines += "device: $deviceName"
$lines += "agent_hint: $agentHint"
$lines += "takeover: $takeoverFlag"

$dirtyRecords = @()
$git = Get-Command git -ErrorAction SilentlyContinue
$insideRepo = $false
if ($null -ne $git) {
    $repoProbe = Invoke-NativeProbe { & $git.Source -C $rootFull rev-parse --is-inside-work-tree }
    if ($repoProbe.Code -eq 0 -and $repoProbe.Text -eq 'true') { $insideRepo = $true }
}
if ($insideRepo) {
    $headProbe = Invoke-NativeProbe { & $git.Source -C $rootFull rev-parse HEAD }
    $headValue = if ($headProbe.Code -eq 0 -and -not [string]::IsNullOrWhiteSpace($headProbe.Text)) {
        ($headProbe.Text -split "`n")[0].Trim()
    } else {
        'no-commit'
    }
    $lines += "head: $headValue"
    $lines += 'git: available'
    $lines += '-- dirty --'
    $statusProbe = Invoke-NativeProbe {
        $prevEnc = [Console]::OutputEncoding
        try {
            [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
            & $git.Source -C $rootFull status --porcelain -z --untracked-files=all
        } finally {
            [Console]::OutputEncoding = $prevEnc
        }
    }
    $rawStatus = ($statusProbe.Output | ForEach-Object { "$_" }) -join "`n"
    $skipNext = $false
    foreach ($statusEntry in $rawStatus.Split([char]0)) {
        if ($skipNext) { $skipNext = $false; continue }
        $line = "$statusEntry"
        if ($line.Length -le 3) { continue }
        $entryStatus = $line.Substring(0, 2)
        $entryPath = $line.Substring(3)
        if ($entryStatus -match '^[RC]') { $skipNext = $true }
        $entryFull = Join-Path $rootFull $entryPath
        $contentHash = if (Test-Path -LiteralPath $entryFull -PathType Leaf) {
            Get-PathSha256 $entryFull
        } else {
            'absent'
        }
        $record = "$entryStatus`t$entryPath`t$contentHash"
        $dirtyRecords += $record
        $lines += $record
    }
} else {
    $lines += 'head: no-git'
    $lines += 'git: unavailable'
    $lines += '-- dirty --'
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($snapshotFile, (($lines -join "`n") + "`n"), $utf8NoBom)

# Objective anchor (anti goal-drift): hash the goal-bearing sections now so
# the verify gate can prove later that the objective was not silently
# rewritten mid-session. A goal change without a recorded 'objective-revised'
# event is drift, not progress.
function Get-TextSha256([string]$Text) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}
function Get-AnchorSection([string]$Title, [string]$Text) {
    $anchorMatch = [regex]::Match($Text, "(?ms)^##\s+$([regex]::Escape($Title))\s*\r?\n(?<body>.*?)(?=^##\s+|\z)")
    if ($anchorMatch.Success) { return $anchorMatch.Groups['body'].Value }
    return ''
}
$anchorStateText = [System.IO.File]::ReadAllText(
    (Join-Path $rootFull 'PROJECT_STATE.md'), [System.Text.Encoding]::UTF8)
$anchorContextText = [System.IO.File]::ReadAllText(
    (Join-Path $rootFull 'CONTEXT.md'), [System.Text.Encoding]::UTF8)
$anchorRawText = (Get-AnchorSection 'Objective' $anchorStateText) + "`n" +
    (Get-AnchorSection 'Current Package' $anchorContextText)
$anchorNormText = (($anchorRawText -split "`r?`n") |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ -ne '' }) -join "`n"
$anchorLines = @(
    "objective_sha256: $(Get-TextSha256 $anchorNormText)",
    "anchored_at: $nowIso",
    # R2: a hash is unreadable. The gate compares the hash; a mid-session agent
    # that has lost its working memory needs the objective itself, in one small
    # file, without diffing two Markdown documents. Everything below the marker
    # is human/agent-readable context and is NOT part of the compared digest.
    '-- objective --'
) + @($anchorNormText -split "`n")
[System.IO.File]::WriteAllText(
    (Join-Path $snapshotDir 'objective-anchor'),
    ($anchorLines -join "`n") + "`n",
    [System.Text.UTF8Encoding]::new($false))

Write-Output '== PPS session begin =='
Write-Output 'Snapshot: .pps/session-snapshot'
Write-Output "Started: $nowIso on $deviceName"
if ($Takeover) {
    Write-Output 'Takeover: yes (record it with scripts/append_event.ps1 so the relay is visible)'
}
Write-Output "Protected paths (uncommitted at session start): $($dirtyRecords.Count)"
if ($dirtyRecords.Count -gt 0) {
    $shown = 0
    foreach ($record in $dirtyRecords) {
        if ($shown -ge 20) { break }
        $parts = $record -split "`t"
        Write-Output "- $($parts[1]) ($($parts[0]))"
        $shown++
    }
    if ($dirtyRecords.Count -gt 20) {
        Write-Output "- ... $($dirtyRecords.Count - 20) more"
    }
    Write-Output ''
    Write-Output 'These files carry work that Git is not protecting yet.'
    Write-Output 'Do not overwrite them wholesale; extend them, or discard explicitly with boundary_check -DiscardHandover PATH.'
}
# A takeover that leaves no trace is exactly the silent relay this lock exists
# to prevent. Write the event here rather than trusting the operator.
if ($Takeover) {
    $appendScript = Join-Path $rootFull 'scripts/append_event.ps1'
    if (-not (Test-Path -LiteralPath $appendScript -PathType Leaf)) {
        Write-Output 'ERROR: takeover requires scripts/append_event.ps1 to record the relay event.'
        Remove-Item -LiteralPath $snapshotFile -ErrorAction SilentlyContinue
        exit 4
    }
    $takeoverFiles = @($dirtyRecords | ForEach-Object { ($_ -split "`t")[1] } |
        Where-Object { $_ } | Select-Object -First 6)
    $takeoverFilesValue = if ($takeoverFiles.Count -gt 0) { $takeoverFiles -join ',' } else { 'none' }
    $engineCmd = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($null -eq $engineCmd) { $engineCmd = Get-Command powershell -ErrorAction SilentlyContinue }
    & $engineCmd.Source -NoProfile -ExecutionPolicy Bypass -File $appendScript `
        -Root $rootFull -Title 'relay takeover claimed the worktree' `
        -Files $takeoverFilesValue -Verify 'session_begin snapshot recorded' `
        -Pending 'preserve or discard the protected paths deliberately' | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Output 'ERROR: takeover could not be recorded in EVENTS.md; the relay must stay visible.'
        Write-Output 'Fix the chronicle (scripts/append_event.ps1) and re-run -Takeover.'
        Remove-Item -LiteralPath $snapshotFile -ErrorAction SilentlyContinue
        exit 4
    }
    Write-Output 'Relay event recorded in EVENTS.md.'
}
Write-Output 'PPS session begin: OK'
exit 0
