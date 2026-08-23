[CmdletBinding()]
param(
    [string]$Root,
    [switch]$All,
    [switch]$Handoff,
    [switch]$Risk,
    [switch]$Quick,
    [switch]$Structure
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($Root)) {
    $Root = Split-Path -Parent $PSScriptRoot
}
$rootFull = [System.IO.Path]::GetFullPath($Root)
if (-not (Test-Path -LiteralPath $rootFull -PathType Container)) {
    throw "Project root is not a directory: $rootFull"
}
if ($Quick -and $Handoff) {
    throw '-Handoff requires full SHA-256 verification and cannot be combined with -Quick.'
}
$manifestPath = Join-Path $rootFull 'ASSETS.md'
$contextPath = Join-Path $rootFull 'CONTEXT.md'
$errors = [System.Collections.Generic.List[string]]::new()
$warnings = [System.Collections.Generic.List[string]]::new()
$rows = [System.Collections.Generic.List[object]]::new()

function Invoke-NativeProbe([scriptblock]$Command) {
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'SilentlyContinue'
        $output = @(& $Command)
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    return @{
        Code = $exitCode
        Text = (($output | ForEach-Object { "$_" }) -join "`n").Trim()
    }
}

function Add-AssetError([string]$Message) {
    $script:errors.Add($Message)
}
function Add-AssetWarning([string]$Message) {
    $script:warnings.Add($Message)
}
function Get-SectionField([string[]]$Lines, [string]$Section, [string]$Field) {
    $inside = $false
    foreach ($line in $Lines) {
        if ($line -eq "## $Section") { $inside = $true; continue }
        if ($inside -and $line -match '^## ') { break }
        if ($inside -and $line.StartsWith("- ${Field}:")) {
            return $line.Substring(("- ${Field}:").Length).Trim()
        }
    }
    return $null
}
function Resolve-SafeAssetPath([string]$RelativePath) {
    if ([string]::IsNullOrWhiteSpace($RelativePath) -or
        [System.IO.Path]::IsPathRooted($RelativePath) -or
        $RelativePath.Contains('\') -or
        $RelativePath -match '(^|/)\.\.(/|$)') {
        return $null
    }
    $rootTrimmed = $rootFull.TrimEnd('\', '/')
    $candidate = [System.IO.Path]::GetFullPath((Join-Path $rootTrimmed $RelativePath))
    $comparison = if ($IsWindows -or $env:OS -eq 'Windows_NT') {
        [System.StringComparison]::OrdinalIgnoreCase
    } else {
        [System.StringComparison]::Ordinal
    }
    $prefix = $rootTrimmed + [System.IO.Path]::DirectorySeparatorChar
    if (-not $candidate.StartsWith($prefix, $comparison)) {
        return $null
    }
    $cursor = $rootTrimmed
    foreach ($segment in @($RelativePath -split '/')) {
        if ([string]::IsNullOrWhiteSpace($segment) -or $segment -eq '.') { continue }
        $cursor = Join-Path $cursor $segment
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                return $null
            }
        }
    }
    return $candidate
}

$contextLines = if (Test-Path -LiteralPath $contextPath -PathType Leaf) {
    [System.IO.File]::ReadAllLines($contextPath, [System.Text.Encoding]::UTF8)
} else {
    @()
}
$assetsValue = Get-SectionField $contextLines 'Workset Manifest' 'Assets'
if ([string]::IsNullOrWhiteSpace($assetsValue)) { $assetsValue = 'none' }
$currentIds = [System.Collections.Generic.List[string]]::new()
if ($assetsValue -ne 'none') {
    if ($assetsValue -notmatch '^A-[A-Za-z0-9](?:[A-Za-z0-9_-]*[A-Za-z0-9])?(?:\s*,\s*A-[A-Za-z0-9](?:[A-Za-z0-9_-]*[A-Za-z0-9])?)*$') {
        Add-AssetError "Workset Assets must be 'none' or a strict comma-separated A-* list: $assetsValue"
    } else {
        foreach ($id in @($assetsValue -split ',' | ForEach-Object { $_.Trim() })) {
            if ($currentIds.Contains($id)) {
                Add-AssetError "Workset Assets contains duplicate ID: $id"
            } else {
                $currentIds.Add($id)
            }
        }
    }
}

if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
    $manifestLines = [System.IO.File]::ReadAllLines($manifestPath, [System.Text.Encoding]::UTF8)
    for ($index = 0; $index -lt $manifestLines.Count; $index++) {
        $line = $manifestLines[$index]
        if ($line -notmatch '^\|\s*A-') { continue }
        $parts = @($line.Split('|'))
        if ($parts.Count -ne 10) {
            Add-AssetError "Malformed ASSETS.md row at line $($index + 1): $line"
            continue
        }
        $rows.Add([pscustomobject]@{
            Id = $parts[1].Trim()
            Priority = $parts[2].Trim()
            Sync = $parts[3].Trim()
            Materialize = $parts[4].Trim()
            Locator = $parts[5].Trim()
            Sha = $parts[6].Trim().ToLowerInvariant()
            Bytes = $parts[7].Trim()
            Purpose = $parts[8].Trim()
        })
    }
} elseif ($currentIds.Count -gt 0) {
    Add-AssetError 'Workset lists assets but ASSETS.md is missing.'
}

