[CmdletBinding()]
param([string]$Root)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($Root)) {
    $Root = Split-Path -Parent $PSScriptRoot
}
$rootFull = [System.IO.Path]::GetFullPath($Root)
$statePath = Join-Path $rootFull 'PROJECT_STATE.md'
$contextPath = Join-Path $rootFull 'CONTEXT.md'
$decisionsPath = Join-Path $rootFull 'DECISIONS.md'
$mapPath = Join-Path $rootFull 'PROJECT_MAP.md'
$validator = Join-Path $rootFull 'scripts/validate_project.ps1'
if (-not (Test-Path -LiteralPath $validator -PathType Leaf)) {
    throw "Missing project validator: $validator"
}

$engine = Get-Command pwsh -ErrorAction SilentlyContinue
if ($null -eq $engine) { $engine = Get-Command powershell -ErrorAction Stop }
$validationOutput = @(& $engine.Source -NoProfile -ExecutionPolicy Bypass -File $validator -Root $rootFull -Quiet 2>&1)
if ($LASTEXITCODE -ne 0) {
    $validationOutput | Select-Object -First 200 | ForEach-Object { [Console]::Error.WriteLine($_) }
    throw 'Resume packet refused because project validation failed.'
}

$stateLines = [System.IO.File]::ReadAllLines($statePath, [System.Text.Encoding]::UTF8)
$contextLines = [System.IO.File]::ReadAllLines($contextPath, [System.Text.Encoding]::UTF8)
$decisionLines = [System.IO.File]::ReadAllLines($decisionsPath, [System.Text.Encoding]::UTF8)
$mapLines = [System.IO.File]::ReadAllLines($mapPath, [System.Text.Encoding]::UTF8)

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

function Test-GitRepository([string]$GitCommand, [string]$Path) {
    $previousPreference = $ErrorActionPreference
    try {
        # Windows PowerShell 5 converts expected native stderr into an error
        # record. A non-repository is a normal probe result, so use the native
        # exit code rather than allowing that record to terminate the packet.
        $ErrorActionPreference = 'SilentlyContinue'
        $probeOutput = @(
            & $GitCommand -C $Path rev-parse --is-inside-work-tree 2>$null
        )
        $probeExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    return $probeExitCode -eq 0 -and
        (($probeOutput -join "`n").Trim() -eq 'true')
}

$packet = [System.Collections.Generic.List[string]]::new()
$packet.Add('# PPS Resume Packet')
$packet.Add('')
$packet.Add('## Hot State')
foreach ($field in @('Protocol', 'Profile', 'Mode', 'Stage', 'Main', 'Map', 'Environment', 'Package', 'Status', 'Capsule', 'Coverage', 'Blockers', 'Next', 'Updated', 'Device')) {
    $value = Get-SectionField $stateLines 'Hot State' $field
    if (-not [string]::IsNullOrWhiteSpace($value)) { $packet.Add("- ${field}: $value") }
}

$packet.Add('')
$packet.Add('## Workset')
foreach ($field in @('Methods', 'Facts', 'Decisions', 'Sources', 'Assets', 'Components', 'Read', 'Write', 'Verify', 'Excluded', 'Coverage')) {
    $value = Get-SectionField $contextLines 'Workset Manifest' $field
    if (-not [string]::IsNullOrWhiteSpace($value)) { $packet.Add("- ${field}: $value") }
}

$packet.Add('')
$packet.Add('## Current Package')
foreach ($field in @('ID', 'Goal', 'Output anchor', 'Allowed change', 'Forbidden change')) {
    $value = Get-SectionField $contextLines 'Current Package' $field
    if (-not [string]::IsNullOrWhiteSpace($value)) { $packet.Add("- ${field}: $value") }
}
$insideNext = $false
foreach ($line in $contextLines) {
    if ($line -match '^## Next Action\s*$') { $insideNext = $true; continue }
    if ($insideNext -and $line -match '^## ') { break }
    if ($insideNext -and -not [string]::IsNullOrWhiteSpace($line)) {
        $packet.Add("- Next action: $line")
        break
    }
}

$packet.Add('')
$packet.Add('## Component Rows')
$components = Get-SectionField $contextLines 'Workset Manifest' 'Components'
if ($components -eq 'none') {
    $packet.Add('- none')
} else {
    foreach ($component in @($components.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
        $row = $mapLines | Where-Object {
            $cells = $_.Split('|')
            $cells.Count -ge 3 -and $cells[1].Trim() -eq $component
        } | Select-Object -First 1
        if ($null -ne $row) { $packet.Add($row) }
    }
}

$packet.Add('')
$packet.Add('## Active Authority Summaries')
$authorityIds = [System.Collections.Generic.List[string]]::new()
foreach ($field in @('Methods', 'Facts', 'Decisions')) {
    $raw = Get-SectionField $contextLines 'Workset Manifest' $field
    if ($raw -ne 'none') {
        @($raw.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }) | ForEach-Object { $authorityIds.Add($_) }
    }
}
if ($authorityIds.Count -eq 0) {
    $packet.Add('- none')
} else {
    foreach ($authorityId in $authorityIds) {
        foreach ($line in $decisionLines) {
            if ($line -match "^### $([regex]::Escape($authorityId))(\s|$)") {
                $packet.Add($line)
                break
            }
        }
    }
}

$packet.Add('')
$packet.Add('## Asset Readiness')
$assetChecker = Join-Path $rootFull 'scripts/asset_check.ps1'
if (Test-Path -LiteralPath $assetChecker -PathType Leaf) {
    $assetOutput = @(
        & $engine.Source -NoProfile -ExecutionPolicy Bypass -File `
            $assetChecker -Root $rootFull -Quick 2>&1
    )
    $assetExit = $LASTEXITCODE
    foreach ($line in @($assetOutput | Select-Object -First 80)) {
        $packet.Add("$line")
    }
    if ($assetExit -ne 0) {
        $packet.Add('Materialization: incomplete; Git synchronization alone is not a complete project handoff.')
    }
} else {
    $packet.Add('Asset checker: unavailable')
}

$packet.Add('')
$packet.Add('## Repository Risk')
$git = Get-Command git -ErrorAction SilentlyContinue
if ($null -ne $git -and (Test-GitRepository $git.Source $rootFull)) {
    $branch = ((& $git.Source -C $rootFull branch --show-current 2>$null) | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($branch)) { $branch = 'detached' }
    $firstChange = ((& $git.Source -C $rootFull status --porcelain --untracked-files=normal 2>$null | Select-Object -First 1) | Out-String).Trim()
    $dirty = if ([string]::IsNullOrWhiteSpace($firstChange)) { 'clean' } else { 'dirty' }
    $packet.Add("- Branch: $branch")
    $packet.Add("- Worktree: $dirty")
} else {
    $packet.Add('- Git: unavailable or not initialized')
}
$packet.Add('- Validation: pass')

if ($packet.Count -gt 240) {
    throw 'Resume packet would exceed the 240-line hard limit; narrow the workset.'
}
$packetBytes = [System.Text.Encoding]::UTF8.GetByteCount(($packet -join [Environment]::NewLine))
if ($packetBytes -gt 32768) {
    throw 'Resume packet would exceed the 32768-byte hard limit; narrow the workset.'
}
$packet
