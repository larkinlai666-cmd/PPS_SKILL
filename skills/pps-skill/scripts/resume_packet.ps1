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
foreach ($field in @('Protocol', 'Profile', 'Mode', 'Stage', 'Main', 'Map', 'Environment', 'Package', 'Status', 'Capsule', 'Coverage', 'Blockers', 'Next', 'Updated', 'Device', 'Writer')) {
    $value = Get-SectionField $stateLines 'Hot State' $field
    if (-not [string]::IsNullOrWhiteSpace($value)) { $packet.Add("- ${field}: $value") }
}

# R1: the packet is the authority after a context reset, so it must carry the
# objective itself — not only the one-line package Goal. Bounded like the red
# lines: truncate on a byte budget rather than dropping the section.
$objectiveBody = [System.Collections.Generic.List[string]]::new()
$insideObjective = $false
foreach ($line in $stateLines) {
    if ($line -match '^##\s+Objective\s*$') { $insideObjective = $true; continue }
    if ($insideObjective -and $line -match '^##\s') { break }
    if ($insideObjective -and -not [string]::IsNullOrWhiteSpace($line)) {
        $objectiveBody.Add($line)
    }
}
if ($objectiveBody.Count -gt 0) {
    $packet.Add('')
    $packet.Add('## Objective')
    $objectiveBudget = 800
    $objectiveUsed = 0
    $objectiveTruncated = $false
    foreach ($line in $objectiveBody) {
        $lineBytes = [System.Text.Encoding]::UTF8.GetByteCount($line) + 1
        if (($objectiveUsed + $lineBytes) -gt $objectiveBudget) {
            $objectiveTruncated = $true
            break
        }
        $packet.Add($line)
        $objectiveUsed += $lineBytes
    }
    if ($objectiveTruncated) {
        $packet.Add('- Objective truncated; read PROJECT_STATE.md for the full statement.')
    }
}

$agentsPath = Join-Path $rootFull 'AGENTS.md'
if (Test-Path -LiteralPath $agentsPath -PathType Leaf) {
    $agentsLines = [System.IO.File]::ReadAllLines($agentsPath, [System.Text.Encoding]::UTF8)
    $redLines = [System.Collections.Generic.List[string]]::new()
    $insideRed = $false
    $insideRedComment = $false
    foreach ($line in $agentsLines) {
        if ($line -match '^##\s+Red Lines\s*$') { $insideRed = $true; continue }
        if ($insideRed -and $line -match '^## ') { break }
        # Take every non-empty line, not only "- " bullets: numbered items and
        # bold headers are red lines too, and dropping them made the packet
        # claim a project had no engineering red lines at all. Skip HTML
        # comments: template guidance is not a red line and must not consume
        # the byte budget.
        if ($insideRed) {
            if ($line -match '<!--') { $insideRedComment = $true }
            if ($line -match '-->') { $insideRedComment = $false; continue }
            if (-not $insideRedComment -and -not [string]::IsNullOrWhiteSpace($line)) {
                $redLines.Add($line)
            }
        }
    }
    if ($redLines.Count -gt 0) {
        $packet.Add('')
        $packet.Add('## Red Lines')
        # Budget by bytes so the shape of the list cannot silently truncate it.
        $redBudget = 1500
        $redUsed = 0
        $redTruncated = $false
        foreach ($line in $redLines) {
            $lineSize = [System.Text.Encoding]::UTF8.GetByteCount($line) + 1
            if (($redUsed + $lineSize) -gt $redBudget) { $redTruncated = $true; break }
            $packet.Add($line)
            $redUsed += $lineSize
        }
        if ($redTruncated) {
            $packet.Add('- Red Lines truncated; read AGENTS.md for the full list.')
        }
    }
}