$seenRows = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::Ordinal
)
foreach ($row in $rows) {
    if (-not $seenRows.Add($row.Id)) {
        Add-AssetError "ASSETS.md contains duplicate rows for $($row.Id)."
    }
    if ($row.Id -notmatch '^A-[A-Za-z0-9](?:[A-Za-z0-9_-]*[A-Za-z0-9])?$') {
        Add-AssetError "Malformed asset ID: $($row.Id)"
    }
    if ($row.Priority -notin @('core', 'supporting', 'reference')) {
        Add-AssetError "Asset $($row.Id) has unsupported Priority '$($row.Priority)'."
    }
    if ($row.Sync -notin @('git', 'git-lfs', 'cloud', 'local-marker')) {
        Add-AssetError "Asset $($row.Id) has unsupported Sync '$($row.Sync)'."
    }
    if ($null -eq (Resolve-SafeAssetPath $row.Materialize)) {
        Add-AssetError "Asset $($row.Id) Materialize must be a safe project-relative path: $($row.Materialize)"
    }
    if ($row.Sync -in @('cloud', 'local-marker') -and
        -not $row.Materialize.StartsWith('local-assets/')) {
        Add-AssetError "External asset $($row.Id) must materialize under local-assets/: $($row.Materialize)"
    }
    if ($row.Sha -notmatch '^[0-9a-f]{64}$') {
        Add-AssetError "Asset $($row.Id) SHA-256 must contain exactly 64 hexadecimal characters."
    }
    $parsedBytes = 0L
    if (-not [long]::TryParse($row.Bytes, [ref]$parsedBytes) -or $parsedBytes -le 0) {
        Add-AssetError "Asset $($row.Id) Bytes must be a positive integer."
    }
    if ([string]::IsNullOrWhiteSpace($row.Purpose)) {
        Add-AssetError "Asset $($row.Id) Purpose cannot be empty."
    }
    if ($row.Priority -eq 'core' -and $row.Sync -eq 'local-marker') {
        Add-AssetError "Core asset $($row.Id) cannot use local-marker; choose git, git-lfs, or cloud."
    }
    if ($row.Sync -eq 'cloud') {
        $cloudLocatorMatch = [regex]::Match(
            $row.Locator,
            '^rclone:(?<remote>[A-Za-z0-9][A-Za-z0-9._-]*):(?<path>[A-Za-z0-9][A-Za-z0-9._/-]*)$'
        )
        if (-not $cloudLocatorMatch.Success -or
            $cloudLocatorMatch.Groups['path'].Value -match '(^|/)\.\.(/|$)') {
            Add-AssetError "Cloud asset $($row.Id) Locator must use restricted non-secret rclone:REMOTE:path syntax."
        }
    }
}
foreach ($id in $currentIds) {
    $matchedRows = @($rows | Where-Object { $_.Id -eq $id })
    $count = $matchedRows.Count
    if ($count -ne 1) {
        Add-AssetError "Workset asset $id must have exactly one ASSETS.md row, found $count."
    } elseif ($matchedRows[0].Priority -eq 'reference') {
        Add-AssetError "Reference asset $id cannot enter the current Workset; promote it to supporting or core."
    }
}

if ($Structure) {
    foreach ($warning in $warnings) { Write-Output "WARNING: $warning" }
    if ($errors.Count -gt 0) {
        foreach ($message in $errors) { Write-Output "ERROR: $message" }
        exit 1
    }
    Write-Output 'Asset registry structure: OK'
    exit 0
}

