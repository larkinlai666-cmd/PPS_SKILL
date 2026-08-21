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

# An unexpired snapshot means another session may still be mid-flight. Do not
# block (a stuck lock is worse than a warning), but require an explicit
# takeover so the handover is visible in the chronicle.
if ((Test-Path -LiteralPath $snapshotFile -PathType Leaf) -and -not $Takeover) {
    $previousLines = [System.IO.File]::ReadAllLines($snapshotFile, [System.Text.Encoding]::UTF8)
    $previousEpoch = 0
    $previousStarted = 'unknown'
    $previousDevice = 'unknown'
    foreach ($line in $previousLines) {
        if ($line -match '^started_epoch:\s*(\d+)') { $previousEpoch = [long]$Matches[1] }
        elseif ($line -match '^started_at:\s*(.+)$') { $previousStarted = $Matches[1].Trim() }
        elseif ($line -match '^device:\s*(.+)$') { $previousDevice = $Matches[1].Trim() }
    }
    if ($previousEpoch -gt 0 -and ($nowEpoch - $previousEpoch) -lt 43200) {
        Write-Output "ERROR: an unexpired session snapshot already exists (started $previousStarted on $previousDevice)."
        Write-Output 'Another session may still hold uncommitted work. Re-run with -Takeover to claim the worktree;'
        Write-Output 'the takeover must then be recorded with scripts/append_event.* so the relay stays visible.'
        exit 3
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
Write-Output 'PPS session begin: OK'
exit 0