$eventsPath = Join-Path $rootFull 'EVENTS.md'
if (Test-Path -LiteralPath $eventsPath -PathType Leaf) {
    $eventsLines = [System.IO.File]::ReadAllLines($eventsPath, [System.Text.Encoding]::UTF8)
    $eventEntries = [System.Collections.Generic.List[string]]::new()
    $insideEvents = $false
    foreach ($line in $eventsLines) {
        if ($line -match '^##\s+Events\s*$') { $insideEvents = $true; continue }
        if ($insideEvents -and $line -match '^## ') { $insideEvents = $false; continue }
        if ($insideEvents -and $line.StartsWith('- ')) { $eventEntries.Add($line) }
    }
    $packet.Add('')
    $packet.Add('## Recent Events')
    foreach ($line in @($eventEntries | Select-Object -Last 5)) { $packet.Add($line) }
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
# R1: "done" must survive a context reset. Acceptance is a multi-line sub-list,
# which Get-SectionField cannot see, so a recovered agent used to get Goal
# without ever learning what closes the package. Emit the items verbatim.
$acceptanceItems = [System.Collections.Generic.List[string]]::new()
$insideAcceptancePkg = $false
foreach ($line in $contextLines) {
    if ($line -match '^##\s+Current Package\s*$') { $insideAcceptancePkg = $true; continue }
    if ($insideAcceptancePkg -and $line -match '^##\s') { break }
    if ($insideAcceptancePkg -and $line -match '^\s*-\s*A\d+:') {
        $acceptanceItems.Add($line.Trim())
    }
}
if ($acceptanceItems.Count -gt 0) {
    $packet.Add('- Acceptance:')
    foreach ($item in $acceptanceItems) { $packet.Add("  $item") }
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
$packet.Add('## Handover')
# A single word "dirty" tells the next agent nothing about WHICH files carry
# the previous session's uncommitted work. Name them.
$handoverEntries = @()
$gitProbe = Get-Command git -ErrorAction SilentlyContinue
if ($null -ne $gitProbe -and (Test-GitRepository $gitProbe.Source $rootFull)) {
    $prevEnc = [Console]::OutputEncoding
    try {
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        $rawHandover = ((& $gitProbe.Source -C $rootFull status --porcelain -z --untracked-files=all 2>$null) |
            ForEach-Object { "$_" }) -join "`n"
    } finally {
        [Console]::OutputEncoding = $prevEnc
    }
    $skipNextHandover = $false
    foreach ($entry in $rawHandover.Split([char]0)) {
        if ($skipNextHandover) { $skipNextHandover = $false; continue }
        if ($entry.Length -le 3) { continue }
        $entryStatus = $entry.Substring(0, 2)
        $entryPath = $entry.Substring(3)
        if ($entryStatus -match '^[RC]') { $skipNextHandover = $true }
        $handoverEntries += [pscustomobject]@{ Status = $entryStatus; Path = $entryPath }
    }
}
if ($handoverEntries.Count -eq 0) {
    $packet.Add('- Uncommitted paths: none')
} else {
    $packet.Add("- Uncommitted paths: $($handoverEntries.Count)")
    $shownHandover = 0
    foreach ($entry in $handoverEntries) {
        if ($shownHandover -ge 20) { break }
        $packet.Add("- protected: $($entry.Path) ($($entry.Status))")
        $shownHandover++
    }
    if ($handoverEntries.Count -gt 20) {
        $packet.Add("- protected: ... $($handoverEntries.Count - 20) more")
    }
    $nextValue = Get-SectionField $stateLines 'Hot State' 'Next'
    $declared = @()
    foreach ($entry in $handoverEntries) {
        if ($nextValue -and $nextValue.Contains($entry.Path)) { $declared += $entry.Path }
    }
    if ($declared.Count -gt 0) {
        $packet.Add("- Declared in Next: $($declared -join ', ')")
    } else {
        $packet.Add('- Declared in Next: none')
        $packet.Add('- WARNING: dirty worktree without explicit handover; do not overwrite the paths above wholesale.')
    }
}
$snapshotForPacket = Join-Path $rootFull '.pps/session-snapshot'
if (Test-Path -LiteralPath $snapshotForPacket -PathType Leaf) {
    $snapStarted = 'unknown'
    foreach ($snapLine in [System.IO.File]::ReadAllLines($snapshotForPacket, [System.Text.Encoding]::UTF8)) {
        if ($snapLine -match '^started_at:\s*(.+)$') { $snapStarted = $Matches[1].Trim(); break }
    }
    $packet.Add("- Session snapshot: present ($snapStarted)")
} else {
    $packet.Add('- Relay: SNAPSHOT MISSING; run scripts/session_begin.* before writing.')
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