$selectedCount = 0
$referenceCount = @($rows | Where-Object { $_.Priority -eq 'reference' }).Count
$git = Get-Command git -ErrorAction SilentlyContinue
foreach ($row in $rows) {
    $current = $currentIds.Contains($row.Id)
    $selected = $row.Priority -eq 'core' -or $current -or $All
    if (-not $selected) { continue }
    $selectedCount++
    $path = Resolve-SafeAssetPath $row.Materialize
    if ($null -eq $path -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
        if ($row.Priority -eq 'reference') {
            Add-AssetWarning "Reference asset $($row.Id) is not materialized on this device: $($row.Materialize)"
        } else {
            Add-AssetError "Required asset $($row.Id) is not materialized on this device: $($row.Materialize)"
        }
        continue
    }
    $item = Get-Item -LiteralPath $path
    if ($item.Length.ToString() -ne $row.Bytes) {
        Add-AssetError "Asset $($row.Id) size mismatch: expected $($row.Bytes) bytes, found $($item.Length)."
    }
    if (-not $Quick) {
        $actualSha = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualSha -ne $row.Sha) {
            Add-AssetError "Asset $($row.Id) SHA-256 mismatch."
        }
    }
    if ($row.Sync -in @('git', 'git-lfs')) {
        if ($null -eq $git) {
            Add-AssetError "Asset $($row.Id) declares $($row.Sync) but Git is unavailable."
        } else {
            $trackedProbe = Invoke-NativeProbe {
                & $git.Source -C $rootFull ls-files --error-unmatch -- $row.Materialize 2>$null
            }
            if ($trackedProbe.Code -ne 0) {
                Add-AssetError "Asset $($row.Id) declares $($row.Sync) but Materialize is not Git tracked: $($row.Materialize)"
            } elseif ($row.Sync -eq 'git-lfs') {
                $attributeProbe = Invoke-NativeProbe {
                    & $git.Source -C $rootFull check-attr filter -- $row.Materialize 2>$null
                }
                $attr = $attributeProbe.Text
                if ($attr -notmatch ':\s+lfs\s*$') {
                    Add-AssetError "Asset $($row.Id) declares git-lfs but Git attributes do not select LFS: $($row.Materialize)"
                }
            }
        }
    }
    if ($Handoff -and $row.Sync -eq 'cloud') {
        $remoteSpec = $row.Locator.Substring('rclone:'.Length)
        $rclone = Get-Command rclone -ErrorAction SilentlyContinue
        if ($null -eq $rclone) {
            Add-AssetError "Cloud asset $($row.Id) cannot prove its durable copy because rclone is unavailable."
        } else {
            $remoteProbe = Invoke-NativeProbe {
                & $rclone.Source size $remoteSpec --json --max-depth 1 2>$null
            }
            if ($remoteProbe.Code -ne 0) {
                Add-AssetError "Cloud asset $($row.Id) durable Locator is unreachable: $($row.Locator)"
            } else {
                try {
                    $remoteInfo = $remoteProbe.Text | ConvertFrom-Json
                    $remoteCount = [long]$remoteInfo.count
                    $remoteBytes = [long]$remoteInfo.bytes
                    if ($remoteCount -ne 1 -or $remoteBytes -ne [long]$row.Bytes) {
                        Add-AssetError "Cloud asset $($row.Id) durable copy mismatch: expected 1 object / $($row.Bytes) bytes, found $remoteCount object(s) / $remoteBytes bytes."
                    } else {
                        Write-Output "PASS cloud copy: $($row.Id) [$($row.Locator)]"
                    }
                } catch {
                    Add-AssetError "Cloud asset $($row.Id) returned invalid rclone size metadata."
                }
            }
        }
    }
    if ($Handoff -and $row.Sync -eq 'local-marker' -and
        ($row.Priority -eq 'core' -or $current)) {
        Add-AssetError "Current asset $($row.Id) is local-marker only; handoff would be materially incomplete."
    }
    Write-Output "PASS asset: $($row.Id) [$($row.Priority)/$($row.Sync)] $($row.Materialize)"
}

$trackedBinaryBytes = 0L
$trackedBinaryCount = 0
if ($Risk -and $null -ne $git) {
    $repositoryProbe = Invoke-NativeProbe {
        & $git.Source -C $rootFull rev-parse --is-inside-work-tree 2>$null
    }
    if ($repositoryProbe.Code -eq 0 -and $repositoryProbe.Text -eq 'true') {
        $binaryPattern = '\.(mp4|mov|mkv|avi|gif|png|jpe?g|webp|wav|psd|ai|xlsx?|docx|pptx|pdf|zip|7z|rar)$'
        foreach ($relative in @(& $git.Source -C $rootFull ls-files)) {
            if ($relative -notmatch $binaryPattern) { continue }
            $path = Join-Path $rootFull $relative
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
            $attributeProbe = Invoke-NativeProbe {
                & $git.Source -C $rootFull check-attr filter -- $relative 2>$null
            }
            $attr = $attributeProbe.Text
            if ($attr -match ':\s+lfs\s*$') { continue }
            $size = (Get-Item -LiteralPath $path).Length
            $trackedBinaryBytes += $size
            $trackedBinaryCount++
            if ($size -gt 99614720) {
                Add-AssetError "Tracked non-LFS file exceeds the 95 MiB safe push ceiling: $relative ($size bytes)."
            } elseif ($size -gt 52428800) {
                Add-AssetWarning "Tracked non-LFS file exceeds 50 MiB: $relative ($size bytes)."
            }
        }
        if ($trackedBinaryBytes -gt 104857600) {
            Add-AssetWarning "Tracked non-LFS binary candidates total $trackedBinaryBytes bytes across $trackedBinaryCount files; review LFS, cloud routing, and output retention."
        }
    }
}

foreach ($warning in $warnings) { Write-Output "WARNING: $warning" }
if ($errors.Count -gt 0) {
    Write-Output "Asset readiness: FAILED ($($errors.Count) error(s))"
    foreach ($message in $errors) { Write-Output "ERROR: $message" }
    exit 1
}
Write-Output 'Asset readiness: OK'
Write-Output "Selected assets checked: $selectedCount"
if ($Quick) {
    Write-Output 'Integrity level: existence-and-size (quick)'
} else {
    Write-Output 'Integrity level: SHA-256'
}
Write-Output "Reference markers: $referenceCount"
if ($Risk) {
    Write-Output "Tracked non-LFS binary candidates: $trackedBinaryCount files / $trackedBinaryBytes bytes"
}
